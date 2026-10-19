# SSD1677 refresh strategy — register findings & tuning log

Working notes for the product-grade refresh effort. Companion reading:
`PAPERBOY.md` (why direct-drive tricks don't apply here). Reference drivers
in this directory:

- `EPD_3in97.cpp/.h` — **Waveshare vendor demo for our exact board**
  (`waveshareteam/ESP32-S3-ePaper-3.97`). The ground truth for what the
  factory intends. Pure OTP, no custom LUT anywhere.
- `Ssd1677Driver.cpp` + `Ssd1677Luts.h` — freeink-sdk (`Free-Ink/freeink-sdk`),
  ships on the Xteink X4 (GDEQ0426T82, also 800×480 SSD1677). Independent
  confirmation of the same sequences, plus the differential-grayscale LUT
  mechanism (the crosspoint-reader "BW partial + gray enhancement" cherry).

## 1. How an SSD1677 update works (30-second model)

An update = `[optionally write RAM planes] → configure → 0x22 <sequence byte>
→ 0x20 master activation → BUSY`. The sequence byte is a bitmask of steps the
controller executes in order:

| bit | value | step |
|-----|-------|------|
| 7   | 0x80  | enable clock (oscillator) |
| 6   | 0x40  | enable analog (±15 V rails, VCOM) |
| 5   | 0x20  | load temperature from sensor (`0x18`) into temp register |
| 4   | 0x10  | load LUT from OTP for the current temp + display mode |
| 3   | 0x08  | display mode 2 (differential/partial) instead of mode 1 |
| 2   | 0x04  | display (replay the LUT against the glass) |
| 1   | 0x02  | disable analog |
| 0   | 0x01  | disable clock |

So: `0xF7` = power up, read real temperature, load the factory full (GC)
waveform, display, power down. `0xFF` = same but the mode-2 partial (DU)
waveform. `0xCF` = power up, **skip temp and OTP load** (uses whatever LUT was
written via `0x32`), display in mode 2, power down. `0xFC` = like `0xFF` but
**leaves the rails powered** (no bits 1:0).

The `0x1A` trick: OTP holds one waveform per temperature band. Writing a fake
temperature into `0x1A` and then using a sequence **without bit 5** (`0xD7`)
replays the waveform of a hotter band — hotter ink switches faster, so the
factory tables there are shorter. This is the vendor's official "Fast" mode.

## 2. Vendor sequences (EPD_3in97.cpp) — our targets

| Mode | Prep | RAM | 0x22 | Notes |
|------|------|-----|------|-------|
| Full GC | border `0x3C=0x01` | new → `0x24` (+`0x26` in `_Base`) | `0xF7` | the ghost eraser; ~2 s |
| Fast full | `0x1A=0x6A`, border `0x01` | new → `0x24` (+`0x26` base) | `0xD7` | "Fast(1.5s)"; hotter OTP bank |
| 4-gray | `0x1A=0x5A` | 2bpp packed → `0x24`+`0x26` | `0xD7` | factory grayscale, **no custom LUT** |
| Partial | border `0x3C=0x80` | window, new → `0x24` only | `0xFF` | powers down after; RED holds baseline from the previous `_Base` display |

Vendor 4-gray plane packing (Display_4Gray): per pixel, `0x24` bit / `0x26`
bit = white `1/1`, light-gray `1/0`, dark-gray `0/1`, black `0/0` (i.e. `0x24`
is the MSB... derive from code when porting — note it does NOT match our
current `bw=level&1 / red=level>>1` packing).

## 3. What our driver does today (`src/display_ssd16xx_800x480.c`) and why it fails

| Path | Today | Problem |
|------|-------|---------|
| Full | custom 105-byte LUT via `0x32` + `0x22=0xCF` | LUT was borrowed from a **Waveshare 3.7" panel** (different film). Level-indexed and open-loop: no inversion flashing tuned for this film → cannot erase ghost. And we never program `0x03/0x04/0x2C` (gate/source/VCOM), so it runs at reset-default voltages. |
| Partial | OTP `0x22=0xFC`, prev→`0x26`, new→`0x24`, re-sync after | Waveform is fine; but `0xFC` leaves rails powered forever (vendor uses `0xFF`), and nothing ever consolidates before power loss → fade. |
| Border | init `0x01`, partial sets `0x80`, **never restored** | after the first partial, all subsequent fulls run with the partial border. |
| Sleep | never: `0x10` unused, no analog-off step | fade on abrupt power cut; wasted power. |

Physics of the two symptoms:

- **Partial fades after power-off**: a DU partial drives changed pixels with a
  short pulse train — particles end up *optically* right but *mechanically*
  shallow (low bistable margin). Cut power and they relax. A GC full drives
  every pixel to saturation through inversion flashes — that image holds for
  months. Fix = always end a session/sleep with a fully-driven frame, then
  power the panel down gracefully (`0x22=0x03` + `0x20`, then `0x10`).
- **Full doesn't erase ghost**: erasing ghost requires driving *every* pixel
  through saturating black↔white excursions tuned to the film (that's what the
  factory GC does). Our foreign, voltage-less, non-flashing LUT can't.

## 4. Experiment protocol (shell harness, `epd` group)

Build with `CONFIG_LLSS_EPD_TEST_SHELL=y` (default). Over telnet:

```
epd pattern digits      # framebuffer only
epd seq f7              # display it with vendor full (RAM both planes)
epd seq f7 - - bw       # vendor plain Display(): BW RAM only
epd seq d7 - 6a         # vendor fast-full (temp bank 0x6A)
epd seq d7 - 5a         # 4-gray bank (with gradient pattern)
epd pattern checker && epd partial
epd status              # counters, last 0x22 value, duration ms
epd floor 0             # disable auto full floor during experiments
```

### Planned test matrix

1. **Polarity/RAM-role sanity**: `pattern checker` → `seq f7` (both), then
   `seq f7 - - bw`. Expect identical correct checkerboard. Inverted image or
   no-drive tells us why the earlier "ROM LUT" attempt looked awful.
2. **Ghost gauntlet**: `pattern checker; epd full` → 20× (`pattern digits;
   epd partial` alternating with white) → candidate full (`seq f7` vs current
   `0xCF` custom) → photograph residual.
3. **Fast-full bank sweep**: `seq d7 - 5a|64|6a` — time (epd status) vs
   visual cleanliness after the gauntlet.
4. **Retention**: full-driven image vs partial-driven image → cut power →
   compare after hours. (Control experiment documenting the fade physics.)

### Results log

**2026-07-04, the mode-1 investigation.** Chronology of a wrong theory dying
three times (kept as a teaching record):

1. OTP full (`0xF7`) passed every synthetic test (checker, digits after the
   gauntlet, power-cut retention on `0xD7@0x6A`), but **washed out the real
   chess frame** — pieces gray, dither mush — while a mode-2 partial of the
   *same framebuffer* rendered it crisply. Repeating `0xF7` compounded the
   damage (smears, half-erased regions).
2. Ruled out one by one, on glass: RAM plane divergence (`epd cmp`: BW==RED,
   bit-for-bit equal to the server PNG), RED-as-old-state indexing (`0x21`
   bypass — no change), gray/inverted row indexing (`gradient`/`digits`
   through `0xF7` — correct), booster load (full-screen 1-px dither = *worst*
   load = fine), interlace bit (SM=0 scrambled geometry → SM=1 is correct
   wiring), temperature banks (0x00/0x0A/0x19/0x6A/0x7F — all bad on the
   failing content), voltage/booster lifts (`0x03/0x04/0x0C` — no change).
3. `hlines` vs `vlines` cracked it: **fine detail across gate lines mangles
   in every mode-1 sequence; along gate lines it's perfect; mode-2 always
   renders both.** Rows whose source data flips against the previous gate
   line are under-driven — a per-line drive weakness at the mode-1 banks'
   line timing, present on this unit at every temperature bank. All earlier
   synthetic "passes" were patterns invariant under exactly this defect
   (a blurred 1-px checker *is* uniform gray; blurred block edges are
   invisible). Test-design lesson: symmetric patterns can't catch asymmetric
   defects.
4. Also established: `0xD7@0x6A` retention across power-cut = OK; OTP DU
   partial retention = fades (shallow drive, expected physics); `0x19` bank
   leaves ghost.

**Resolution: the full refresh is a hand-built mode-2 GC LUT**
(`lut_gc_mode2` in the driver, `0x22=0xCF`) at the frame rate the old
borrowed 3.7" LUT had already proven this unit can settle (FR nibble 0x2).
4 synchronized inversion flashes + symmetric 20-frame sets, cross-balanced
±20f, VCOM DC. Validated on glass: crisp `hlines`, crisp chess frame, ghost
gauntlet clean, **power-cut retention OK**, 1965 ms. This is also why the
"wrong" 3.7" LUT looked structurally fine for months: any mode-2 waveform
sidesteps the mode-1 defect. Audit tool: `scripts/lut_check.py`.

## 5. Architecture (as validated)

- **Full** = `lut_gc_mode2` custom mode-2 GC (`0xCF`), the ghost eraser and
  pre-sleep consolidation. OTP `0xF7` kept behind
  `LLSS_DISPLAY_USE_CUSTOM_FULL_LUT=n` for A/B only — defective on this unit.
- **Partial** = OTP DU (`0xFC`), unchanged: fast UI responsiveness while
  powered; retention irrelevant between frequent updates.
- **Deep partial** = `lut_du_deep` custom mode-2, transition-indexed: drives
  only changed pixels, but to GC-grade saturation (bistable-deep). For the
  deep-sleep clock: digits-only flicker, no full-screen flash, retains
  through power-off. Scheduled fulls (screensaver half-hour flash) remain the
  DC/ghost hygiene.
- **Incremental gray** (crosspoint/freeink mechanism): `lut_gray_enhance`
  drives only gray-coded pixels on top of a displayed BW page;
  `lut_gray_revert` returns them to B/W before the next BW update.
- Border tracked per mode: full `0x01`, partial `0x80`.
- Still queued: `power_down()`/`deep_sleep()` (0x22=0x03 + 0x10=0x01) wiring.

### Gray/deep-partial calibration notes (this unit, glass-tested 2026-07-04)

- Frame-rate nibble 0x2 is the only rate where mid-gray states are STABLE;
  at 0x8 the short pulses sit at the film surface and relax away in seconds.
- The film's gray response at FR2 is a staircase of single frames:
  1f = light gray, 2f = dark gray, 3f = darker, 7f ≈ black. Duty-cycled
  micro-alternation and overshoot/pull-back shapes both underperformed
  single-frame doses here.
- Clearing a gray needs a 2f black kick before the white drive; a one-way
  white push leaves residue even at 20 frames.
- Deep-partial retention needs local inversion cycles before the set: a
  monotonic 32f push faded after power-off, 2x(8f,8f) flash + 20f set holds.

## 6. Fast drive — inkboy port (2026-10-19)

Port of `kuslota/inkboy`'s SSD1681 "mixed scan" (itself after paperboy's
per-pixel driving) to our SSD1677: `CONFIG_LLSS_EPD_FAST_DRIVE`, engine in
the driver ("Fast drive" section), `epd f*` shell commands. Unlike paperboy,
inkboy keeps the COG — every trick is a controller feature we also have:

