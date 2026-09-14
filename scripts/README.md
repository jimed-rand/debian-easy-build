# Build Scripts Reference

This directory contains the core build scripts used to assemble custom Debian live ISOs and ready-to-use disk images:

- build.sh: builds a live-installer Debian ISO (using Caper live-boot and Calamares installer).
- build-img.sh: builds a ready-to-deploy Debian cloud disk image (raw .img with cloud-init).
- build-vm.sh: builds a ready-to-use Debian VM disk image (raw .img plus QCOW2, VDI, VMDK, VHDX exports).
- build-removable.sh: builds a ready-to-flash Debian removable-media disk image (raw .img for USB/SD/CF media).

All builders share the same stages, options, and hooks. The repository-root start-here.sh launcher asks which output to build (or accepts --output=iso|img|vm|removable).

---

## The build.sh Script

The primary script build.sh orchestrates the entire Debian live ISO generation process. It runs in two distinct environments:
1. On the Host System: Prepares directories, downloads the base files via debootstrap, enters the chroot to trigger customization, packages the Caper live-boot hook, compresses the system using SquashFS, and packages the result into a hybrid bootable ISO using xorriso.
2. Inside the Chroot Environment: Configures APT repositories, blocks Snap packages via APT pinning, installs the Debian kernel and firmware, configures desktop environments, and installs web browsers. This mode is invoked internally with the --chroot-internal flag.

### Supported Target Releases

- stable (default, currently Debian 12 / Bookworm)
- testing (next Debian release)
- unstable / sid (rolling Debian development branch, with normalized /etc/os-release)

The script installs standard Debian kernels (linux-image-amd64) and full non-free-firmware packages (firmware-linux, firmware-misc-nonfree, firmware-iwlwifi, firmware-realtek, firmware-sof-signed) to ensure hardware compatibility.

### Caper Live System Integration

Ubuntu-style live ISOs rely on casper. For Debian, this builder uses Caper (/home/jimedrand/Git/caper), a Debian-native alternative that provides casper drop-in compatibility, Calamares launcher integration, and clean hardware detection.

The builder supports dual-mode packaging:
- Pre-built packages in caper-deb/ are reused automatically.
- On Debian hosts with dpkg-dev, Caper is compiled on the host.
- On non-Debian hosts (such as Arch Linux), Caper is compiled safely inside the debootstrap chroot environment, exported to caper-deb/ to persist in the repository, and installed without contaminating the host system.

### Syntax and Modular Execution

Execute individual segments of the build pipeline:

```bash
./build.sh [options] [start_cmd] [-] [end_cmd]
```

- Run all stages (default): `./build.sh -`
- Single stage: Run start_cmd to completion of that stage.
- Stage range: Run from start_cmd through end_cmd.

Host stages:
- setup_host: Verifies host tools (debootstrap, squashfs-tools, xorriso).
- debootstrap: Bootstraps the minimal Debian base system.
- run_chroot: Enters chroot to install packages and configure system.
- build_iso: Builds EFI/BIOS boot structures, SquashFS, and ISO.

Chroot stages:
- chroot_prepare: Configures APT sources, policy-rc.d, and APT pinning.
- install_pkg: Installs kernel, firmware, desktops, and applications.
- finish_up: Cleans APT cache and temporary mounts.

---

## The Image Builders (build-img.sh, build-vm.sh, build-removable.sh)

The disk image builders produce ready-to-use partitioned disk images instead of live-installer ISOs:
- build-img.sh: Cloud disk image (.img) with cloud-init and cloud-guest-utils.
- build-vm.sh: VM disk image with optional qemu-img exports to QCOW2, VDI, VMDK, or VHDX.
- build-removable.sh: Removable-media disk image with hybrid BIOS/UEFI boot and first-boot setup wizard.

Each image builder supports:
- Firmware: --firmware=uefi|hybrid
- Size: --disk-size=GB
- Allocation: --alloc-tool=truncate|fallocate|dd
- Profiles: --profile=desktop|cli
- Network: --network=networkd|network-manager
- User mode: --user-mode=build|deploy (baked credentials or first-boot setup)
