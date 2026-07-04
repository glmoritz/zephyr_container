# How paperboy plays Game Boy on an e-ink panel (and why we can't — exactly)

Verdict up front: **it is not a scam.** I pulled the source of
`gitlab.com/zephray/paperboy` and read the display engine. It is real,
it is clever, and it exploits one hardware fact about the M5Paper S3 that
our Waveshare board does not share. This document explains the trick from
the physics up, with file references, and ends with what *is* transferable
to our SSD1677.

## 1. Anatomy of an e-paper display — where the "waveform" lives

Every EPD is three layers:

1. **The film** (the microcapsules): black and white pigment particles in
   fluid. Apply +15 V across a pixel → black particles migrate to the
   surface; −15 V → white; 0 V → particles stay where they are. That's
   all the film understands: a *voltage over time* per pixel. There is no
   "waveform" in the film — a waveform is just the *sequence of frames of
   voltages* someone decides to apply.

2. **The glass drivers**: row (gate) and column (source) driver chips
   bonded on the glass, exactly like a TFT LCD. They scan the panel line
   by line; each scan of the whole panel is one **frame** (typically
   50–100 Hz). Per frame, per pixel, the source driver applies one of
   three levels: +V (drive toward black), −V (toward white), 0 (hold).

3. **The controller (COG, "chip on glass")** — *optional*. Chips like our
   SSD1677 sit between your MCU and the glass drivers. They contain the
   framebuffer RAM, the timing generator, and the **LUT engine**: a table
   that says "for a pixel going from state X to state Y, apply this
   sequence of +/−/0 over the next N frames". The factory-tuned tables
   live in OTP memory on the chip. When we send `0x20` (master
   activation), the COG replays the LUT against the glass drivers on its
   own, and our 4 MHz SPI link just waits on the BUSY pin.

The key insight: **a "refresh" is nothing but a burst of frames.** A full
GC refresh ≈ 30–50 frames (~1.5–2 s worth of black/white flashing). A
partial DU refresh ≈ 10–15 frames. The COG's LUT is a frozen, canned
version of what a video controller does live.

## 2. The M5Paper S3 has no COG — that's the whole trick

The 4.7" 960×540 panel on the M5Paper S3 (ED047TC1-class, same family as
the LilyGo T5 4.7 / epdiy boards) exposes the **raw glass driver
interface** on its flex cable: an 8-bit parallel source-data bus plus the
gate/source clocking strobes. No controller chip, no LUT, no OTP — the
host is the timing generator.

You can see this directly in paperboy's `main/msg/msg.h`:

```c
#define EPD_XCK             24000000   // 24 MHz pixel clock
#define EPD_BUSW            8          // 8-bit source data bus
#define EPD_PWR_EN_PIN      45         // panel power rail enable
#define EPD_BST_EN_PIN      46         // ±15V booster enable
#define EPD_SDCE_PIN 13  // source driver chip enable
#define EPD_SDLE_PIN 15  // source driver latch
#define EPD_SDCK_PIN 16  // source driver clock
#define EPD_GDSP_PIN 17  // gate driver start pulse
#define EPD_GDCK_PIN 18  // gate driver clock
```

SDCE/SDLE/SDCK/GDSP/GDCK are TFT-panel driver signals. If your panel's
cable carries these, you *are* the display controller.

