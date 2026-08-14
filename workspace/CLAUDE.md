# Zephyr Dev Container — Workspace Guide

Canonical guide for agents working in this workspace. `AGENTS.md` predates the
current layout (it still assumes `hello_eink` is the only product app) — prefer
this file when the two disagree.

## Repository layout: two nested git repos

- **Outer repo** = the dev environment (`Dockerfile.*`, `compose.yml`,
  `scripts/`, `.vscode/`, `boards/`, `west.yml`). Host path
  `/home/guilherme/00_tmp/labsc_lora`, container path `/workspace`.
- **Inner repos** = the individual products, under `/workspace/projects/<name>`.
  Each is its own clone, **ignored** by the outer repo. Current ones:
  - `projects/labsc_filament_oven` — PID filament oven, **ESP32-C6 (RISC-V)**
  - `projects/labsc_lora` — **all four LoRa applications**, under `apps/`:
    - `apps/lorawan_uplink` — LoRaWAN via USP/LBM, LR1121, **ESP32-C6**
    - `apps/lr_fhss_tx` — raw LR-FHSS TX, **Heltec V3 (ESP32-S3 + SX1262)**
    - `apps/lorawan_join` — OTAA join, AU915 sub-band 3, Heltec V3
    - `apps/lorawan_lrfhss` — LoRaWAN carried by LR-FHSS (DR7), Heltec V3
  - (`hello_eink` — the e-ink product, **ESP32-S3 (Xtensa)** — is the reference
    for "known working"; same methodology.)

`labsc_lora` is the one repo here that nests apps a level down. It exists
because `lorawan_uplink` and `lorawan_lrfhss` had each vendored the *same two*
USP submodule commits with the *same* patch — 18 MB of duplicate clone and a
patch free to drift. They now share one `modules/`, one `patches/` and one
`setup.sh` at the repo root. `list_projects()` in `scripts/zephyr-project.sh`
searches three levels deep for exactly this reason.

### The radio projects are not variants of one thing

They use two mutually exclusive stacks, and the split is forced by the tree,
not by preference:

| App | Stack | Pin AU915 sub-band | LR-FHSS |
|---|---|---|---|
| `lorawan_join` | Zephyr `subsys/lorawan` (loramac-node) | yes | no |
| `lr_fhss_tx` | Zephyr LoRa driver on lora-basics-modem | n/a | raw PHY only |
| `lorawan_lrfhss` | USP / LoRa Basics Modem | no | yes, as DR7 |

`subsys/lorawan` compiles only under `CONFIG_LORA_MODULE_BACKEND_LORAMAC_NODE`,
which has no LR-FHSS; Zephyr's lora-basics-modem glue compiles the radio
drivers but not LBM's LoRaWAN core. So one image cannot do both — hence USP
(`apps/lorawan_lrfhss`), which vendors the full LBM.

**`labsc_lora` needs `bash setup.sh` after cloning** — once for the repo, not
per app. Submodules plus two patches, one of which (`0002`) breaks every
SX126x build without it.

The three Heltec V3 apps are **built and verified by symbol inspection, never
run on hardware** — no board was attached when they were written.
- `/workspace/apps` is course/training examples, not products.

Everything runs **inside the container**. Host paths (`/home/guilherme/...`)
must not appear in build/debug configs.

Running container: `Zephyr-Introduction` (a VS Code devcontainer, *not* the one
`compose.yml` describes — `compose.yml` is a leftover alternative and does not
map `/dev`). To work from the host:

```bash
docker exec Zephyr-Introduction bash -lc '<command>'
```

The board enumerates as `/dev/ttyACM0` inside the container (ESP32-C6 native
USB-Serial-JTAG — same port carries both the serial console and JTAG).

## Active-project model

`scripts/zephyr-project.sh` is the single entry point. It stores the active
project in `.vscode/.zephyr-active-project` and, on `set`/`build`, regenerates
symlinks that all VS Code configs point at:

| Link | Points to |
|---|---|
| `.vscode/.zephyr-tools/xtensa-espressif_esp32s3_zephyr-elf-gdb` | the **active project's** GDB, from CMake's `CMAKE_GDB` |
| `.vscode/.zephyr-tools/xtensa-espressif_esp32s3_zephyr-elf-gcc` | idem, GCC |
| `.vscode/.zephyr-tools/openocd` | Zephyr SDK's OpenOCD |
| `/workspace/compile_commands.json`, `zephyr.bin`, `zephyr.elf` | active project's `build/` output |

