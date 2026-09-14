#!/bin/bash

set -euo pipefail

show_start_help() {
    local self="$0"
    cat <<HELPEOF
start-here.sh -- guided launcher for Debian image builders.

Usage:
  ${self} [--output=iso|img|vm|removable] [builder options...]
  ${self} --create-config [--output=...]
  ${self} --help

Dispatcher options:
  --output=iso|img|vm|removable  What to produce (default: asked on a TTY, else iso).
                                iso        Live-installer ISO (scripts/build.sh)
                                img        Cloud disk image: raw .img for cloud VMs (scripts/build-img.sh)
                                vm         VM disk image: raw .img + exports (scripts/build-vm.sh)
                                removable  Removable-media disk image: raw .img for USB/SD/CF (scripts/build-removable.sh)
  --distro=debian               Target distribution (default: debian).
  --create-config               Run the selected builder configuration wizard.
  -h, --help                    Show this help and exit.

Environment variables:
  BUILD_OUTPUT                  Pre-select output type (iso, img, vm, removable).

Builders:
  iso        ->  scripts/build.sh
  img        ->  scripts/build-img.sh
  vm         ->  scripts/build-vm.sh
  removable  ->  scripts/build-removable.sh

Examples:
  ${self}
  ${self} --output=iso
  ${self} --output=vm
  ${self} --create-config --output=iso
HELPEOF
}

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_start_help
            exit 0
            ;;
        --auto)
            # Run in fully automated mode: skip any interactive prompts.
            # This forces the underlying builder to use its non‑interactive path.
            # Users can still supply a config file via --config=FILE.
            # The flag is consumed here; remaining args are passed through.
            AUTO_MODE=1
            ;;
    esac
done

if [[ -t 1 ]]; then
    clear || true
fi

GENERATE_CONFIG=0
for arg in "$@"; do
    case "$arg" in
        --create-config|--generate-config) GENERATE_CONFIG=1 ;;
    esac
done

BUILD_DISTRO="${BUILD_DISTRO:-debian}"
BUILD_OUTPUT="${BUILD_OUTPUT:-}"
PASS_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --distro=*)
            BUILD_DISTRO="${arg#--distro=}"
            ;;
        --output=*)
            BUILD_OUTPUT="${arg#--output=}"
            ;;
        --create-config|--generate-config)
            ;;
        *)
            PASS_ARGS+=("$arg")
            ;;
    esac
done

if [[ "$GENERATE_CONFIG" -eq 1 ]]; then
    PASS_ARGS+=("--generate-config")
fi

# If auto mode requested, ensure the builder runs non‑interactive.
if [[ "${AUTO_MODE:-0}" -eq 1 ]]; then
    PASS_ARGS+=("--no-interactive")
fi

case "${BUILD_DISTRO,,}" in
    debian|"")
        BUILD_DISTRO="debian"
        ;;
    *)
        echo "ERROR: BUILD_DISTRO/--distro must be 'debian' (got: '${BUILD_DISTRO}')." >&2
        exit 1
        ;;
esac

case "${BUILD_OUTPUT,,}" in
    iso)
        BUILD_OUTPUT="iso"
        ;;
    img|image|cloud|cloud-img)
        BUILD_OUTPUT="img"
        ;;
    vm)
        BUILD_OUTPUT="vm"
        ;;
    removable|removable-media|usb|sd)
        BUILD_OUTPUT="removable"
        ;;
    "")
        if [[ -t 0 ]]; then
            echo ""
            echo "--- Output type ---"
            echo "    1) ISO           Live-installer ISO (USB/DVD/PXE/VM boot)  [default]"
            echo "    2) Cloud image   Ready-to-deploy raw .img for cloud VMs (cloud-init)"
            echo "    3) VM image      Raw .img + QCOW2/VDI/VMDK/VHDX exports for hypervisors"
            echo "    4) Removable     Ready-to-flash raw .img for USB sticks, SD cards, CF cards"
            while true; do
                read -r -p "  Output [1/2/3/4, Enter=1]: " _choice
                case "${_choice,,}" in
                    ""|1|iso)
                        BUILD_OUTPUT="iso"
                        break
                        ;;
                    2|img|image|cloud|cloud-img)
                        BUILD_OUTPUT="img"
                        break
                        ;;
                    3|vm)
                        BUILD_OUTPUT="vm"
                        break
                        ;;
                    4|removable|removable-media|usb|sd)
                        BUILD_OUTPUT="removable"
                        break
                        ;;
                    *)
                        echo "  Invalid selection: '${_choice}'."
                        ;;
                esac
            done
        else
            echo "  info  No TTY and no --output given: defaulting to 'iso'." >&2
            BUILD_OUTPUT="iso"
        fi
        ;;
    *)
        echo "ERROR: BUILD_OUTPUT/--output must be 'iso', 'img', 'vm', or 'removable' (got: '${BUILD_OUTPUT}')." >&2
        exit 1
        ;;
