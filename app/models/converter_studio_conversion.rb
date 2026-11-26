# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

# One attachment's conversion, from the request to the new attachment (or the reason it failed).
# The table is also the plugin's queue: a row keeps how far its conversion got, so it goes on
# after a restart without a second upload or a second charge, whatever queue adapter runs its job.
#
# queued → uploading → converting → done, or failed at any step; quoted when the price is above
# the most a file may cost on its own, until someone approves it.
#
# Redmine 6.0 and later have ApplicationRecord; 5.x models inherit ActiveRecord::Base directly.
class ConverterStudioConversion < (defined?(ApplicationRecord) ? ApplicationRecord : ActiveRecord::Base)
  STATUSES = %w[queued uploading converting quoted done failed].freeze
  FINISHED = %w[done failed].freeze
  # Those a job is meant to be working on (quoted ones wait for someone's approval).
  ACTIVE = %w[queued uploading converting].freeze
  # A run holds its conversion this long, and renews the hold while it works: a run that stopped
  # (a restart, a crash) lets go of it this long after its last sign of life at most.
  LEASE = 2.minutes
  # A conversion nobody holds whose job should have started this long ago: its job was lost (a
  # restart with Redmine's default in-process queue). RedmineConverterStudio::Recovery runs it again.
  GRACE = 2.minutes
  # Not finished and not touched for this long: "Run again" is offered on the project page.
  STALE_AFTER = 30.minutes
  TARGET = /\A[a-z0-9]{1,16}\z/

  belongs_to :project
  belongs_to :user, optional: true
  belongs_to :attachment, optional: true
  belongs_to :result_attachment, class_name: 'Attachment', optional: true
  belongs_to :rule, class_name: 'ConverterStudioRule', optional: true
  belongs_to :container, polymorphic: true, optional: true

  # Rails 7.1 takes the coder as an option (Redmine 6.0 and later), 6.1 as an argument (Redmine 5.x).
  if ActiveRecord.version >= Gem::Version.new('7.1')
    serialize :options, coder: JSON
  else
    serialize :options, JSON
  end

  validates :target_format, format: { with: TARGET }
  validates :status, inclusion: { in: STATUSES }

  scope :unfinished, -> { where.not(status: FINISHED) }
  scope :recent_first, -> { order(created_on: :desc, id: :desc) }
  # Waiting for a job that is not coming: nobody holds them, and their run is overdue.
  scope :abandoned, lambda { |now = Time.current|
    where(status: ACTIVE).where('locked_until IS NULL OR locked_until < ?', now)
                         .where('run_after IS NULL OR run_after < ?', now - GRACE)
  }

  # Starts converting an attachment: the row, then its job.
  def self.start!(attachment:, user:, target:, options: {}, rule: nil)
    conversion = create!(
      project: attachment.project, attachment: attachment, source_name: attachment.filename.to_s[0, 255],
      container: attachment.container, user: user, rule: rule, target_format: target,
      options: options.presence, status: 'queued', max_credits: RedmineConverterStudio::Configuration.max_credits,
      run_after: Time.current
    )
    conversion.enqueue
    conversion
  end

  # Queues its job, now or after +wait+, and notes when it is due, so a job lost meanwhile is
  # noticed (abandoned).
  def enqueue(wait: nil)
    self.class.where(id: id).update_all(run_after: Time.current + (wait || 0))
    job = wait ? ConverterStudioConvertJob.set(wait: wait) : ConverterStudioConvertJob
    job.perform_later(id)
  end

  # Queues it again when its job was lost, unless another process did just now: false then.
  def requeue_if_abandoned!(now = Time.current)
    taken = self.class.abandoned(now).where(id: id).update_all(run_after: now)
    return false unless taken == 1

    ConverterStudioConvertJob.perform_later(id)
    true
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

  # Its job is gone: not finished, not waiting for an approval, nobody working on it for a while.
  def stale?
    !finished? && !quoted? && updated_on.present? && updated_on < STALE_AFTER.ago &&
      (locked_until.nil? || locked_until < Time.current)
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

  # Takes the conversion for one job run, as +owner+ (a token of that run); false when another
  # run holds it.
  def lease!(seconds = LEASE, owner = SecureRandom.hex(8))
    now = Time.current
    taken = self.class.where(id: id).where('locked_until IS NULL OR locked_until < ?', now)
                .update_all(locked_until: now + seconds, locked_by: owner, updated_on: now)
    reload if taken == 1
    taken == 1
  end

  # Renews the hold of +owner+; false when it lost it (it stopped for longer than its lease and
  # another run took over): that run must then stop without changing anything.
  def extend_lease!(seconds = LEASE, owner = locked_by)
    now = Time.current
    self.class.where(id: id, locked_by: owner).update_all(locked_until: now + seconds, updated_on: now) == 1
  end

  def release!(owner = locked_by)
    self.class.where(id: id, locked_by: owner).update_all(locked_until: nil, locked_by: nil)
  end

  # Ready to run again from the start: a new upload, a new conversion.
  def reset!
    update!(status: 'queued', upload_id: nil, remote_id: nil, credits: nil,
            error_code: nil, error_message: nil, attempts: 0, locked_until: nil, locked_by: nil, finished_on: nil)
  end
end
