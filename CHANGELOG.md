# Changelog

## 0.1.0 (2026-07-23)

Initial release.

- Intech Grid PBF4 mapped to Spotify, system/mic/alert audio, display
  brightness, Night Shift, iTerm session picking, output device switching,
  screenshots, and Claude Code / Codex session launching.
- Learn mode captures real CC numbers from the device.
- AI customization: natural-language config edits via headless Codex or
  Claude Code (model and effort configurable), with validation, diff preview,
  backups, and rollback.
- Incoming-call mode: LEDs flash, B1 answers, B2 silences. Automatic
  detection via Notification Center (Full Disk Access) or manual trigger.
- `gridpilot` CLI: ai, notify, rollback, doctor, schema.
- Config hot-reload on hand edits, with validation gate.

## 0.2.0 (2026-07-23)

- Speaks the Grid serial protocol directly (v1.5.5, byte-validated against
  Intech's reference): module discovery, config read/write with read-back
  verification, flash store. No Grid Editor required.
- `gridpilot setup-leds`: one-command LED theme deployment to every module.
- `gridpilot generate-map` / Detect Modules: auto-add controls for chained
  modules using the dynamic layout formulas.
- Six LED themes with level-true switching; channel-aware controls for
  multi-module chains; named config presets; relative encoder decode modes;
  Series 3 compatibility (verified same protocol + layouts).
