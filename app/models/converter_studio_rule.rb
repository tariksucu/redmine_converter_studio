# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

# An automatic conversion of a project: new attachments with these extensions, on these kinds of
# containers (issues, wiki pages, documents), become this format. Off until someone adds one.
# (Redmine 6.0 and later have ApplicationRecord; 5.x models inherit ActiveRecord::Base directly.)
class ConverterStudioRule < (defined?(ApplicationRecord) ? ApplicationRecord : ActiveRecord::Base)
  CONTAINERS = %w[issues wiki documents].freeze
  EXTENSION = /\A[a-z0-9]{1,10}(\.[a-z0-9]{1,10})?\z/

  belongs_to :project
  belongs_to :author, class_name: 'User', optional: true

  validates :target_format, format: { with: ConverterStudioConversion::TARGET }
  validate :validate_extensions
  validate :validate_containers

  scope :active, -> { where(active: true) }

  # "HEIC, .heif docx" → "heic heif docx"
  def extensions=(value)
    list = value.to_s.downcase.split(/[\s,;]+/).map { |ext| ext.delete_prefix('.').strip }.compact_blank.uniq
    super(list.join(' '))
  end

  def extension_list
    extensions.to_s.split
  end

  def containers=(value)
    list = Array(value).flat_map { |v| v.to_s.split(/[\s,]+/) }.compact_blank.uniq
    super((CONTAINERS & list).join(','))
  end

  def container_list
    containers.to_s.split(',')
  end

  # Whether a new attachment of this kind of container ("issues"…) and name is for this rule.
  def matches?(kind, filename)
    return false unless active? && container_list.include?(kind)

    name = filename.to_s.downcase
    extension_list.any? { |ext| name.end_with?(".#{ext}") } && !name.end_with?(".#{target_format}")
  end

  def options_hash
    ocr? ? { 'ocr' => true } : {}
  end

  private

  def validate_extensions
    list = extension_list
    errors.add(:extensions, :blank) if list.empty?
    errors.add(:extensions, :invalid) unless list.all? { |ext| ext.match?(EXTENSION) }
  end

  def validate_containers
    errors.add(:containers, :blank) if container_list.empty?
  end
end
