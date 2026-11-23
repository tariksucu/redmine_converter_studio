# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

module RedmineConverterStudio
  # Runs the project's automatic conversions when an attachment lands on an issue, a wiki page or
  # a document. Redmine has no hook for that (files arrive through forms, the REST API, e-mail and
  # uploads attached later), so this adds one callback to Attachment, after the commit: no core
  # method is replaced, and the save itself is never slowed down or broken by it.
  module AttachmentPatch
    extend ActiveSupport::Concern

    included do
      # Set on the attachments this plugin makes, which are never converted again on their own.
      attr_accessor :converter_studio_result

      after_commit :converter_studio_apply_rules, on: [:create, :update]
    end

    private

    def converter_studio_apply_rules
      return if converter_studio_result || container_id.blank?
      return unless previously_new_record? || saved_change_to_container_id?

      Rules.apply(self)
    rescue StandardError => e
      Rails.logger.error("Converter Studio: automatic conversions of attachment #{id} failed: #{e.class}")
    end
  end
end
