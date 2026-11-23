# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

require 'json'
require 'net/http'
require 'tempfile'

module RedmineConverterStudio
  # The converter.studio REST API (https://converter.studio/developers), as this plugin uses it:
  # upload slots (filled in parts for large files), conversions, their results, the account and
  # the formats.
  #
  # Calls that spend credits carry the API key. Upload parts and result downloads carry only the
  # token in their own address. Nothing about the Redmine server or its users is sent, except the
  # files being converted and their names. Redirects are never followed.
  class Client
    CLIENT_HEADER = 'X-Converter-Studio-Client'
    OPEN_TIMEOUT = 10
    TIMEOUT = 30
    TRANSFER_TIMEOUT = 600
    # One request carries at most this much of a file (Cloudflare passes 100 MB a request).
    PART_BYTES = 95_000_000
    UPLOAD_ID = /\A[A-Za-z0-9_-]{8,128}\z/
    CONVERSION_ID = /\A[A-Za-z0-9_-]{8,128}\z/
    NETWORK_ERRORS = [
      SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError,
      Net::HTTPBadResponse, Net::ProtocolError, Zlib::Error
    ].freeze

    def self.from_settings
      new(base_url: Configuration.base_url, api_key: Configuration.api_key)
    end

    attr_reader :base_url

    def initialize(base_url:, api_key:)
      @base_url = base_url.to_s.strip.delete_suffix('/')
      @base = URI.parse(@base_url)
      raise ArgumentError unless @base.is_a?(URI::HTTP) && @base.host.present? && @base.userinfo.nil?

      @api_key = api_key.to_s.strip
    rescue URI::InvalidURIError, ArgumentError
      raise ApiError.new('invalidBaseUrl', 'The Converter Studio API address in the settings is not a web address.')
    end

    # Never shows the key (exceptions and logs print objects with inspect).
    def inspect
      "#<#{self.class.name} #{@base_url}>"
    end

    # The key's account: email, plan, credits, maxFileBytes…
    def account(timeout: TIMEOUT)
      json(:get, '/v1/account', timeout: timeout)
    end

    # What the server converts right now (no key needed).
    def formats(timeout: TIMEOUT)
      list = json(:get, '/v1/formats', auth: false, timeout: timeout)['formats']
      list.is_a?(Array) ? list.grep(Hash) : []
    end

    # Opens an upload slot for a file of +size+ bytes: { 'id', 'url', 'part_bytes' }.
    def create_upload(file_name, size)
      body = json(:post, '/v1/uploads', body: { fileName: self.class.safe_name(file_name), size: size })
      id = body['id']
      url = body['uploadUrl']
      raise unexpected unless id.is_a?(String) && id.match?(UPLOAD_ID) && url.is_a?(String) && api_address?(url)

      part = body['partBytes'].is_a?(Integer) && body['partBytes'].positive? ? body['partBytes'] : PART_BYTES
      { 'id' => id, 'url' => url, 'part_bytes' => [part, PART_BYTES].min }
    end

    # Sends the file to its upload slot: in one request, or in parts (Upload-Offset) when it is
    # larger than one request may carry. Returns the API's answer for the complete file.
    def send_file(upload, io, size)
      in_parts = size > upload['part_bytes']
      offset = 0
      ((size / upload['part_bytes']) + 5).times do
        length = in_parts ? [upload['part_bytes'], size - offset].min : size
        io.seek(offset)
        headers = { 'Content-Type' => 'application/octet-stream' }
        headers['Upload-Offset'] = offset.to_s if in_parts
        response = request(:put, upload['url'], auth: false, headers: headers,
                                                stream: PartReader.new(io, length), length: length,
                                                timeout: TRANSFER_TIMEOUT)
        status = response.code.to_i
        data = decode(response)
        received = data.dig('error', 'params', 'received')
        if status == 409 && received.is_a?(Integer)
          offset = received.clamp(0, size)
          next
        end
        raise error(status, data) if status >= 400
        return data if data['status'] == 'ready'

        offset = data['received'].is_a?(Integer) ? data['received'] : offset + length
        raise unexpected if offset >= size
      end
      raise unexpected
    end

    # Starts converting an upload. The idempotency key makes a repeated request (after a lost
    # answer) return the first conversion instead of starting and charging a second one.
    def start_conversion(upload_id:, to:, max_credits:, idempotency_key:, options: {})
      body = { uploadId: upload_id, to: to, maxCredits: max_credits }
      body[:options] = options if options.present?
      json(:post, '/v1/conversions', body: body, headers: { 'Idempotency-Key' => idempotency_key })
    end

    # A conversion's state, waiting up to +wait+ seconds (at most 60) for it to settle.
    def conversion(id, wait: 0)
      wait = wait.to_i.clamp(0, 60)
      path = "/v1/conversions/#{conversion_id(id)}"
      path += "?wait=#{wait}" if wait.positive?
      json(:get, path, timeout: TIMEOUT + wait)
    end

    # Goes ahead with a conversion whose price was above maxCredits.
    def confirm(id)
      json(:post, "/v1/conversions/#{conversion_id(id)}/confirm", body: {})
    end

    # Downloads a result into a Tempfile (rewound): only from the API's own address, without
    # redirects, and never more than +max_bytes+.
    def download(url, max_bytes)
      raise ApiError.new('downloadFailed', 'converter.studio sent an unexpected download address.') unless api_address?(url)

      file = Tempfile.new('converter-studio', binmode: true)
      uri = URI.parse(url)
      get = Net::HTTP::Get.new(uri)
      headers(false).each { |name, value| get[name] = value }
      connection(uri, TRANSFER_TIMEOUT).start do |http|
        http.request(get) do |response|
          status = response.code.to_i
          unless status == 200
            raise ApiError.new(status == 410 ? 'fileExpired' : 'downloadFailed',
                               'The converted file could not be downloaded from converter.studio.', status: status)
          end
          raise too_large(max_bytes) if response['Content-Length'].to_i > max_bytes

          size = 0
          response.read_body do |chunk|
            size += chunk.bytesize
            raise too_large(max_bytes) if size > max_bytes

            file.write(chunk)
          end
        end
      end
      file.flush
      raise ApiError.new('downloadFailed', 'The converted file could not be downloaded from converter.studio.') if File.empty?(file.path)

      file.rewind
      file
    rescue *NETWORK_ERRORS
      file&.close!
      raise ApiError.new('downloadFailed', 'The converted file could not be downloaded from converter.studio.')
    rescue StandardError
      file&.close!
      raise
    end

    # Whether an address is on the API's own scheme, host and port.
    def api_address?(url)
      uri = URI.parse(url.to_s)
      uri.is_a?(URI::HTTP) && uri.userinfo.nil? &&
        uri.scheme.casecmp?(@base.scheme) && uri.host.to_s.casecmp?(@base.host.to_s) && uri.port == @base.port
    rescue URI::InvalidURIError
      false
    end

    # The file name the API sees: it reads the format from the extension.
    def self.safe_name(name)
      clean = name.to_s.delete("\0").tr('/\\', '').strip
      clean = 'file' if clean.empty?
      clean.length > 200 ? clean[-200..] : clean
    end

    # Reads at most +length+ bytes of an IO, for one request's body.
    class PartReader
      def initialize(io, length)
        @io = io
        @left = length
      end

      def read(length = nil, buffer = nil)
        if @left <= 0
          buffer&.clear
          return length.nil? ? +'' : nil
        end
        length = length.nil? ? @left : [length, @left].min
        data = @io.read(length, buffer)
        @left -= data.bytesize if data
        data
      end
    end

    private

    def json(method, path, auth: true, body: nil, headers: {}, timeout: TIMEOUT)
      response = request(method, path, auth: auth, body: body, headers: headers, timeout: timeout)
      status = response.code.to_i
      data = decode(response)
      raise error(status, data) if status >= 400
      raise unexpected(status) if data.empty? || status >= 300

      data
    end

    def request(method, target, auth:, headers: {}, body: nil, stream: nil, length: nil, timeout: TIMEOUT)
      if auth && @api_key.blank?
        raise ApiError.new('notConfigured', 'No Converter Studio API key is set in the plugin settings.')
      end

      uri = target.start_with?('http') ? URI.parse(target) : URI.parse(@base_url + target)
      req = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put }.fetch(method).new(uri)
      headers(auth).merge('Accept' => 'application/json').merge(headers).each { |name, value| req[name] = value }
      if stream
        req.body_stream = stream
        req['Content-Length'] = length.to_s
      elsif body
        req.body = JSON.generate(body)
        req['Content-Type'] = 'application/json'
      end
      connection(uri, timeout).start { |http| http.request(req) }
    rescue *NETWORK_ERRORS
      # The exception's message may hold the request; the key must not reach a log.
      raise ApiError.new('network', 'converter.studio could not be reached. Try again in a few minutes.')
    end

    def connection(uri, timeout)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = [OPEN_TIMEOUT, timeout].min
      http.read_timeout = timeout
      http.write_timeout = timeout
      http
    end

    def headers(auth)
      redmine = [Redmine::VERSION::MAJOR, Redmine::VERSION::MINOR, Redmine::VERSION::TINY].join('.')
      list = {
        'User-Agent' => "redmine_converter_studio/#{VERSION} Redmine/#{redmine} Ruby/#{RUBY_VERSION}",
        CLIENT_HEADER => "#{CLIENT_NAME}/#{VERSION}"
      }
      list['Authorization'] = "Bearer #{@api_key}" if auth
      list
    end

    def decode(response)
      data = JSON.parse(response.body.to_s, max_nesting: 32)
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError
      {}
    end

    def error(status, data)
      error = data['error'].is_a?(Hash) ? data['error'] : {}
      code = error['code'].is_a?(String) && error['code'].match?(ApiError::CODE) ? error['code'] : "http_#{status}"
      message = error['message'].is_a?(String) && error['message'].present? ? error['message'][0, 500] : nil
      message ||= "converter.studio answered with an error (HTTP #{status})."
      params = (error['params'].is_a?(Hash) ? error['params'] : {}).select do |name, value|
        name.is_a?(String) && (value.is_a?(String) || value.is_a?(Numeric))
      end
      ApiError.new(code, message, status: status, params: params)
    end

    def unexpected(status = nil)
      ApiError.new('unexpected', 'converter.studio sent an answer this plugin does not understand.', status: status)
    end

    def too_large(max_bytes)
      ApiError.new('resultTooLarge', 'The converted file is larger than Redmine accepts.',
                   params: { 'maxBytes' => max_bytes })
    end

    def conversion_id(id)
      raise unexpected unless id.to_s.match?(CONVERSION_ID)

      id
    end
  end
end
