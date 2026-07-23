# GridPilot — Design Spec

**Date:** 2026-07-23
**Status:** Approved (user waived written-spec review; verbal approval of mapping + architecture in session)

## What

A native macOS menu-bar app that turns an Intech Studio Grid PBF4 MIDI controller into a
desk-side control surface for Spotify, macOS audio/display, and Claude Code / Codex CLI
workflows. Includes an AI customization layer: the user describes a change in natural
language and a headless coding agent (Codex CLI or Claude Code CLI, user-selectable model +
effort) edits the JSON config, which is validated and hot-reloaded with backup/rollback.

## Hardware context

- Device: Intech Studio Grid **PBF4** — 4 potentiometers (top), 4 faders (middle), 4 buttons (bottom).
- Appears over USB-MIDI as a single CoreMIDI source/destination named "Grid" (manufacturer "Intech Studio").
- Default firmware profile emits MIDI CC per element; exact CC numbers vary by profile, so the
  app has a **learn mode** rather than hardcoded CCs. Ships with a best-guess default map.

## Control mapping (approved)

| Control | Action |
|---|---|
| P1 | Display brightness |
| P2 | Mic input volume (0 = hard mute) |
| P3 | Claude session picker — knob zone selects focused iTerm tab |
| P4 | Output device dial — zones switch default audio output device |
| F1 | Spotify app volume (AppleScript `sound volume`) |
| F2 | System output volume (CoreAudio) |
| F3 | Alert/notification volume |
| F4 | Night Shift warmth (private CoreBrightness API; isolated, best-effort) |
| B1 tap | Interrupt: Escape keystroke, context-aware (iTerm / ChatGPT frontmost; no-op elsewhere) |
| B2 tap | New iTerm tab running `claude --dangerously-skip-permissions` |
| B2 long | New iTerm tab running `codex --yolo` |
| B3 tap | Region screenshot → clipboard (`screencapture -i -c`) |
| B3 long | Full-screen screenshot → clipboard |
| B4 tap | Spotify play/pause |
| B4 long | Spotify next track |

Notes:
- User always runs Claude Code/Codex with permissions skipped, so there is no "approve" button.
- Buttons are context-aware where it matters: keystroke actions inspect the frontmost app
  bundle id and send app-appropriate keys, or no-op.
- Long-press threshold default 400 ms, configurable.

## Architecture

Single Swift Package Manager executable (`GridPilot`), AppKit menu-bar app (LSUIElement),
bundled into a `.app` by `scripts/make-app.sh`. macOS 13+.

Units:

- **MIDIListener** (CoreMIDI): connects to the Grid by name, delivers `(cc, value, channel)`
  events; auto-reconnects on unplug/replug via MIDI system notifications.
- **ConfigStore**: loads/saves `~/.config/gridpilot/config.json` (Codable, strict), watches the
  file for hand-edits (DispatchSource) and hot-reloads. Writes timestamped backups on every
  programmatic change; supports rollback.
- **MappingEngine**: routes control events to actions. Continuous controls are coalesced
  (~30 Hz max, latest-value-wins) so AppleScript targets are never flooded. Buttons go through
  **ButtonGesture** (tap vs long-press from press/release timing).
- **ActionRegistry**: named built-in actions plus generic `shell`, `applescript`, and
  `keystroke` actions with `{{value}}`/`{{percent}}` substitution — this is what makes the AI
  layer able to add arbitrary new behavior without recompiling.
- **ContextRouter**: NSWorkspace frontmost-app detection; per-app keystroke tables in config.
- **Executors**: CoreAudio (system/mic/alert volume, output device list+switch), AppleScript
  via NSAppleScript (Spotify, iTerm), CGEvent keystrokes, `screencapture`, DisplayServices
  (dlopen, private) for brightness, CoreBrightness CBBlueLightClient (dlopen, private) for
  Night Shift. Private-API users are isolated behind protocols; failure logs and disables that
  one mapping only.
- **AICustomizer**: builds a prompt = schema reference (`docs/ai-schema.md`) + current config +
  user request; runs the configured provider headless:
  - Codex: `codex exec -m <model> -c model_reasoning_effort=<effort> --sandbox read-only --skip-git-repo-check --ephemeral --color never -o <tmpfile> <prompt>`
  - Claude: `claude -p --model <model> --effort <effort> --output-format json`
  - Parses the returned config JSON, validates (decode + semantic checks: known actions,
    required params, CC uniqueness, ranges; AppleScript actions must compile), shows a diff
    summary for confirmation, backs up, applies, hot-reloads. Menu item reverts the last AI change.
  - Provider, model, and effort are user-choosable (config + menu). Defaults: codex/gpt-5.6-sol/high;
    alternate claude/claude-opus-4-8/xhigh.
- **LearnMode**: guided window: "wiggle P1…" → captures CC numbers and type (button vs
  continuous) in fixed order; auto-offered on first run.
- **Attention/notify**: `gridpilot notify --event <name>` CLI subcommand posts to the running
  app (distributed notification); app flashes the menu-bar icon and sends configurable MIDI
  back to the Grid (LED response depends on the module's profile — documented as such). README
  ships a Claude Code hook example wiring Stop/Notification events to it.
- **MenuBar**: status, pause, learn, AI customize, revert, open config, view log, AI
  provider/model submenu, launch at login (SMAppService), quit.
- **CLI branch**: the same binary handles subcommands (`gridpilot ai "..."`, `gridpilot notify ...`,
  `gridpilot learn`, `gridpilot doctor`) for scriptability; no args → menu-bar app.

## Permissions

One-time TCC prompts, requested lazily on first use: Accessibility (CGEvent keystrokes),
Automation (Spotify, iTerm, System Events), Screen Recording (screenshots). `gridpilot doctor`
reports what's granted/missing.

## Error handling

- Device disconnect → menu-bar state change, silent reconnect loop.
- Action failure → log to `~/Library/Logs/GridPilot.log` (+ os.log), badge the menu-bar icon;
  never modal popups.
- AI customize failure (bad JSON, validation, CLI missing) → error surfaced in the customize
  window with the raw output; config untouched.
- Private-API breakage (brightness / Night Shift) → that mapping disables itself with a log line.

## Testing

- Unit tests (`swift test`): config decode/encode round-trip, validation rules, mapping engine
  routing, zone math, gesture timing (injected clock), AI response parsing (fenced/unfenced
  JSON), template substitution.
- Integration: virtual CoreMIDI source injecting events end-to-end in a test harness.
- Hardware/TCC-dependent paths (keystrokes, Spotify, brightness) are manually verified;
  documented in README.

## Out of scope

- Grid Editor firmware programming; multi-module chains (config supports arbitrary CCs, so
  chains work via learn mode, but no per-module UI); Spotify Web API "AI DJ" (explicitly
  rejected in brainstorm); Windows/Linux.

## Distribution

Public GitHub repo `cj-vana/grid-pilot` (MIT), contribution-ready: README, CONTRIBUTING,
issue/PR templates, CI (GitHub Actions, macOS: build + test).
