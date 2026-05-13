#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
container_workspace_root="/workspace"
workspace_root="$container_workspace_root"

if [[ ! -d "$workspace_root/.vscode" ]]; then
    workspace_root="$(cd -- "$script_dir/.." && pwd)"
fi

state_file="$workspace_root/.vscode/.zephyr-active-project"
compile_commands_link="$workspace_root/compile_commands.json"
firmware_link="$workspace_root/zephyr.bin"
elf_link="$workspace_root/zephyr.elf"

usage() {
    cat <<'EOF'
Usage:
    zephyr-project.sh set <project_dir>
  zephyr-project.sh build
  zephyr-project.sh flash [port]
  zephyr-project.sh current
EOF
}

resolve_project_path() {
    local stored_path="$1"

    if [[ -z "$stored_path" ]]; then
        return 1
    fi

    if [[ "$stored_path" != /* ]]; then
        printf '%s\n' "$workspace_root/$stored_path"
        return 0
    fi

    if [[ -d "$stored_path" ]]; then
        printf '%s\n' "$stored_path"
        return 0
    fi

    if [[ "$workspace_root" != "$container_workspace_root" && "$stored_path" == "$container_workspace_root"/* ]]; then
        printf '%s\n' "$workspace_root/${stored_path#${container_workspace_root}/}"
        return 0
    fi

    if [[ "$workspace_root" == "$container_workspace_root" && "$stored_path" == /home/*/workspace/* ]]; then
        printf '%s\n' "$container_workspace_root/${stored_path##*/workspace/}"
        return 0
    fi

    printf '%s\n' "$stored_path"
}

state_path_for_project() {
    local project_path="$1"

    if [[ "$project_path" == "$workspace_root/"* ]]; then
        printf '%s\n' "${project_path#${workspace_root}/}"
    else
        printf '%s\n' "$project_path"
    fi
}

require_active_project() {
    if [[ ! -f "$state_file" ]]; then
        echo "No active Zephyr project set. Run: zephyr-project.sh set /workspace/apps/<project> or /workspace/projects/<project>" >&2
        exit 1
    fi

    active_project="$(resolve_project_path "$(<"$state_file")")"

    if [[ ! -d "$active_project" ]]; then
        echo "Active project directory does not exist: $active_project" >&2
        exit 1
    fi
}

refresh_links() {
    local app_dir="$1"
    local compile_commands="$app_dir/build/compile_commands.json"
    local firmware_bin="$app_dir/build/zephyr/zephyr.bin"
    local firmware_elf="$app_dir/build/zephyr/zephyr.elf"

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

    if [[ -f "$firmware_elf" ]]; then
        ln -sfn "$firmware_elf" "$elf_link"
    else
        rm -f "$elf_link"
    fi
}

apply_patches() {
    local zephyr_base="${ZEPHYR_BASE:-/opt/toolchains/zephyr}"
    local patch_dirs=()
    local patch_dir

    if [[ -n "${active_project:-}" && -d "$active_project/patches" ]]; then
        patch_dirs+=("$active_project/patches")
    fi

    if [[ -d "$workspace_root/patches" ]]; then
        patch_dirs+=("$workspace_root/patches")
    fi

    if [[ ${#patch_dirs[@]} -eq 0 ]]; then
        return 0
    fi

    for patch_dir in "${patch_dirs[@]}"; do
        for patch in "$patch_dir"/*.patch; do
            [[ -f "$patch" ]] || continue
            # --check with --reverse: if it succeeds the patch is already applied
            if git -C "$zephyr_base" apply --check --reverse "$patch" &>/dev/null; then
                echo "Patch already applied: $(basename "$patch")"
            elif git -C "$zephyr_base" apply --check "$patch" &>/dev/null; then
                git -C "$zephyr_base" apply "$patch"
                echo "Applied patch: $(basename "$patch")"
            else
                echo "WARNING: patch cannot be applied (conflict?): $(basename "$patch")" >&2
            fi
        done
    done
}

detect_cached_board() {
    local cache_file="$1/build/CMakeCache.txt"

    if [[ ! -f "$cache_file" ]]; then
        return 0
    fi

    sed -n 's/^CACHED_BOARD:STRING=//p' "$cache_file" | head -n 1
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

    printf '%s\n' "$(state_path_for_project "$app_dir")" > "$state_file"
    refresh_links "$app_dir"
    echo "Active Zephyr project: $app_dir"

    if [[ ! -f "$app_dir/build/compile_commands.json" ]]; then
        echo "Build this project once to generate compile_commands.json for IntelliSense."
    fi
}

cmd_build() {
    require_active_project

    local board="${BOARD:-}"
    local -a west_args=("build" "-p" "auto")
    local -a cmake_args=("-DCMAKE_BUILD_TYPE=Debug")

    if [[ -z "$board" ]]; then
        board="$(detect_cached_board "$active_project")"
    fi

    if [[ -z "$board" ]]; then
        # Check for a per-project .board file
        if [[ -f "$active_project/.board" ]]; then
            board="$(<"$active_project/.board")"
        else
            board="esp32s3_devkitc/esp32s3/procpu"
        fi
    fi

    west_args+=("-b" "$board")

    if [[ -f "$active_project/debug.conf" ]]; then
        cmake_args+=("-DEXTRA_CONF_FILE=debug.conf")
    fi

    west_args+=("--")
    west_args+=("${cmake_args[@]}")

    echo "Building $active_project for board: $board"
    apply_patches
    west "${west_args[@]}"
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