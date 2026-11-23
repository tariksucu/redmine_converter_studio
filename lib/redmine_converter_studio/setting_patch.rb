# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

module RedmineConverterStudio
  # Keeps the API key out of the settings page and encrypted at rest. Redmine saves a plugin's
  # settings form as a whole hash and has no hook for it, so this adds one callback to Setting,
  # for this plugin's row only (no core method is replaced):
  #
  # - the form never shows the key; its "new_api_key" field replaces the saved key when filled,
  #   and an empty field keeps it ("remove_api_key" deletes it);
  # - the saved key is encrypted with Redmine's database_cipher_key when one is configured
  #   (Redmine::Ciphering, as Redmine does for LDAP and repository passwords).
  module SettingPatch
    extend ActiveSupport::Concern

    included do
      before_save :converter_studio_protect_api_key, if: -> { name == "plugin_#{PLUGIN_ID}" }
    end

    private

    def converter_studio_protect_api_key
      current = value
      hash = current.is_a?(Hash) ? current.to_h.stringify_keys : {}
      entered = hash.delete('new_api_key').to_s.strip
      remove = hash.delete('remove_api_key').to_s == '1'
      hash['api_key'] = converter_studio_saved_api_key unless hash.key?('api_key')
      if remove
        hash.delete('api_key')
      elsif entered.present?
        hash['api_key'] = entered
      end
      stored = hash['api_key'].to_s
      if stored.blank?
        hash.delete('api_key')
      elsif !stored.start_with?('aes-256-cbc:')
        hash['api_key'] = Redmine::Ciphering.encrypt_text(stored)
      end
      self.value = hash
    end

    def converter_studio_saved_api_key
      raw = attribute_in_database(:value)
      return nil if raw.blank?

      saved = YAML.safe_load(raw, permitted_classes: Rails.configuration.active_record.yaml_column_permitted_classes)
      saved.is_a?(Hash) ? saved.to_h.stringify_keys['api_key'] : nil
    rescue Psych::Exception
      nil
    end
  end
end
