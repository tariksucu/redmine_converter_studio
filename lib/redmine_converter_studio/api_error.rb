# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

module RedmineConverterStudio
  # An error of the converter.studio API (its code and its own sentence, meant for people) or of
  # this plugin's work around it. The message never holds the API key.
  class ApiError < StandardError
    CODE = /\A[A-Za-z0-9_]{1,64}\z/

    attr_reader :code, :status, :params

    def initialize(code, message, status: nil, params: {})
      super(message)
      @code = code.to_s.match?(CODE) ? code.to_s : 'unexpected'
      @status = status
      @params = params
    end

    # Worth trying again later: the network, a busy server, too many requests.
    def transient?
      %w[network serverBusy tooManyRequests].include?(code) || status.to_i == 429 || status.to_i >= 500
    end
  end
end
