#!/usr/bin/env bash
#
# maintenance/plugin.sh — rebuild the Quickshell cursor-feed Hyprland plugin
# against whatever Hyprland is CURRENTLY installed/running.
#
# Why this exists:
#   The plugin performs a runtime "API hash" check against the compositor. That
#   hash embeds Hyprland's git commit + sub-library versions from the headers it
#   was compiled against. After a Hyprland update the running compositor's hash
#   changes, so the old prebuilt cursor-feed.so is rejected and the cursor feed
#   stops working. This script recompiles the (bundled, self-contained) plugin
#   sources against headers whose GIT_COMMIT_HASH matches the running build.
#
# What it does:
#   1. Reads the running compositor's ABI git hash (hyprland --version).
#   2. Finds matching Hyprland headers (system pkg-config, else ~/hyprland,
#      else `hyprpm update` and retry).
#   3. Compiles maintenance/src/{cursor-feed,protocol} into cursor-feed.so.
#   4. Verifies the built .so embeds the running hash (refuses to install if not).
#   5. Backs up and installs into <config>/native/cursor-feed.so.
#   6. Tries to hot-load into the running Hyprland; if the session is polluted it
#      tells you to reboot (see note at the bottom).
#
# Usage:
#   ./plugin.sh            build + install + attempt hot-load
#   ./plugin.sh --no-load  build + install only (activate on next reboot)
#   ./plugin.sh --status   just print detected versions, build nothing
#
set -euo pipefail

# ---- paths (resolved relative to this script, so cwd does not matter) --------
SELF="$(readlink -f "$0")"
M_DIR="$(cd "$(dirname "$SELF")" && pwd)"          # .../quickshell/maintenance
CFG_DIR="$(cd "$M_DIR/.." && pwd)"                 # .../quickshell
SRC_DIR="$M_DIR/src"
OUT_DIR="$M_DIR/build"
BUILT_SO="$OUT_DIR/cursor-feed.so"
TARGET_SO="$CFG_DIR/native/cursor-feed.so"

DO_LOAD=1
MODE=build

for a in "$@"; do
    case "$a" in
        --no-load) DO_LOAD=0 ;;
        --status)  MODE=status ;;
        -h|--help) grep '^#' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
    esac
done

