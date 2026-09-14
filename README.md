# Debian Easy Build

Debian Easy Build is a live ISO and disk image generator for Debian GNU/Linux. It creates modern bootable live ISOs, cloud images, VM images, and removable-media disk images from Debian package repositories with a strict no-snap and no-fwupd policy (snapd and fwupd pinned with APT priority -1).

This project is designed for:
- Beginners who want a working Debian live system with straightforward interactive prompts and guided builders.
- Users who need deterministic output, chroot-level customization, modular stage execution, and configuration file automation.

---

## Key Features

- Debian Release Tracking: Builds standard Debian releases using dynamic suite names: stable (default), testing, and unstable (sid). For sid installs, release descriptors in /etc/os-release and /etc/debian_version are normalized during target installation.
- Caper Live Boot Subsystem: Uses Caper as a Debian-native live boot environment. Caper creates a default 'debian' live user with full sudo permissions and configures autologin across GDM3, LightDM, SDDM, and LXDM display managers without Ubuntu dependencies. Packaged deb packages are maintained in caper-deb/.
- Dual Installers: Every live ISO includes the Calamares graphical installer customized with Debian branding, alongside scripts/cli-installer/install-system for TTY and headless installations. Calamares uses a text-only presentation matching official Debian theming with an explicit notice that the ISO was created with an unofficial tool.
- Official Desktop Metapackages: Select from 13 standard Debian desktop environments mapped directly to Debian tasksel packages (XFCE default, KDE Plasma second default, GNOME, GNOME Flashback, Cinnamon, MATE, LXDE, LXQt, Lomiri, Lomiri Tablet, Phosh, Standard Desktop, or None/CLI).
- Server and System Roles: Optional pre-installation flags for Web Server (task-web-server), SSH Server (task-ssh-server), Cockpit Web Console (cockpit), and Laptop Support (task-laptop). SSH and Cockpit services are disabled by default for security.
- Deb-Multimedia Repository Support: Optional support for http://www.deb-multimedia.org/ via deb822 sources and signed keyring, with options to install necessary multimedia codecs (ffmpeg, libdvdcss2, gstreamer plugins) and tools (mpv).
- GRUB Boot Modes (Live and Installed): Live media uses the default label "Try Debian before installing" alongside dedicated CLI/TTY entries. Installed systems configure dual top-level boot entries: "Debian (desktop mode)" for standard graphical sessions and "Debian (CLI mode)" (systemd.unit=multi-user.target 3) for maintenance and terminal workflows.
- Hardware Firmware: Hardware enablement via standard Debian firmware packages (firmware-linux, firmware-misc-nonfree, firmware-iwlwifi, firmware-realtek, firmware-sof-signed) and standard kernel (linux-image-amd64).
- Mandatory Flatpak Support: Flatpak is installed out of the box with the corresponding graphical software store backend (gnome-software-plugin-flatpak or plasma-discover-backend-flatpak).
- Strict No-Snap and No-Fwupd Pinning: Blocks snapd and fwupd from installation via APT pinning preferences (/etc/apt/preferences.d/no-snapd.pref and /etc/apt/preferences.d/no-fwupd.pref).
- Multiple Output Formats:
  - Live ISO: Hybrid UEFI and BIOS bootable live installer image (scripts/build.sh).
  - Cloud Disk Image: Raw .img with cloud-init for cloud infrastructure (scripts/build-img.sh).
  - VM Disk Image: Raw .img with automated exports to QCOW2, VDI, VMDK, and VHDX via qemu-img (scripts/build-vm.sh).
  - Removable Media: Flashable raw .img with hybrid BIOS/UEFI boot for USB and SD cards (scripts/build-removable.sh).
- Guided Entrypoint: start-here.sh provides an interactive launcher for selecting the desired output format and options.
- Modloader Hooks: Custom shell scripts dropped into scripts/hooks/pre-chroot/ and scripts/hooks/chroot/ run automatically during the build.

---

## Output Types and Builders

The project provides four builder targets:

1. Live Installer ISO (scripts/build.sh)
   - Produces a bootable hybrid ISO image.
   - Includes Caper initramfs hooks and Calamares installer.
   - Default filename: debian-<release>-<desktop>-amd64-<timestamp>.iso.

2. Cloud Disk Image (scripts/build-img.sh)
   - Produces a raw disk image with cloud-init and cloud-guest-utils.
   - Supports UEFI-only or Hybrid BIOS/UEFI firmware.
   - Default filename: debian-<release>-<flavor>-cloud-amd64-<timestamp>.img.

