# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

require_relative '../test_helper'

class ConverterStudioClientTest < ActiveSupport::TestCase
  include ConverterStudioTestHelper

  def setup
    @api = FakeConverterStudioApi.instance
    @api.reset
    @client = RedmineConverterStudio::Client.new(base_url: "#{@api.base_url}/", api_key: FakeConverterStudioApi::KEY)
  end

  def test_json_calls_carry_the_key_and_name_the_plugin
    assert_equal 'pro', @client.account['plan']
    request = @api.requests.last
    assert_equal "Bearer #{FakeConverterStudioApi::KEY}", request[:authorization]
    assert_equal "redmine/#{RedmineConverterStudio::VERSION}", request[:client]
    assert_match %r{\Aredmine_converter_studio/1\.1\.0 Redmine/\d+\.\d+\.\d+ Ruby/}, request[:user_agent]
  end

  def test_formats_need_no_key
    client = RedmineConverterStudio::Client.new(base_url: @api.base_url, api_key: '')
    assert_includes client.formats.pluck('id'), 'docx'
    assert_nil @api.requests.last[:authorization]
  end

  def test_upload_parts_and_downloads_never_carry_the_key
    @api.part_bytes = 10
    upload = @client.create_upload('notes.txt', 25)
    answer = @client.send_file(upload, StringIO.new('a' * 25), 25)
    assert_equal 'ready', answer['status']
    parts = @api.requests_to('PUT', '/v1/uploads/')
    assert_equal %w[0 10 20], parts.pluck(:offset)
    assert_equal [10, 10, 5], parts.pluck(:bytes)
    assert(parts.all? { |r| r[:authorization].nil? })
    assert(parts.all? { |r| r[:client] == "redmine/#{RedmineConverterStudio::VERSION}" })

    view = @client.start_conversion(upload_id: upload['id'], to: 'pdf', max_credits: 20, idempotency_key: 'redmine-1-x')
    view = @client.conversion(view['id'], wait: 5)
    assert_equal 'done', view['status']
    file = @client.download(view['downloadUrl'], 1000)
    assert_equal "converted:#{'a' * 25}", file.read
    assert_nil @api.requests.last[:authorization]
  ensure
    file&.close!
  end

  def test_a_small_file_goes_in_one_request
    upload = @client.create_upload('notes.txt', 5)
    @client.send_file(upload, StringIO.new('hello'), 5)
    request = only(@api.requests_to('PUT', '/v1/uploads/'))
    assert_nil request[:offset]
    assert_equal 5, request[:bytes]
  end

  def test_the_same_idempotency_key_returns_the_first_conversion
    upload = @client.create_upload('notes.txt', 5)
    @client.send_file(upload, StringIO.new('hello'), 5)
    first = @client.start_conversion(upload_id: upload['id'], to: 'pdf', max_credits: 20, idempotency_key: 'redmine-7-a')
    again = @client.start_conversion(upload_id: upload['id'], to: 'pdf', max_credits: 20, idempotency_key: 'redmine-7-a')
    assert_equal first['id'], again['id']
    assert_equal 1, @api.conversions.size
    assert_equal %w[redmine-7-a redmine-7-a], @api.requests_to('POST', '/v1/conversions').pluck(:idempotency_key)
  end

  def test_api_errors_keep_the_code_and_the_sentence
    client = RedmineConverterStudio::Client.new(base_url: @api.base_url, api_key: 'cvs_live_wrong')
    error = assert_raises(RedmineConverterStudio::ApiError) { client.account }
    assert_equal 'invalidApiKey', error.code
    assert_equal 401, error.status
    assert_equal 'This API key does not work. Check it on your account page.', error.message
    assert_not error.transient?
  end

  def test_no_key_is_refused_before_any_request
    client = RedmineConverterStudio::Client.new(base_url: @api.base_url, api_key: ' ')
    error = assert_raises(RedmineConverterStudio::ApiError) { client.account }
    assert_equal 'notConfigured', error.code
    assert_empty @api.requests
  end

  def test_redirects_are_not_followed
    error = assert_raises(RedmineConverterStudio::ApiError) { @client.send(:json, :get, '/redirect') }
    assert_equal 'unexpected', error.code
    assert_equal 1, @api.requests.size
  end

  def test_downloads_only_from_the_api_address
    error = assert_raises(RedmineConverterStudio::ApiError) { @client.download('https://example.com/jobs/x/download', 1000) }
    assert_equal 'downloadFailed', error.code
    assert_empty @api.requests
  end

  def test_a_result_larger_than_redmine_accepts_is_refused
    upload = @client.create_upload('notes.txt', 5)
    @client.send_file(upload, StringIO.new('hello'), 5)
    view = @client.start_conversion(upload_id: upload['id'], to: 'pdf', max_credits: 20, idempotency_key: 'k1')
    view = @client.conversion(view['id'])
    error = assert_raises(RedmineConverterStudio::ApiError) { @client.download(view['downloadUrl'], 4) }
    assert_equal 'resultTooLarge', error.code
  end

  def test_network_errors_never_show_the_key
    port = TCPServer.open('127.0.0.1', 0) { |s| s.addr[1] }
    client = RedmineConverterStudio::Client.new(base_url: "http://127.0.0.1:#{port}", api_key: FakeConverterStudioApi::KEY)
    error = assert_raises(RedmineConverterStudio::ApiError) { client.account }
    assert_equal 'network', error.code
    assert error.transient?
    assert_not_includes error.message, FakeConverterStudioApi::KEY
    assert_not_includes client.inspect, FakeConverterStudioApi::KEY
  end

  def test_a_base_url_must_be_a_web_address
    error = assert_raises(RedmineConverterStudio::ApiError) { RedmineConverterStudio::Client.new(base_url: 'ftp://x', api_key: 'k') }
    assert_equal 'invalidBaseUrl', error.code
  end

  def test_safe_names
    assert_equal 'abc.docx', RedmineConverterStudio::Client.safe_name("a/b\\c\0.docx")
    assert_equal 'file', RedmineConverterStudio::Client.safe_name('  ')
    assert_equal 200, RedmineConverterStudio::Client.safe_name("#{'x' * 300}.pdf").length
  end
end