**The `xtensa-espressif_esp32s3_*` names are historical and misleading.** They
are generic slots. With `labsc_filament_oven` active they resolve to
`riscv64-zephyr-elf-gdb`/`-gcc`. Do not "fix" the names without updating
`zephyr-project.sh` and every `launch.json` entry together.

Board selection order in `cmd_build`: `$BOARD` env → CMake `CACHED_BOARD` →
per-project `.board` file → fallback `esp32s3_devkitc/esp32s3/procpu`.
`labsc_filament_oven/.board` holds `esp32c6_devkitc/esp32c6/hpcore`.

Commands:

```bash
bash /workspace/scripts/zephyr-project.sh set projects/labsc_filament_oven
bash /workspace/scripts/zephyr-project.sh build
bash /workspace/scripts/zephyr-project.sh flash /dev/ttyACM0
bash /workspace/scripts/zephyr-project.sh current
```

`set` takes the path to the application directory, which for `labsc_lora` is
one level deeper — `projects/labsc_lora/apps/lorawan_join`, not the repo root.
And the Heltec V3 is a CP2102, so it is `/dev/ttyUSB0`; `/dev/ttyACM0` above is
the ESP32-C6 devkit's native USB.

Flashing is plain esptool (`python -m esptool --port <port> --chip auto --baud
921600 ... write-flash -u --flash_size detect 0x0 zephyr.bin`) — it does **not**
use JTAG, which is why flashing can succeed while debugging fails.

## Debugging (VS Code tasks + launch configs)

Two independent halves; diagnose them separately.

1. **OpenOCD** — a `tasks.json` task runs `openocd -f
   /workspace/boards/esp32c6-zephyr.cfg -c "init; reset halt; esp
   appimage_offset 0x0"` and the task's `problemMatcher` waits for
   `Listening on port 3333 for gdb connections`.
2. **GDB** — the `launch.json` `cppdbg` entry starts `miDebuggerPath` and
   connects to `localhost:3333`.

Board configs live in `/workspace/boards/`:

- `esp32c6-zephyr.cfg` → `esp_usb_jtag` + `ESP_RTOS "Zephyr"` (single-core
  RISC-V, so the Zephyr RTOS plugin works).
- `esp32s3-zephyr.cfg` → `esp_usb_jtag` + `ESP_RTOS "hwthread"` (the Zephyr
  plugin crashes on SMP/dual-core; `hwthread` is the workaround).

### OpenOCD binary: there are two, and only one has C6 support

| Path | Version | ESP32-C6 |
|---|---|---|
| `/usr/local/bin/openocd` (first on `PATH`) | `v0.12.0-esp32-20260424` | **yes** — `target/esp32c6.cfg` present |
| `/root/zephyr-sdk-1.0.1/hosttools/.../bin/openocd` (what `.zephyr-tools/openocd` links to) | older SDK build | **no** — only esp32/s2/s3 |

The tasks invoke bare `openocd`, so they get the working one. Anything that
resolves OpenOCD through the `.zephyr-tools/openocd` symlink will fail on C6
with a missing-config error.

These OpenOCD warnings on C6 are **benign** — the session works anyway:

```
Warn : Installed stub code magic_num(0x1000006F) ... Expected ... (0xFEEDFACE)
Warn : No flash mapping / Could not get flash mapping (0)
```

### C6 GDB specifics

Required setup commands (already in the C6 launch configs): `set architecture
riscv:rv32`, `set breakpoint auto-hw on`, `set remote
hardware-breakpoint-limit 2`, `set mem inaccessible-by-default off`. The C6 has
**2 hardware breakpoints**; flash is not writable, so software breakpoints do
not work.

That budget of two is the whole story for breakpoints on this part, and it is
easy to overrun without noticing: VS Code counts every breakpoint in the gutter
across every open file, plus any left over from a previous session. A third one
does not warn — it silently fails to bind, and the target runs straight past it.

**Symptom seen here:** a breakpoint on `main` never hit; `continue` ran on
forever. Prime suspect is the two-breakpoint limit, not the toolchain — the same
session attached, halted, read registers and resolved `main` to a real address in
`src/main.c` correctly.

If a breakpoint does not hit: clear ALL of them, set only the one you care about,
and re-check. `info breakpoints` in the Debug Console tells you what GDB thinks
it has; `mon esp appimage_offset 0x0` (already in the OpenOCD task) is what makes
flash addresses resolvable in the first place.

Note also that the ESP32 second-stage bootloader resets the CPU on its way into
the application, which is a known way to lose breakpoints armed before the app
starts. Untested here; mentioned so the next person does not re-derive it.

### Known failure: "it flashes but won't attach" — GDB path

**Symptom:** the *Debug ESP32-C6 (flash first, attach)* config flashes fine,
then the debug session never starts.

