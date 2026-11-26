# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

require_relative '../test_helper'

# The "Convert…" links the view hooks add to the pages of issues, wiki pages, documents and
# attachments.
class ConverterStudioIssuePageTest < Redmine::ControllerTest
  include ConverterStudioTestHelper
  tests IssuesController

  def setup
    setup_converter_studio
    @source = attach(Issue.find(1), 'report.docx')
    @other = attach(Issue.find(1), 'photo.xyz')
  end

  def test_links_for_a_user_who_may_convert
    @request.session[:user_id] = 2
    get :show, params: { id: 1 }
    assert_response :success
    assert_select 'link[href*="converter_studio"][rel=stylesheet]'
    assert_select 'script[src*="converter_studio"]'
    assert_select '#converter-studio-links[hidden]' do
      assert_select ".converter-studio-item[data-attachment-id='#{@source.id}'] a.converter-studio-convert" \
                    "[href='/converter_studio/attachments/#{@source.id}/conversions/new']"
      # converter.studio does not read .xyz files.
      assert_select ".converter-studio-item[data-attachment-id='#{@other.id}']", 0
    end
  end

  def test_the_latest_failure_is_shown_next_to_the_file
    convert(attach(Issue.find(1), 'damaged.docx'), 'pdf')
    @request.session[:user_id] = 2
    get :show, params: { id: 1 }
    assert_select '.converter-studio-state-failed', text: 'Failed: This file is damaged or is not a DOCX file.'
  end

  def test_no_links_without_the_permission_the_module_or_a_key
    @request.session[:user_id] = 3
    get :show, params: { id: 1 }
    assert_select '#converter-studio-links', 0

    @request.session[:user_id] = 2
    @project.disable_module!(:converter_studio)
    get :show, params: { id: 1 }
    assert_select '#converter-studio-links', 0
    assert_select 'script[src*="converter_studio"]', 0

    @project.enable_module!(:converter_studio)
    Setting.plugin_redmine_converter_studio = { 'base_url' => @api.base_url, 'remove_api_key' => '1' }
    get :show, params: { id: 1 }
    assert_select '#converter-studio-links', 0
  end

  def test_anonymous_visitors_get_nothing
    get :show, params: { id: 1 }
    assert_response :success
    assert_select '#converter-studio-links', 0
  end

  # After a request, conversions a restart left behind are looked for (RedmineConverterStudio::Recovery).
  def test_a_request_lets_lost_conversions_be_looked_for
    RedmineConverterStudio::Recovery.expects(:poke).once
    get :show, params: { id: 1 }
    assert_response :success
  end
end

class ConverterStudioAttachmentPageTest < Redmine::ControllerTest
  include ConverterStudioTestHelper
  tests AttachmentsController

  def test_the_link_goes_next_to_download
    setup_converter_studio
    source = attach(Issue.find(1), 'report.docx')
    @request.session[:user_id] = 2
    get :show, params: { id: source.id }
    assert_response :success
    # An SVG icon and its label on Redmine 6.0 and later; the label and the icon classes on 5.x.
    label = Redmine::VERSION::MAJOR >= 6 ? ' span.icon-label' : ''
    assert_select "#converter-studio-links[data-place=contextual] a.converter-studio-convert.icon.icon-reload#{label}",
                  text: 'Convert…'
  end
end

class ConverterStudioWikiPageTest < Redmine::ControllerTest
  include ConverterStudioTestHelper
  tests WikiController

  def test_wiki_page_attachments_get_links
    setup_converter_studio
    source = attach(WikiPage.find(1), 'IMG_0001.heic')
    @request.session[:user_id] = 2
    get :show, params: { project_id: 'ecookbook', id: 'CookBook_documentation' }
    assert_response :success
    assert_select ".converter-studio-item[data-attachment-id='#{source.id}']"
  end
end

class ConverterStudioSettingsPageTest < Redmine::ControllerTest
  include ConverterStudioTestHelper
  tests SettingsController

  def setup
    setup_converter_studio
    @request.session[:user_id] = 1 # admin
  end

  def test_the_page_never_shows_the_key_and_checks_the_connection
    get :plugin, params: { id: 'redmine_converter_studio' }
    assert_response :success
    assert_select 'input#settings_new_api_key[type=password][value=""]'
    assert_not_includes response.body, FakeConverterStudioApi::KEY
    assert_select '.converter-studio-ok', text: /Connected to owner@example\.com \(pro plan, 480 credits left\)/
    assert_select 'input#settings_base_url[value=?]', @api.base_url
  end

  def test_a_wrong_key_shows_the_api_sentence
    Setting.plugin_redmine_converter_studio = { 'base_url' => @api.base_url, 'api_key' => 'cvs_live_wrong_key_0000' }
    get :plugin, params: { id: 'redmine_converter_studio' }
    assert_select '.converter-studio-error', text: 'This API key does not work. Check it on your account page.'
  end

  def test_saving_with_an_empty_key_field_keeps_the_key
    post :plugin, params: { id: 'redmine_converter_studio',
                            settings: { new_api_key: '', base_url: @api.base_url, max_credits: '7' } }
    assert_redirected_to '/settings/plugin/redmine_converter_studio'
    assert_equal FakeConverterStudioApi::KEY, RedmineConverterStudio::Configuration.api_key
    assert_equal 7, RedmineConverterStudio::Configuration.max_credits
  end
end
