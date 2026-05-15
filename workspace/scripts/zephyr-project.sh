#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
container_workspace_root="/workspace"
workspace_root="$container_workspace_root"

if [[ ! -d "$workspace_root/.vscode" ]]; then
    workspace_root="$(cd -- "$script_dir/.." && pwd)"
fi

state_file="$workspace_root/.vscode/.zephyr-active-project"
tool_dir="$workspace_root/.vscode/.zephyr-tools"
gdb_link="$tool_dir/xtensa-espressif_esp32s3_zephyr-elf-gdb"
gcc_link="$tool_dir/xtensa-espressif_esp32s3_zephyr-elf-gcc"
openocd_link="$tool_dir/openocd"
compile_commands_link="$workspace_root/compile_commands.json"
firmware_link="$workspace_root/zephyr.bin"
elf_link="$workspace_root/zephyr.elf"

usage() {
    cat <<'EOF'
Usage:
        zephyr-project.sh set [project_dir]
  zephyr-project.sh build
  zephyr-project.sh flash [port]
  zephyr-project.sh current
    zephyr-project.sh openocd
EOF
}

trim_trailing_slash() {
        local path="$1"

        while [[ "$path" != "/" && "$path" == */ ]]; do
                path="${path%/}"
        done

        printf '%s\n' "$path"
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

list_projects() {
    local root
    local candidate

    for root in "$workspace_root/projects" "$workspace_root/apps"; do
        [[ -d "$root" ]] || continue

        while IFS= read -r candidate; do
            [[ -f "$candidate/CMakeLists.txt" ]] || continue
            printf '%s\n' "$candidate"
        done < <(find "$root" -mindepth 1 -maxdepth 1 -type d | sort)
    done
}

select_project_path() {
    local projects=()
    local project
    local selection
    local prompt_input="/dev/stdin"
    local prompt_output="/dev/stdout"
    local index
    local choice

    mapfile -t projects < <(list_projects)

    if [[ ${#projects[@]} -eq 0 ]]; then
        echo "No Zephyr projects found under $workspace_root/apps or $workspace_root/projects" >&2
        return 1
    fi

    if [[ -r /dev/tty && -w /dev/tty ]]; then
        prompt_input="/dev/tty"
        prompt_output="/dev/tty"
    elif [[ ! -t 0 || ! -t 1 ]]; then
        echo "No project path provided and no interactive terminal is available." >&2
        echo "Available projects:" >&2
        printf '  %s\n' "${projects[@]}" >&2
        return 1
    fi

    printf 'Select the active Zephyr project:\n' > "$prompt_output"
    for index in "${!projects[@]}"; do
        printf '  %d) %s\n' "$((index + 1))" "${projects[index]}" > "$prompt_output"
    done

    while true; do
        printf 'Enter one of the listed numbers [1-%d]: ' "${#projects[@]}" > "$prompt_output"

        if ! IFS= read -r choice < "$prompt_input"; then
            echo "Project selection cancelled." >&2
            return 1
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#projects[@]} )); then
            selection="${projects[choice - 1]}"
            printf '%s\n' "$selection"
            return 0
        fi

        printf 'Enter one of the listed numbers.\n' > "$prompt_output"
    done
}

read_cache_value() {
    local cache_file="$1"
    local key="$2"

    [[ -f "$cache_file" ]] || return 1
    sed -n "s#^${key}:[^=]*=##p" "$cache_file" | head -n 1
}

add_unique_candidate() {
    local dir="$1"

    [[ -n "$dir" ]] || return 0
    [[ -d "$dir" ]] || return 0

    case ":${sdk_candidates:-}:" in
        *":$dir:"*)
            return 0
            ;;
    esac

    if [[ -n "${sdk_candidates:-}" ]]; then
        sdk_candidates+=$'\n'
    fi

    sdk_candidates+="$dir"
}

find_zephyr_sdk_root() {
    local cache_file="${active_project:-}/build/CMakeCache.txt"
    local candidate
    local sdk_root

    sdk_candidates=""

    add_unique_candidate "$(trim_trailing_slash "${ZEPHYR_SDK_INSTALL_DIR:-}")"
    add_unique_candidate "$(trim_trailing_slash "$(read_cache_value "$cache_file" "ZEPHYR_SDK_INSTALL_DIR" 2>/dev/null || true)")"
    add_unique_candidate "/opt/toolchains/zephyr-sdk"

    while IFS= read -r candidate; do
        add_unique_candidate "$(trim_trailing_slash "$candidate")"
    done < <(find /opt/toolchains /root -maxdepth 1 -type d -name 'zephyr-sdk*' 2>/dev/null | sort -V -r)

    while IFS= read -r sdk_root; do
        [[ -n "$sdk_root" ]] || continue
        if [[ -d "$sdk_root" ]]; then
            printf '%s\n' "$sdk_root"
            return 0
        fi
    done <<< "$sdk_candidates"

    return 1
}

find_tool_path() {
    local tool_name="$1"
    local cache_key="$2"
    local cache_file="${active_project:-}/build/CMakeCache.txt"
    local cached_path
    local sdk_root
    local candidate

    cached_path="$(read_cache_value "$cache_file" "$cache_key" 2>/dev/null || true)"
    if [[ -n "$cached_path" && -x "$cached_path" ]]; then
        printf '%s\n' "$cached_path"
        return 0
    fi

    if sdk_root="$(find_zephyr_sdk_root)"; then
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            if [[ -x "$candidate" ]]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done < <(find "$sdk_root" -path "*/bin/$tool_name" -type f 2>/dev/null | sort)
    fi

    if candidate="$(command -v "$tool_name" 2>/dev/null)" && [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    return 1
}

refresh_tool_links() {
    local gdb_path
    local gcc_path
    local openocd_path

    mkdir -p "$tool_dir"

    if gdb_path="$(find_tool_path xtensa-espressif_esp32s3_zephyr-elf-gdb CMAKE_GDB)"; then
        ln -sfn "$gdb_path" "$gdb_link"
    else
        rm -f "$gdb_link"
    fi

    if gcc_path="$(find_tool_path xtensa-espressif_esp32s3_zephyr-elf-gcc CMAKE_C_COMPILER)"; then
        ln -sfn "$gcc_path" "$gcc_link"
    else
        rm -f "$gcc_link"
    fi

    if openocd_path="$(find_tool_path openocd OPENOCD)"; then
        ln -sfn "$openocd_path" "$openocd_link"
    else
        rm -f "$openocd_link"
    fi
}

ensure_toolchain_env() {
    local sdk_root

    if sdk_root="$(find_zephyr_sdk_root)"; then
        export ZEPHYR_TOOLCHAIN_VARIANT="${ZEPHYR_TOOLCHAIN_VARIANT:-zephyr}"
        export ZEPHYR_SDK_INSTALL_DIR="$sdk_root"
    fi
}

build_cache_uses_missing_toolchain() {
    local cache_file="$1/build/CMakeCache.txt"
    local cached_compiler
    local cached_sdk

    [[ -f "$cache_file" ]] || return 1

    cached_compiler="$(read_cache_value "$cache_file" "CMAKE_C_COMPILER" 2>/dev/null || true)"
    if [[ -n "$cached_compiler" && ! -x "$cached_compiler" ]]; then
        return 0
    fi

    cached_sdk="$(trim_trailing_slash "$(read_cache_value "$cache_file" "ZEPHYR_SDK_INSTALL_DIR" 2>/dev/null || true)")"
    if [[ -n "$cached_sdk" && ! -d "$cached_sdk" ]]; then
        return 0
    fi

    return 1
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

    refresh_tool_links
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
        app_dir="$(select_project_path)"
    fi

    app_dir="$(trim_trailing_slash "$app_dir")"

    if [[ ! -d "$app_dir" ]]; then
        echo "Project directory not found: $app_dir" >&2
        exit 1
    fi

    printf '%s\n' "$(state_path_for_project "$app_dir")" > "$state_file"
    active_project="$app_dir"
    ensure_toolchain_env
    refresh_tool_links
    refresh_links "$app_dir"
    echo "Active Zephyr project: $app_dir"

    if [[ ! -f "$app_dir/build/compile_commands.json" ]]; then
        echo "Build this project once to generate compile_commands.json for IntelliSense."
    fi
}

cmd_build() {
    require_active_project

    local board="${BOARD:-}"
    local pristine_mode="auto"
    local -a west_args=("build" "-p")
    local -a cmake_args=("-DCMAKE_BUILD_TYPE=Debug")

    ensure_toolchain_env

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

    if build_cache_uses_missing_toolchain "$active_project"; then
        pristine_mode="always"
        echo "Detected stale toolchain paths in the build cache. Re-configuring from a pristine build directory."
    fi

    west_args+=("$pristine_mode")
    west_args+=("-b" "$board")

    if [[ -f "$active_project/debug.conf" ]]; then
        cmake_args+=("-DEXTRA_CONF_FILE=debug.conf")
    fi

    west_args+=("--")
    west_args+=("${cmake_args[@]}")

    echo "Building $active_project for board: $board"
    apply_patches
    west "${west_args[@]}"
    refresh_tool_links
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

cmd_openocd() {
    require_active_project

    local openocd_bin
    openocd_bin="${openocd_link}"

    if [[ ! -x "$openocd_bin" ]]; then
        echo "OpenOCD executable not found. Checked: $openocd_bin" >&2
        exit 1
    fi

    exec "$openocd_bin" \
        -f "$workspace_root/boards/esp32s3-zephyr.cfg" \
        -c "init; reset halt; esp appimage_offset 0x0"
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
    openocd)
        cmd_openocd
        ;;
    *)
        usage
        exit 1
        ;;
esac