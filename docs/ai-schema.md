# GridPilot config schema

The config is a single JSON object controlling how an Intech Grid PBF4 MIDI
controller drives macOS. Controls are named P1-P4 (pots), F1-F4 (faders),
B1-B4 (buttons).

Top-level keys (all required):
- `version`: must be 1.
- `midi`: `{ "deviceName": string, "channel": int|null }` — null channel = any.
- `longPressMs`: 100-2000, button hold threshold.
- `controls`: map of control name → `{ "cc": 0-127, "kind": "continuous"|"button", "type": "cc"|"note" }`.
  `cc` is the CC or note number; `type` says which (Grid buttons send notes).
  type+number pairs must be unique. Do not change these unless asked — they
  were captured from the physical device by learn mode.
- `mappings`: map of control name → mapping.
  Continuous controls: `{ "action": ActionSpec }`.
  Buttons: `{ "tap": ActionSpec?, "longPress": ActionSpec? }` (at least one).
- `ai`: `{ "provider": "codex"|"claude", "codex": {"model": string, "effort": string}, "claude": {...} }`.
- `notify`: `{ "flashIcon": bool, "midiOut": [{"cc": int, "value": int, "channel": int}] }` —
  CCs sent to the Grid when `gridpilot notify` fires (LED feedback).
- `contextKeys`: action name → bundle id → `{ "keyCode": int, "modifiers": [string]? }`.
  Used by context-aware actions; apps not listed are no-ops.
- `call` (optional): incoming-call mode. `{ "enabled": bool, "ringTimeoutSec": int,
  "flashLEDs": bool, "apps": { bundleId: { "name": string, "answerKey": KeySpec|null } } }`.
  While a configured app rings, B1 answers (activates the app, sends answerKey if set)
  and B2 silences the ring by muting output; both revert automatically.

ActionSpec: `{ "action": string, "params": object? }`.

Available actions:
- `alertVolume` [continuous (fader/pot)]: macOS alert/notification volume.
- `applescript` [any control]: Run AppleScript source. Same templates as shell. Required params: source.
- `contextEscape` [button]: Send the key configured in contextKeys for the frontmost app; no-op elsewhere.
- `displayBrightness` [continuous (fader/pot)]: Main display brightness (private DisplayServices API).
- `itermTabPicker` [continuous (fader/pot)]: Knob zones select the focused iTerm tab.
- `keystroke` [button]: Send a keystroke. Params: keyCode (int), modifiers (array of cmd/shift/option/control). Required params: keyCode.
- `micVolume` [continuous (fader/pot)]: Default input device volume; 0 mutes.
- `midiSend` [any control]: Send a CC back to the Grid (LED feedback). Params: cc, value, channel (default 0). Required params: cc, value.
- `newClaudeSession` [button]: New iTerm tab running `claude --dangerously-skip-permissions`. Optional param `command` overrides.
- `newCodexSession` [button]: New iTerm tab running `codex --yolo`. Optional param `command` overrides.
- `nightShiftWarmth` [continuous (fader/pot)]: Night Shift strength (private CoreBrightness API); 0 disables.
- `outputDeviceDial` [continuous (fader/pot)]: Knob zones switch the default audio output device. Optional param `devices`: ordered name list.
- `screenshotFull` [button]: Full-screen screenshot to clipboard.
- `screenshotRegion` [button]: Interactive region screenshot to clipboard.
- `shell` [any control]: Run a zsh command. Templates: {{value}} 0-127, {{percent}} 0-100, {{float}} 0-1. Required params: command.
- `spotifyNextTrack` [button]: Skip to next Spotify track.
- `spotifyPlayPause` [button]: Toggle Spotify playback.
- `spotifyVolume` [continuous (fader/pot)]: Spotify app volume, independent of system volume.
- `systemVolume` [continuous (fader/pot)]: Default output device volume.

Notes for edits:
- `shell` and `applescript` let you add behavior that has no builtin —
  e.g. params.command = "open -a Slack". Keep commands non-interactive.
- Continuous shell/applescript actions receive {{value}} (0-127),
  {{percent}} (0-100), {{float}} (0.00-1.00) substitutions.
- Key codes: Escape 53, Return 36, Tab 48, Space 49, Delete 51.
- Bundle ids: iTerm com.googlecode.iterm2, ChatGPT com.openai.chat,
  Terminal com.apple.Terminal, Spotify com.spotify.client.
