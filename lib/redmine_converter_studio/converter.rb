# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

module RedmineConverterStudio
  # Runs one conversion, as far as it can go in one job run: uploads the attachment, starts the
  # conversion, waits for it (long polling), then adds the result to the same issue, wiki page or
  # document, with a journal entry on an issue. Every step is saved, so a run that stops (a
  # restart, a lost answer) goes on where it was without a second upload or a second charge.
  #
  # A run holds the conversion (ConverterStudioConversion#lease!) and renews its hold at least
  # every BEAT, during uploads and downloads too. Before it starts a conversion (the charge) and
  # before it writes the result, it renews the hold or, when another run took over meanwhile (this
  # one stalled for longer than the lease), stops without a charge or a change.
  class Converter
    include Redmine::I18n

    # Seconds one status request waits on converter.studio's side.
    POLL_WAIT = 25
    # How long one job run waits before it hands over to a new run (when the queue can schedule).
    STEP = 2.minutes
    # How long a conversion may take in all, from its request.
    DEADLINE = 3.hours
    # A run holds the conversion this long without a sign of life at most, and renews its hold at
    # least this often while it works (one API request takes a minute at most; a transfer renews it
    # as its bytes go).
    LEASE = ConverterStudioConversion::LEASE
    BEAT = 20.seconds
    # Transient errors (the network, a busy server) are tried again this many times.
    MAX_ATTEMPTS = 5

    # This run lost its hold: it stopped for longer than LEASE and another run took over.
    class LeaseLost < StandardError; end

    attr_reader :conversion

    # +hand_over+: false to keep waiting in this process instead of scheduling a new job run (a
    # rake task, whose process ends with it).
    def initialize(conversion, client: nil, hand_over: true)
      @conversion = conversion
      @client = client
      @hand_over = hand_over
      @owner = SecureRandom.hex(8)
    end

    def run
      return if conversion.finished? || conversion.quoted?
      return unless conversion.lease!(LEASE.to_i, @owner)

      @held_at = Time.current
      begin
        work
      ensure
        conversion.release!(@owner)
      end
    end

    private

    def work
      check!
      start! if conversion.remote_id.blank?
      wait!
    rescue LeaseLost
      taken_over
    rescue ApiError => e
      return unless held?

      e.transient? ? try_later(e) : fail!(e.code, message_for(e))
    rescue StandardError => e
      Rails.logger.error("Converter Studio: conversion #{conversion.id} stopped: #{e.class}")
      fail!('unexpected') if held?
    end

    # Renews the hold, or stops the run (LeaseLost) when another run has the conversion now.
    def hold!
      raise LeaseLost unless conversion.extend_lease!(LEASE.to_i, @owner)

      @held_at = Time.current
    end

    # Whether the conversion is still this run's (renewing the hold).
    def held?
      hold!
      true
    rescue LeaseLost
      taken_over
      false
    end

    # A sign of life during a long upload or download: the hold is renewed every BEAT.
    def beat
      hold! if Time.current - @held_at >= BEAT
    end

    def taken_over
      Rails.logger.warn("Converter Studio: conversion #{conversion.id} was taken over by another run; this one stops.")
    end

    def client
      @client ||= Client.from_settings
    end

    def check!
      raise ApiError.new('moduleDisabled', '') unless Access.enabled?(conversion.project)
      raise ApiError.new('notConfigured', '') unless Configuration.configured?

      source = conversion.attachment
      raise ApiError.new('sourceMissing', '') unless source&.readable? && source.container.present?
      return if catalog.empty? || catalog.convertible?(source.filename, conversion.target_format)

      raise ApiError.new('unsupportedConversion', '')
    end

    def catalog
      @catalog ||= Catalog.load(client)
    end

    # Upload, then POST /v1/conversions with an idempotency key tied to that upload. An upload that
    # is gone (it expired before its conversion started) or never finished (a run stopped while it
    # sent the file) is made once more.
    def start!
      upload! if conversion.upload_id.blank?
      view = begin_conversion
      if view.nil?
        upload!
        view = begin_conversion
        raise ApiError.new('uploadFailed', '') if view.nil?
      end
      remember(view)
    end

    def upload!
      source = conversion.attachment
      conversion.update!(status: 'uploading')
      upload = client.create_upload(source.filename, source.filesize)
      conversion.update!(upload_id: upload['id'])
      File.open(source.diskfile, 'rb') { |io| client.send_file(upload, io, source.filesize) { beat } }
    end

    # The conversion's view, or nil when its upload is gone or incomplete.
    def begin_conversion
      hold!
      client.start_conversion(upload_id: conversion.upload_id, to: conversion.target_format,
                              options: conversion.options_hash, max_credits: conversion.max_credits.to_i,
                              idempotency_key: conversion.idempotency_key)
    rescue ApiError => e
      raise unless e.code == 'notFound' || (e.status == 409 && e.params['status'] == 'waiting_for_upload')

      conversion.update!(upload_id: nil)
      nil
    end

    def wait!
      step_ends = Time.current + STEP
      loop do
        view = client.conversion(conversion.remote_id, wait: POLL_WAIT)
        remember(view)
        case view['status']
        when 'done' then return finish!(view)
        when 'failed' then return fail_from_api!(view)
        when 'quoted' then return quoted!(view)
        when 'canceled' then return fail!('canceled')
        when 'expired' then return fail!('fileExpired')
        end
        return fail!('timedOut') if conversion.created_on < DEADLINE.ago
        return if Time.current > step_ends && schedule(10.seconds)

        hold!
      end
    end

    def remember(view)
      id = view['id'].to_s
      changes = {}
      changes[:remote_id] = id if id.match?(Client::CONVERSION_ID) && conversion.remote_id != id
      changes[:credits] = view['credits'] if view['credits'].is_a?(Integer) && conversion.credits != view['credits']
      changes[:status] = 'converting' unless conversion.status == 'converting'
      conversion.update!(changes) if changes.any?
    end

    def quoted!(view)
      conversion.update!(status: 'quoted', error_code: nil, error_message: view['next'].to_s[0, 500].presence)
    end

    def finish!(view)
      source = conversion.attachment
      hold!
      file = client.download(view['downloadUrl'].to_s, max_attachment_bytes) { beat }
      begin
        hold!
        attach!(source, file, result_name(view, source))
      ensure
        file.close!
      end
    end

    def attach!(source, file, name)
      container = source.container
      user = conversion.user || User.anonymous
      attachment = Attachment.new(file: file, author: user)
      attachment.filename = name
      attachment.content_type = Redmine::MimeType.of(name).presence || 'application/octet-stream'
      attachment.description = ll(language, :converter_studio_text_result_description, source: source.filename)[0, 255]
      attachment.container = container
      attachment.converter_studio_result = true
      Attachment.transaction do
        raise ApiError.new('attachmentRejected', attachment.errors.full_messages.join(' ')) unless attachment.save

        journal!(container, user, :converter_studio_text_journal_done, attachment: attachment)
        conversion.update!(status: 'done', result_attachment_id: attachment.id, finished_on: Time.current,
                           error_code: nil, error_message: nil)
      end
    end

    def fail_from_api!(view)
      error = view['error'].is_a?(Hash) ? view['error'] : {}
      code = error['code'].to_s.match?(ApiError::CODE) ? error['code'] : 'conversionFailed'
      fail!(code, error['message'].to_s.presence)
    end

    # Marks it failed with the reason, and says so on its issue.
    def fail!(code, message = nil)
      message = message.to_s.presence || message_for(ApiError.new(code, ''))
      conversion.update!(status: 'failed', error_code: code, error_message: message[0, 500], finished_on: Time.current)
      container = conversion.container
      return unless container.is_a?(Issue)

      journal!(container, conversion.user || User.anonymous, :converter_studio_text_journal_failed, reason: message)
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.error("Converter Studio: conversion #{conversion.id} could not be marked failed: #{e.class}")
    end

    # Network trouble or a busy server: tried again later, a few times, then a failure.
    def try_later(error)
      attempts = conversion.attempts + 1
      conversion.update!(attempts: attempts)
      return if attempts < MAX_ATTEMPTS && schedule((30 * (2**attempts)).seconds)

      fail!(error.code, message_for(error))
    end

    # Hands the rest to a new job run; false when the queue cannot schedule (the inline adapter).
    def schedule(wait)
      return false unless @hand_over

      conversion.enqueue(wait: wait)
      true
    rescue NotImplementedError
      false
    end

    # A journal entry on an issue (wiki pages and documents have none): who, what, the new file.
    def journal!(container, user, key, attachment: nil, reason: nil)
      return unless container.is_a?(Issue)

      notes = ll(language, key, source: conversion.source_name, target: format_name,
                                credits: conversion.credits.to_i, reason: reason)
      journal = Journal.new(journalized: container, user: user, notes: notes)
      journal.journalize_attachment(attachment, :added) if attachment
      journal.save!
    end

    def result_name(view, source)
      name = view['outputName'].present? ? Client.safe_name(view['outputName']) : nil
      name ||= "#{File.basename(source.filename.to_s, '.*')}.#{conversion.target_format}"
      name.length > 255 ? name[-255, 255] : name
    end

    def format_name
      @format_name ||= begin
        catalog.name_of(conversion.target_format)
      rescue ApiError
        conversion.target_format.upcase
      end
    end

    def max_attachment_bytes
      Setting.attachment_max_size.to_i * 1024
    end

    # Our own failures are said in Redmine's language; the API's come in its own words.
    def message_for(error)
      key = :"converter_studio_error_#{error.code}"
      if ::I18n.exists?(key, :en)
        ll(language, key, max: ActiveSupport::NumberHelper.number_to_human_size(max_attachment_bytes),
                          reason: error.message)
      else
        error.message.presence || ll(language, :converter_studio_error_unexpected)
      end
    end

    def language
      Setting.default_language.presence || 'en'
    end
  end
end
