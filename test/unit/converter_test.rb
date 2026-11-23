# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

require_relative '../test_helper'

# Whole conversions through the job (Redmine's test queue runs jobs inline) and the fake API.
class ConverterStudioConverterTest < ActiveSupport::TestCase
  include ConverterStudioTestHelper

  def setup
    setup_converter_studio
    @issue = Issue.find(1)
  end

  def test_an_issue_attachment_gets_its_result_and_a_journal_entry
    source = attach(@issue, 'report.docx', 'The report')
    conversion = convert(source, 'pdf')

    assert_equal 'done', conversion.status
    assert_equal 1, conversion.credits
    result = conversion.result_attachment
    assert_equal 'report.pdf', result.filename
    assert_equal @issue, result.container
    assert_equal User.find(2), result.author
    assert_equal 'converted:The report', File.binread(result.diskfile)
    assert_equal 'application/pdf', result.content_type
    assert_equal 'Converted from report.docx with Converter Studio', result.description

    journal = @issue.journals.order(:id).last
    assert_equal User.find(2), journal.user
    assert_equal 'Converted report.docx to PDF with Converter Studio. Credits used: 1.', journal.notes
    detail = journal.details.sole
    assert_equal ['attachment', result.id.to_s, 'report.pdf'], [detail.property, detail.prop_key, detail.value]

    create = @api.requests_to('POST', '/v1/conversions').sole
    assert_equal "redmine-#{conversion.id}-#{conversion.upload_id}", create[:idempotency_key]
    assert_equal "redmine/#{RedmineConverterStudio::VERSION}", create[:client]
    assert_equal({ 'to' => 'pdf', 'max' => 20 }, { 'to' => @api.conversions.values.sole[:to], 'max' => @api.conversions.values.sole[:max] })
  end

  def test_wiki_pages_and_documents_get_their_result_without_a_journal
    page = WikiPage.find(1)
    conversion = convert(attach(page, 'IMG_0001.HEIC'), 'jpg')
    assert_equal 'done', conversion.status
    assert_equal page, conversion.result_attachment.container
    assert_equal 'IMG_0001.jpg', conversion.result_attachment.filename

    document = Document.find(1)
    conversion = convert(attach(document, 'notes.txt'), 'pdf')
    assert_equal document, conversion.result_attachment.container
  end

  def test_the_ocr_option_reaches_the_api
    convert(attach(@issue, 'scan.pdf'), 'txt', options: { 'ocr' => true })
    assert_equal({ 'ocr' => true }, @api.conversions.values.sole[:options])
  end

  def test_a_failed_conversion_keeps_the_api_reason_and_says_so_on_the_issue
    source = attach(@issue, 'damaged.docx')
    conversion = convert(source, 'pdf')

    assert_equal 'failed', conversion.status
    assert_equal 'damagedFile', conversion.error_code
    assert_equal 'This file is damaged or is not a DOCX file.', conversion.error_message
    assert_nil conversion.result_attachment
    assert_equal 1, @issue.attachments.count { |a| a.filename.start_with?('damaged') }
    assert_equal 'Converter Studio could not convert damaged.docx to PDF: This file is damaged or is not a DOCX file.',
                 @issue.journals.order(:id).last.notes
  end

  def test_a_wrong_key_fails_with_the_api_sentence
    Setting.plugin_redmine_converter_studio = { 'base_url' => @api.base_url, 'api_key' => 'cvs_live_wrong_key_0000' }
    conversion = convert(attach(@issue, 'report.docx'), 'pdf')
    assert_equal 'failed', conversion.status
    assert_equal 'invalidApiKey', conversion.error_code
    assert_equal 'This API key does not work. Check it on your account page.', conversion.error_message
    assert_empty @api.requests_to('PUT', '/v1/uploads/')
  end

  def test_a_price_above_the_limit_waits_for_approval
    conversion = convert(attach(@issue, 'expensive.docx'), 'pdf')
    assert_equal 'quoted', conversion.status
    assert_equal 45, conversion.credits
    assert_match(/costs 45 credits/, conversion.error_message)
    assert_nil conversion.result_attachment
  end

  def test_a_slow_conversion_is_polled_until_done
    conversion = convert(attach(@issue, 'slow.docx'), 'pdf')
    assert_equal 'done', conversion.status
    assert_operator @api.requests_to('GET', '/v1/conversions/').size, :>=, 3
  end

  def test_a_lost_answer_does_not_upload_or_charge_twice
    source = attach(@issue, 'report.docx')
    conversion = ConverterStudioConversion.create!(project: @project, attachment: source, source_name: source.filename,
                                                   container: @issue, user: User.find(2), target_format: 'pdf',
                                                   status: 'queued', max_credits: 20)
    client = RedmineConverterStudio::Client.from_settings
    upload = client.create_upload(source.filename, source.filesize)
    File.open(source.diskfile, 'rb') { |io| client.send_file(upload, io, source.filesize) }
    conversion.update!(upload_id: upload['id'])
    # The first POST reached the API, its answer did not come back.
    client.start_conversion(upload_id: upload['id'], to: 'pdf', max_credits: 20, idempotency_key: conversion.idempotency_key)

    RedmineConverterStudio::Converter.new(conversion).run
    conversion.reload
    assert_equal 'done', conversion.status
    assert_equal 1, @api.conversions.size
    assert_equal 1, @api.requests_to('POST', '/v1/uploads').size
  end

  def test_an_expired_upload_is_uploaded_again_once
    source = attach(@issue, 'report.docx')
    conversion = ConverterStudioConversion.create!(project: @project, attachment: source, source_name: source.filename,
                                                   container: @issue, user: User.find(2), target_format: 'pdf',
                                                   status: 'uploading', upload_id: 'up_gone0000000', max_credits: 20)
    RedmineConverterStudio::Converter.new(conversion).run
    assert_equal 'done', conversion.reload.status
    assert_equal 1, @api.requests_to('POST', '/v1/uploads').size
  end

  def test_an_upload_that_never_finished_is_made_again
    source = attach(@issue, 'report.docx')
    client = RedmineConverterStudio::Client.from_settings
    upload = client.create_upload(source.filename, source.filesize) # nothing sent: the run stopped
    conversion = ConverterStudioConversion.create!(project: @project, attachment: source, source_name: source.filename,
                                                   container: @issue, user: User.find(2), target_format: 'pdf',
                                                   status: 'uploading', upload_id: upload['id'], max_credits: 20)
    RedmineConverterStudio::Converter.new(conversion).run
    assert_equal 'done', conversion.reload.status
    assert_equal 2, @api.requests_to('POST', '/v1/uploads').size
    assert_equal 1, @api.conversions.size
  end

  def test_a_result_larger_than_redmine_allows
    with_settings attachment_max_size: '1' do
      @api.result_bytes = 'x' * 2048
      conversion = convert(attach(@issue, 'report.docx'), 'pdf')
      assert_equal 'resultTooLarge', conversion.error_code
      assert_equal "The converted file is larger than Redmine's maximum attachment size (1 KB).", conversion.error_message
    end
  end

  def test_a_result_redmine_refuses
    with_settings attachment_extensions_denied: 'pdf' do
      conversion = convert(attach(@issue, 'report.docx'), 'pdf')
      assert_equal 'attachmentRejected', conversion.error_code
      assert_match(/\ARedmine did not accept the converted file: /, conversion.error_message)
      assert_not(@issue.attachments.reload.any? { |a| a.filename == 'report.pdf' })
    end
  end

  def test_an_unsupported_target_fails_before_uploading
    conversion = convert(attach(@issue, 'report.docx'), 'mp4')
    assert_equal 'unsupportedConversion', conversion.error_code
    assert_empty @api.requests_to('POST', '/v1/uploads')
  end

  def test_the_module_switched_off_meanwhile
    source = attach(@issue, 'report.docx')
    @project.disable_module!(:converter_studio)
    conversion = convert(source, 'pdf')
    assert_equal 'moduleDisabled', conversion.error_code
    assert_equal 'The Converter Studio module is switched off in this project.', conversion.error_message
  end

  def test_a_deleted_original
    source = attach(@issue, 'report.docx')
    File.delete(source.diskfile)
    assert_equal 'sourceMissing', convert(source, 'pdf').error_code
  end

  def test_converter_studio_out_of_reach
    port = TCPServer.open('127.0.0.1', 0) { |s| s.addr[1] }
    Setting.plugin_redmine_converter_studio = { 'base_url' => "http://127.0.0.1:#{port}", 'api_key' => FakeConverterStudioApi::KEY }
    conversion = convert(attach(@issue, 'report.docx'), 'pdf')
    # The inline queue cannot schedule a later try: it fails at once, with the reason.
    assert_equal 'network', conversion.error_code
    assert_equal 'converter.studio could not be reached. Try again in a few minutes.', conversion.error_message
    assert_equal 1, conversion.attempts
  end

  def test_transient_errors_are_tried_again_later_with_a_scheduling_queue
    port = TCPServer.open('127.0.0.1', 0) { |s| s.addr[1] }
    Setting.plugin_redmine_converter_studio = { 'base_url' => "http://127.0.0.1:#{port}", 'api_key' => FakeConverterStudioApi::KEY }
    source = attach(@issue, 'report.docx')
    conversion = ConverterStudioConversion.create!(project: @project, attachment: source, source_name: source.filename,
                                                   container: @issue, user: User.find(2), target_format: 'pdf',
                                                   status: 'queued', max_credits: 20)
    job = ConverterStudioConvertJob.set(wait: 1.minute)
    ConverterStudioConvertJob.expects(:set).with(wait: 60.seconds).returns(job)
    job.expects(:perform_later).with(conversion.id)
    RedmineConverterStudio::Converter.new(conversion).run
    assert_equal 'queued', conversion.reload.status
    assert_equal 1, conversion.attempts
  end

  def test_a_run_that_must_not_hand_over_never_schedules
    port = TCPServer.open('127.0.0.1', 0) { |s| s.addr[1] }
    Setting.plugin_redmine_converter_studio = { 'base_url' => "http://127.0.0.1:#{port}", 'api_key' => FakeConverterStudioApi::KEY }
    source = attach(@issue, 'report.docx')
    conversion = ConverterStudioConversion.create!(project: @project, attachment: source, source_name: source.filename,
                                                   container: @issue, user: User.find(2), target_format: 'pdf',
                                                   status: 'queued', max_credits: 20)
    ConverterStudioConvertJob.expects(:set).never
    RedmineConverterStudio::Converter.new(conversion, hand_over: false).run
    assert_equal %w[failed network], [conversion.reload.status, conversion.error_code]
  end

  def test_a_conversion_runs_once_at_a_time
    source = attach(@issue, 'report.docx')
    conversion = ConverterStudioConversion.create!(project: @project, attachment: source, source_name: source.filename,
                                                   container: @issue, user: User.find(2), target_format: 'pdf',
                                                   status: 'queued', max_credits: 20)
    assert conversion.lease!(60)
    RedmineConverterStudio::Converter.new(ConverterStudioConversion.find(conversion.id)).run
    assert_equal 'queued', conversion.reload.status
    assert_empty @api.requests
  end

  def test_a_finished_conversion_is_never_run_again
    conversion = convert(attach(@issue, 'report.docx'), 'pdf')
    @api.reset
    ConverterStudioConvertJob.perform_now(conversion.id)
    assert_empty @api.requests
    assert_equal 1, @issue.attachments.reload.count { |a| a.filename == 'report.pdf' }
  end
end
