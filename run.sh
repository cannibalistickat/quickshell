#!/usr/bin/env bash
set -euo pipefail
ROOT="/home/alice/.config/quickshell"
PLUGIN="$ROOT/native/cursor-feed.so"
if ! hyprctl plugin list 2>/dev/null | grep -q 'quickshell-cursor-feed'; then
    hyprctl plugin load "$PLUGIN" >/dev/null
fi
export QSG_RHI_BACKEND=vulkan
export INTEL_XE_IGNORE_EXPERIMENTAL_WARNING=1
export QT_LOGGING_RULES="default.warning=false"

# Quickshell's shell/path id is the MD5 of the canonical shell path. Remove
# only a stale by-path link whose corresponding by-shell directory is gone.
QS_DATA_BASE="${XDG_DATA_HOME:-$HOME/.local/share}/quickshell"
QS_SHELL_ID="$(printf '%s' "$ROOT/shell.qml" | md5sum | cut -d' ' -f1)"
QS_PATH_LINK="${QS_DATA_BASE}/by-path/${QS_SHELL_ID}"
QS_SHELL_DIR="${QS_DATA_BASE}/by-shell/${QS_SHELL_ID}"
if [[ -L "$QS_PATH_LINK" && ! -e "$QS_SHELL_DIR" ]]; then
    rm -f -- "$QS_PATH_LINK"
fi

if [[ "${DEBUG_GREENFIELD:-0}" == 1 ]]; then
    exec qs -p "$ROOT/shell.qml"
else
    exec qs -p "$ROOT/shell.qml" >/dev/null 2>&1
fi
