# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

require_relative '../test_helper'

class ConverterStudioConfigurationTest < ActiveSupport::TestCase
  Configuration = RedmineConverterStudio::Configuration
  KEY = 'cvs_live_abcdefghijklmnopqrstuvwxyz0123456789'

  def setup
    ENV.delete(Configuration::ENV_KEY)
    Setting.plugin_redmine_converter_studio = {}
  end

  def teardown
    ENV.delete(Configuration::ENV_KEY)
  end

  def saved
    YAML.safe_load(Setting.find_by(name: 'plugin_redmine_converter_studio').read_attribute(:value),
                   permitted_classes: Rails.configuration.active_record.yaml_column_permitted_classes)
  end

  # What the settings form sends: the whole hash, with the key field empty unless a key is typed.
  def save_form(values)
    Setting.plugin_redmine_converter_studio = ActionController::Parameters.new(values).permit!.to_h
  end

  def test_a_typed_key_is_saved_and_an_empty_field_keeps_it
    save_form('new_api_key' => " #{KEY} ", 'base_url' => 'https://converter.studio/api', 'max_credits' => '20')
    assert_equal KEY, Configuration.api_key
    assert_equal :settings, Configuration.api_key_source
    assert_equal 'cvs_live_…6789', Configuration.api_key_hint

    save_form('new_api_key' => '', 'base_url' => 'https://converter.studio/api', 'max_credits' => '5')
    assert_equal KEY, Configuration.api_key
    assert_equal 5, Configuration.max_credits
    assert_not saved.key?('new_api_key')
  end

  def test_the_key_can_be_removed
    save_form('new_api_key' => KEY)
    save_form('new_api_key' => '', 'remove_api_key' => '1')
    assert_equal '', Configuration.api_key
    assert_nil Configuration.api_key_source
    assert_not saved.key?('api_key')
  end

  # Redmine's database_cipher_key (config/configuration.yml), whatever this Redmine has.
  def with_cipher_key(key, &)
    Redmine::Configuration.with('database_cipher_key' => key, &)
  end

  def test_the_key_is_encrypted_with_the_database_cipher_key
    with_cipher_key('secret-of-this-redmine') do
      save_form('new_api_key' => KEY)
      assert_match(/\Aaes-256-cbc:/, saved['api_key'])
      assert_not_includes saved.to_s, KEY
      assert_equal KEY, Configuration.api_key
      assert Configuration.encryption?
    end
    # Without the cipher key it cannot be read, and is not used.
    with_cipher_key(nil) { assert_equal '', Configuration.api_key }
  end

  def test_without_a_cipher_key_the_key_is_stored_as_it_is
    with_cipher_key(nil) do
      save_form('new_api_key' => KEY)
      assert_equal KEY, saved['api_key']
      assert_not Configuration.encryption?
    end
  end

  def test_a_plain_key_is_encrypted_when_the_settings_are_saved_again
    with_cipher_key(nil) { save_form('new_api_key' => KEY) }
    assert_equal KEY, saved['api_key']
    with_cipher_key('secret-of-this-redmine') do
      save_form('new_api_key' => '', 'max_credits' => '20')
      assert_match(/\Aaes-256-cbc:/, saved['api_key'])
      assert_equal KEY, Configuration.api_key
    end
  end

  def test_the_environment_wins
    save_form('new_api_key' => KEY)
    ENV[Configuration::ENV_KEY] = 'cvs_live_from_the_environment_1234'
    assert_equal 'cvs_live_from_the_environment_1234', Configuration.api_key
    assert_equal :environment, Configuration.api_key_source
  end

  def test_base_url_and_max_credits_fall_back_to_the_defaults
    save_form('base_url' => 'javascript:alert(1)', 'max_credits' => 'many')
    assert_equal 'https://converter.studio/api', Configuration.base_url
    assert_equal 20, Configuration.max_credits
    save_form('base_url' => 'http://localhost:8080/api/', 'max_credits' => '999999999')
    assert_equal 'http://localhost:8080/api', Configuration.base_url
    assert_equal 100_000, Configuration.max_credits
  end
end
