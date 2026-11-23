/*
 * Converter Studio for Redmine
 * Copyright (C) 2026 Converter Studio
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Puts each "Convert…" link the page was given (#converter-studio-links, made by the plugin's
 * view hook for the attachments the user may convert) into its attachment's row, or, on an
 * attachment's own page, next to its Download link. Without this script the links stay hidden.
 */
/* global document */
(function () {
  'use strict';

  function attachmentId(href) {
    var match = /\/attachments\/(?:download\/)?(\d+)(?:[/?#]|$)/.exec(href || '');
    return match ? match[1] : null;
  }

  function place() {
    var holder = document.getElementById('converter-studio-links');
    if (!holder) return;
    var items = {};
    holder.querySelectorAll('.converter-studio-item').forEach(function (item) {
      items[item.getAttribute('data-attachment-id')] = item;
    });

    if (holder.getAttribute('data-place') === 'contextual') {
      var bar = document.querySelector('#content > .contextual');
      var only = holder.querySelector('.converter-studio-item');
      if (bar && only) bar.appendChild(only);
      return;
    }

    document.querySelectorAll('div.attachments table tr').forEach(function (row) {
      var link = row.querySelector('a.icon-attachment');
      var id = link && attachmentId(link.getAttribute('href'));
      var item = id && items[id];
      if (!item) return;
      // An attachment listed twice (an issue and its journal) gets a copy of its link.
      var target = item.parentNode === holder ? item : item.cloneNode(true);
      link.parentNode.appendChild(target);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', place);
  } else {
    place();
  }
})();
