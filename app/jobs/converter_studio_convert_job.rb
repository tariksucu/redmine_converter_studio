# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

# Runs one conversion (RedmineConverterStudio::Converter) in the background, through Active Job
# and whatever queue adapter Redmine is configured with. A run that cannot finish in one go
# schedules the next one; a finished conversion is never run again. Redmine 5.1 and later have
# ApplicationJob (6.1 keeps the current user in it); 5.0 has none.
class ConverterStudioConvertJob < (defined?(ApplicationJob) ? ApplicationJob : ActiveJob::Base)
  queue_as :default

  def perform(conversion_id)
    conversion = ConverterStudioConversion.find_by(id: conversion_id)
    return unless conversion

    RedmineConverterStudio::Converter.new(conversion).run
  end
end