- one-frame custom LUT (`0x32`), mode 2, transition-indexed like
  `lut_du_deep`: BW = target T, RED = T ^ A (A = pixel still has budget) →
  rows 00/11 HOLD, 01 one VSL frame, 10 one VSH1 frame;
- rails up once (`0x22=0xC0`), then `0x22=0x0C` per scan;
- display option `0x37` all zero at session entry — **RAM ping-pong off**.
  This panel comes up with mode-2 ping-pong ON (the vendor partial writes
  only `0x24` and leans on it). Left on, scans after the first don't see
  the planes as written: on glass the box flickered faintly and ended white.
  With `epd reg 37 00 00 00 00 00 00` first, the same `fdrive` drove it
  solid black (glass-tested 2026-10-19). Our other paths write both planes
  explicitly, and the OTP partial's timing is the same with `0x37` at its
  boot value, all zero, or only ping-pong set (413 ms each, measured);
- per-pixel pulse budget (bit-sliced, 4 planes), Y-windowed RAM writes of
  only the rows whose target/mask changed, one all-HOLD scan at the end.

**Status: on at boot** — every partial refresh goes through the engine
(first scan synchronous, the rest spent by the display thread); fulls are
unchanged, and the partial floor still forces a full every 20 updates.
`epd fmode off` falls back to the OTP partial at runtime. Defaults: k=8
black pulses, **w=15 white pulses**, 1 frame/scan, FR2, HOLD ending, RED
delta writes, rails kept up.