esac

case "${BUILD_OUTPUT}" in
    iso)       BUILD_SCRIPT="build.sh" ;;
    img)       BUILD_SCRIPT="build-img.sh" ;;
    vm)        BUILD_SCRIPT="build-vm.sh" ;;
    removable) BUILD_SCRIPT="build-removable.sh" ;;
esac

echo "=====> Selected: Debian / ${BUILD_OUTPUT} (scripts/${BUILD_SCRIPT})"

IS_DEBIAN_OR_UBUNTU=0
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" ]] || [[ "${ID_LIKE:-}" == *ubuntu* ]] || \
       [[ "${ID:-}" == "debian" ]] || [[ "${ID_LIKE:-}" == *debian* ]]; then
        IS_DEBIAN_OR_UBUNTU=1
    fi
fi

DEPS=(debootstrap)
case "${BUILD_OUTPUT}" in
    iso)       DEPS+=(squashfs-tools xorriso) ;;
    img)       DEPS+=(parted dosfstools e2fsprogs rsync) ;;
    vm)        DEPS+=(parted dosfstools e2fsprogs rsync qemu-utils) ;;
    removable) DEPS+=(parted dosfstools e2fsprogs rsync) ;;
esac

if [[ "$IS_DEBIAN_OR_UBUNTU" -eq 1 ]]; then
    DEPS+=(debian-archive-keyring)
fi

if [[ "$GENERATE_CONFIG" -eq 0 ]]; then
    if [[ "$IS_DEBIAN_OR_UBUNTU" -eq 1 ]] && command -v dpkg &>/dev/null; then
        MISSING_DEPS=()
        for dep in "${DEPS[@]}"; do
            if ! dpkg -s "$dep" &>/dev/null; then
                MISSING_DEPS+=("$dep")
            fi
        done

        if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
            echo "=====> Installing missing host dependencies: ${MISSING_DEPS[*]}"
            if [ "$(id -u)" -eq 0 ]; then
                apt-get update
                apt-get install -y "${MISSING_DEPS[@]}"
            else
                sudo apt-get update
                sudo apt-get install -y "${MISSING_DEPS[@]}"
            fi
        fi
    else
        MISSING_CMDS=()
        for dep in "${DEPS[@]}"; do
            case "$dep" in
                squashfs-tools)
                    command -v mksquashfs &>/dev/null || MISSING_CMDS+=(mksquashfs)
                    ;;
                xorriso)
                    command -v xorriso &>/dev/null || MISSING_CMDS+=(xorriso)
                    ;;
                qemu-utils)
                    command -v qemu-img &>/dev/null || MISSING_CMDS+=(qemu-img)
                    ;;
                parted|dosfstools|e2fsprogs|rsync|debootstrap)
                    command -v "$dep" &>/dev/null || MISSING_CMDS+=("$dep")
                    ;;
            esac
        done
        if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
            echo "=====> WARNING: host is not Debian/Ubuntu and missing commands: ${MISSING_CMDS[*]}" >&2
            echo "=====>          Please install the required tools using your host package manager." >&2
        fi
    fi
fi

SUDO_KEEPALIVE_PID=""

cleanup_sudo_keepalive() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}

if [[ "$GENERATE_CONFIG" -eq 0 ]] && [[ "$(id -u)" -ne 0 ]]; then
    echo "=====> Requesting sudo credentials..."
    if ! sudo -v 2>/dev/null; then
        echo "=====> ERROR: Failed to obtain sudo credentials. Sudo access required." >&2
        exit 1
    fi

    (while sudo -v -n 2>/dev/null; do sleep 60; done) &
    SUDO_KEEPALIVE_PID=$!

    trap cleanup_sudo_keepalive EXIT
fi

export LAUNCHED_FROM_START_HERE=1

chmod +x "$0"
chmod +x "$(dirname "$0")/scripts/${BUILD_SCRIPT}"
"$(dirname "$0")/scripts/${BUILD_SCRIPT}" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}
