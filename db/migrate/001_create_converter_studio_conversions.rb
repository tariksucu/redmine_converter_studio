# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

# One row per attachment conversion: what was asked, how far it got, what it cost and, for a
# failure, why (a code from a fixed list and the API's own sentence).
class CreateConverterStudioConversions < ActiveRecord::Migration[7.2]
  def change
    create_table :converter_studio_conversions do |t|
      t.integer :project_id, null: false
      t.integer :attachment_id
      t.string :source_name, limit: 255, null: false, default: ''
      t.string :container_type, limit: 30
      t.integer :container_id
      t.integer :user_id
      t.integer :rule_id
      t.string :target_format, limit: 16, null: false
      t.text :options
      t.string :status, limit: 20, null: false, default: 'queued'
      t.string :upload_id, limit: 128
      t.string :remote_id, limit: 128
      t.integer :credits
      t.integer :max_credits
      t.string :error_code, limit: 64
      t.string :error_message, limit: 500
      t.integer :result_attachment_id
      t.integer :attempts, null: false, default: 0
      t.datetime :locked_until
      t.datetime :finished_on
      t.datetime :created_on, null: false
      t.datetime :updated_on, null: false
    end
    add_index :converter_studio_conversions, [:project_id, :created_on]
    add_index :converter_studio_conversions, :attachment_id
    add_index :converter_studio_conversions, [:container_type, :container_id]
    add_index :converter_studio_conversions, :status
  end
end
