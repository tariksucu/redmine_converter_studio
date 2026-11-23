# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

# Load the Redmine helper
require_relative '../../../test/test_helper'
require_relative 'support/fake_api'

module ConverterStudioTestHelper
  def setup_converter_studio(key: FakeConverterStudioApi::KEY)
    @api = FakeConverterStudioApi.instance
    @api.reset
    RedmineConverterStudio::Catalog.forget
    set_tmp_attachments_directory
    Setting.plugin_redmine_converter_studio = { 'base_url' => @api.base_url, 'max_credits' => '20', 'api_key' => key }
    @project = Project.find(1)
    @project.enable_module!(:converter_studio)
    Role.find(1).add_permission!(:convert_attachments, :manage_converter_studio_rules)
    User.current = nil
  end

  # A new attachment with these bytes on an issue, a wiki page or a document.
  def attach(container, name, content = 'Hello from Redmine', author: User.find(2))
    file = Redmine::MockFile.new(original_filename: name, content: content, size: content.bytesize,
                                 content_type: 'application/octet-stream')
    Attachment.create!(file: file, author: author, container: container)
  end

  def convert(attachment, target, user: User.find(2), options: {})
    ConverterStudioConversion.start!(attachment: attachment, user: user, target: target, options: options).reload
  end
end