`msg.c` ("MSG" is Wenting's scan generator, MIT-licensed, 442 lines) then
does something elegant: it abuses the ESP32-S3's **LCD peripheral
(`esp_lcd` i80 bus) + DMA** to stream source-driver data at 24 MHz with
zero CPU cost per line, and bit-bangs the gate strobes around it. Result:
the panel scans continuously at a fixed frame rate, like a dumb LCD, and
the firmware decides *every frame* what voltage polarity each pixel gets.
That's why there's a real `msg_flip()`/VSYNC API — the emulator renders
into a back buffer and swaps on frame boundaries, a true video pipeline
on e-ink.

## 3. Where the "playable" image quality comes from

Driving the glass directly buys three things a COG can never give you:

- **One-frame updates.** A changed pixel gets a single ~16 ms drive pulse
  toward its new color *this frame*. It won't reach full saturation —
  that needs 5–10 pulses — but it becomes visibly darker/lighter
  immediately, and if it keeps the same value next frame, it keeps
  getting driven. Latency ≈ one frame. A COG's minimum is one full LUT
  playback plus command overhead.

- **Grayscale for free (temporal + spatial).** The Game Boy has 4 shades.
  paperboy renders 1-bit fields and lets shades emerge from *how often* a
  pixel is driven black across successive fields — the ink integrates the
  duty cycle (the film is slow; that's now a feature). `msg.h` has
  `EPD_IMAGE_FIELDS 8` — static images are pushed as 8 successive fields,
  i.e. 8 chances per pixel to be nudged, which is exactly a hand-rolled
  waveform. This is also precisely how the commercial "A2 video mode" on
  eReaders works, just done in the open.

- **Ghost control on demand.** Undriven/weakly-driven pixels accumulate
  error (ghosting) and the fix is the same one the factory LUTs use:
  saturate everything both ways. paperboy's `ui.h`:

  ```
  /* Clear EPD ghosting by flashing 5 full-black then 5 full-white frames. */
  ```

  Five black + five white frames ≈ 160 ms of flash, applied when the UI
  decides, not when a LUT dictates.

The price he pays: **no DC balance bookkeeping, weak saturation, and
retention is poor** — a game frame is driven with a handful of pulses, so
if you cut power the image fades (the same physics as our partial-refresh
fade, amplified). For a game session that's irrelevant; for a chess board
that must survive deep sleep, it's disqualifying even if we could do it.

So: a good engineer, a controllerless panel, and the ESP32-S3's LCD
peripheral. Impressive, verifiable, no fireworks.

## 4. Why this is physically unavailable on our board

Our 3.97" 800×480 panel has the **SSD1677 bonded on the panel glass**.
The flex cable exposes SPI + BUSY, nothing else. The gate/source drivers
are wired to the SSD1677 die; there is no way to clock frames into the
glass ourselves. The waveform engine is the SSD1677's, period.

Concretely, per update our path is:

```
48 KB framebuffer over 4 MHz SPI  (~100 ms, CPU-driven)
→ 0x20 master activation
→ COG replays a LUT (10–50 frames, 300 ms–2 s, we wait on BUSY)
```

Even with a minimal 1-frame LUT, we can't beat ~5–8 Hz full-screen, and
each update carries the RAM-rewrite cost. paperboy pays neither: his
"RAM write" *is* the scan, via DMA.

## 5. What we take from it anyway

1. **The mental model.** OTP LUT = canned frame sequence. Once you see
   that, the SSD1677 stops being magic: `0x22 = 0xF7` means "replay the
   factory 30-frame movie", the `0x1A` fake-temperature trick means
   "replay the shorter movie from a hotter shelf", and a custom `0x32`
   LUT is us writing a 105-byte movie of our own.

2. **Consolidate, then flash.** His 5-black/5-white ghost purge is our
   "full GC refresh at moments the user forgives" (screensaver flip,
   game end, before deep sleep). Ghost management is a *scheduling*
   problem, not a waveform problem.

3. **A2-style feedback (future experiment).** A custom 1–2 frame DU LUT
   via `0x32` is the COG-constrained cousin of his per-frame driving:
   good for instant button-press feedback on a small window, at the cost
   of saturation — always followed by a proper refresh. That's Phase 4+
   material, after the fundamentals are right.

## 6. References

- paperboy source: <https://gitlab.com/zephray/paperboy> — `main/msg/msg.{h,c}`
  (scan generator), `main/gbemu.c` (`blit_lcd_to_epd`, dirty-line
  tracking), `main/ui.h` (ghost flash comment).
- The same author's earlier FPGA EPD controller ("Caster"/Glider) is the
  long-form proof this technique scales: custom per-pixel waveform state
  machines, published at <https://gitlab.com/zephray/caster>.
- epdiy (<https://github.com/vroland/epdiy>) — the community library for
  driving controllerless panels from ESP32, same principle as MSG.
- Our controller's factory approach: `docs/epd/EPD_3in97.cpp` (Waveshare
  vendor demo for this exact board) and `docs/epd/WAVEFORMS.md` (register
  findings for our driver).
