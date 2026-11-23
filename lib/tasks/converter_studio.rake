# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

namespace :redmine do
  namespace :converter_studio do
    desc 'Runs again the conversions whose job was lost (a restart with the default queue adapter, for example)'
    task resume: :environment do
      stale = ConverterStudioConversion.unfinished.where.not(status: 'quoted')
                                       .where(updated_on: ...ConverterStudioConversion::STALE_AFTER.ago)
      # Redmine's default adapter runs jobs in the process that queued them: this task's process
      # ends with it, so it runs them itself, one after the other, to the end.
      here = %w[async inline].include?(ActiveJob::Base.queue_adapter_name.to_s)
      count = 0
      stale.find_each do |conversion|
        conversion.touch
        if here
          RedmineConverterStudio::Converter.new(conversion, hand_over: false).run
        else
          conversion.enqueue
        end
        count += 1
      end
      puts "Converter Studio: #{count} conversion(s) #{here ? 'run' : 'queued'} again."
    end
  end
end
