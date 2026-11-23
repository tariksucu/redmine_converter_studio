# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

# A project's automatic conversions: new attachments with these extensions, on these kinds of
# containers, are converted to one format. A project has none until someone adds one.
class CreateConverterStudioRules < ActiveRecord::Migration[7.2]
  def change
    create_table :converter_studio_rules do |t|
      t.integer :project_id, null: false
      t.string :extensions, limit: 255, null: false
      t.string :target_format, limit: 16, null: false
      t.string :containers, limit: 64, null: false, default: 'issues'
      t.boolean :ocr, null: false, default: false
      t.boolean :active, null: false, default: true
      t.integer :author_id
      t.datetime :created_on, null: false
      t.datetime :updated_on, null: false
    end
    add_index :converter_studio_rules, :project_id
  end
end
