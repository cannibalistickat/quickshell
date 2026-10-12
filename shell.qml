//@ pragma Env QSG_RHI_BACKEND = vulkan
//@ pragma Env QT_LOGGING_RULES = default.warning=false
//@ pragma Env INTEL_XE_IGNORE_EXPERIMENTAL_WARNING = 1
//@ pragma DefaultEnv QS_DISABLE_FILE_WATCHER=1

pragma ComponentBehavior: Bound

import Quickshell
import qs.Shell.Backend
import "ui"

ShellRoot {
    Wallpaper {}
    ScreenCorners {}
    VolumeOsd { suppressed: lockScr.locked }
    BrightnessOsd { suppressed: lockScr.locked }
    LockScreen { id: lockScr }
}