**Cause:** all four C6 `launch.json` entries hardcoded
`/opt/toolchains/zephyr-sdk-0.17.4/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-gdb`.
This container ships **Zephyr SDK 1.0.1 at `/root/zephyr-sdk-1.0.1`** — that
path does not exist, so `cppdbg` cannot start GDB. The S3 configs were never
affected because they use the `.zephyr-tools` symlink.

**Fix (applied):** point the C6 configs at
`${workspaceFolder}/.vscode/.zephyr-tools/xtensa-espressif_esp32s3_zephyr-elf-gdb`,
same as S3. The symlink tracks the active project's toolchain and survives SDK
upgrades. **Never hardcode an SDK version path in `launch.json`.**

### Manual reproduction / smoke test

Verifies the whole chain without VS Code:

```bash
docker exec Zephyr-Introduction bash -lc '
nohup openocd -f /workspace/boards/esp32c6-zephyr.cfg \
  -c "init; reset halt; esp appimage_offset 0x0" >/tmp/ocd.log 2>&1 &
for i in $(seq 1 40); do grep -q "Listening on port 3333" /tmp/ocd.log && break; sleep 0.5; done
timeout 60 /root/zephyr-sdk-1.0.1/gnu/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-gdb -batch \
  -ex "set pagination off" -ex "set architecture riscv:rv32" \
  -ex "set breakpoint auto-hw on" -ex "set remote hardware-breakpoint-limit 2" \
  -ex "set mem inaccessible-by-default off" \
  -ex "target remote localhost:3333" -ex "monitor reset halt" \
  -ex "maintenance flush register-cache" -ex "info registers pc" -ex "break main" \
  /workspace/zephyr.elf'
```

Healthy output: TAP id `0x0000dc25`, `Examined RISC-V core`, `XLEN=32`,
`pc 0x40000000` (reset vector), and a breakpoint resolved in the project's
`src/main.c`.

Do **not** run `continue` in a `-batch` GDB smoke test — it blocks forever.
Also avoid `pkill -f openocd` inside `docker exec bash -lc`: the pattern matches
the wrapper shell's own command line and kills the session. Use `pkill -x`.

## Bench instrumentation (labsc_filament_oven)

Turned on by `debug.conf`; absent from a field image. Worth reading before
touching it, because the split between what is optional and what is not is
deliberate and not the obvious one.

### The rule: the control path has no debug variant

`src/pid.c` and `src/pid_thread.c` contain **not one `#ifdef`**. Every build
computes the same values, publishes them the same way, and takes the same time
doing it. A loop whose timing depends on the build configuration is a loop that
was never actually validated, so:

| layer | file | in a field image? |
|---|---|---|
| capture the cycle into `struct pid_diag` | `src/pid.c` | **yes**, unconditional |
| publish it | `src/pid_thread.c` → `pid_pub_publish()` | **yes**, unconditional |
| seqlock buffer + cycle semaphore | `src/pid_pub.c` | **yes** — publishes into a buffer nobody reads |
| consume it (LED + trace) | `src/oven_debug.c` | only with `CONFIG_OVEN_DEBUG` |

Do not "optimise" this by wrapping the capture or the publish in a Kconfig
guard. That is the one thing this design exists to prevent.

`pid_pub` is a **seqlock**: the writer is the cooperative PID thread and can
preempt the preemptible reader mid-copy, so a plain struct copy would tear. The
writer never blocks; the reader retries three times then gives up (a dropped
trace line, never an unbounded loop).

### Debug DT overlays

`scripts/zephyr-project.sh` applies `debug/<sanitized board>.overlay` as
`EXTRA_DTC_OVERLAY_FILE` whenever `debug.conf` is in play — mirroring how
`boards/<board>.overlay` works, so a C6 bench overlay never leaks into a
BlackPill build.

`debug/esp32c6_devkitc_esp32c6_hpcore.overlay` does two things:

1. **WS2812 status LED on GPIO8, over I2S.** There is no ESP32 RMT driver in
   this Zephyr and the WS2812 GPIO bit-bang driver is nRF-only, so I2S is the
   route — it is also what Espressif themselves use, see upstream
   `samples/drivers/led/led_strip/boards/esp32c6_devkitc_hpcore.overlay`.
   **The overlay REPLACES the board's `i2s_default` group1 with the single pin
   `I2S_O_SD_GPIO8`.** The stock group also claims GPIO6 and GPIO7 — which on
   this carrier are SPI SCLK and MISO, the thermocouple bus. Leaving them in
   would hand the safety bus to the I2S peripheral. Keep that group at one pin.
