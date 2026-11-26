# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

module RedmineConverterStudio
  # After each request Redmine serves, Recovery looks (at most once a minute, and only with an
  # in-process queue adapter) for conversions whose job a restart lost. This adds one callback to
  # ApplicationController; no core method is replaced, and a request is never slowed down much or
  # broken by it (Recovery.poke never raises).
  module ControllerPatch
    extend ActiveSupport::Concern

    included do
      after_action :converter_studio_recover
    end

    private

    def converter_studio_recover
      Recovery.poke
    end
  end
end
