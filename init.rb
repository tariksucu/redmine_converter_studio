# frozen_string_literal: true

# Converter Studio for Redmine: convert attachments with converter.studio.
# Copyright (C) 2026 Converter Studio
#
# This program is free software; you can redistribute it and/or modify it under the terms of the
# GNU General Public License as published by the Free Software Foundation; either version 2 of the
# License, or (at your option) any later version. See LICENSE.

Redmine::Plugin.register :redmine_converter_studio do
  name 'Converter Studio'
  author 'Converter Studio'
  description 'Convert issue, wiki and document attachments with Converter Studio: ' \
              'Office files to PDF, HEIC photos to JPG, scans to text (OCR), videos to MP4.'
  version RedmineConverterStudio::VERSION
  url 'https://github.com/tariksucu/redmine_converter_studio'
  author_url 'https://converter.studio'

  requires_redmine version_or_higher: '6.1.0'

  settings default: {
    'base_url' => RedmineConverterStudio::DEFAULT_BASE_URL,
    'max_credits' => RedmineConverterStudio::DEFAULT_MAX_CREDITS.to_s
  }, partial: 'settings/converter_studio'

  project_module :converter_studio do
    permission :convert_attachments,
               { converter_studio_conversions: [:index, :new, :create, :confirm, :run_again] },
               require: :loggedin
    permission :manage_converter_studio_rules,
               { converter_studio_rules: [:create, :update, :destroy] },
               require: :member
  end

  menu :project_menu, :converter_studio,
       { controller: 'converter_studio_conversions', action: 'index' },
       caption: :label_converter_studio, param: :project_id, after: :files
end

# Redmine has no hook for a new attachment or for saving plugin settings: these add a callback to
# each (no core method is replaced). The view hooks register themselves when loaded.
Attachment.include RedmineConverterStudio::AttachmentPatch
Setting.include RedmineConverterStudio::SettingPatch
RedmineConverterStudio::Hooks
