# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

require_relative '../test_helper'

class ConverterStudioCatalogTest < ActiveSupport::TestCase
  def setup
    @catalog = RedmineConverterStudio::Catalog.new(FakeConverterStudioApi::FORMATS)
  end

  def test_formats_come_from_the_extension
    assert_equal 'docx', @catalog.format_of('Report.DOCX')
    assert_equal 'heic', @catalog.format_of('IMG_0001.heif')
    assert_equal 'tgz', @catalog.format_of('backup.tar.gz')
    assert_nil @catalog.format_of('README')
    assert_nil @catalog.format_of('photo.xyz')
  end

  def test_targets_in_the_api_order
    assert_equal %w[pdf txt odt], @catalog.targets_for('report.docx')
    assert_empty @catalog.targets_for('photo.xyz')
    assert @catalog.convertible?('IMG.HEIC', 'jpg')
    assert_not @catalog.convertible?('IMG.HEIC', 'mp4')
  end

  def test_text_from_pictures_and_scans
    assert @catalog.ocr_target?('photo.png', 'txt')
    assert_not @catalog.ocr_target?('report.docx', 'txt')
    assert @catalog.ocr_option?('scan.pdf', 'txt')
    assert @catalog.ocr_option?('scan.pdf', 'docx')
    assert_not @catalog.ocr_option?('scan.pdf', 'jpg')
  end

  def test_names_and_every_target
    assert_equal 'Word', @catalog.name_of('docx')
    assert_equal 'MP4', @catalog.name_of('mp4')
    assert_includes @catalog.all_targets, 'mp4'
    assert_equal @catalog.all_targets.uniq, @catalog.all_targets
  end

  def test_the_list_is_asked_for_once_an_hour
    api = FakeConverterStudioApi.instance
    api.reset
    RedmineConverterStudio::Catalog.forget
    client = RedmineConverterStudio::Client.new(base_url: api.base_url, api_key: '')
    2.times { RedmineConverterStudio::Catalog.load(client, quick: true) }
    assert_equal 1, api.requests_to('GET', '/v1/formats').size
    travel 61.minutes do
      RedmineConverterStudio::Catalog.load(client)
    end
    assert_equal 2, api.requests_to('GET', '/v1/formats').size
  end

  def test_pages_do_not_wait_on_an_api_that_just_failed
    RedmineConverterStudio::Catalog.forget
    port = TCPServer.open('127.0.0.1', 0) { |s| s.addr[1] }
    client = RedmineConverterStudio::Client.new(base_url: "http://127.0.0.1:#{port}", api_key: '')
    assert_raises(RedmineConverterStudio::ApiError) { RedmineConverterStudio::Catalog.load(client) }
    client.expects(:formats).never
    error = assert_raises(RedmineConverterStudio::ApiError) { RedmineConverterStudio::Catalog.load(client, quick: true) }
    assert_equal 'network', error.code
  end

  def test_odd_entries_are_skipped
    catalog = RedmineConverterStudio::Catalog.new([{ 'id' => '../x', 'to' => ['pdf'] }, { 'id' => 'ok', 'to' => ['p df', 'pdf'] }])
    assert_equal ['pdf'], catalog.targets_for('a.ok')
    assert_nil catalog.format_of('a.x')
  end
end
