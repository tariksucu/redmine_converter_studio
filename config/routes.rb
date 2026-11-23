# frozen_string_literal: true

# Converter Studio for Redmine
# Copyright (C) 2026 Converter Studio
# SPDX-License-Identifier: GPL-2.0-or-later

# Redmine reads this file inside its own routes block, after its own routes: every path here has a
# converter_studio part, so none is taken by a core route (attachments/:id/:filename…).
get 'converter_studio/attachments/:attachment_id/conversions/new',
    to: 'converter_studio_conversions#new', as: 'new_converter_studio_conversion', attachment_id: /\d+/
post 'converter_studio/attachments/:attachment_id/conversions',
     to: 'converter_studio_conversions#create', as: 'converter_studio_conversions', attachment_id: /\d+/
post 'converter_studio/conversions/:id/confirm',
     to: 'converter_studio_conversions#confirm', as: 'confirm_converter_studio_conversion', id: /\d+/
post 'converter_studio/conversions/:id/run_again',
     to: 'converter_studio_conversions#run_again', as: 'run_again_converter_studio_conversion', id: /\d+/
get 'projects/:project_id/converter_studio',
    to: 'converter_studio_conversions#index', as: 'project_converter_studio'
post 'projects/:project_id/converter_studio/rules',
     to: 'converter_studio_rules#create', as: 'project_converter_studio_rules'
patch 'converter_studio/rules/:id', to: 'converter_studio_rules#update', as: 'converter_studio_rule', id: /\d+/
delete 'converter_studio/rules/:id', to: 'converter_studio_rules#destroy', id: /\d+/
