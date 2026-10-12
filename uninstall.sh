#!/usr/bin/env bash
set -euo pipefail
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
TARGET_DIR=${TARGET_DIR:-$CONFIG_HOME/quickshell}

if [[ -d "$TARGET_DIR" ]]; then
    stamp=$(date +%Y%m%d-%H%M%S)
    mv "$TARGET_DIR" "$TARGET_DIR.uninstalled-$stamp"
    echo "Moved $TARGET_DIR to $TARGET_DIR.uninstalled-$stamp"
else
    echo "No installed shell found at $TARGET_DIR"
fi

echo "The managed Hyprland startup block is intentionally left in place so user configuration can be restored/reviewed manually."
