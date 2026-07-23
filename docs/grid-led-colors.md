# LED color themes

The PBF4's LEDs are full RGB. Out of the box the module only uses its stock
palette locally; it does not react to incoming MIDI. This one-time setup makes
LED color and brightness track your control positions live, with four themes
switchable from the GridPilot menu bar (LED Theme):

- **Heat** — blue at zero, purple in the middle, red at max
- **Ocean** — deep blue through teal toward white
- **Synthwave** — purple through pink to orange
- **Matrix** — dim green to bright green

How it works: GridPilot echoes every control event back to the module
(`leds.echo` in the config, on by default) and sends the selected theme index
as CC 20 on channel 15 whenever you change it or replug the Grid. The snippet
below receives both and paints the LEDs.

## One-time setup in Grid Editor

1. Open Grid Editor with the module connected.
2. Select the **System** element (top-left module icon), open the **Setup** event.
3. Add a **Code Block** action and paste the snippet.
4. Click **Store** so it survives power cycles.

```lua
self.midirx_cb = function(self, header, event)
  local ch, cmd, p1, v = event[1], event[2], event[3], event[4]
  if ch == 15 and cmd == 176 and p1 == 20 then
    self.theme = v
    return
  end
  local num = -1
  if cmd == 176 and p1 >= 32 and p1 <= 39 then num = p1 - 32 end
  if (cmd == 144 or cmd == 128) and p1 >= 40 and p1 <= 43 then num = p1 - 32 end
  if num < 0 then return end
  if cmd == 128 then v = 0 end
  local t = self.theme or 0
  local r, g, b = 0, 0, 0
  if t == 0 then         -- Heat
    r = v * 2
    b = (127 - v) * 2
  elseif t == 1 then     -- Ocean
    if v > 63 then r = (v - 64) * 4 end
    g = v * 2
    b = 200 + v // 3
  elseif t == 2 then     -- Synthwave
    r = 150 + v
    if r > 255 then r = 255 end
    g = v // 2
    b = (127 - v) * 2
  else                   -- Matrix
    g = 40 + v + v // 2
    b = v // 8
  end
  led_color(num, 1, r, g, b)
  led_value(num, 1, 25 + (v * 230) // 127)
end
```

## Notes

- The snippet assumes the default MIDI layout (CC 32-39 for pots/faders,
  notes 40-43 for buttons). If learn mode captured different numbers, adjust
  the two range checks to match `~/.config/gridpilot/config.json`.
- Buttons idle at a dim theme color and go full-bright while held; call mode's
  ring flash becomes theme-colored blinking automatically.
- Add your own theme: extend the `if t ==` chain with another palette and it
  becomes selectable by sending CC 20 with the next index (the GridPilot menu
  lists whatever `LEDConfig.themeNames` contains — PRs welcome).
- LED function reference: `led_color(num, layer, r, g, b)` and
  `led_value(num, layer, 0-255)` per the
  [Grid LED function docs](https://docs.intech.studio/reference-manual/grid-functions/led/).
