# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

require_relative '../test_helper'

class ConverterStudioRulesTest < ActiveSupport::TestCase
  include ConverterStudioTestHelper

  def setup
    setup_converter_studio
    @issue = Issue.find(1)
  end

  def add_rule(**attributes)
    ConverterStudioRule.create!({ project: @project, extensions: 'heic heif', target_format: 'jpg',
                                  containers: %w[issues] }.merge(attributes))
  end

  def test_no_rule_no_conversion
    attach(@issue, 'IMG_0001.heic')
    assert_equal 0, ConverterStudioConversion.count
  end

  def test_a_new_attachment_is_converted_by_the_projects_rule
    rule = add_rule
    source = attach(@issue, 'IMG_0001.HEIC')
    conversion = only(ConverterStudioConversion.all)
    assert_equal [source, rule, 'jpg', 'done'], [conversion.attachment, conversion.rule, conversion.target_format, conversion.status]
    assert_equal User.find(2), conversion.user
    assert_equal 'IMG_0001.jpg', conversion.result_attachment.filename
    # The result is not converted again.
    assert_equal 1, ConverterStudioConversion.count
  end

  def test_a_file_uploaded_first_and_attached_later
    add_rule
    upload = Attachment.create!(file: Redmine::MockFile.new(original_filename: 'IMG_0002.heif', content: 'heif', size: 4),
                                author: User.find(2))
    assert_equal 0, ConverterStudioConversion.count
    issue = Issue.find(2)
    issue.init_journal(User.find(2))
    issue.save_attachments([{ 'token' => upload.token }])
    issue.save!
    assert_equal 'IMG_0002.jpg', only(ConverterStudioConversion.all).result_attachment.filename
  end

  def test_rules_apply_only_where_they_are_meant
    add_rule(containers: %w[wiki])
    attach(@issue, 'IMG_0001.heic')
    add_rule(active: false)
    attach(@issue, 'IMG_0002.heic')
    attach(Document.find(1), 'IMG_0003.heic')
    assert_equal 0, ConverterStudioConversion.count

    attach(WikiPage.find(1), 'IMG_0004.heic')
    assert_equal 1, ConverterStudioConversion.count
  end

  def test_other_extensions_projects_and_a_switched_off_module
    add_rule
    attach(@issue, 'notes.txt')
    assert_equal 0, ConverterStudioConversion.count
    attach(Issue.find(4), 'IMG_0001.heic') # project 2
    assert_equal 0, ConverterStudioConversion.count
    @project.disable_module!(:converter_studio)
    attach(Issue.find(1), 'IMG_0002.heic')
    assert_equal 0, ConverterStudioConversion.count
  end

  def test_no_key_no_automatic_conversion
    add_rule
    Setting.plugin_redmine_converter_studio = { 'base_url' => @api.base_url, 'remove_api_key' => '1' }
    attach(@issue, 'IMG_0001.heic')
    assert_equal 0, ConverterStudioConversion.count
  end

  def test_a_result_already_there_is_not_made_again
    add_rule
    attach(@issue, 'IMG_0001.jpg')
    attach(@issue, 'IMG_0001.heic')
    assert_equal 0, ConverterStudioConversion.count
  end

  def test_extensions_and_containers_are_cleaned
    rule = ConverterStudioRule.new(project: @project, extensions: 'HEIC, .heif ;docx', target_format: 'pdf',
                                   containers: ['issues', 'documents', 'news', ''])
    assert rule.valid?
    assert_equal %w[heic heif docx], rule.extension_list
    assert_equal %w[issues documents], rule.container_list
    assert_not ConverterStudioRule.new(project: @project, extensions: '', target_format: 'pdf', containers: 'issues').valid?
    assert_not ConverterStudioRule.new(project: @project, extensions: 'a/b', target_format: 'pdf', containers: 'issues').valid?
    assert_not ConverterStudioRule.new(project: @project, extensions: 'docx', target_format: 'pdf', containers: '').valid?
    assert_not rule.matches?('issues', 'report.pdf')
  end
end
