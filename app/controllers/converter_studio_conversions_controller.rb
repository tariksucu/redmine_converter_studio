# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

# Converting one attachment (the "Convert…" page), and a project's list of conversions with its
# automatic conversions, where a price above the limit is approved and a failure run again.
class ConverterStudioConversionsController < ApplicationController
  include ConverterStudioHelper
  helper :converter_studio

  before_action :find_attachment, only: [:new, :create]
  before_action :find_project_by_project_id, only: :index
  before_action :find_conversion, only: [:confirm, :run_again]
  before_action :authorize
  before_action :authorize_attachment, only: [:new, :create]

  def index
    @conversions = ConverterStudioConversion.where(project_id: @project.id).recent_first.limit(100)
                                            .preload(:attachment, :result_attachment, :user, :container)
                                            .to_a.select(&:visible?)
    @rules = ConverterStudioRule.where(project_id: @project.id).order(:id).to_a
    @can_manage_rules = User.current.allowed_to?(:manage_converter_studio_rules, @project)
    load_catalog
  end

  def new
    load_catalog
    @targets = @catalog ? converter_studio_target_options(@catalog, @attachment.filename) : []
    @conversions = ConverterStudioConversion.where(attachment_id: @attachment.id).recent_first.limit(10).to_a
  end

  def create
    raise RedmineConverterStudio::ApiError.new('notConfigured', l(:converter_studio_error_notConfigured)) unless
      RedmineConverterStudio::Configuration.configured?

    catalog = RedmineConverterStudio::Catalog.load
    target = params[:to].to_s
    unless catalog.convertible?(@attachment.filename, target)
      flash[:error] = l(:converter_studio_error_unsupportedConversion)
      return redirect_to(new_converter_studio_conversion_path(@attachment))
    end

    options = {}
    options['ocr'] = true if params[:ocr] == '1' && catalog.ocr_option?(@attachment.filename, target)
    ConverterStudioConversion.start!(attachment: @attachment, user: User.current, target: target, options: options)
    flash[:notice] = l(:converter_studio_notice_started, source: @attachment.filename, target: catalog.name_of(target))
    redirect_to converter_studio_container_path(@attachment.container) || project_converter_studio_path(@project)
  rescue RedmineConverterStudio::ApiError => e
    flash[:error] = e.message.presence || l(:converter_studio_error_unexpected)
    redirect_to new_converter_studio_conversion_path(@attachment)
  end

  # Goes ahead with a conversion whose price was above the limit.
  def confirm
    return render_403 unless @conversion.quoted? && @conversion.remote_id.present?

    RedmineConverterStudio::Client.from_settings.confirm(@conversion.remote_id)
    @conversion.update!(status: 'converting', error_message: nil)
    @conversion.enqueue
    flash[:notice] = l(:converter_studio_notice_confirmed, source: @conversion.source_name)
    redirect_back_or_default project_converter_studio_path(@project)
  rescue RedmineConverterStudio::ApiError => e
    flash[:error] = e.message.presence || l(:converter_studio_error_unexpected)
    redirect_back_or_default project_converter_studio_path(@project)
  end

  # Runs a failed conversion again from the start, or a lost one from where it was.
  def run_again
    return render_403 unless @conversion.retryable?

    @conversion.failed? ? @conversion.reset! : @conversion.touch
    @conversion.enqueue
    flash[:notice] = l(:converter_studio_notice_retried, source: @conversion.source_name)
    redirect_back_or_default project_converter_studio_path(@project)
  end

  private

  def find_attachment
    @attachment = Attachment.find(params[:attachment_id])
    @project = @attachment.project
    render_404 unless @project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_conversion
    @conversion = ConverterStudioConversion.find(params[:id])
    @project = @conversion.project
    render_404 unless @project && @conversion.visible?
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  # The project's permission is checked by authorize; this checks the file and where it goes.
  def authorize_attachment
    deny_access unless RedmineConverterStudio::Access.can_convert?(@attachment, User.current)
  end

  def load_catalog
    @catalog = RedmineConverterStudio::Catalog.load
  rescue RedmineConverterStudio::ApiError => e
    @catalog = nil
    @catalog_error = e.message
  end
end
