# Changelog

## 1.1.0 (unreleased)

- **Redmine 6.0, 5.1 and 5.0 too**, besides 7.0 and 6.1: the installs that come with Debian 13
  (Redmine 6.0.5), Debian 12 (5.0.4) and older images. The plugin uses each version's own way
  where they differ (Rails 6.1 or 7.2 migrations and serialization, `ApplicationRecord` and
  `ApplicationJob` where Redmine has them, Redmine 6's SVG icons or 5.x's icon classes), and is
  tested on the newest release of each (5.0.14, 5.1.13, 6.0.12, 6.1.6, 7.0.3).
- **Conversions a restart cut off finish on their own.** Redmine's default Active Job adapter
  (`async`) keeps jobs in the memory of the web server, so a restart, a deploy or a crash lost the
  conversions it was running or about to run, until someone ran
  `rake redmine:converter_studio:resume` or clicked **Run again** half an hour later. Now, with
  that adapter, Redmine looks for them after the requests it serves (at most once a minute in each
  process) and runs them again from where they stopped: a conversion already started at Converter
  Studio is waited for and its result added, never uploaded, started or paid for again. Persistent
  adapters (Sidekiq, Solid Queue, GoodJob…) keep their jobs over a restart and are left as they
  were.
- A run holds its conversion for two minutes at a time (it was half an hour) and renews the hold
  while it works, uploads and downloads included; a run that stalled for longer and lost the
  conversion to another one stops before it starts (and pays for) a conversion of its own or adds a
  file. The rake task now takes the conversions nobody holds whose run is overdue.
- A new migration adds two columns to `converter_studio_conversions` (`locked_by`, `run_after`):
  run `bundle exec rake redmine:plugins:migrate RAILS_ENV=production` after updating.

## 1.0.0 (unreleased)

First release, for Redmine 7.0 and 6.1.

- A "Convert…" link on the attachments of issues, wiki pages and documents, with the formats
  Converter Studio converts each file to; the result is added next to the original, with a journal
  entry on an issue.
- Conversions in the background (Active Job), with long polling, an `Idempotency-Key` and every
  step saved, so a run that stops goes on without a second upload or charge.
- Automatic conversions per project, off until someone adds one.
- A project module, the "Convert attachments" and "Manage automatic conversions" permissions, and a
  project page with the conversions, their cost and Converter Studio's reason for each failure.
- The API key in the plugin settings, encrypted with Redmine's `database_cipher_key`, or from the
  `CONVERTER_STUDIO_API_KEY` environment variable.
- `rake redmine:converter_studio:resume` for conversions a restart interrupted.
- English texts.
