# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

require_relative '../test_helper'

class ConverterStudioRulesControllerTest < Redmine::ControllerTest
  include ConverterStudioTestHelper

  def setup
    setup_converter_studio
    @request.session[:user_id] = 2
  end

  def test_create_a_rule
    post :create, params: { project_id: 'ecookbook',
                            rule: { extensions: 'HEIC heif', target_format: 'jpg', containers: %w[issues wiki] } }
    assert_redirected_to '/projects/ecookbook/converter_studio#rules'
    rule = ConverterStudioRule.sole
    assert_equal ['heic heif', 'jpg', 'issues,wiki', true, User.find(2)],
                 [rule.extensions, rule.target_format, rule.containers, rule.active, rule.author]
  end

  def test_an_extension_that_cannot_become_the_format
    post :create, params: { project_id: 'ecookbook', rule: { extensions: 'docx xyz', target_format: 'jpg', containers: %w[issues] } }
    assert_equal 0, ConverterStudioRule.count
    assert_includes flash[:error], 'Converter Studio cannot convert DOCX files to JPG.'
    assert_includes flash[:error], 'Converter Studio cannot convert XYZ files to JPG.'
  end

  def test_a_rule_needs_extensions_and_containers
    post :create, params: { project_id: 'ecookbook', rule: { extensions: ' ', target_format: 'jpg' } }
    assert_equal 0, ConverterStudioRule.count
    assert flash[:error].present?
  end

  def test_switch_off_and_delete
    rule = ConverterStudioRule.create!(project: @project, extensions: 'heic', target_format: 'jpg', containers: 'issues')
    patch :update, params: { id: rule.id, active: '0' }
    assert_not rule.reload.active?
    delete :destroy, params: { id: rule.id }
    assert_equal 0, ConverterStudioRule.count
  end

  def test_roles_without_the_permission
    Role.find(2).add_permission!(:convert_attachments)
    @request.session[:user_id] = 3
    post :create, params: { project_id: 'ecookbook', rule: { extensions: 'heic', target_format: 'jpg', containers: %w[issues] } }
    assert_response :forbidden
    rule = ConverterStudioRule.create!(project: @project, extensions: 'heic', target_format: 'jpg', containers: 'issues')
    delete :destroy, params: { id: rule.id }
    assert_response :forbidden
    assert_equal 1, ConverterStudioRule.count
  end
end
