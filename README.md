# GridPilot

Turn an [Intech Studio Grid](https://intech.studio) controller into a control surface for your Mac: Spotify on a fader, Claude Code and Codex on buttons, brightness and audio routing on knobs, and an AI layer that reconfigures all of it from a plain English sentence.

No Electron, no dependencies. One Swift menu-bar app.

## What it does out of the box

The default mapping targets a PBF4; other modules and chains get controls via learn mode or `gridpilot generate-map` (see Hardware notes).

| Control | Action |
|---------|--------|
| P1 (pot) | Display brightness |
| P2 (pot) | Mic input volume, zero is a hard mute |
| P3 (pot) | Session picker: knob position selects the focused iTerm tab |
| P4 (pot) | iTerm background transparency |
| F1 (fader) | Spotify volume, independent of system volume |
| F2 (fader) | System output volume |
| F3 (fader) | Alert/notification volume |
| F4 (fader) | Night Shift warmth (private API, best effort) |
| B1 (button) | Interrupt: sends Escape to iTerm or ChatGPT, no-op elsewhere |
| B2 (button) | New `claude --dangerously-skip-permissions` iTerm tab. Hold for `codex --yolo` |
| B3 (button) | Region screenshot to clipboard. Hold for full screen |
| B4 (button) | Spotify play/pause. Hold for next track |

Buttons are context-aware. The interrupt button checks which app is frontmost and sends the right key to the right place, or nothing at all. An output-device dial (knob zones switch speakers/headphones/AirPods) is also built in; assign it to any control with one `gridpilot ai` sentence.

### LED color themes

The Grid's RGB LEDs can track your control positions live, with six palettes (Heat, Ocean, Synthwave, Matrix, Lava, Mono) switchable from the menu bar. `gridpilot setup-leds` deploys the LED handler to every module in the chain over serial, no Grid Editor needed — fully automatic on PBF4/PO16/BU16, one manual color cleanup on EN16/EF44/TEK2. See [docs/grid-led-colors.md](docs/grid-led-colors.md).

### Incoming call mode

When FaceTime, Teams, Zoom, Discord, or Slack rings, the Grid's button LEDs flash and two buttons are temporarily hijacked: B1 answers (activates the app and sends its answer shortcut if it has one), B2 silences the ring by muting output without rejecting the call. Everything reverts when the ringing stops.

Automatic detection reads Notification Center's database, which requires giving GridPilot Full Disk Access (optional). Without it you can still trigger call mode from anything that can run a command:

```sh
gridpilot notify --event call:com.apple.FaceTime
gridpilot notify --event call-end
```

### AI customization

This is the part we're most fond of. Instead of editing JSON, describe the change:

```sh
gridpilot ai "make F3 control spotify seek position instead of alert volume"
gridpilot ai "add a long press on B1 that opens Slack"
gridpilot ai "swap what B3 and B4 do"
```

Or use "Customize with AI" in the menu bar. GridPilot hands your current config and the schema to a headless coding agent (Codex or Claude Code, your choice of model and effort), validates whatever comes back (strict JSON decode, semantic checks, AppleScript compilation), shows you a diff, and applies only after you confirm. Every change is backed up; "Revert Last Change" or `gridpilot rollback` undoes it.

The agent can add behavior that has no builtin by writing `shell` or `applescript` actions into the config. Ask for "previous track" and it writes the AppleScript itself. Generative UX, but with a validation gate and an undo button.

Pick your provider and model in the config:

```json
"ai": {
  "provider": "codex",
  "codex":  { "model": "gpt-5.6-sol",   "effort": "high"  },
  "claude": { "model": "claude-opus-5", "effort": "xhigh" }
}
```

## Install

Requires macOS 13+, Xcode command line tools, and a Grid module. Spotify, iTerm, and the AI CLIs are all optional; anything missing just makes that one feature inert.

```sh
git clone https://github.com/cj-vana/grid-pilot.git
cd grid-pilot
./scripts/install.sh
```

On first launch GridPilot offers learn mode: wiggle each control once and it captures your module's real CC numbers. Grid modules vary by profile, so don't skip this unless the defaults happen to work.

Check what's healthy at any time:

```sh
gridpilot doctor
```

### Permissions

macOS asks for each of these the first time a feature needs it. All are one-time grants to GridPilot.app:

| Permission | Needed for |
|------------|-----------|
| Accessibility | Keystrokes (interrupt button, answer key) |
| Automation | Spotify and iTerm control |
| Screen Recording | Screenshot button |
| Full Disk Access | Automatic call detection (optional) |

## Claude Code integration

Make the Grid flash when a Claude Code session finishes or needs attention. Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [{ "hooks": [{ "type": "command", "command": "gridpilot notify --event claude-attention" }] }],
    "Stop":         [{ "hooks": [{ "type": "command", "command": "gridpilot notify --event claude-done" }] }]
  }
}
```

The menu-bar icon flashes on any event. To also light the Grid's LEDs, add CC messages to `notify.midiOut` in the config and map those CCs to LED reactions in your Grid Editor profile. LED behavior depends on how your module's profile handles incoming MIDI, so this half is yours to wire.

## The config file

Everything lives in `~/.config/gridpilot/config.json`. Hand-edits hot-reload while the app runs; invalid edits are rejected and logged, never applied. `docs/ai-schema.md` documents the schema (it's generated from the source of truth with `gridpilot schema`).

Continuous shell and AppleScript actions get template substitution: `{{value}}` is 0-127, `{{percent}}` is 0-100, `{{float}}` is 0.00-1.00.

```json
"F3": { "action": "applescript", "params": { "source": "tell application \"Spotify\" to set player position to (duration of current track / 1000) * {{float}}" } }
```

## CLI

```
gridpilot                        menu-bar app
gridpilot ai "<request>" [--yes] AI config edit
gridpilot preset list|save|load  named config snapshots
gridpilot modules                discover the module chain over serial
gridpilot setup-leds             deploy LED themes, no Grid Editor needed
gridpilot generate-map           add controls for every detected module
gridpilot notify --event <name>  ping the running app
gridpilot rollback               restore last config backup
gridpilot doctor                 health check
gridpilot schema                 print the AI schema
gridpilot config-path            print config location
```

The serial commands (`modules`, `setup-leds`, `generate-map`) talk the Grid
protocol directly over USB-CDC — quit Grid Editor first, the port is
exclusive. Protocol notes: [docs/grid-serial-protocol.md](docs/grid-serial-protocol.md).

## Troubleshooting

- **Nothing happens when I move controls.** Run `gridpilot doctor`. If the device shows up but events don't land, re-run learn mode; your Grid profile probably uses different CCs.
- **Keystrokes don't send.** Grant Accessibility to GridPilot.app (not to your terminal) and restart the app.
- **Night Shift or brightness stopped working after a macOS update.** Those use private frameworks by necessity. The mapping disables itself and logs; the rest of the app is unaffected. Open an issue with your macOS version.
- **AI edit fails with "could not launch".** The provider CLI isn't on PATH for GUI apps. Use the CLI (`gridpilot ai`) or switch providers in the menu.
- Logs: `~/Library/Logs/GridPilot.log`.

## Architecture, for contributors

```
Sources/GridPilot/
  Core/      Config, validation, ConfigStore (backups, hot-reload), MappingEngine
             (coalescing, tap vs long-press), MIDIListener (CoreMIDI, reconnect)
  Actions/   ActionRegistry dispatch, CoreAudio, AppleScript, CGEvent keystrokes,
             private-API wrappers (isolated, fail-soft)
  AI/        Prompt building, provider argv, JSON extraction, validation chain
  Serial/    Grid protocol over USB-CDC: module discovery, verified config
             read/write, LED theme deploy, control-map generation
  App/       Menu bar, learn mode, customize window, call mode, CLI