3. VM Disk Image (scripts/build-vm.sh)
   - Produces a raw disk image plus exports to QCOW2 (QEMU/KVM, Proxmox), VDI (VirtualBox), VMDK (VMware), or VHDX (Hyper-V).
   - Can bake credentials in at build time or install a first-boot console setup wizard.
   - Default filename: debian-<release>-<flavor>-vm-amd64-<timestamp>.img.

4. Removable Media Image (scripts/build-removable.sh)
   - Produces a flashable raw disk image for USB drives, SD cards, and CF media.
   - Uses hybrid BIOS and UEFI boot by default for broad hardware bootability.
   - Default filename: debian-<release>-<flavor>-removable-amd64-<timestamp>.img.

---

## Supported Debian Releases

The builder targets dynamic suite names to track upstream Debian releases:

- stable: Default release. Uses stable, stable-updates, stable-security, and stable-backports.
- testing: Next Debian testing release. Uses testing, testing-security, and testing-updates.
- unstable: Debian sid rolling development release. The installer normalizes /etc/os-release and /etc/debian_version post-install so the installed system identifies clearly as Debian Sid.

All releases enable the main, contrib, non-free, and non-free-firmware archive components.

---

## Caper Live System Architecture

Ubuntu live media uses casper to discover and mount the live root filesystem. Upstream casper has Ubuntu-specific dependencies and telemetry.

This project integrates Caper, an adapted alternative designed for Debian live images:
- Provides drop-in compatibility for casper kernel command-line parameters (boot=casper and boot=caper).
- Sets default live username to debian with password debian and full sudo rights.
- Configures live autologin across GDM3 (/etc/gdm3/daemon.conf), LightDM ([Seat:*]), SDDM (session name without .desktop suffix), and LXDM.
- Disables automatic screen locking on live boot.
- Removes Ubuntu-specific telemetry and apport dependencies.
- Integrates Calamares desktop launcher directly on live boot.
- Supports squashfs search in both /casper and /caper paths.

### Package Compilation Strategy

Caper Debian packages (.deb) are stored in caper-deb/ in this repository:
1. Existing Packages: If a valid .deb exists in caper-deb/, the build script uses it directly.
2. Debian Host Compilation: If building on a Debian host with dpkg-dev tools, Caper is compiled on the host and copied to caper-deb/.
3. Non-Debian Host Compilation (such as Arch Linux): The build script copies Caper source into the debootstrap chroot, installs build dependencies inside the chroot, runs dpkg-buildpackage inside the chroot, exports the compiled .deb back to caper-deb/ on the host, and installs it into the image. The host environment remains completely free of foreign packages.

---

## Quick Start

### 1. Using the Guided Dispatcher

The simplest way to start is running the interactive launcher:

```bash
./start-here.sh
```

To specify the output type directly:

```bash
./start-here.sh --output=iso
./start-here.sh --output=vm
./start-here.sh --output=img
./start-here.sh --output=removable
```

### 2. Building a Live ISO Directly

Run the ISO builder with interactive prompts:

```bash
./scripts/build.sh -
```

Build a stable XFCE live ISO (default desktop):

```bash
./scripts/build.sh --release=stable --desktop=xfce -
```

Build a stable KDE Plasma live ISO (second default):

```bash
./scripts/build.sh --release=stable --desktop=kde-plasma -
```

Build a headless CLI live ISO:

```bash
./scripts/build.sh --release=stable --desktop=none -
```

Build an ISO with Web Server and SSH Server tasks enabled:

```bash
./scripts/build.sh --release=stable --desktop=xfce --web-server --ssh-server -
```

### 3. Building Disk Images Directly

Build a cloud image:

```bash
./scripts/build-img.sh --release=stable --profile=cli --disk-size=32 -
```

Build a VM image with QCOW2 and VDI exports:

```bash
./scripts/build-vm.sh --release=stable --desktop=xfce --formats=qcow2,vdi -
```

Build a removable USB disk image:

```bash
./scripts/build-removable.sh --release=stable --desktop=mate --disk-size=16 -
```

---

## Desktop Environment Options

The live builder supports 13 desktop variant options mapped to official Debian tasksel packages:

