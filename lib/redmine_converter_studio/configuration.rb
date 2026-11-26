# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

module RedmineConverterStudio
  # The plugin's settings (Administration » Plugins » Converter Studio » Configure), read fresh on
  # every call so a change applies at once.
  #
  # The API key: the CONVERTER_STUDIO_API_KEY environment variable when it is set, otherwise the key
  # saved in the settings. A saved key is encrypted with Redmine's database_cipher_key
  # (config/configuration.yml) when one is configured, the way Redmine keeps LDAP and repository
  # passwords (Redmine::Ciphering); without it, it is stored as plain text (SettingPatch).
  module Configuration
    ENV_KEY = 'CONVERTER_STUDIO_API_KEY'
    MAX_CREDITS_LIMIT = 100_000

    module_function

    def settings
      value = Setting.send(:"plugin_#{PLUGIN_ID}")
      value.is_a?(Hash) ? value.to_h.stringify_keys : {}
    end

    def api_key
      from_env = ENV[ENV_KEY].to_s.strip
      return from_env if from_env.present?

      stored_api_key
    end

    # The key saved in the settings, decrypted; empty when there is none or it cannot be read.
    def stored_api_key
      stored = settings['api_key'].to_s
      return '' if stored.blank?

      key = Redmine::Ciphering.decrypt_text(stored).to_s.strip
      # Encrypted with a database_cipher_key that is no longer configured.
      key.start_with?('aes-256-cbc:') ? '' : key
    rescue OpenSSL::Cipher::CipherError, ArgumentError
      ''
    end

    # :environment, :settings, or nil when no key is set.
    def api_key_source
      return :environment if ENV[ENV_KEY].to_s.strip.present?

      stored_api_key.present? ? :settings : nil
    end

    def configured?
      api_key.present?
    end

    # A hint at which key is in use, never the key: "cvs_live_…a1b2".
    def api_key_hint
      key = api_key
      return nil if key.blank?

      prefix = key.start_with?('cvs_live_') ? 'cvs_live_' : ''
      "#{prefix}…#{key[-4, 4]}"
    end

    def base_url
      url = settings['base_url'].to_s.strip.delete_suffix('/')
      url.match?(%r{\Ahttps?://[^\s/]+}i) ? url : DEFAULT_BASE_URL
    end

    # The most one file may cost to start without someone approving its price.
    def max_credits
      value = settings['max_credits'].to_s.strip
      return DEFAULT_MAX_CREDITS unless value.match?(/\A\d+\z/)

      value.to_i.clamp(0, MAX_CREDITS_LIMIT)
    end

    def encryption?
      Redmine::Ciphering.cipher_key.present?
    end
  end
end
