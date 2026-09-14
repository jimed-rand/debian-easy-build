# Debian CLI Installer

A TTY-friendly, Calamares-equivalent installer for the Debian Easy Build
live ISO. It walks the user through the same stages as
Calamares (welcome -> locale -> keyboard -> partition -> users -> summary
-> mount -> unpackfs -> machineid -> fstab -> locale -> keyboard -> users
-> displaymanager -> networkcfg -> hwclock -> initramfs -> grubcfg ->
bootloader -> packages -> umount -> finished) but entirely from a shell.

## Why

* Boots a desktop ISO into a TTY (or a CLI-only ISO) and installs the system
  from the live environment, useful on machines without a working display
  server or for scripted headless installs.
* The Calamares-based ISO works on desktops; this script is a companion
  path for the same ISO that runs entirely from a shell.

## Usage

The script is a single self-contained bash file (install-system). To use it
on the live system, make it executable first, copy it into the system (such
as /usr/local/bin/), and run it:

```bash
chmod +x install-system
sudo install -m 0755 install-system /usr/local/bin/
sudo install-system
```

If you are testing the script and only need it temporarily:

```bash
chmod +x install-system
sudo ./install-system
```

The script is strictly interactive by design; every step prompts the user
on the TTY.

### UI Mode

At the welcome screen the user is asked which interface to use:

1. TUI (whiptail/dialog boxes) - recommended, falls back to plain text
   if neither whiptail nor dialog is installed.
2. Plain text prompts - pure read-based, works in any TTY, zero extra
   dependencies.

### What It Covers

- Locale: UTF-8 locale selection
- Timezone: Manual timezone selection without GeoIP dependency
- Disk partitioning: GPT, 512 MiB ESP, 4 GiB swap, root fills remaining space
- User configuration: sudo group, /bin/bash, password minimum length
- Bootloader: GRUB UEFI and BIOS bootloader configuration with debian ID
- Package cleanup: removal of live tooling (calamares, casper, caper)

### Files

- install-system - the installer (one self-contained bash script).
- README.md - this file.
