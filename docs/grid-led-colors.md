# LED color themes

Grid module LEDs are full RGB. Out of the box a module only uses its stock
palette locally; it does not react to incoming MIDI. This one-time setup makes
LED color and brightness track your control positions live, on every module in
the chain, with six themes switchable from the GridPilot menu bar (LED Theme):

- **Heat** — blue at zero, purple in the middle, red at max
- **Ocean** — deep navy through teal toward foam white
- **Synthwave** — purple through hot pink to orange
- **Matrix** — dim green to bright green
- **Lava** — dark red through orange to yellow
- **Mono** — black through gray to white

How it works: GridPilot sends the selected theme index as CC 20 on channel 15
whenever you change it or replug the Grid. The snippet below sets each
element's min/mid/max LED palette from the theme, and the firmware's native
palette interpolation renders the gradient as values move — smooth, and a
theme switch recolors every LED instantly, including ones you aren't touching.
Incoming button notes (GridPilot's call-mode ring flash) drive button LED
phase directly. Requires firmware 1.5+ (the mid-color function); Grid Editor
will prompt you to update older modules.

## One-command setup (recommended)

```sh
gridpilot setup-leds
```

GridPilot talks to the module directly over serial (quit Grid Editor first —
the port is exclusive): it detects every module in the chain, writes each
one a theme handler with MIDI ranges derived from its position, verifies
every write by reading it back, and stores to flash. Idempotent — re-running
it changes nothing if you're already set up. Also available from the menu
bar: **Set Up Module LEDs**.

Per-family support:

- **PBF4, PO16, BU16** — fully automatic. The theme handler deploys and the
  stock per-element color blocks are stripped using templates fetched from
  real hardware.
- **EN16, EF44, TEK2** — the theme handler deploys, but the stock color
  blocks need the manual cleanup below (once) — or send a PR with fetched
  templates from your hardware.
- **PB44, TEK1, VSN, OCTV, XY** — no verified element layout yet, so
  `setup-leds` skips them; control mapping via learn mode still works.
  PRs with layouts welcome.

## Manual setup in Grid Editor (fallback/reference)

Two parts, both required.

**1. Remove the stock color blocks.** The default profile puts a "Simple
Color" action in every element's event, and it repaints that LED its stock
color on every touch — fighting any theme. For each element (all 12 on a
PBF4): select the element, open its main event (Potmeter/Button), tick the
**Simple Color** block's checkbox, and delete it with the trash icon. Leave
"…Mode" and "MIDI" blocks alone.

**2. Install the theme handler.** Select the **System** element (Element 12),
open the **Setup** event, replace the code block's contents with the snippet
below, Commit, then click **Store** so it survives power cycles.

```lua
-- Theme palettes: flat {minR,minG,minB, midR,midG,midB, maxR,maxG,maxB},
-- indexed by CC 20's value + 1.
self.T={{0,60,255,170,0,255,255,30,0},{0,10,80,0,190,190,200,255,255},{80,0,160,255,0,120,255,150,0},{0,20,0,0,180,30,120,255,80},{20,0,0,255,60,0,255,220,0},{10,10,10,120,120,120,255,255,255}}
-- Last seen value per element, so theme switches keep true LED levels.
self.q={}
self.midirx_cb=function(s,h,e)
  local c,m,p,v=e[1],e[2],e[3],e[4]
  if c==15 and m==176 and p==20 then
    local t=s.T[v+1] or s.T[1]
    for n=0,11 do
      gln(n,1,t[1],t[2],t[3])
      gld(n,1,t[4],t[5],t[6])
      glx(n,1,t[7],t[8],t[9])
      glp(n,1,(s.q[n] or 0)*2)
    end
    return
  end
  local n=-1
  if m==176 and p>=32 and p<=39 then n=p-32 end
  if (m==144 or m==128) and p>=40 and p<=43 then
    n=p-32
    if m==128 then v=0 end
  end
  if n>=0 then
    s.q[n]=v
    glp(n,1,v*2)
  end
end
```

(`gln`/`gld`/`glx` are `led_color_min`/`led_color_mid`/`led_color_max`;
`glp` is `led_value`. The firmware re-blends the three anchors by phase on
every frame, so setting anchors plus phase is the whole job.) Do not add
`led_color` (`glc`) to the loop: it doesn't set the displayed color, it
rewrites all three anchors to `{c/20, c/2, c}` and flattens the gradient —
with a control at zero that strands every LED near the theme's minimum color.
GridPilot's echo (`leds.echo`) feeds the element branch; after each theme
switch GridPilot also replays every control's last known value so LEDs light
at real positions. Controls the module hasn't heard since power-up idle at
the theme's zero color until moved once.

## Notes

- The snippet assumes a head PBF4 with the default MIDI layout (CC 32-39 for
  pots/faders, notes 40-43 for buttons). Chained modules shift by position —
  CC block = 32 + column × 16, plus a row guard on the channel — which
  `setup-leds` derives per module. Adjust the range checks by hand only if
  learn mode captured different numbers
  (`~/.config/gridpilot/config.json`).
- Buttons idle at a dim theme color and go full-bright while held; call mode's
  ring flash becomes theme-colored blinking automatically.
- Add your own theme: extend the `if t ==` chain with another palette and it
  becomes selectable by sending CC 20 with the next index (the GridPilot menu
  lists whatever `LEDConfig.themeNames` contains — PRs welcome).
- LED function reference: `led_color(num, layer, r, g, b)` and
  `led_value(num, layer, 0-255)` per the
  [Grid LED function docs](https://docs.intech.studio/reference-manual/grid-functions/led/).
