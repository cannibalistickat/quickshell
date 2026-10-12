#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
TARGET_DIR=${TARGET_DIR:-$CONFIG_HOME/quickshell}
BACKUP_ROOT=${BACKUP_ROOT:-$HOME/.local/state/quickshell-rewrite/backups}
BUILD_DIR=${BUILD_DIR:-"$ROOT_DIR/build"}

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

AUTO_DEPS=1
AUTO_HYPRLAND=1
AUTO_START=1
RELOAD=1

usage() {
    cat <<USAGE
Usage: ./install.sh [options]

Builds, installs and (when possible) activates the Quickshell rewrite.
Everything is auto-detected; explicit Hyprland/Qt paths are optional overrides.

Options:
  --no-deps          Do not install missing Arch build dependencies.
  --no-hyprland      Do not modify Hyprland startup configuration or load plugin.
  --no-start         Do not add a Quickshell startup entry when none exists.
  --no-reload        Do not restart/reload the currently running shell.
  --target DIR       Install runtime files to DIR instead of ~/.config/quickshell.
  -h, --help         Show this help.
USAGE
}

while (($#)); do
    case "$1" in
        --no-deps) AUTO_DEPS=0 ;;
        --no-hyprland) AUTO_HYPRLAND=0 ;;
        --no-start) AUTO_START=0 ;;
        --no-reload) RELOAD=0 ;;
        --target)
            [[ $# -ge 2 ]] || fail "--target requires a directory"
            TARGET_DIR=$2
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
    shift
done

[[ $EUID -ne 0 ]] || fail "Run this installer as your normal user, not root."

install_arch_deps() {
    command -v pacman >/dev/null 2>&1 || return 0
    [[ "$AUTO_DEPS" == 1 ]] || return 0

    local missing=()
    command -v cmake >/dev/null 2>&1 || missing+=(cmake)
    command -v ninja >/dev/null 2>&1 || missing+=(ninja)
    command -v pkg-config >/dev/null 2>&1 || missing+=(pkgconf)
    command -v c++ >/dev/null 2>&1 || missing+=(base-devel)
    pkg-config --exists libudev 2>/dev/null || missing+=(systemd-libs)
    if ! command -v qsb >/dev/null 2>&1; then
        local qsb_found=0
        for qbin in /usr/lib/qt6/bin/qsb /usr/lib/qt/bin/qsb; do
            [[ -x "$qbin" ]] && qsb_found=1 && break
        done
        (( qsb_found )) || missing+=(qt6-shadertools)
    fi

    if ((${#missing[@]})); then
        local unique=()
        local item seen
        for item in "${missing[@]}"; do
            seen=0
            for existing in "${unique[@]:-}"; do
                [[ "$existing" == "$item" ]] && seen=1 && break
            done
            (( seen )) || unique+=("$item")
        done
        say "Installing missing Arch build dependencies: ${unique[*]}"
        sudo pacman -S --needed "${unique[@]}"
    fi
}

install_arch_deps

command -v cmake >/dev/null 2>&1 || fail "cmake is missing"
command -v ninja >/dev/null 2>&1 || fail "ninja is missing"
command -v pkg-config >/dev/null 2>&1 || fail "pkg-config is missing"
command -v c++ >/dev/null 2>&1 || fail "a C++ compiler is missing"

if ! command -v qs >/dev/null 2>&1 && ! command -v quickshell >/dev/null 2>&1; then
    warn "Quickshell executable not found. On Arch, install the quickshell package (or quickshell-git) first."
    fail "Cannot continue without Quickshell."
fi

run_detect() {
    local hint=${HYPRLAND_SOURCE_DIR:-}
    eval "$(HYPRLAND_SOURCE_DIR_HINT=$(printf '%q' "$hint") bash "$ROOT_DIR/tools/detect_environment.sh")"
}

run_detect

if [[ -z "$HYPRLAND_COMMIT" && "$AUTO_HYPRLAND" == 1 ]]; then
    warn "No running/installed Hyprland version was detected. The cursor plugin cannot be safely built."
    fail "Start Hyprland before installing cursor-feed, or set HYPRLAND_SOURCE_DIR to a matching checkout."
fi

# If the distro-installed headers are stale/missing, use Hyprland's own plugin
# header manager. This is deliberately only a recovery path; normal installs use
# already-installed matching package headers or a matching local checkout.
if [[ "$AUTO_HYPRLAND" == 1 && -n "$HYPRLAND_COMMIT" && -z "$HYPRLAND_SOURCE_DIR" && -z "$HYPRLAND_INCLUDE_ROOT" ]]; then
    if command -v hyprpm >/dev/null 2>&1; then
        say "No matching Hyprland headers found; asking hyprpm to refresh its header set for the running compositor."
        hyprpm update || true
        run_detect
    fi
fi

if [[ -z "$HYPRLAND_SOURCE_DIR" && -z "$HYPRLAND_INCLUDE_ROOT" ]]; then
    fail "No matching Hyprland headers were found for commit $HYPRLAND_COMMIT. Install/update matching Hyprland headers (hyprpm can do this automatically) and rerun."
fi

say "Detected:"
say "  Hyprland : ${HYPRLAND_VERSION:-unknown} ${HYPRLAND_TAG:+($HYPRLAND_TAG)}"
say "  Commit   : ${HYPRLAND_COMMIT:-unknown}"
say "  ABI      : ${HYPRLAND_ABI:-unknown}"
say "  Qt       : ${QT_VERSION:-auto-detected by CMake}"
say "  qsb      : ${QSB_BIN:-auto-detected by CMake}"
say "  Quickshell: ${QUICKSHELL_BIN:-unknown}"
say "  Headers  : ${HYPRLAND_SOURCE_DIR:-$HYPRLAND_INCLUDE_ROOT}"
say "  Target   : $TARGET_DIR"

export HYPRLAND_SOURCE_DIR HYPRLAND_INCLUDE_ROOT HYPRLAND_BUILD_DIR QT_HOST_BINS

bash "$ROOT_DIR/tools_build.sh"

[[ -f "$ROOT_DIR/Shell/Backend/libshellbackend.so" ]] || fail "shell backend build did not produce its library"
[[ -f "$ROOT_DIR/native/cursor-feed.so" ]] || fail "cursor plugin build did not produce its library"
[[ -f "$ROOT_DIR/ui/shaders/flashlight.frag.qsb" ]] || fail "shader build did not produce QSB"

# Stage only runtime files. Build products/CMake metadata stay outside the user's
# active Quickshell tree.
STAGE=$(mktemp -d)
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
mkdir -p "$STAGE/Shell/Backend" "$STAGE/backend" "$STAGE/native" "$STAGE/protocol" "$STAGE/services" "$STAGE/ui/shaders"

cp -a "$ROOT_DIR/Shell/Backend/qmldir" "$STAGE/Shell/Backend/"
cp -a "$ROOT_DIR/Shell/Backend/libshellbackend.so" "$STAGE/Shell/Backend/"
cp -a "$ROOT_DIR/backend"/*.h "$ROOT_DIR/backend"/*.cpp "$STAGE/backend/"
cp -a "$ROOT_DIR/native/cursor-feed.so" "$STAGE/native/"
cp -a "$ROOT_DIR/protocol"/*.h "$STAGE/protocol/"
cp -a "$ROOT_DIR/services"/*.qml "$STAGE/services/"
cp -a "$ROOT_DIR/shell.qml" "$STAGE/"
cp -a "$ROOT_DIR/ui"/*.qml "$STAGE/ui/"
cp -a "$ROOT_DIR/ui/shaders/flashlight.frag.qsb" "$STAGE/ui/shaders/"

if [[ -d "$TARGET_DIR" ]]; then
    mkdir -p "$BACKUP_ROOT"
    stamp=$(date +%Y%m%d-%H%M%S)
    backup="$BACKUP_ROOT/quickshell-$stamp"
    cp -a "$TARGET_DIR" "$backup"
    say "Backed up existing shell to $backup"
fi

mkdir -p "$(dirname "$TARGET_DIR")"
rm -rf "$TARGET_DIR"
cp -a "$STAGE/." "$TARGET_DIR/"
chmod 755 "$TARGET_DIR/Shell/Backend/libshellbackend.so" "$TARGET_DIR/native/cursor-feed.so"

say "Installed runtime tree to $TARGET_DIR"

add_hyprland_startup_conf() {
    local conf="$1"
    [[ -f "$conf" ]] || return 0
    local marker_begin='# >>> quickshell-rewrite managed cursor-feed >>>'
    local marker_end='# <<< quickshell-rewrite managed cursor-feed <<<'
    if grep -Fq "$marker_begin" "$conf"; then
        return 0
    fi
    cp -a "$conf" "$conf.quickshell-rewrite.bak-$(date +%Y%m%d-%H%M%S)"
    cat >> "$conf" <<CFG

$marker_begin
exec-once = hyprctl plugin load $TARGET_DIR/native/cursor-feed.so
$marker_end
CFG
}

add_hyprland_startup_lua() {
    local lua="$1"
    [[ -f "$lua" ]] || return 0
    local marker_begin='-- >>> quickshell-rewrite managed startup >>>'
    local marker_end='-- <<< quickshell-rewrite managed startup <<<'
    if grep -Fq "$marker_begin" "$lua"; then
        return 0
    fi
    cp -a "$lua" "$lua.quickshell-rewrite.bak-$(date +%Y%m%d-%H%M%S)"
    cat >> "$lua" <<LUA

$marker_begin
hl.on("hyprland.start", function()
    hl.exec_cmd("hyprctl plugin load $TARGET_DIR/native/cursor-feed.so")
end)
$marker_end
LUA
}

ensure_quickshell_startup() {
    [[ "$AUTO_START" == 1 ]] || return 0
    local conf="$CONFIG_HOME/hypr/hyprland.conf"
    local lua="$CONFIG_HOME/hypr/hyprland.lua"
    local found=0
    if [[ -d "$CONFIG_HOME/hypr" ]]; then
        if grep -RqsE '(^|[^[:alnum:]_-])(qs|quickshell)([[:space:]]|$)' "$CONFIG_HOME/hypr" --include='*.conf' --include='*.lua' 2>/dev/null; then
            found=1
        fi
    fi
    (( found )) && return 0

    if [[ -f "$lua" ]]; then
        local marker_begin='-- >>> quickshell-rewrite managed startup >>>'
        if ! grep -Fq "$marker_begin" "$lua"; then
            cp -a "$lua" "$lua.quickshell-rewrite.bak-$(date +%Y%m%d-%H%M%S)"
            cat >> "$lua" <<LUA

$marker_begin
hl.on("hyprland.start", function()
    hl.exec_cmd("${QUICKSHELL_BIN:-qs}")
end)
-- <<< quickshell-rewrite managed startup <<<
LUA
        fi
    elif [[ -f "$conf" ]]; then
        local marker_begin='# >>> quickshell-rewrite managed startup >>>'
        if ! grep -Fq "$marker_begin" "$conf"; then
            cp -a "$conf" "$conf.quickshell-rewrite.bak-$(date +%Y%m%d-%H%M%S)"
            cat >> "$conf" <<CFG

$marker_begin
exec-once = ${QUICKSHELL_BIN:-qs}
# <<< quickshell-rewrite managed startup <<<
CFG
        fi
    fi
}

if [[ "$AUTO_HYPRLAND" == 1 ]]; then
    if [[ -f "$CONFIG_HOME/hypr/hyprland.lua" ]]; then
        add_hyprland_startup_lua "$CONFIG_HOME/hypr/hyprland.lua"
    elif [[ -f "$CONFIG_HOME/hypr/hyprland.conf" ]]; then
        add_hyprland_startup_conf "$CONFIG_HOME/hypr/hyprland.conf"
    fi
    ensure_quickshell_startup
fi

# Activate the freshly built plugin in the current compositor. This is a cold-path
# command and is intentionally outside the high-frequency cursor architecture.
if [[ "$AUTO_HYPRLAND" == 1 && -n "${HYPRLAND_COMMIT:-}" && -n "${HYPRLAND_BIN:-}" ]]; then
    : # reserved for explicit binary-path detection
fi

if [[ "$AUTO_HYPRLAND" == 1 && -n "${HYPRLAND_COMMIT:-}" && $(command -v hyprctl >/dev/null 2>&1; echo $?) -eq 0 ]]; then
    hyprctl plugin unload "$TARGET_DIR/native/cursor-feed.so" >/dev/null 2>&1 || true
    if hyprctl plugin load "$TARGET_DIR/native/cursor-feed.so"; then
        say "cursor-feed.so loaded into the running Hyprland instance."
    else
        warn "The plugin could not be loaded into the current session. It is still installed for the next Hyprland start."
    fi
fi

if [[ "$RELOAD" == 1 ]]; then
    # Replacing the native QML plugin library on disk does not replace the library
    # already mapped into an existing Quickshell process. Restart an identifiable
    # instance for this config; otherwise leave unrelated shell instances alone.
    restarted=0
    if [[ -d /proc ]]; then
        while IFS= read -r pid; do
            [[ -r "/proc/$pid/cmdline" ]] || continue
            cmdline=$(tr '\\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
            [[ "$cmdline" == *"$TARGET_DIR"* ]] || continue
            kill -TERM "$pid" 2>/dev/null || true
            restarted=1
        done < <(pgrep -x qs 2>/dev/null || true)
        while IFS= read -r pid; do
            [[ -r "/proc/$pid/cmdline" ]] || continue
            cmdline=$(tr '\\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
            [[ "$cmdline" == *"$TARGET_DIR"* ]] || continue
            kill -TERM "$pid" 2>/dev/null || true
            restarted=1
        done < <(pgrep -x quickshell 2>/dev/null || true)
    fi
    if command -v qs >/dev/null 2>&1; then
        nohup qs >/dev/null 2>&1 &
        say "Started Quickshell from the installed config."
    elif command -v quickshell >/dev/null 2>&1; then
        nohup quickshell >/dev/null 2>&1 &
        say "Started Quickshell from the installed config."
    fi
    (( restarted )) && say "Restarted the Quickshell instance using the installed native backend."
fi

say "Install complete."
say "Run ./tools/doctor.sh any time to inspect detected Qt/Quickshell/Hyprland state."
