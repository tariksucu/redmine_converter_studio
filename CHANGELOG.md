# Changelog

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
