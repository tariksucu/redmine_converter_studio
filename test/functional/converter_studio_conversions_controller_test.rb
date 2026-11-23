# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

require_relative '../test_helper'

class ConverterStudioConversionsControllerTest < Redmine::ControllerTest
  include ConverterStudioTestHelper

  def setup
    setup_converter_studio
    @issue = Issue.find(1)
    @source = attach(@issue, 'report.docx', 'The report')
    @request.session[:user_id] = 2 # jsmith, Manager of project 1
  end

  def test_new_offers_the_formats_of_the_file
    get :new, params: { attachment_id: @source.id }
    assert_response :success
    assert_select 'select#converter_studio_to option', 3
    assert_select 'select#converter_studio_to option[value=pdf]', text: 'PDF'
    assert_select 'input#converter_studio_ocr', 0
    assert_select 'a.external[href="https://converter.studio/privacy"]'
  end

  def test_new_offers_text_recognition_for_a_pdf
    pdf = attach(@issue, 'scan.pdf')
    get :new, params: { attachment_id: pdf.id }
    assert_response :success
    assert_select 'input#converter_studio_ocr'
  end

  def test_create_starts_the_conversion_and_goes_back_to_the_issue
    post :create, params: { attachment_id: @source.id, to: 'pdf' }
    assert_redirected_to '/issues/1'
    assert_equal 'Converting report.docx to PDF. The new file is added here in a moment: reload the page to see it.', flash[:notice]
    conversion = ConverterStudioConversion.sole
    assert_equal 'done', conversion.status
    assert_equal User.find(2), conversion.user
    assert_equal 'report.pdf', conversion.result_attachment.filename
  end

  def test_create_with_text_recognition
    pdf = attach(@issue, 'scan.pdf')
    post :create, params: { attachment_id: pdf.id, to: 'txt', ocr: '1' }
    assert_equal({ 'ocr' => true }, ConverterStudioConversion.sole.options)
  end

  def test_create_refuses_a_format_the_file_cannot_become
    post :create, params: { attachment_id: @source.id, to: 'mp4' }
    assert_redirected_to "/converter_studio/attachments/#{@source.id}/conversions/new"
    assert_equal 0, ConverterStudioConversion.count
  end

  def test_a_role_without_the_permission
    @request.session[:user_id] = 3 # dlopper, Developer of project 1
    get :new, params: { attachment_id: @source.id }
    assert_response :forbidden
    post :create, params: { attachment_id: @source.id, to: 'pdf' }
    assert_response :forbidden
    assert_equal 0, ConverterStudioConversion.count
  end

  def test_a_user_who_may_not_add_files_to_the_issue
    Role.find(2).add_permission!(:convert_attachments)
    Role.find(2).remove_permission!(:edit_issues, :add_issue_notes, :edit_own_issues)
    @request.session[:user_id] = 3
    get :new, params: { attachment_id: @source.id }
    assert_response :forbidden
  end

  def test_the_module_switched_off
    @project.disable_module!(:converter_studio)
    get :new, params: { attachment_id: @source.id }
    assert_response :forbidden
  end

  def test_anonymous_users_are_sent_to_sign_in
    @request.session[:user_id] = nil
    get :new, params: { attachment_id: @source.id }
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  def test_an_unknown_attachment
    get :new, params: { attachment_id: 999_999 }
    assert_response :not_found
  end

  def test_index_lists_the_conversions_and_the_rules
    convert(@source, 'pdf')
    convert(attach(@issue, 'damaged.docx'), 'pdf')
    ConverterStudioRule.create!(project: @project, extensions: 'heic', target_format: 'jpg', containers: 'issues')
    get :index, params: { project_id: 'ecookbook' }
    assert_response :success
    assert_select 'table.converter-studio-conversions tbody tr', 2
    assert_select 'td.status', text: /Failed: This file is damaged or is not a DOCX file\./
    assert_select 'td.status a', text: 'report.pdf'
    assert_select 'table.converter-studio-rules tr', 1
    assert_select 'form#converter-studio-rule-form'
    assert_select 'td.buttons input[value="Run again"]', 1
  end

  def test_index_without_managing_rules
    Role.find(2).add_permission!(:convert_attachments)
    @request.session[:user_id] = 3
    get :index, params: { project_id: 'ecookbook' }
    assert_response :success
    assert_select 'form#converter-studio-rule-form', 0
  end

  def test_confirm_a_price_above_the_limit
    conversion = convert(attach(@issue, 'expensive.docx'), 'pdf')
    assert_equal 'quoted', conversion.status
    post :confirm, params: { id: conversion.id }
    assert_redirected_to '/projects/ecookbook/converter_studio'
    assert_equal 'done', conversion.reload.status
    assert_equal 'expensive.pdf', conversion.result_attachment.filename
  end

  def test_run_again_a_failed_conversion
    conversion = convert(attach(@issue, 'report.docx'), 'pdf')
    conversion.update!(status: 'failed', error_code: 'network', error_message: 'x', result_attachment_id: nil)
    post :run_again, params: { id: conversion.id }
    assert_equal 'done', conversion.reload.status
    assert_nil conversion.error_code
  end

  def test_run_again_refuses_a_running_conversion
    conversion = ConverterStudioConversion.create!(project: @project, attachment: @source, source_name: 'report.docx',
                                                   container: @issue, user: User.find(2), target_format: 'pdf',
                                                   status: 'converting')
    post :run_again, params: { id: conversion.id }
    assert_response :forbidden
  end
end
