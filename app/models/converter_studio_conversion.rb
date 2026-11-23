# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

# One attachment's conversion, from the request to the new attachment (or the reason it failed).
#
# queued → uploading → converting → done, or failed at any step; quoted when the price is above
# the most a file may cost on its own, until someone approves it.
class ConverterStudioConversion < ApplicationRecord
  STATUSES = %w[queued uploading converting quoted done failed].freeze
  FINISHED = %w[done failed].freeze
  # Not finished and not touched for this long: its job was lost (a restart with the default
  # in-process queue). It can be run again. A running job shows a sign of life well within it.
  STALE_AFTER = 30.minutes
  TARGET = /\A[a-z0-9]{1,16}\z/

  belongs_to :project
  belongs_to :user, optional: true
  belongs_to :attachment, optional: true
  belongs_to :result_attachment, class_name: 'Attachment', optional: true
  belongs_to :rule, class_name: 'ConverterStudioRule', optional: true
  belongs_to :container, polymorphic: true, optional: true

  serialize :options, coder: JSON

  validates :target_format, format: { with: TARGET }
  validates :status, inclusion: { in: STATUSES }

  scope :unfinished, -> { where.not(status: FINISHED) }
  scope :recent_first, -> { order(created_on: :desc, id: :desc) }

  # Starts converting an attachment: the row, then its job.
  def self.start!(attachment:, user:, target:, options: {}, rule: nil)
    conversion = create!(
      project: attachment.project, attachment: attachment, source_name: attachment.filename.to_s[0, 255],
      container: attachment.container, user: user, rule: rule, target_format: target,
      options: options.presence, status: 'queued', max_credits: RedmineConverterStudio::Configuration.max_credits
    )
    conversion.enqueue
    conversion
  end

  def enqueue
    ConverterStudioConvertJob.perform_later(id)
  end

  def finished?
    FINISHED.include?(status)
  end

  def done?
    status == 'done'
  end

  def failed?
    status == 'failed'
  end

  def quoted?
    status == 'quoted'
  end

  # Its job is gone: not finished, not waiting for an approval, untouched for a while.
  def stale?
    !finished? && !quoted? && updated_on.present? && updated_on < STALE_AFTER.ago
  end

  def retryable?
    failed? || stale?
  end

  # Who may see it: those who see its file (or saw it, when it was deleted since: its requester).
  def visible?(user = User.current)
    return attachment.visible?(user) if attachment

    user.logged? && user_id == user.id
  end

  def options_hash
    options.is_a?(Hash) ? options : {}
  end

  def ocr?
    options_hash['ocr'] == true
  end

  # The idempotency key of its POST /v1/conversions: the same for every retry of one upload.
  def idempotency_key
    "redmine-#{id}-#{upload_id}"
  end

  # Takes the conversion for one job run; false when another run has it.
  def lease!(seconds)
    now = Time.current
    taken = self.class.where(id: id).where('locked_until IS NULL OR locked_until < ?', now)
                .update_all(locked_until: now + seconds, updated_on: now)
    reload if taken == 1
    taken == 1
  end

  def extend_lease!(seconds)
    self.class.where(id: id).update_all(locked_until: Time.current + seconds, updated_on: Time.current)
  end

  def release!
    self.class.where(id: id).update_all(locked_until: nil)
  end

  # Ready to run again from the start: a new upload, a new conversion.
  def reset!
    update!(status: 'queued', upload_id: nil, remote_id: nil, credits: nil,
            error_code: nil, error_message: nil, attempts: 0, locked_until: nil, finished_on: nil)
  end
end
