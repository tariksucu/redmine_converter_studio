# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

module RedmineConverterStudio
  # The attachments of the page being shown (an issue, a wiki page, a document, or one attachment's
  # own page) that the current user may convert, with each one's latest conversion when it is not
  # done yet or failed.
  module PageLinks
    Item = Struct.new(:attachment, :conversion)
    PAGES = {
      %w[issues show] => :@issue,
      %w[wiki show] => :@page,
      %w[documents show] => :@document,
      %w[attachments show] => :@attachment
    }.freeze

    module_function

    def items(view, user = User.current)
      return [] unless user.logged? && Configuration.configured?

      project = view.instance_variable_get(:@project)
      return [] unless Access.enabled?(project) && user.allowed_to?(:convert_attachments, project)

      attachments = attachments_of(view).select { |a| Access.can_convert?(a, user) }
      attachments = convertible(attachments)
      return [] if attachments.empty?

      latest = latest_conversions(attachments.map(&:id))
      attachments.map { |a| Item.new(a, latest[a.id]) }
    end

    # The attachments page of these items: one attachment's own page puts its link in the title bar.
    def attachment_page?(view)
      [view.controller_name, view.action_name] == %w[attachments show]
    end

    def attachments_of(view)
      ivar = PAGES[[view.controller_name, view.action_name]]
      record = ivar && view.instance_variable_get(ivar)
      return [] if record.nil? || record.new_record?

      record.is_a?(Attachment) ? [record] : record.attachments.to_a
    end

    # Those converter.studio converts; all of them when the list of formats cannot be had now
    # (the conversion page then says why).
    def convertible(attachments)
      catalog = Catalog.load(Client.from_settings, quick: true)
      return attachments if catalog.empty?

      attachments.select { |a| catalog.targets_for(a.filename).any? }
    rescue ApiError
      attachments
    end

    def latest_conversions(ids)
      ConverterStudioConversion.where(attachment_id: ids).where(created_on: 1.day.ago..)
                               .recent_first.to_a.group_by(&:attachment_id)
                               .transform_values(&:first).reject { |_, c| c.done? }
    end
  end
end
