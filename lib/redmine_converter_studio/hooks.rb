# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

module RedmineConverterStudio
  # Redmine's view hooks: the plugin's stylesheet and script in the page head, and at the end of
  # the page a "Convert…" link for each attachment the user may convert, which the script places
  # in the attachment's row (Redmine's attachment list has no hook of its own).
  class Hooks < Redmine::Hook::ViewListener
    render_on :view_layouts_base_html_head, partial: 'converter_studio/head'
    render_on :view_layouts_base_body_bottom, partial: 'converter_studio/page_links'
  end
end
