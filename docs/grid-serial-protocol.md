# Grid serial protocol notes (as implemented)

GridPilot speaks the Intech Grid serial protocol (v1.5.5) directly over the
module's USB-CDC port, which is what `gridpilot modules`, `setup-leds`, and
`generate-map` use. Reverse-engineered from the open-source
[grid-protocol](https://github.com/intechstudio/grid-protocol) and
[grid-editor](https://github.com/intechstudio/grid-editor) repos; every
encoder in `Sources/GridPilot/Serial/` is validated against byte-exact frames
from the reference implementation (see `ProtocolTests`).

The port is **exclusive**: quit Grid Editor before using GridPilot's serial
features, and vice versa. Framing and classes are identical across the whole
1.5.x line and across hardware generations — one code path covers legacy and
Series 3 modules.

## Frame

```
SOH(0x01) BRC(0x0F) <20 hex chars: header> EOB(0x17)
STX(0x02) <3 hex: class> <1 hex: instruction> <params> ETX(0x03)
EOT(0x04) <2 hex: checksum> LF(0x0A)
```

- Header fields (hex chars): LEN(4) = bytes SOH..EOT; ID(2); SESSION(2);
  SX(2) SY(2) source coords; DX(2) DY(2) destination; ROT(1) PORTROT(1);
  MSGAGE(2). Coordinates ride with a **+127 bias** (`7f` = 0). The host is
  (-127,-127) → `00`; global broadcast targets (-127,-127) → `0000`.
- Checksum: XOR-8 over SOH..EOT inclusive, two lowercase hex chars. LF ends
  the frame and is outside LEN and the checksum.
- Instructions: `e` execute, `f` fetch, `a` ack, `b` nack, `c` check, `d` report.

## Classes GridPilot uses

| Class | Code | Use |
|---|---|---|
| HEARTBEAT | 0x010 | modules announce type (HWCFG), firmware, position (header SX/SY) every 250 ms; the host announces itself every ~300 ms with HWCFG 255 |
| CONFIG | 0x060 | read (`f`) / write (`e`) one event script: version(3×2) page(2) element(2) event(2) length(4) + raw Lua. System element = **255**. Max script 908 bytes |
| PAGESTORE | 0x061 | global broadcast; persists RAM config to flash; ACK within ~3 s |

Event ids: 0 setup, 1 potmeter, 2 encoder, 3 button, 6 timer, 7 endless,
8 draw, 9 touch. Scripts are stored minified with block markers
(`--[[@cb]]` code block, `--[[@spc]]`/`--[[@sbc]]` element settings,
`--[[@gms]]` MIDI). Scripts must not contain protocol control bytes — no
raw newlines.

Reply correlation is semantic (source coords + class + instruction), not by
message id. A NACK ends a request as failure; timeouts retry once.

## Discovery model

Each module heartbeats its HWCFG (hardware id → module family + revision;
odd = ESP32, even = D51), firmware version, and chain position (head = 0,0).
`GridModuleCatalog` maps HWCFG → family and element layout. Identity is
positional: re-plugging USB into a different module re-origins the chain.

Default dynamic MIDI layout (why `generate-map` produces what it does):
`cc/note = 32 + x*16 + element`, `channel = (y*4 + page) % 16`. Element
events use an "Auto" MIDI block that resolves the command per element type —
pots/faders/encoders send CC, buttons send Note On/Off.