Frame time per LUT FR nibble (bare all-HOLD scans, `epd fsweep`): ~25 Hz
per unit up to 8 — FR0 67.5 ms, FR1 40.4, **FR2 20.2**, FR3 13.5, FR4 10.1,
FR6 6.8, FR8 5.1; FRC 9.2, FRF 5.5 (saturates). Activation overhead with the
rails up ≈ 0.2 ms. **Rail power-up (`0xC0`) = 83 ms** — so the rails stay up
and a full re-raises them right after it finishes (fast mode only).

`epd fbench` (k=w=8 pulses, 1 frame/scan, FR2, RED delta writes):

| change | fast: first scan on glass | fast: all pulses + HOLD | OTP partial (0xFC) |
|---|---|---|---|
| 200×64 box | **24.9 ms** | 197 ms | 468 ms |
| full screen | 66.6 ms | 366 ms | 468 ms |

With w=15 the first scan is unchanged; a change to white needs 15 scans +
HOLD ≈ 330 ms of background drive (a real UI band after boot: first scan
35 ms, all 15 scans 611 ms including RAM writes).

Real press feedback (`epd press <btn>`, `fmode on`, scan 1 synchronous,
the rest spent by the display thread in the background):
**request → first scan done = 65 ms** (LVGL band 40 + panel 24), vs 509 ms
(40 + 469) on the OTP partial. Remaining device-side cost is LVGL:
~40 ms per band, ~215–226 ms for a full server frame.

Glass (2026-10-19, white field, black boxes driven with k=8, then erased):

| erase | result |
|---|---|
| 8 black pulses (white → black) | solid black |
| 8 white pulses | very faint mark left |
| 15 white pulses | **clean** — the default |
| 12 white pulses | not tested (that erase never ran: a command was lost on the serial link) |

The film resists the white direction here as in the gray calibration
(§5 notes). w=15 vs k=8 is not DC-balanced per black↔white cycle; the
periodic full (floor 20) is the hygiene. An opposite kick before the white
drive (as in `lut_gray_revert`) might clear in fewer pulses — untried.

Open:
- After a fast session (rails left up, our one-frame LUT in the register),
  the OTP partial `0xFC` runs in **107 ms** instead of 413 ms, every time,
  also after `epd fpoff`; it is not the `0x37` write (ruled out above). On
  glass that run erased a box worse than 8 fast white pulses. Irrelevant
  while fast mode is on (that path doesn't run); matters only if
  `epd fmode off` is used without a reboot. Not investigated further.
- Ghost build-up over many fast updates; retention after power cut
  (expected DU-grade, i.e. fades like the OTP partial — the full / deep
  partial remain the consolidation).
