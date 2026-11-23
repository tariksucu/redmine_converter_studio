# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

# Views of the conversions: where a container is, what a status means, which formats to offer.
module ConverterStudioHelper
  # The page of an issue, a wiki page or a document.
  def converter_studio_container_path(container)
    case container
    when Issue then issue_path(container)
    when WikiPage then project_wiki_page_path(container.project, container.title)
    when Document then document_path(container)
    end
  end

  # The format a conversion makes, by its name when the list of formats is at hand.
  def converter_studio_format_name(id, catalog = @catalog)
    catalog ? catalog.name_of(id) : id.to_s.upcase
  end

  # "Converting", "Failed: <reason>"… for a conversion's status.
  def converter_studio_status_text(conversion)
    RedmineConverterStudio::StatusText.for(conversion)
  end

  # The formats offered for a file, as options of a select: [label, id].
  def converter_studio_target_options(catalog, filename)
    catalog.targets_for(filename).map do |target|
      label = catalog.name_of(target)
      if catalog.ocr_target?(filename, target)
        label = l(:converter_studio_label_ocr_target, target: label)
      elsif catalog.format_of(filename) == target
        label = l(:converter_studio_label_smaller_target, target: label)
      end
      [label, target]
    end
  end

  # What a rule converts, in words: "HEIC, HEIF → JPG on issues, wiki pages".
  def converter_studio_rule_text(rule, catalog = @catalog)
    where = rule.container_list.map { |c| l(:"converter_studio_label_container_#{c}") }.join(', ')
    l(:converter_studio_text_rule, extensions: rule.extension_list.map(&:upcase).join(', '),
                                   target: converter_studio_format_name(rule.target_format, catalog), where: where)
  end
end
