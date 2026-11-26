# frozen_string_literal: true

# Converter Studio for Redmine: convert attachments with converter.studio.
# Copyright (C) 2026 Converter Studio
#
# This program is free software; you can redistribute it and/or modify it under the terms of the
# GNU General Public License as published by the Free Software Foundation; either version 2 of the
# License, or (at your option) any later version. See LICENSE.

# The plugin's code outside Rails' own folders (loaded by Redmine's autoloader).
module RedmineConverterStudio
  VERSION = '1.1.0'
  PLUGIN_ID = :redmine_converter_studio
  # Names this plugin on its API calls (converter.studio's statistics of its connectors).
  CLIENT_NAME = 'redmine'
  DEFAULT_BASE_URL = 'https://converter.studio/api'
  # A file that costs more than this waits for someone to approve its price (the API's default).
  DEFAULT_MAX_CREDITS = 20
end
