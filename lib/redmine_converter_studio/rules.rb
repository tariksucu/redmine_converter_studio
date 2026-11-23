# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

module RedmineConverterStudio
  # A project's automatic conversions (ConverterStudioRule), applied to a new attachment. Only
  # cheap checks happen here, in the request that saved the file: the job does the rest.
  module Rules
    module_function

    def apply(attachment)
      container = attachment.container
      kind = Access.kind_of(container)
      project = container&.project
      return [] unless kind && Access.enabled?(project) && Configuration.configured?

      rules = ConverterStudioRule.active.where(project_id: project.id).order(:id).to_a
      rules.filter_map do |rule|
        next unless rule.matches?(kind, attachment.filename)
        next if result_present?(container, attachment, rule.target_format)

        ConverterStudioConversion.start!(attachment: attachment, user: attachment.author || User.anonymous,
                                         target: rule.target_format, options: rule.options_hash, rule: rule)
      end
    end

    # A file named like the result is there already: the file was converted before (an issue
    # copied with its files) or by hand.
    def result_present?(container, attachment, target)
      name = "#{File.basename(attachment.filename.to_s, '.*')}.#{target}".downcase
      container.attachments.where.not(id: attachment.id).any? { |a| a.filename.to_s.downcase == name }
    end
  end
end
