# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

module RedmineConverterStudio
  # Who may convert which attachment: the attachments of issues, wiki pages and documents, in a
  # project with the Converter Studio module, by a user whose role has "Convert attachments", who
  # can see the file and may add files to the same issue, page or document.
  module Access
    KINDS = { 'Issue' => 'issues', 'WikiPage' => 'wiki', 'Document' => 'documents' }.freeze

    module_function

    # "issues", "wiki" or "documents"; nil for other containers (news, forums, project files…).
    def kind_of(container)
      container && KINDS[container.class.base_class.name]
    end

    def enabled?(project)
      project.present? && project.module_enabled?(:converter_studio).present?
    end

    def can_convert?(attachment, user = User.current)
      container = attachment&.container
      return false unless kind_of(container)

      project = attachment.project
      enabled?(project) && user.allowed_to?(:convert_attachments, project) &&
        attachment.visible?(user) && can_add_to?(container, user)
    end

    # Whether the user may add a file to this issue, wiki page or document (Redmine's own rules).
    def can_add_to?(container, user)
      project = container.project
      case container
      when Issue
        container.attachments_addable?(user)
      when WikiPage
        container.editable_by?(user) && user.allowed_to?(:edit_wiki_pages, project)
      when Document
        container.visible?(user) &&
          (user.allowed_to?(:add_documents, project) || user.allowed_to?(:edit_documents, project))
      else
        false
      end
    end
  end
end