- xfce: task-xfce-desktop (Default)
- kde-plasma: task-kde-desktop with SDDM and Breeze theme (Second Default)
- gnome: task-gnome-desktop
- gnome-flashback: task-gnome-flashback-desktop
- cinnamon: task-cinnamon-desktop
- mate: task-mate-desktop
- lxde: task-lxde-desktop
- lxqt: task-lxqt-desktop
- lomiri: task-lomiri-desktop
- lomiri-tablet: task-lomiri-tablet
- phosh: task-phosh-desktop
- task-desktop: task-desktop (standard desktop)
- none: Minimal headless CLI system (multi-user.target, no GUI packages)

---

## Installers and Post-Install Software Selection

The live system includes two installer options:

### 1. Calamares (Graphical Installer)

Calamares launches directly from the live desktop. It features a text-only presentation styled with official Debian color palettes, includes prominent notices that the ISO was produced using an unofficial build tool rather than official Debian tools, and executes system installation with automatic LUKS encryption support, user account creation, and bootloader installation.

Calamares includes dedicated post-install modules:
- shellprocess@grub-entries: Configures the installed target system bootloader via /usr/local/sbin/setup-grub-modes, creating dedicated top-level "Debian (desktop mode)" and "Debian (CLI mode)" boot entries.
- shellprocess@normalize-sid: On Debian Sid installations, sets standard Debian Sid identification in /etc/os-release and /etc/debian_version.

### 2. CLI Installer (install-system)

Every live ISO copies scripts/cli-installer/install-system to /usr/local/bin/install-system inside the live environment. This enables terminal installations from virtual consoles (Ctrl+Alt+F2) or headless SSH connections:

```bash
sudo install-system
```

Key features of install-system:
- Interactive TUI (dialog/whiptail) and fallback text-based prompts.
- Interactive optional software selection:
  - Web browsers: Firefox ESR, Chromium, Brave Browser, LibreWolf.
  - Server services: Web server (task-web-server), SSH server (task-ssh-server), Cockpit web console (cockpit).
- Bootloader configuration generating desktop and CLI mode entries via setup-grub-modes.
- Automated Sid normalization on Debian Sid targets.
- Target cleanup removing live-only packages (calamares, casper, caper).

---

## Configuration and Automation

### Configuration File (build.cfg)

You can generate a configuration file with the setup wizard:

```bash
./scripts/build.sh --generate-config
```

Or copy the example configuration:

```bash
cp scripts/build.cfg.example build.cfg
```

Run an unattended build with a configuration file:

```bash
./scripts/build.sh --config=build.cfg --no-interactive -
```

### Build Stages and Range Execution

Both the ISO builder and image builders support modular stage execution:

```bash
./scripts/build.sh [start_stage] [-] [end_stage]
```

ISO Builder stages:
- build_workspace: Creates and initializes the build workspace directory structure (setup_host supported as backward-compatible alias).
- debootstrap: Bootstraps the minimal Debian base system.
- run_chroot: Customizes packages, kernel, firmware, desktops, Caper, and deb-multimedia.
- build_iso: Assembles SquashFS, GRUB boot structures, and outputs ISO.

Image Builder stages:
- setup_host: Verifies host tools (parted, dosfstools, e2fsprogs, rsync).
- debootstrap: Bootstraps base Debian system.
- run_chroot: Installs packages and configures chroot.
- build_disk_image: Partitions disk image, formats partitions, installs GRUB, and exports VM formats.

Examples:
- Run only debootstrap: `./scripts/build.sh debootstrap`
- Run from debootstrap through chroot: `./scripts/build.sh debootstrap - run_chroot`
- Re-run only the ISO assembly stage: `./scripts/build.sh build_iso`

---

## Build Hooks (Modloader)

You can drop custom bash scripts into the hooks directory to extend the build process:

- scripts/hooks/pre-chroot/: Runs on the host after debootstrap, before entering the chroot. Has access to WORKSPACE_CHROOT.
- scripts/hooks/chroot/: Runs inside the chroot after base packages are installed.

Scripts run in alphabetical order by filename. Ensure your hook scripts have executable permissions (chmod +x).

---

## Host System Requirements

- Linux operating system (Debian, Ubuntu, Arch Linux, Fedora, etc.).
- Root or sudo privileges.
- Minimum 20 GB free disk space for ISO builds, 40+ GB for disk image builds.
- Required host tools:
  - ISO builds: debootstrap, squashfs-tools, xorriso.
  - Image builds: debootstrap, parted, dosfstools, e2fsprogs, rsync, qemu-utils (for VM exports).
- On Arch Linux, install host tools with pacman (e.g. pacman -S debootstrap squashfs-tools libisoburn parted dosfstools e2fsprogs rsync qemu-img). Never install Debian .deb packages on Arch Linux host.
