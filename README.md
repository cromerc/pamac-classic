# Pamac-classic

A graphical package manager for pacman

# Features:

- Alpm bindings for Vala
- A DBus daemon to perform every tasks with root access using polkit to check authorizations
- A Gtk3 Package Manager
- A Gtk3 Updates Manager
- A Tray icon with configurable periodic refresh and updates notifications
- Complete AUR support:
	* Multiple words search capability
	* Enable/Disable check updates from AUR
	* Build and update AUR packages

# How to build

## Requirements

- GTK+: 3.0
- GIO: 2.0
- GLib: 2.38
- GObject: 2.0
- Json-Glib: 1.0
- libalpm
- libcurl
- LibSoup: 2.4
- polkit-gobject-1
- libnotify
- vte: 2.91
- appindicator-gtk3 (optional to build KDE tray icon)
- CMake
- Vala: 0.38
- AutoVala: 1.2.0 (optional to regenerate CMake and Meson files)

## Using Meson with Ninja

```
mkdir build
cd build
meson \
    --prefix=/usr \
    --sysconfdir=/etc
ninja
ninja install
```
### Extra build flags

- -DDISABLE_AUR=ON (to disable AUR in Pamac)
- -DKDE_TRAY=ON (to build kde tray icon instead of gtk tray icon)
- -DENABLE_UPDATE_ICON=ON (to install the update desktop entry)
- -DICON_UPDATE=OFF (to disable updating the icon cache)
- -DENABLE_HAMBURGER=ON (to build with the classic hamburger menu)