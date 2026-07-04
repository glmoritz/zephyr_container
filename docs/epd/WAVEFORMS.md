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

(append findings here as hardware tests run)

## 5. Decisions (to be confirmed by the matrix)

- Full = vendor OTP `0xF7`; drop the borrowed 3.7" LUT once confirmed.
- New fast-full = `0x1A` bank + `0xD7` for move-confirmed / view-toggle
  refreshes (`UI_CTX_SWITCH`).
- Partial: `0xFC → 0xFF` (power down between updates); keep prev/new dual-RAM
  + post-refresh re-sync (it's more careful than the vendor's).
- Border tracked per mode: full `0x01`, partial `0x80`.
- Add `power_down()` + `deep_sleep()`; consolidation full before sleep.
- 4-gray later via the OTP `0x5A` bank (vendor packing), not a custom LUT;
  freeink's differential gray enhance/revert LUTs are the stretch goal.
