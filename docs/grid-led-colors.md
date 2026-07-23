# LED color themes

The PBF4's LEDs are full RGB. Out of the box the module only uses its stock
palette locally; it does not react to incoming MIDI. This one-time setup makes
LED color and brightness track your control positions live, with four themes
switchable from the GridPilot menu bar (LED Theme):

- **Heat** — blue at zero, purple in the middle, red at max
- **Ocean** — deep blue through teal toward white
- **Synthwave** — purple through pink to orange
- **Matrix** — dim green to bright green

How it works: GridPilot sends the selected theme index as CC 20 on channel 15
whenever you change it or replug the Grid. The snippet below sets each
element's min/mid/max LED palette from the theme, and the firmware's native
palette interpolation renders the gradient as values move — smooth, and a
theme switch recolors every LED instantly, including ones you aren't touching.
Incoming button notes (GridPilot's call-mode ring flash) drive button LED
phase directly. Requires firmware 1.5+ (the mid-color function); Grid Editor
will prompt you to update older modules.

## One-time setup in Grid Editor

1. Open Grid Editor with the module connected.
2. Select the **System** element (top-left module icon), open the **Setup** event.
3. Add a **Code Block** action and paste the snippet.
4. Click **Store** so it survives power cycles.

```lua
self.midirx_cb = function(s, h, e)
  local c, m, p, v = e[1], e[2], e[3], e[4]
  if c == 15 and m == 176 and p == 20 then
    for n = 0, 11 do
      if v == 0 then     -- Heat
        gln(n,1,0,0,255)   gld(n,1,190,0,190)  glx(n,1,255,0,0)
      elseif v == 1 then -- Ocean
        gln(n,1,0,20,200)  gld(n,1,0,170,220)  glx(n,1,240,255,255)
      elseif v == 2 then -- Synthwave
        gln(n,1,120,0,255) gld(n,1,255,60,160) glx(n,1,255,140,0)
      else               -- Matrix
        gln(n,1,0,30,0)    gld(n,1,0,150,20)   glx(n,1,90,255,60)
      end
    end
    return
  end
  -- Incoming button notes = call-mode ring flash
  if (m == 144 or m == 128) and p >= 40 and p <= 43 then
    local x = v * 2
    if m == 128 then x = 0 end
    if x > 254 then x = 254 end
    glp(p - 32, 1, x)
  end
end
```

(`gln`/`gld`/`glx` are `led_color_min`/`led_color_mid`/`led_color_max`;
`glp` is `led_value`.)

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
