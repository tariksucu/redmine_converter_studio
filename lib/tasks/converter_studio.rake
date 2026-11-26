# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

namespace :redmine do
  namespace :converter_studio do
    desc 'Runs again the conversions whose job was lost (a worker killed mid-run, for example)'
    task resume: :environment do
      # With an in-process adapter (Redmine's default, async) the queue would end with this task's
      # process: the task runs them itself, one after the other, to the end. Otherwise they go to
      # the queue's workers.
      here = %w[async inline].include?(ConverterStudioConvertJob.queue_adapter_name.to_s)
      count = 0
      ConverterStudioConversion.abandoned.find_each do |conversion|
        if here
          RedmineConverterStudio::Converter.new(conversion, hand_over: false).run
        else
          next unless conversion.requeue_if_abandoned!
        end
        count += 1
      end
      puts "Converter Studio: #{count} conversion(s) #{here ? 'run' : 'queued'} again."
    end
  end
end
