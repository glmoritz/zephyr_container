#!/usr/bin/env bash

set -euo pipefail

workspace_root="/workspace"
state_file="$workspace_root/.vscode/.zephyr-active-project"
compile_commands_link="$workspace_root/compile_commands.json"
firmware_link="$workspace_root/zephyr.bin"

usage() {
    cat <<'EOF'
Usage:
  zephyr-project.sh set <app_dir>
  zephyr-project.sh build
  zephyr-project.sh flash [port]
  zephyr-project.sh current
EOF
}

require_active_project() {
    if [[ ! -f "$state_file" ]]; then
        echo "No active Zephyr project set. Run: zephyr-project.sh set /workspace/apps/<project>" >&2
        exit 1
    fi

    active_project="$(<"$state_file")"

    if [[ ! -d "$active_project" ]]; then
        echo "Active project directory does not exist: $active_project" >&2
        exit 1
    fi
}

refresh_links() {
    local app_dir="$1"
    local compile_commands="$app_dir/build/compile_commands.json"
    local firmware_bin="$app_dir/build/zephyr/zephyr.bin"

    if [[ -f "$compile_commands" ]]; then
        ln -sfn "$compile_commands" "$compile_commands_link"
    else
        rm -f "$compile_commands_link"
    fi

    if [[ -f "$firmware_bin" ]]; then
        ln -sfn "$firmware_bin" "$firmware_link"
    else
        rm -f "$firmware_link"
    fi
}

cmd_set() {
    local app_dir="${1:-}"

    if [[ -z "$app_dir" ]]; then
        usage
        exit 1
    fi

    if [[ ! -d "$app_dir" ]]; then
        echo "Project directory not found: $app_dir" >&2
        exit 1
    fi

    printf '%s\n' "$app_dir" > "$state_file"
    refresh_links "$app_dir"
    echo "Active Zephyr project: $app_dir"

    if [[ ! -f "$app_dir/build/compile_commands.json" ]]; then
        echo "Build this project once to generate compile_commands.json for IntelliSense."
    fi
}

cmd_build() {
    require_active_project

    west build -p always -b esp32s3_devkitc/esp32s3/procpu -- -DDTC_OVERLAY_FILE=boards/esp32s3_devkitc.overlay -DEXTRA_CONF_FILE=boards/esp32s3_devkitc.conf
    refresh_links "$active_project"
    echo "Build complete for: $active_project"
}

cmd_flash() {
    require_active_project
    local port="${1:-/dev/ttyACM0}"
    local firmware_bin="$active_project/build/zephyr/zephyr.bin"

    if [[ ! -f "$firmware_bin" ]]; then
        echo "Firmware binary not found: $firmware_bin" >&2
        echo "Build the active project first." >&2
        exit 1
    fi

    python -m esptool --port "$port" --chip auto --baud 921600 --before default_reset --after hard_reset write-flash -u --flash_size detect 0x0 "$firmware_bin"
}

cmd_current() {
    require_active_project
    echo "$active_project"
}

command_name="${1:-}"
shift || true

case "$command_name" in
    set)
        cmd_set "$@"
        ;;
    build)
        require_active_project
        cd "$active_project"
        cmd_build
        ;;
    flash)
        cmd_flash "$@"
        ;;
    current)
        cmd_current
        ;;
    *)
        usage
        exit 1
        ;;
esac