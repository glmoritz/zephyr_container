# VS Code Zephyr Workflow

This workspace is configured so you can switch between Zephyr apps without manually editing VS Code settings each time.

## What is configured

- C/C++ IntelliSense reads compile commands from `/workspace/compile_commands.json`
- `/workspace/compile_commands.json` is a symlink that points to the currently active app's `build/compile_commands.json`
- `/workspace/zephyr.bin` is a symlink that points to the currently active app's firmware binary
- VS Code tasks call `/workspace/scripts/zephyr-project.sh` to manage the active app

## Board and build settings

The build workflow currently uses this board target and overlay:

```sh
west build -p always -b esp32s3_devkitc/esp32s3/procpu -- -DDTC_OVERLAY_FILE=boards/esp32s3_devkitc.overlay
```

This is the command used by the active-project build task.

## How to switch projects

Use the VS Code task:

```text
Zephyr: Set Active Project
```

When prompted, select the app from the dropdown list. The task terminal will open and print the selected active project. Example entries:

```text
/workspace/apps/01_blink
/workspace/apps/03_demo_kconfig
/workspace/apps/05_demo_adc
```

This updates the active-project state file:

```text
/workspace/.vscode/.zephyr-active-project
```

If the selected app has already been built, the script also refreshes these symlinks:

```text
/workspace/compile_commands.json
/workspace/zephyr.bin
```

## Build, flash, and monitor

Available VS Code tasks:

- `Zephyr: Set Active Project`
- `Zephyr: Build Active Project`
- `Zephyr: Flash Active Project`
- `Zephyr: Monitor (miniterm)`

Typical workflow:

1. Run `Zephyr: Set Active Project`
2. Choose an app directory such as `/workspace/apps/03_demo_kconfig`
3. Run `Zephyr: Build Active Project`
4. Run `Zephyr: Flash Active Project`
5. Run `Zephyr: Monitor (miniterm)`

## Flash command

The flash task uses:

```sh
python -m esptool --port "/dev/ttyACM0" --chip auto --baud 921600 --before default_reset --after hard_reset write-flash -u --flash_size detect 0x0 <active-app>/build/zephyr/zephyr.bin
```

The actual binary path is taken from the currently active project.

## Monitor command

The serial monitor task uses:

```sh
python -m serial.tools.miniterm "/dev/ttyACM0" 115200
```

## IntelliSense notes

The C/C++ extension is configured in `.vscode/c_cpp_properties.json` to use:

- the active `compile_commands.json` symlink
- the ESP32-S3 Zephyr cross-compiler
- the Zephyr source tree under `/opt/toolchains/zephyr`

After switching to another app, IntelliSense should follow the new compile database once that app has been built.

If IntelliSense looks stale, run these VS Code commands:

1. `C/C++: Reset IntelliSense Database`
2. `Developer: Reload Window`

## Command line alternative

You can also manage the active app directly from a shell:

```sh
bash /workspace/scripts/zephyr-project.sh set /workspace/apps/03_demo_kconfig
bash /workspace/scripts/zephyr-project.sh build
bash /workspace/scripts/zephyr-project.sh flash
bash /workspace/scripts/zephyr-project.sh current
```

## Important limitation

The active-project workflow assumes the ESP32-S3 board and overlay shown above. If another app needs a different board, overlay, or extra build arguments, the helper script and tasks should be adjusted for that app.