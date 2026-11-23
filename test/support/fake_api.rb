# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

require 'json'
require 'puma'
require 'puma/log_writer'
require 'securerandom'

# A small stand-in for the converter.studio API (the parts the plugin uses), served over real HTTP
# by Puma (in Redmine's test gems) on 127.0.0.1, so the client is tested on the wire. What it
# does depends on the file's name: "damaged" fails, "expensive" costs 45 credits (above the
# default limit), "slow" needs a few status requests. The result is "converted:" + the file.
class FakeConverterStudioApi
  KEY = 'cvs_live_test0123456789abcdefghijklmnopqrstuv'
  FORMATS = [
    { 'id' => 'docx', 'name' => 'Word', 'category' => 'document', 'extensions' => %w[docx], 'to' => %w[pdf txt odt] },
    { 'id' => 'txt', 'name' => 'Text', 'category' => 'document', 'extensions' => %w[txt], 'to' => %w[pdf docx] },
    { 'id' => 'pdf', 'name' => 'PDF', 'category' => 'document', 'extensions' => %w[pdf], 'to' => %w[jpg pdf docx txt] },
    { 'id' => 'heic', 'name' => 'HEIC', 'category' => 'image', 'extensions' => %w[heic heif], 'to' => %w[jpg png pdf txt] },
    { 'id' => 'png', 'name' => 'PNG', 'category' => 'image', 'extensions' => %w[png], 'to' => %w[jpg webp txt] },
    { 'id' => 'mov', 'name' => 'QuickTime', 'category' => 'video', 'extensions' => %w[mov], 'to' => %w[mp4 mp3] },
    { 'id' => 'tgz', 'name' => 'TAR.GZ', 'category' => 'archive', 'extensions' => %w[tar.gz tgz], 'to' => %w[zip] }
  ].freeze
  NAMES = { 'pdf' => 'PDF', 'jpg' => 'JPG', 'txt' => 'Text', 'mp4' => 'MP4', 'docx' => 'Word' }.freeze

  attr_reader :requests, :uploads, :conversions
  attr_accessor :part_bytes, :result_bytes

  def self.instance
    @instance ||= new.tap(&:start)
  end

  def start
    reset
    @server = Puma::Server.new(self, nil, min_threads: 0, max_threads: 4, log_writer: Puma::LogWriter.null)
    @server.add_tcp_listener('127.0.0.1', 0)
    @port = @server.connected_ports.first
    @server.run
  end

  def base_url
    "http://127.0.0.1:#{@port}"
  end

  def reset
    @lock = Mutex.new
    @requests = []
    @uploads = {}
    @conversions = {}
    @idempotency = {}
    @part_bytes = 95_000_000
    @result_bytes = nil
  end

  def call(env)
    request = Rack::Request.new(env)
    body = request.body&.read.to_s
    @lock.synchronize do
      @requests << {
        method: request.request_method, path: request.path, query: request.query_string,
        authorization: env['HTTP_AUTHORIZATION'], client: env['HTTP_X_CONVERTER_STUDIO_CLIENT'],
        user_agent: env['HTTP_USER_AGENT'], idempotency_key: env['HTTP_IDEMPOTENCY_KEY'],
        offset: env['HTTP_UPLOAD_OFFSET'], bytes: body.bytesize
      }
      route(request, env, body)
    end
  end

  def requests_to(method, prefix)
    requests.select { |r| r[:method] == method && r[:path].start_with?(prefix) }
  end

  private

  def route(request, env, body)
    route = "#{request.request_method} #{request.path}"
    id = route[%r{\A\w+ /(?:v1/uploads|v1/conversions|jobs)/([\w-]+)}, 1]
    case route
    when 'GET /v1/formats' then json(200, 'formats' => FORMATS)
    when 'GET /v1/account' then authorized(env) { json(200, account) }
    when 'POST /v1/uploads' then authorized(env) { create_upload(JSON.parse(body)) }
    when %r{\APUT /v1/uploads/[\w-]+\z} then receive_upload(id, request, env, body)
    when 'POST /v1/conversions' then authorized(env) { convert(JSON.parse(body), env['HTTP_IDEMPOTENCY_KEY']) }
    when %r{\AGET /v1/conversions/[\w-]+\z} then authorized(env) { status(id) }
    when %r{\APOST /v1/conversions/[\w-]+/confirm\z} then authorized(env) { confirm(id) }
    when %r{\AGET /jobs/[\w-]+/download\z} then download(id, request)
    when 'GET /redirect' then [302, { 'location' => "#{base_url}/v1/account" }, []]
    else json(404, error('notFound', 'Not found.'))
    end
  end

  def authorized(env)
    return json(401, error('invalidApiKey', 'This API key does not work. Check it on your account page.')) unless env['HTTP_AUTHORIZATION'] == "Bearer #{KEY}"

    yield
  end

  def account
    { 'email' => 'owner@example.com', 'plan' => 'pro', 'credits' => 480, 'maxFileBytes' => 100_000_000 }
  end

  def create_upload(data)
    id = "up_#{SecureRandom.hex(6)}"
    @uploads[id] = { name: data['fileName'], size: data['size'], bytes: +'', token: SecureRandom.hex(4) }
    json(201, 'id' => id, 'uploadUrl' => "#{base_url}/v1/uploads/#{id}?token=#{@uploads[id][:token]}",
              'method' => 'PUT', 'partBytes' => @part_bytes)
  end

  def receive_upload(id, request, env, body)
    upload = @uploads[id]
    return json(404, error('notFound', 'Not found.')) unless upload && request.params['token'] == upload[:token]

    offset = env['HTTP_UPLOAD_OFFSET']
    if offset && offset.to_i != upload[:bytes].bytesize
      return json(409, error('invalidRequest', 'Wrong offset.').tap { |e| e['error']['params'] = { 'received' => upload[:bytes].bytesize } })
    end

    upload[:bytes] << body
    return json(200, 'id' => id, 'status' => 'partial', 'received' => upload[:bytes].bytesize) if upload[:bytes].bytesize < upload[:size].to_i

    json(200, 'id' => id, 'status' => 'ready', 'file' => { 'name' => upload[:name], 'size' => upload[:bytes].bytesize })
  end

  def convert(data, key)
    if key && (id = @idempotency[key])
      return json(200, view(id))
    end

    upload = @uploads[data['uploadId']]
    return json(404, error('notFound', 'Not found.')) unless upload

    if upload[:bytes].bytesize < upload[:size].to_i
      body = error('invalidRequest', 'The file has not been uploaded yet.')
      body['error']['params'] = { 'status' => 'waiting_for_upload' }
      return json(409, body)
    end

    @uploads.delete(data['uploadId'])

    id = data['uploadId']
    name = upload[:name]
    credits = name.include?('expensive') ? 45 : 1
    max = data.key?('maxCredits') ? data['maxCredits'] : 20
    @conversions[id] = {
      name: name, to: data['to'], options: data['options'], bytes: upload[:bytes], credits: credits,
      status: credits > max ? 'quoted' : 'processing', polls: name.include?('slow') ? 3 : 1, max: max
    }
    @idempotency[key] = id if key
    json(201, view(id))
  end

  def status(id)
    conversion = @conversions[id]
    return json(404, error('notFound', 'Not found.')) unless conversion

    if conversion[:status] == 'processing'
      conversion[:polls] -= 1
      conversion[:status] = conversion[:name].include?('damaged') ? 'failed' : 'done' if conversion[:polls] <= 0
    end
    json(200, view(id))
  end

  def confirm(id)
    conversion = @conversions[id]
    return json(404, error('notFound', 'Not found.')) unless conversion

    conversion[:status] = 'processing' if conversion[:status] == 'quoted'
    json(200, view(id))
  end

  def download(id, request)
    conversion = @conversions[id]
    return json(404, error('notFound', 'Not found.')) unless conversion && request.params['token'] == "t#{id}"

    bytes = @result_bytes || "converted:#{conversion[:bytes]}"
    [200, { 'content-type' => 'application/octet-stream', 'content-length' => bytes.bytesize.to_s }, [bytes]]
  end

  def view(id)
    c = @conversions[id]
    done = c[:status] == 'done'
    output = "#{File.basename(c[:name], '.*')}.#{c[:to]}"
    {
      'id' => id, 'status' => c[:status], 'to' => c[:to], 'inputName' => c[:name], 'credits' => c[:credits],
      'maxCredits' => c[:max], 'outputName' => done ? output : nil,
      'downloadUrl' => done ? "#{base_url}/jobs/#{id}/download?token=t#{id}" : nil,
      'error' => c[:status] == 'failed' ? error('damagedFile', 'This file is damaged or is not a DOCX file.')['error'] : nil,
      'next' => c[:status] == 'quoted' ? "This conversion costs #{c[:credits]} credits, more than the #{c[:max]} allowed to go ahead on their own. Confirm it to start, or leave it." : nil
    }
  end

  def error(code, message)
    { 'error' => { 'code' => code, 'message' => message } }
  end

  def json(status, data)
    [status, { 'content-type' => 'application/json' }, [JSON.generate(data)]]
  end
end
