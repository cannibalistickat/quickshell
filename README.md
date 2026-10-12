# Quickshell shell rewrite

Greenfield rewrite of the supplied shell snapshot, with the user-facing wallpaper/flashlight, screen corners, volume OSD, and brightness OSD preserved.

## One-command build + install

On Arch, the installer automatically checks for the required compiler/build/Qt packages and installs missing build dependencies. It then detects the running Hyprland version/commit/ABI, finds matching installed Hyprland headers through `pkg-config`, falls back to a matching local checkout when present, and uses `hyprpm` to refresh headers only when no matching header set is available.

```bash
./install.sh
```

No `HYPRLAND_SOURCE_DIR` or `HYPRLAND_BUILD_DIR` variables are required for a normal Arch/Hyprland installation.

Useful switches:

```bash
./install.sh --no-deps
./install.sh --no-hyprland
./install.sh --no-start
./install.sh --no-reload
```

The installer:

1. detects Qt, qsb, Quickshell and the active Hyprland commit/ABI;
2. builds the C++ backend, Hyprland cursor plugin and optimized QSB;
3. backs up an existing `~/.config/quickshell` tree;
4. installs only runtime files into `~/.config/quickshell`;
5. installs a managed Hyprland startup entry for `cursor-feed.so`;
6. adds a Quickshell startup entry only when no existing Quickshell startup is detected;
7. loads the new cursor plugin into the running Hyprland when possible.

Run the environment/architecture checks with:

```bash
./tools/doctor.sh
```

## Build architecture

The cursor path is event-driven and latest-state-wins:

```text
Hyprland mouse event
    -> fixed native x/y + serial + dirty
    -> compositor frame boundary
    -> nonblocking 16-byte AF_UNIX SOCK_SEQPACKET
    -> Quickshell native socket notifier
    -> canonical CursorState
    -> one precise positionChanged()
```

The backlight path is a filtered uevent stream plus direct sysfs I/O. QML remains presentation/interaction code rather than system polling.

## Version compatibility

The plugin embeds the Hyprland API version from the headers it was compiled against and checks Hyprland's runtime/client API hash before registering. The installer also compares the running commit against discovered source/header metadata before choosing the build input.

Hyprland's current plugin guidance recommends API/EventBus entry points, prefers event hooks over function hooks, and requires a version/header compatibility check.

## Rendering/build notes

The flashlight remains one ShaderEffect pass. The shader build uses qsb's SPIR-V optimization pass (`-O`). QML source remains normal Quickshell configuration rather than being converted into a standalone Qt application, so the build does not invent an unrelated application-level `qt_add_qml_module` wrapper merely to claim compiler optimization.

The supplied performance doctrine calls for release builds, QML compiler/cache support, shader precompilation, linting, and version verification; the atlas specifically recommends `qsb -O` and checking installed Qt/Hyprland versions before applying version-sensitive parameters.

## Runtime target

The shell is designed around a 120 Hz output, low idle wakeups, bounded state, event-driven system integration, and the smallest practical update/render path. The guiding rule is still to remove work before optimizing the work that remains.
