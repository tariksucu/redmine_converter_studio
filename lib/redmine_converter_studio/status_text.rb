# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

module RedmineConverterStudio
  # A conversion's status in words, in the current user's language: "Converting",
  # "Failed: <reason>", "Waiting for approval: 45 credits"…
  module StatusText
    module_function

    def for(conversion)
      case conversion.status
      when 'failed'
        ::I18n.t(:converter_studio_status_failed_reason, reason: conversion.error_message.to_s)
      when 'quoted'
        ::I18n.t(:converter_studio_status_quoted_credits, credits: conversion.credits.to_i)
      else
        text = ::I18n.t(:"converter_studio_status_#{conversion.status}")
        conversion.stale? ? "#{text} (#{::I18n.t(:converter_studio_status_stale)})" : text
      end
    end
  end
end