```

The flow is `MIDIListener → MappingEngine → ActionRegistry`. Adding a builtin action is one entry in `Builtins.all` plus one case in `ActionRegistry.run`; the validator and AI schema pick it up automatically.

`swift test` runs 78 tests with no hardware attached (fake clocks, spy executors, stubbed AI runners). See [CONTRIBUTING.md](CONTRIBUTING.md).

## Hardware notes

Built for the PBF4, but nothing is PBF4-specific: controls are named CC/note+channel entries in the config. Other Grid modules (or non-Grid controllers) work if you run learn mode and adjust the control names.

**Module chains:** chained Grid modules appear as one MIDI device. Each module offsets its numbers by position — CC block = 32 + column × 16, channel = row × 4 + page. Run `gridpilot generate-map` (or menu → Detect Modules → Update Config) and every detected module's controls are added to the config automatically, named like `M1,0-E5`; assign them actions via the AI. Identity is positional: re-plugging USB into a different module remaps the chain, so keep the cable in the same module.

**Series 3:** legacy and Series 3 modules chain together and use identical MIDI layouts, so both generations work as-is. Series 3 Hall-effect buttons default to plain press/release; if you configure velocity or pressure modes in Grid Editor, the values ride the same CC/note and map cleanly onto continuous actions. Endless encoders (EN16, EF44, TEK2, VSN1) default to absolute output; if a profile opts into a relative mode, set the control's `encoding` to `relative64` or `relative2c` and GridPilot accumulates steps into a position.

PRs welcome for other layouts.

## License

MIT
