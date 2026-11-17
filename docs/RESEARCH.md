# Research notes (facts only, no code copied)

Sources (read 2026-11-11):
- Linux `drivers/hid/hid-lg4ff.c`, `hid-lg.c`, `hid-ids.h` — SPDX `GPL-2.0-or-later`.
- berarma/oversteer (`oversteer/device.py`, `oversteer/wheel_ids.py`) — GPL-3.0.
- berarma/new-lg4ff (README) — GPL-2.0.

Licence handling: PedalBox copies no code from these projects. It re-implements only
protocol facts (byte values), each cited below and tagged `unverified` in code until
confirmed on a real wheel.

## USB IDs (vendor 0x046D)
| Model | PID | Source |
|---|---|---|
| G29 (native) | 0xC24F | hid-ids.h `USB_DEVICE_ID_LOGITECH_G29_WHEEL` |
| G920 | 0xC262 | hid-ids.h |
| G923 Xbox | 0xC26E (+0xC26D) | hid-ids.h; 0xC26D new-lg4ff README |
| G923 PS/PC | 0xC266 (+0xC267) | oversteer wheel_ids.py; 0xC267 new-lg4ff README |
| G27 | 0xC29B | hid-ids.h |
| G25 | 0xC299 | hid-ids.h |
| DFGT | 0xC29A | hid-ids.h |
| DFP | 0xC298 | hid-ids.h |
| DF-EX (compat) | 0xC294 | hid-ids.h `USB_DEVICE_ID_LOGITECH_WHEEL` |

Multimode: a G29 can enumerate under compat PIDs 0xC294/0xC298/0xC299/0xC29A/0xC29B.
`lg4ff_identify_multimode_wheel`: G29 if `bcdDevice & 0xFFF8 == 0x1350` or `bcdDevice & 0xFF00 == 0x8900`.
Linux auto-switches only from 0xC294 (DF-EX). G920/G923-Xbox use HID++ (not lg4ff).
`hid-lg.c lg_probe`: G29 works only on interface 0.

## G29 output commands (7 bytes, no report-ID byte in the lg4ff arrays)
Checked on a real G29 (native mode, interface 0, 16-byte output report ID 0, zero-padded): constant
force and stop work; a force byte above 0x80 pushes the wheel **left**. The rest is still unverified.

| Purpose | Bytes | lg4ff function |
|---|---|---|
| Revert mode on USB reset | `f8 0a 00 00 00 00 00` | `lg4ff_mode_switch_ext09_g29` (1st cmd) |
| Switch to native G29 (detach) | `f8 09 05 01 01 00 00` | `lg4ff_mode_switch_ext09_g29` (2nd cmd) |
| Range (40–900) | `f8 81 <lo> <hi> 00 00 00` (u16 LE degrees) | `lg4ff_set_range_g25` |
| Autocenter off | `f5 00 00 00 00 00 00` | `lg4ff_set_autocenter_default` |
| Autocenter on (m: 0–0xFFFF) | `fe 0d a a b 00 00` then `14 00 00 00 00 00 00` | `lg4ff_set_autocenter_default` |
| LEDs (bit0=RPM1…bit4=RPM5) | `f8 12 <bits> 00 00 00 00` | `lg4ff_set_leds` (G27/G29 only) |
| Constant force slot 1 | `11 08 <x> 80 00 00 00`, x = level+0x80 (0x80 = none) | `lg4ff_play` |
| Stop slot 1 | `13 00 00 00 00 00 00` | `lg4ff_play` |

Autocenter: if m ≤ 0xAAAA: A = 0x0C·m, B = 0x80·m; else A = 0x0C·0xAAAA + 0x06·(m−0xAAAA),
B = 0x80·0xAAAA + 0xFF·(m−0xAAAA). Non-Momo wheels: A >>= 1. Bytes: a = A/0xAAAA, b = B/0xAAAA.
FFB gain: no device command in in-tree lg4ff (software scaling only).
lg4ff init sends: range 900, autocenter off, LEDs off (G27/G29).
