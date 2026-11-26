# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

module RedmineConverterStudio
  # Picks up the conversions whose job was lost. Redmine's default Active Job adapter (async) keeps
  # jobs in the memory of the Redmine process that queued them, so a restart (a deploy, a crash, an
  # update) loses the conversions it was running or about to run; their rows keep how far they got.
  #
  # After the requests a Redmine process serves (ControllerPatch), at most once a minute, this looks
  # for such conversions (ConverterStudioConversion.abandoned) and queues them again in that process.
  # Each one goes on where it stopped: a conversion already started at Converter Studio is waited
  # for, never started or paid for again. Several processes may look at once: a conversion is queued
  # again by one of them, and run by one job at a time.
  #
  # Adapters that keep their jobs over a restart (Sidekiq, Solid Queue, GoodJob…) are left alone;
  # `rake redmine:converter_studio:resume` is there for a job they lost (a worker killed mid-run).
  module Recovery
    INTERVAL = 1.minute
    # The most conversions queued again at once (the next look takes the rest).
    BATCH = 50
    # Adapters whose jobs live in the memory of the web process.
    IN_PROCESS = %w[async].freeze
    LOCK = Mutex.new
    # When this process looks next.
    STATE = { next_at: nil }

    module_function

    # Looks for lost conversions when it is time to (once a minute in each process) and queues them
    # again. Returns how many; never raises (it runs after a request).
    def poke(now = Time.current)
      return 0 unless in_process_queue? && due?(now)

      resume(now)
    rescue StandardError => e
      Rails.logger.error("Converter Studio: lost conversions could not be looked for: #{e.class}")
      0
    end

    # Queues again the conversions whose job was lost; returns how many it queued.
    def resume(now = Time.current)
      ConverterStudioConversion.abandoned(now).order(:id).limit(BATCH).to_a.count do |conversion|
        conversion.requeue_if_abandoned!(now)
      end
    end

    def in_process_queue?
      IN_PROCESS.include?(ConverterStudioConvertJob.queue_adapter_name.to_s)
    end

    def due?(now)
      LOCK.synchronize do
        next_at = STATE[:next_at]
        next false if next_at && now < next_at

        STATE[:next_at] = now + INTERVAL
        true
      end
    end

    # The next request looks again at once (tests).
    def forget
      LOCK.synchronize { STATE[:next_at] = nil }
    end
  end
end
