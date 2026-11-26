# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

require_relative '../test_helper'

# Conversions whose job a restart lost (Redmine's default queue adapter keeps jobs in the web
# process's memory), and runs that lost their hold on a conversion: picked up where they stopped,
# never uploaded or paid for twice.
class ConverterStudioRecoveryTest < ActiveSupport::TestCase
  include ConverterStudioTestHelper

  def setup
    setup_converter_studio
    RedmineConverterStudio::Recovery.forget
    @issue = Issue.find(1)
    @client = RedmineConverterStudio::Client.from_settings
  end

  def teardown
    RedmineConverterStudio::Recovery.forget
  end

  # A row as a run that died left it: +stage+ :queued (nothing sent yet), :uploaded (the file is at
  # the API, no conversion), :charged (the conversion was started, its answer never saved) or
  # :converting (its id saved). Its hold ran out a moment ago.
  def left_by_a_dead_run(stage, name = 'report.docx')
    source = attach(@issue, name)
    conversion = ConverterStudioConversion.create!(
      project: @project, attachment: source, source_name: source.filename, container: @issue, user: User.find(2),
      target_format: 'pdf', status: stage == :queued ? 'queued' : 'uploading', max_credits: 20,
      locked_by: 'dead-run', locked_until: 1.second.ago, run_after: 5.minutes.ago
    )
    return conversion if stage == :queued

    upload = @client.create_upload(source.filename, source.filesize)
    File.open(source.diskfile, 'rb') { |io| @client.send_file(upload, io, source.filesize) }
    conversion.update!(upload_id: upload['id'])
    return conversion if stage == :uploaded

    view = @client.start_conversion(upload_id: upload['id'], to: 'pdf', max_credits: 20,
                                    idempotency_key: conversion.idempotency_key)
    conversion.update!(status: 'converting', remote_id: view['id']) if stage == :converting
    conversion
  end

  # Redmine's default adapter (async) runs jobs in the web process; the test queue runs them inline.
  def with_in_process_queue
    RedmineConverterStudio::Recovery.stubs(:in_process_queue?).returns(true)
    yield
  ensure
    RedmineConverterStudio::Recovery.unstub(:in_process_queue?)
  end

  def test_a_conversion_cut_off_by_a_restart_is_finished_without_a_second_charge
    conversion = left_by_a_dead_run(:converting)
    @api.requests.clear

    assert_equal 1, with_in_process_queue { RedmineConverterStudio::Recovery.poke }
    conversion.reload
    assert_equal 'done', conversion.status
    assert_equal 'report.pdf', conversion.result_attachment.filename
    # Waited for the conversion already started, nothing uploaded or started again.
    assert_empty @api.requests_to('POST', '/v1/uploads')
    assert_empty @api.requests_to('POST', '/v1/conversions')
    assert_equal 1, @api.conversions.size
    assert_nil conversion.locked_by
  end

  def test_a_restart_between_the_charge_and_its_answer_gets_the_same_conversion
    conversion = left_by_a_dead_run(:charged)
    @api.requests.clear

    with_in_process_queue { RedmineConverterStudio::Recovery.poke }
    assert_equal 'done', conversion.reload.status
    assert_empty @api.requests_to('POST', '/v1/uploads')
    assert_equal [conversion.idempotency_key], @api.requests_to('POST', '/v1/conversions').pluck(:idempotency_key)
    assert_equal 1, @api.conversions.size
  end

  def test_a_restart_after_the_upload_starts_the_conversion_once
    conversion = left_by_a_dead_run(:uploaded)
    @api.requests.clear

    with_in_process_queue { RedmineConverterStudio::Recovery.poke }
    assert_equal 'done', conversion.reload.status
    assert_empty @api.requests_to('POST', '/v1/uploads')
    assert_equal 1, @api.conversions.size
  end

  def test_a_queued_conversion_whose_job_was_lost_runs
    conversion = left_by_a_dead_run(:queued)
    with_in_process_queue { RedmineConverterStudio::Recovery.poke }
    assert_equal 'done', conversion.reload.status
  end

  def test_a_conversion_a_live_run_holds_is_left_alone
    conversion = left_by_a_dead_run(:converting)
    ConverterStudioConversion.where(id: conversion.id).update_all(locked_by: 'live-run', locked_until: 1.minute.from_now)
    @api.requests.clear

    assert_equal 0, with_in_process_queue { RedmineConverterStudio::Recovery.poke }
    assert_equal 'converting', conversion.reload.status
    assert_empty @api.requests
  end

  def test_a_run_planned_for_later_is_not_taken_early
    conversion = left_by_a_dead_run(:converting)
    # A retry after a busy server, due in a minute: its job is still on its way.
    ConverterStudioConversion.where(id: conversion.id).update_all(locked_by: nil, locked_until: nil, run_after: 1.minute.from_now)
    assert_not ConverterStudioConversion.abandoned.exists?(conversion.id)

    travel 1.minute + ConverterStudioConversion::GRACE + 1.second do
      assert ConverterStudioConversion.abandoned.exists?(conversion.id)
    end
  end

  def test_waiting_for_approval_and_finished_conversions_are_left_alone
    quoted = left_by_a_dead_run(:converting, 'expensive.docx')
    ConverterStudioConversion.where(id: quoted.id).update_all(status: 'quoted')
    done = convert(attach(@issue, 'notes.docx'), 'pdf')
    ConverterStudioConversion.where(id: done.id).update_all(run_after: 1.hour.ago)
    assert_empty ConverterStudioConversion.abandoned
  end

  def test_only_an_in_process_queue_is_looked_at_and_at_most_once_a_minute
    conversion = left_by_a_dead_run(:converting)
    # The test adapter (inline) is not Redmine's in-process default: nothing to pick up.
    assert_equal 0, RedmineConverterStudio::Recovery.poke
    assert_equal 'converting', conversion.reload.status

    ConverterStudioConvertJob.expects(:perform_later).with(conversion.id).twice
    with_in_process_queue do
      assert_equal 1, RedmineConverterStudio::Recovery.poke
      ConverterStudioConversion.where(id: conversion.id).update_all(run_after: 1.hour.ago)
      assert_equal 0, RedmineConverterStudio::Recovery.poke, 'looked again within the minute'
      travel 61.seconds do
        assert_equal 1, RedmineConverterStudio::Recovery.poke
      end
    end
  end

  def test_two_processes_queue_a_lost_conversion_once
    conversion = left_by_a_dead_run(:converting)
    ConverterStudioConvertJob.expects(:perform_later).with(conversion.id).once
    assert conversion.requeue_if_abandoned!
    assert_not ConverterStudioConversion.find(conversion.id).requeue_if_abandoned!
  end

  def test_a_failure_while_looking_never_breaks_the_request
    ConverterStudioConversion.stubs(:abandoned).raises(ActiveRecord::StatementInvalid, 'database gone')
    assert_equal 0, with_in_process_queue { RedmineConverterStudio::Recovery.poke }
  end

  # A run that stalled for longer than its hold (a network that stopped mid-upload) while another
  # run took the conversion over must not start (and pay for) a conversion of its own.
  def test_a_run_that_lost_its_hold_never_starts_a_conversion
    source = attach(@issue, 'report.docx')
    conversion = ConverterStudioConversion.create!(project: @project, attachment: source, source_name: source.filename,
                                                   container: @issue, user: User.find(2), target_format: 'pdf',
                                                   status: 'queued', max_credits: 20)
    client = RedmineConverterStudio::Client.from_settings
    client.define_singleton_method(:send_file) do |upload, io, size, &progress|
      ConverterStudioConversion.where(id: conversion.id).update_all(locked_by: 'another-run', locked_until: 1.minute.from_now)
      super(upload, io, size, &progress)
    end

    RedmineConverterStudio::Converter.new(conversion, client: client).run
    conversion.reload
    assert_empty @api.requests_to('POST', '/v1/conversions')
    assert_equal 'uploading', conversion.status
    assert_nil conversion.error_code
    assert_equal 'another-run', conversion.locked_by, 'the other run keeps its hold'
  end

  def test_the_hold_is_renewed_while_a_long_upload_goes_on
    source = attach(@issue, 'report.docx')
    conversion = ConverterStudioConversion.create!(project: @project, attachment: source, source_name: source.filename,
                                                   container: @issue, user: User.find(2), target_format: 'pdf',
                                                   status: 'queued', max_credits: 20)
    held = []
    test = self
    client = RedmineConverterStudio::Client.from_settings
    client.define_singleton_method(:send_file) do |upload, io, size, &progress|
      # Over two minutes of upload, in pieces: each piece is a sign of life.
      6.times do
        test.travel(21.seconds) # BEAT, and a second Rails may drop when it travels
        progress.call
        held << (ConverterStudioConversion.find(conversion.id).locked_until - Time.current)
      end
      super(upload, io, size, &progress)
    end

    RedmineConverterStudio::Converter.new(conversion, client: client).run
    assert_equal 'done', conversion.reload.status
    # Renewed at each sign of life: a whole lease ahead every time, though the upload took longer.
    assert_equal 6, held.size
    assert(held.all? { |left| left > ConverterStudioConversion::LEASE - 2.seconds }, held.inspect)
  ensure
    travel_back
  end
end