say()  { printf '\033[1;34m[plugin]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[plugin]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[plugin]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- 1. running compositor ABI hash -----------------------------------------
command -v hyprland >/dev/null 2>&1 || die "hyprland not found in PATH"

ABI="$(hyprland --version 2>/dev/null | sed -n 's/^Version ABI string: //p' | head -1)"
RUN_HASH="${ABI%%_*}"
if ! printf '%s' "$RUN_HASH" | grep -Eq '^[0-9a-f]{40}$'; then
    # fallback: pull the 40-hex commit out of the human-readable banner
    RUN_HASH="$(hyprland --version 2>/dev/null | sed -n 's/.*at commit \([0-9a-f]\{40\}\).*/\1/p' | head -1)"
fi
[ -n "$RUN_HASH" ] || die "could not determine running Hyprland commit hash"
say "running Hyprland ABI commit: $RUN_HASH"

# ---- 2. locate matching Hyprland headers ------------------------------------
# reads GIT_COMMIT_HASH from a version.h
hash_of() { sed -n 's/.*GIT_COMMIT_HASH[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$1" 2>/dev/null | head -1; }

# returns "cflags" for a header set on stdout if it matches RUN_HASH, else empty
match_pkgconfig() {
    pkg-config --exists hyprland 2>/dev/null || return 0
    local src_inc cflags
    src_inc="$(pkg-config --cflags-only-I hyprland 2>/dev/null | tr ' ' '\n' | sed -n 's/^-I\(.*\/src\)$/\1/p' | head -1)"
    [ -n "$src_inc" ] && [ -f "$src_inc/version.h" ] || return 0
    [ "$(hash_of "$src_inc/version.h")" = "$RUN_HASH" ] || return 0
    cflags="$(pkg-config --cflags hyprland 2>/dev/null || true)"
    printf '%s' "$cflags"
}

match_checkout() {
    local root="${1%/}"
    [ -f "$root/src/version.h" ] || return 0
    [ "$(hash_of "$root/src/version.h")" = "$RUN_HASH" ] || return 0
    local deps
    deps="$(pkg-config --cflags libdrm pixman-1 wayland-server xkbcommon libinput gbm cairo pango pangocairo gio-2.0 lcms2 2>/dev/null || true)"
    printf -- '-isystem %s/src -isystem %s %s' "$root" "$root" "$deps"
}

HYPR_CFLAGS=""
HYPR_SRC=""

try_resolve() {
    HYPR_CFLAGS="$(match_pkgconfig || true)"
    [ -n "$HYPR_CFLAGS" ] && { HYPR_SRC="system pkg-config headers"; return 0; }
    HYPR_CFLAGS="$(match_checkout "$HOME/hyprland" || true)"
    [ -n "$HYPR_CFLAGS" ] && { HYPR_SRC="$HOME/hyprland checkout"; return 0; }
    return 1
}

if ! try_resolve; then
    if [ "$MODE" = status ]; then
        warn "no header set matches the running commit yet (a build would run 'hyprpm update')"
    else
        say "no matching headers found; asking hyprpm to sync them to the running build..."
        command -v hyprpm >/dev/null 2>&1 && hyprpm update || true
        try_resolve || die "still no Hyprland headers match commit $RUN_HASH. Install matching headers (e.g. the hyprland dev package for your running version, or 'hyprpm update') and re-run."
    fi
fi

[ -n "$HYPR_CFLAGS" ] || die "no usable Hyprland headers resolved"
say "using headers: $HYPR_SRC"

if [ "$MODE" = status ]; then
    say "status: headers OK, ready to build. (nothing built)"
    exit 0
fi

# ---- 3. compile -------------------------------------------------------------
command -v c++ >/dev/null 2>&1 || die "no C++ compiler (c++) in PATH"
[ -f "$SRC_DIR/cursor-feed/plugin.cpp" ] || die "bundled sources missing under $SRC_DIR"

mkdir -p "$OUT_DIR"
CXXF=(-D_GNU_SOURCE -DNDEBUG -std=c++23 -fPIC -O2 -fno-semantic-interposition -DHYPRLAND_PLUGIN)
# shellcheck disable=SC2206
HF=($HYPR_CFLAGS)
say "compiling plugin.cpp + transport.cpp ..."
c++ "${CXXF[@]}" "${HF[@]}" -I"$SRC_DIR" -c "$SRC_DIR/cursor-feed/plugin.cpp"    -o "$OUT_DIR/plugin.o"
c++ "${CXXF[@]}" "${HF[@]}" -I"$SRC_DIR" -c "$SRC_DIR/cursor-feed/transport.cpp" -o "$OUT_DIR/transport.o"
c++ -shared -Wl,-O1,--as-needed,-z,relro,-z,now "$OUT_DIR/plugin.o" "$OUT_DIR/transport.o" -o "$BUILT_SO"
say "built $BUILT_SO"

# ---- 4. verify embedded hash matches running --------------------------------
BUILT_HASH="$(strings "$BUILT_SO" | grep -oE '[0-9a-f]{40}' | head -1)"
[ "$BUILT_HASH" = "$RUN_HASH" ] || die "built .so embeds $BUILT_HASH but compositor is $RUN_HASH — header mismatch, refusing to install"
say "verified: built .so ABI commit matches running compositor ($BUILT_HASH)"

# ---- 5. back up + install ---------------------------------------------------
if [ -f "$TARGET_SO" ]; then
    cp -a "$TARGET_SO" "$TARGET_SO.bak-$(date +%Y%m%d-%H%M%S)"
    # keep only the newest backup to avoid clutter
    ls -1t "$TARGET_SO".bak-* 2>/dev/null | tail -n +2 | xargs -r rm -f
fi
install -m755 "$BUILT_SO" "$TARGET_SO"
say "installed -> $TARGET_SO"

# ---- 6. activate ------------------------------------------------------------
if [ "$DO_LOAD" = 0 ]; then
    say "--no-load set: reboot (or 'hyprctl plugin load $TARGET_SO') to activate."
    exit 0
fi

if ! command -v hyprctl >/dev/null 2>&1 || ! hyprctl keepalive >/dev/null 2>&1; then
    say "Hyprland not reachable via hyprctl — it will load on next reboot."
    exit 0
fi

hyprctl plugin unload "$TARGET_SO" >/dev/null 2>&1 || true
if hyprctl plugin load "$TARGET_SO" >/dev/null 2>&1 && hyprctl plugins list 2>/dev/null | grep -q 'quickshell-cursor-feed'; then
    say "hot-loaded successfully — cursor feed is live now."
else
    warn "built and installed correctly, but could NOT hot-load into this running session."
    warn "This is a known quirk: a previously failed plugin load can leak the old"
    warn "version's symbol into the compositor's global scope for the whole session,"
    warn "so a freshly built plugin is rejected until the compositor restarts."
    say "Just REBOOT (or restart Hyprland) — the new plugin will load at startup."
fi
