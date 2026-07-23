# Claude Code → Grid LED feedback

Goal: the Grid lights up when a Claude Code session finishes or needs you.

## 1. Wire the hooks

In `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      { "hooks": [{ "type": "command", "command": "gridpilot notify --event claude-attention" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "gridpilot notify --event claude-done" }] }
    ]
  }
}
```

`Notification` fires when Claude is waiting on you; `Stop` fires when a turn
finishes. Either way the GridPilot menu-bar icon flashes.

## 2. Optional: light the module itself

Add outgoing CCs to `notify.midiOut` in `~/.config/gridpilot/config.json`:

```json
"notify": {
  "flashIcon": true,
  "midiOut": [
    { "cc": 40, "value": 127, "channel": 0 },
    { "cc": 41, "value": 127, "channel": 0 }
  ]
}
```

GridPilot sends those CCs to the Grid on every notify event. Whether an LED
responds depends on your module's profile: in Grid Editor, add a **MIDI rx**
event handler on the elements you want lit and set the LED color there. The
default profiles don't react to incoming MIDI, so this half is a one-time
Grid Editor edit.

Call mode ignores this list; while a call rings, the four button CCs are
flashed automatically.
