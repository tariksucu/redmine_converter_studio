# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

# Who holds a conversion (a token of the job run working on it) and when its next run is due, so a
# run that lost its hold never charges or writes, and a job lost in a restart is noticed and run
# again. Rails 7.2's migrations where Redmine runs on it (6.0 and later), Rails 6.1's on Redmine 5.x.
class AddQueueColumnsToConverterStudioConversions < ActiveRecord::Migration[Rails.version.to_f >= 7.2 ? 7.2 : 6.1]
  def change
    add_column :converter_studio_conversions, :locked_by, :string, limit: 32
    add_column :converter_studio_conversions, :run_after, :datetime
  end
end