2. **Log stream moved to the USB-Serial-JTAG** via `chosen zephyr,log-uart`.

### Two serial ports, different things on each

The devkit exposes two USB connectors and they are not interchangeable:

| device | peripheral | carries |
|---|---|---|
| `/dev/ttyACM0` | USB-Serial-JTAG (native) | PID trace (log stream), **and** JTAG |
| `/dev/ttyACM1` | UART bridge → `uart0` (GPIO16/17) | console + shell (`oven …` commands) |

This trips people up: with only the USB cable plugged in you see the trace but
cannot reach the shell, and `printk`/boot banner go to a port with nothing on it.
`debug.conf` sets `CONFIG_LOG_BACKEND_UART=y` explicitly (it defaults to `n` once
`SHELL_BACKEND_SERIAL` is on) and `CONFIG_SHELL_LOG_BACKEND=n` so trace lines are
not duplicated onto the console.

### The trace is a CSV

One row per control cycle, integers only, every row self-contained. Prefixes are
greppable and distinct: `pidcsv#` for header/units rows, `pidcsv,` for data.

```bash
docker exec Zephyr-Introduction python -m serial.tools.miniterm --raw /dev/ttyACM0 115200 \
  | grep -o 'pidcsv,.*' > run.csv
```

Columns: `cycle,dt_ms,act,sp_cc,pv_cc,e_cc,dpv_cc,kp_m,ki_m,kd_m,p_mhc,i_mhc,d_mhc,sum_mhc,out_hc,sat,retune,armedge`
(`_cc` centi-degC, `_m` gain x1000, `_mhc` milli half-cycles, `sat` −1/0/+1 with
non-zero meaning anti-windup pinned the integrator). The header is emitted at
boot and re-emitted every 240 rows, so a capture started mid-run still explains
itself.

`p_mhc`/`sum_mhc` are **int64** on purpose: the actuator command is clamped to
120, but the unsaturated sum is not, and how far past the rail the law asked for
is most of what you are tracing.

### Status LED

White flash marks the cycle start, then red for the fraction of the remaining
window matching commanded power:

```
power = 100%  |WWWWW|RRRRRRRRRRRRRRRRRRRR|
power =  50%  |WWWWW|RRRRRRRRRR..........|
power =   0%  |WWWWW|....................|
              0   100ms              500ms
```

It shows **commanded** power, not delivered power — it follows the PID even while
DISARMED, when the Output thread is correctly refusing to energize anything. That
is how you watch the loop settle without a live heater. While DISARMED the output
is forced to 0, so you only ever see the white flash; `oven arm` (on ACM1) is what
makes red appear.

### Thread priority

The diagnostics thread is `K_PRIO_PREEMPT(12)` — below `main`, **above** the
Watchdog. The Watchdog must stay the lowest-priority thread in the system because
its starvation is the detector; `oven_threads.h` carries a `BUILD_ASSERT` to that
effect. The diagnostics thread cannot starve anything: it is blocked on the cycle
semaphore or a timed sleep essentially all the time.

## Gotchas checklist

- Only one OpenOCD may own `/dev/ttyACM0`'s JTAG interface at a time; the
  "Restart OpenOCD" tasks run `Debug: Stop OpenOCD` first for that reason.
- A serial monitor (`miniterm`) on `/dev/ttyACM0` coexists with JTAG on the C6
  (same USB device, different interfaces), but a stale monitor from a previous
  session can still hold the port.
- `zephyr.elf` / `zephyr.bin` / `compile_commands.json` at `/workspace` are
  symlinks into the *active* project. If you debug the wrong binary, check
  `zephyr-project.sh current` first.
- Keep product-specific boards/overlays inside the product repo
  (`projects/<name>/boards/`), not in `/workspace/boards` (which holds shared
  OpenOCD configs and course example boards).
- `docker exec … bash -lc` does **not** read `/root/.bashrc`, which is where
  `zephyr-env.sh` is sourced. Without it `ZEPHYR_BASE` is the stale
  `/workspace/zephyr` baked into the image and `west build` fails with "unknown
  command build". Prefix scripted builds with
  `source /opt/toolchains/zephyr/zephyr-env.sh;`. (The west workspace itself is
  `/opt/toolchains`, not `/workspace`.)
- The oven's protection sensor (`tc1`) reading a constant `0.00 °C` raises **no
  fault**: zero is inside the plausibility window `[-20, +300] °C`. This is the
  documented MAX6675 gap (`SAFETY-STATUS.md`: open-thermocouple detection only,
  no short-to-GND), seen live on the bench. Do not read "fault=0x00000000" as
  "both sensors are good".
