# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

# A project's automatic conversions: added, switched on or off, and deleted from the project's
# Converter Studio page, by roles with "Manage automatic conversions".
class ConverterStudioRulesController < ApplicationController
  before_action :find_project_by_project_id, only: :create
  before_action :find_rule, only: [:update, :destroy]
  before_action :authorize

  def create
    rule = ConverterStudioRule.new(project: @project, author: User.current)
    values = params[:rule] || {}
    rule.extensions = values[:extensions]
    rule.target_format = values[:target_format].to_s
    rule.containers = values[:containers]
    rule.ocr = values[:ocr] == '1'
    check_formats(rule)
    if rule.errors.empty? && rule.save
      flash[:notice] = l(:notice_successful_create)
    else
      flash[:error] = rule.errors.full_messages.join(' ')
    end
    redirect_to project_converter_studio_path(@project, anchor: 'rules')
  end

  def update
    @rule.update!(active: params[:active] == '1')
    flash[:notice] = l(:notice_successful_update)
    redirect_to project_converter_studio_path(@project, anchor: 'rules')
  end

  def destroy
    @rule.destroy
    flash[:notice] = l(:notice_successful_delete)
    redirect_to project_converter_studio_path(@project, anchor: 'rules')
  end

  private

  def find_rule
    @rule = ConverterStudioRule.find(params[:id])
    @project = @rule.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  # Every extension must be one converter.studio reads and can turn into the chosen format.
  def check_formats(rule)
    return unless rule.valid?

    catalog = RedmineConverterStudio::Catalog.load
    rule.extension_list.each do |ext|
      next if catalog.convertible?("file.#{ext}", rule.target_format)

      rule.errors.add(:base, l(:converter_studio_error_rule_unsupported,
                               extension: ext.upcase, target: catalog.name_of(rule.target_format)))
    end
  rescue RedmineConverterStudio::ApiError => e
    rule.errors.add(:base, e.message)
  end
end
