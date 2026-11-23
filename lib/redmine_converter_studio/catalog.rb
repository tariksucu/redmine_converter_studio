# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

module RedmineConverterStudio
  # What converter.studio converts right now (GET /v1/formats), by file name: the formats a file
  # can become, their names, and whether a target reads text (OCR). Kept for an hour in each
  # process and in Rails' cache (which some setups switch off), so pages do not call the API.
  class Catalog
    CACHE_TTL = 1.hour
    # After a failure, pages do not ask again for this long (they must not wait on the API).
    FAILURE_TTL = 5.minutes
    QUICK_TIMEOUT = 5
    TEXT_TARGETS = %w[txt docx].freeze
    MEMO = {}
    LOCK = Mutex.new

    # Raises ApiError when the list cannot be loaded. +quick+: for a page being shown, with a
    # short timeout, and not at all for a while after a failure.
    def self.load(client = Client.from_settings, quick: false)
      now = Time.current
      memo = LOCK.synchronize { MEMO[client.base_url] }
      return new(memo[:list]) if memo && memo[:list] && memo[:until] > now
      raise ApiError.new(memo[:code], memo[:message]) if quick && memo && memo[:failed_until].to_i > now.to_i

      list = Rails.cache.fetch(['converter_studio', 'formats', client.base_url], expires_in: CACHE_TTL) do
        client.formats(timeout: quick ? QUICK_TIMEOUT : Client::TIMEOUT)
      end
      LOCK.synchronize { MEMO[client.base_url] = { list: list, until: now + CACHE_TTL } }
      new(list)
    rescue ApiError => e
      LOCK.synchronize { MEMO[client.base_url] = { failed_until: now + FAILURE_TTL, code: e.code, message: e.message } }
      raise
    end

    def self.forget
      LOCK.synchronize { MEMO.clear }
    end

    def initialize(list)
      @formats = {}
      @extensions = {}
      list.each do |entry|
        id = entry['id'].to_s
        next unless id.match?(/\A[a-z0-9]{1,16}\z/)

        @formats[id] = {
          name: entry['name'].to_s.presence || id.upcase,
          category: entry['category'].to_s,
          to: Array(entry['to']).map(&:to_s).grep(/\A[a-z0-9]{1,16}\z/)
        }
        Array(entry['extensions']).each { |ext| @extensions[ext.to_s.downcase.delete_prefix('.')] ||= id }
        @extensions[id] ||= id
      end
    end

    def empty?
      @formats.empty?
    end

    # A file's format, from its name's extension ("tar.gz" before "gz"); nil when unknown.
    def format_of(filename)
      parts = filename.to_s.downcase.split('.')
      return nil if parts.length < 2

      [parts.last(2).join('.'), parts.last].each do |ext|
        return @extensions[ext] if @extensions.key?(ext)
      end
      nil
    end

    def extension?(extension)
      @extensions.key?(extension.to_s.downcase.delete_prefix('.'))
    end

    def format_of_extension(extension)
      @extensions[extension.to_s.downcase.delete_prefix('.')]
    end

    # The formats a file can become, most popular first (the API's order).
    def targets_for(filename)
      source = format_of(filename)
      source ? @formats.dig(source, :to) || [] : []
    end

    def convertible?(filename, target)
      targets_for(filename).include?(target.to_s)
    end

    # Every format some file can become, by name.
    def all_targets
      @formats.values.flat_map { |f| f[:to] }.uniq.sort_by { |id| name_of(id).downcase }
    end

    def name_of(id)
      @formats.dig(id.to_s, :name) || id.to_s.upcase
    end

    def category_of(id)
      @formats.dig(id.to_s, :category)
    end

    # A picture's text (OCR) is what a text target means for an image.
    def ocr_target?(filename, target)
      category_of(format_of(filename)) == 'image' && TEXT_TARGETS.include?(target.to_s)
    end

    # A PDF can be read as it is or, for scans, with text recognition (the "ocr" option).
    def ocr_option?(filename, target)
      format_of(filename) == 'pdf' && TEXT_TARGETS.include?(target.to_s)
    end
  end
end
