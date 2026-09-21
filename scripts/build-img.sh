#!/bin/bash

set -e
set -o pipefail
set -u

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SCRIPT_BASE="$(basename "$0")"

if [[ -z "${DEB_IMAGE_KIND:-}" ]]; then
    case "$SCRIPT_BASE" in
        *vm*)        DEB_IMAGE_KIND="vm" ;;
        *removable*) DEB_IMAGE_KIND="removable" ;;
        *)           DEB_IMAGE_KIND="cloud" ;;
    esac
fi

WORKSPACE_DIR=""
WORKSPACE_CHROOT=""
WORKSPACE_IMAGE=""
OUTPUT_DIR=""
DEB_SYSTEM_WORKSPACE_PARENT="/var/cache/debian-easy-build"
HOST_ABORT_CLEANUP_DONE=0
DATE="$(TZ="UTC" date +"%y%m%d-%H%M%S")"
HOOKS_DIR=""
OUTPUT_FILES=()
IMG_LOOP_DEV=""
IMG_MOUNT_DIR=""

if [[ -n "${ADVANCED_MODE+x}" ]]; then
    ADVANCED_MODE_EXPLICIT=1
else
    ADVANCED_MODE_EXPLICIT=0
fi
ADVANCED_MODE="${ADVANCED_MODE:-0}"

function ui_banner() {
    local title="$1"
    local bar="=================================================================="
    printf "\n%s\n  %s\n%s\n\n" "$bar" "$title" "$bar"
}

function ui_heading() {
    printf "\n--- %s ---\n" "$1"
}

function ui_step() {
    local n="$1" total="$2" name="$3"
    printf "\n[%d/%d] %s\n" "$n" "$total" "$name"
}

function ui_ok()   { printf "  OK    %s\n" "$1"; }
function ui_warn() { printf "  WARN  %s\n" "$1" >&2; }
function ui_err()  { printf "  ERROR %s\n" "$1" >&2; }
function ui_info() { printf "  info  %s\n" "$1"; }

function ui_kv() {
    printf "    %-24s %s\n" "$1" "$2"
}

function ui_confirm() {
    local prompt="${1:-Proceed?}"
    local default="${2:-y}"
    if [[ "${NO_CONFIRM:-0}" == "1" ]] || ! prompts_enabled; then
        return 0
    fi
    local hint yn
    if [[ "$default" == "y" ]]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi
    while true; do
        read -r -p "  ${prompt} ${hint}: " yn
        yn="${yn,,}"
        if [[ -z "$yn" ]]; then
            yn="$default"
        fi
        case "$yn" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     echo "Please answer yes or no." ;;
        esac
    done
}

function prompts_enabled() {
    if [[ "${INTERACTIVE_OVERRIDE:-}" == "0" ]]; then
        return 1
    fi
    if [[ "${INTERACTIVE_OVERRIDE:-}" == "1" ]]; then
        return 0
    fi
    [[ -t 0 ]]
}

function set_defaults() {
    TARGET_DEBIAN_RELEASE="${TARGET_DEBIAN_RELEASE:-stable}"
    TARGET_DEBIAN_MIRROR="${TARGET_DEBIAN_MIRROR:-http://deb.debian.org/debian/}"
    TARGET_DEBIAN_SECURITY_MIRROR="${TARGET_DEBIAN_SECURITY_MIRROR:-http://security.debian.org/debian-security}"
    TARGET_PROFILE="${TARGET_PROFILE:-desktop}"
    TARGET_DESKTOP="${TARGET_DESKTOP:-gnome}"
    TARGET_DESKTOP_RECOMMENDS="${TARGET_DESKTOP_RECOMMENDS:-1}"
    TARGET_BROWSER_FIREFOX="${TARGET_BROWSER_FIREFOX:-1}"
    TARGET_BROWSER_THUNDERBIRD="${TARGET_BROWSER_THUNDERBIRD:-0}"
    TARGET_BROWSER_CHROMIUM="${TARGET_BROWSER_CHROMIUM:-0}"
    TARGET_BROWSER_BRAVE="${TARGET_BROWSER_BRAVE:-0}"
    TARGET_BROWSER_LIBREWOLF="${TARGET_BROWSER_LIBREWOLF:-0}"
    TARGET_HOSTNAME="${TARGET_HOSTNAME:-debian}"
    TARGET_USERNAME="${TARGET_USERNAME:-user}"
    TARGET_PASSWORD="${TARGET_PASSWORD:-debian}"
    TARGET_USER_FULLNAME="${TARGET_USER_FULLNAME:-Debian User}"
    TARGET_ALLOC_TOOL="${TARGET_ALLOC_TOOL:-truncate}"
    TARGET_NETWORK_STACK="${TARGET_NETWORK_STACK:-networkd}"
    TARGET_SSH_SERVER="${TARGET_SSH_SERVER:-1}"

    case "$DEB_IMAGE_KIND" in
        vm)
            TARGET_FIRMWARE="${TARGET_FIRMWARE:-uefi}"
            TARGET_DISK_SIZE_GB="${TARGET_DISK_SIZE_GB:-32}"
            TARGET_USER_MODE="${TARGET_USER_MODE:-build}"
            TARGET_VM_FORMATS="${TARGET_VM_FORMATS:-qcow2}"
            ;;
        removable)
            TARGET_FIRMWARE="${TARGET_FIRMWARE:-hybrid}"
            TARGET_DISK_SIZE_GB="${TARGET_DISK_SIZE_GB:-16}"
            TARGET_USER_MODE="${TARGET_USER_MODE:-deploy}"
            TARGET_VM_FORMATS="${TARGET_VM_FORMATS:-none}"
            ;;
        *)
            TARGET_FIRMWARE="${TARGET_FIRMWARE:-uefi}"
            TARGET_DISK_SIZE_GB="${TARGET_DISK_SIZE_GB:-32}"
            TARGET_USER_MODE="${TARGET_USER_MODE:-deploy}"
            TARGET_VM_FORMATS="${TARGET_VM_FORMATS:-none}"
            ;;
    esac

    local flavor
    if [[ "$TARGET_PROFILE" == "cli" ]]; then
        flavor="cli"
    else
        flavor="$TARGET_DESKTOP"
    fi
    TARGET_NAME="debian-${TARGET_DEBIAN_RELEASE}-${flavor}-${DEB_IMAGE_KIND}-amd64-${DATE}"
}

function resolve_workspace_paths() {
    local ws_parent
    if [[ "$ADVANCED_MODE" -eq 1 ]]; then
        ws_parent="${DEB_WORKSPACE_DIR:-$HOME/deb-workspace}"
    else
        ws_parent="$DEB_SYSTEM_WORKSPACE_PARENT"
    fi

    WORKSPACE_DIR="${ws_parent%/}/workspace-${DEB_IMAGE_KIND}"
    WORKSPACE_CHROOT="$WORKSPACE_DIR/chroot"
    WORKSPACE_IMAGE="$WORKSPACE_DIR/${TARGET_NAME}.img"
    OUTPUT_DIR="${DEB_OUTPUT_DIR:-$HOME}"
}

function host_priv() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

SUDO_KEEPALIVE_PID=""

function setup_sudo_keepalive() {
    if [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    if ! sudo -v 2>/dev/null; then
        ui_err "Failed to obtain sudo credentials. Sudo access is required."
        exit 1
    fi
    (while sudo -v -n 2>/dev/null; do sleep 60; done) &
    SUDO_KEEPALIVE_PID=$!
}

function cleanup_sudo_keepalive() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}

function detach_image_loop() {
    if [[ -n "$IMG_MOUNT_DIR" ]] && [[ -d "$IMG_MOUNT_DIR" ]]; then
        local mnt
        for mnt in dev/pts dev proc sys run boot/efi ""; do
            local target="$IMG_MOUNT_DIR/$mnt"
            target="${target%/}"
            if mountpoint -q "$target" 2>/dev/null; then
                host_priv umount -lf "$target" 2>/dev/null || true
            fi
        done
        host_priv rm -rf "$IMG_MOUNT_DIR" 2>/dev/null || true
    fi
    if [[ -n "$IMG_LOOP_DEV" ]]; then
        host_priv losetup -d "$IMG_LOOP_DEV" 2>/dev/null || true
        IMG_LOOP_DEV=""
    fi
}

function host_abort_cleanup() {
    if [[ "$HOST_ABORT_CLEANUP_DONE" -eq 1 ]]; then
        return 0
    fi
    HOST_ABORT_CLEANUP_DONE=1
    cleanup_sudo_keepalive
    detach_image_loop
    if [[ -n "$WORKSPACE_CHROOT" ]] && [[ -d "$WORKSPACE_CHROOT" ]]; then
        local mnt
        for mnt in dev/pts dev proc sys run; do
            if mountpoint -q "$WORKSPACE_CHROOT/$mnt" 2>/dev/null; then
                host_priv umount -lf "$WORKSPACE_CHROOT/$mnt" 2>/dev/null || true
            fi
        done
    fi
    if [[ "${ADVANCED_MODE:-0}" == "1" ]]; then
        echo "=====> [advanced] Workspace preserved at: ${WORKSPACE_DIR:-unknown}" >&2
    else
        if [[ -n "${WORKSPACE_DIR:-}" ]] && [[ -d "$WORKSPACE_DIR" ]]; then
            echo "=====> unmounting chroot bind mounts and removing workspace ..." >&2
            host_priv rm -rf "$WORKSPACE_DIR" 2>/dev/null || true
        fi
    fi
}

function host_build_exit_trap() {
    local rc=$?
    host_abort_cleanup
    if [[ $rc -ne 0 ]]; then
        ui_err "Build failed with exit code $rc."
    fi
    exit $rc
}

function run_hooks() {
    local phase="$1"
    local dir="${HOOKS_DIR:-$REPO_ROOT/scripts/hooks}/$phase"
    if [[ ! -d "$dir" ]]; then
        return 0
    fi
    local hook
    for hook in "$dir"/*; do
        if [[ -f "$hook" ]] && [[ -x "$hook" ]]; then
            ui_info "Running hook: $(basename "$hook")"
            "$hook"
        fi
    done
}

function setup_host() {
    ui_banner "Debian Easy Build: Setup Host (${DEB_IMAGE_KIND})"
    setup_sudo_keepalive

    local required_tools=(parted dosfstools e2fsprogs rsync debootstrap)
    if [[ "$DEB_IMAGE_KIND" == "vm" ]] && [[ "${TARGET_VM_FORMATS:-none}" != "none" ]]; then
        required_tools+=(qemu-img)
    fi

    local missing=()
    local tool
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        ui_err "Missing required host tools: ${missing[*]}"
        exit 1
    fi

    host_priv mkdir -p "$WORKSPACE_DIR" "$OUTPUT_DIR"
    ui_ok "Host environment verified."
}

function debootstrap_stage() {
    ui_banner "Debian Easy Build: Debootstrap ($TARGET_DEBIAN_RELEASE)"
    host_priv mkdir -p "$WORKSPACE_CHROOT"

    if [[ -f "$WORKSPACE_CHROOT/etc/debian_version" ]]; then
        ui_info "Existing chroot found, skipping debootstrap."
        return 0
    fi

    local comp_csv="main,contrib,non-free,non-free-firmware"
    ui_info "Running debootstrap --arch=amd64 --components=$comp_csv $TARGET_DEBIAN_RELEASE $WORKSPACE_CHROOT $TARGET_DEBIAN_MIRROR"
    host_priv debootstrap --arch=amd64 --components="$comp_csv" "$TARGET_DEBIAN_RELEASE" "$WORKSPACE_CHROOT" "$TARGET_DEBIAN_MIRROR"
    ui_ok "Debootstrap complete."
}

function in_target() {
    host_priv chroot "$IMG_MOUNT_DIR" /usr/bin/env         DEBIAN_FRONTEND=noninteractive LC_ALL=C HOME=/root "$@"
}

function normalize_sid_os_release() {
    if [[ "$TARGET_DEBIAN_RELEASE" == "unstable" ]] || [[ "$TARGET_DEBIAN_RELEASE" == "sid" ]] || grep -q 'sid' /etc/os-release 2>/dev/null || grep -q 'sid' /usr/lib/os-release 2>/dev/null || grep -q 'sid' /etc/debian_version 2>/dev/null; then
        cat <<'EOF' > /etc/os-release
PRETTY_NAME="Debian GNU/Linux Sid"
NAME="Debian GNU/Linux"
VERSION_CODENAME=sid
ID=debian
HOME_URL="https://www.debian.org/"
SUPPORT_URL="https://www.debian.org/support"
BUG_REPORT_URL="https://bugs.debian.org/"
EOF
        if [[ -f /usr/lib/os-release ]] && ! [[ /etc/os-release -ef /usr/lib/os-release ]]; then
            cp -f /etc/os-release /usr/lib/os-release
        fi
        if [[ -f /etc/debian_version ]]; then
            sed -i 's#[^/[:space:]]*/sid#sid#g' /etc/debian_version
        fi
    fi
}

function chroot_prepare() {
    cat <<POLICY_EOF > /usr/sbin/policy-rc.d
#!/bin/sh
exit 101
POLICY_EOF
    chmod +x /usr/sbin/policy-rc.d

    mount -t proc proc /proc 2>/dev/null || true
    mount -t sysfs sysfs /sys 2>/dev/null || true
    mount -t devpts devpts /dev/pts 2>/dev/null || true

    mkdir -p /etc/apt/preferences.d
    cat <<SNAP_EOF > /etc/apt/preferences.d/no-snapd.pref
Package: snapd*
Pin: release *
Pin-Priority: -1
SNAP_EOF

    local mirror="${TARGET_DEBIAN_MIRROR%/}/"
    local sec_mirror="${TARGET_DEBIAN_SECURITY_MIRROR%/}"
    local comp="main contrib non-free non-free-firmware"

    case "$TARGET_DEBIAN_RELEASE" in
        stable)
            cat <<EOF > /etc/apt/sources.list
deb ${mirror} stable $comp
deb-src ${mirror} stable $comp

deb ${sec_mirror} stable-security $comp
deb-src ${sec_mirror} stable-security $comp

deb ${mirror} stable-updates $comp
deb-src ${mirror} stable-updates $comp

deb ${mirror} stable-backports $comp
deb-src ${mirror} stable-backports $comp
EOF
            ;;
        testing)
            cat <<EOF > /etc/apt/sources.list
deb ${mirror} testing $comp
deb-src ${mirror} testing $comp

deb ${sec_mirror} testing-security $comp
deb-src ${sec_mirror} testing-security $comp

deb ${mirror} testing-updates $comp
deb-src ${mirror} testing-updates $comp
EOF
            ;;
        unstable|sid)
            cat <<EOF > /etc/apt/sources.list
deb ${mirror} unstable $comp
deb-src ${mirror} unstable $comp
EOF
            ;;
    esac

    normalize_sid_os_release
}

function install_pkg() {
    if ! grep -q "non-free-firmware" /etc/apt/sources.list 2>/dev/null; then
        chroot_prepare
    fi

    apt-get update
    apt-get dist-upgrade -y

    apt-get install -y \
        sudo locales tzdata nano less psmisc iproute2 systemd-sysv \
        e2fsprogs dosfstools parted rsync curl wget ca-certificates \
        grub-common grub-pc-bin grub2-common grub-efi-amd64-bin \
        grub-efi-amd64-signed shim-signed

    apt-get install -y \
        linux-image-amd64 linux-headers-amd64

    local fw_pkgs=(
        firmware-linux
        firmware-misc-nonfree
        firmware-iwlwifi
        firmware-realtek
        firmware-sof-signed
    )
    local avail_fw=()
    local p
    for p in "${fw_pkgs[@]}"; do
        if apt-cache show "$p" &>/dev/null; then
            avail_fw+=("$p")
        fi
    done
    if [[ ${#avail_fw[@]} -gt 0 ]]; then
        apt-get install -y "${avail_fw[@]}"
    fi

    if [[ "$TARGET_SSH_SERVER" -eq 1 ]]; then
        apt-get install -y openssh-server
    fi

    if [[ "$DEB_IMAGE_KIND" == "cloud" ]] || [[ "$DEB_IMAGE_KIND" == "removable" ]]; then
        apt-get install -y cloud-init cloud-guest-utils
    fi

    if [[ "$DEB_IMAGE_KIND" == "vm" ]]; then
        apt-get install -y qemu-guest-agent 2>/dev/null || true
    fi

    if [[ "$TARGET_PROFILE" == "desktop" ]]; then
        local pkg_recommends=()
        if [[ "$TARGET_DESKTOP_RECOMMENDS" -eq 0 ]]; then
            pkg_recommends+=(--no-install-recommends)
        fi
        apt-get install -y "${pkg_recommends[@]}" "task-${TARGET_DESKTOP}-desktop" network-manager
        if [[ "$TARGET_DESKTOP" == "gnome" ]]; then
            apt-get install -y network-manager-gnome 2>/dev/null || true
        fi

        if [[ "$TARGET_BROWSER_FIREFOX" -eq 1 ]]; then
            apt-get install -y firefox 2>/dev/null || apt-get install -y firefox-esr 2>/dev/null || true
        fi
        if [[ "$TARGET_BROWSER_THUNDERBIRD" -eq 1 ]]; then
            apt-get install -y thunderbird 2>/dev/null || true
        fi
        if [[ "$TARGET_BROWSER_CHROMIUM" -eq 1 ]]; then
            apt-get install -y chromium 2>/dev/null || true
        fi
        if [[ "$TARGET_BROWSER_BRAVE" -eq 1 ]]; then
            curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg 2>/dev/null || true
            echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" > /etc/apt/sources.list.d/brave-browser-release.list
            apt-get update && apt-get install -y brave-browser 2>/dev/null || true
        fi
        if [[ "$TARGET_BROWSER_LIBREWOLF" -eq 1 ]]; then
            curl -fsSLo /usr/share/keyrings/librewolf.gpg https://repo.librewolf.net/keyring.gpg 2>/dev/null || true
            echo "deb [arch=amd64 signed-by=/usr/share/keyrings/librewolf.gpg] https://repo.librewolf.net librewolf main" > /etc/apt/sources.list.d/librewolf.list
            rm -f /etc/apt/sources.list.d/librewolf.sources
            apt-get update && apt-get install -y librewolf 2>/dev/null || true
        fi
    else
        if [[ "$TARGET_NETWORK_STACK" == "network-manager" ]]; then
            apt-get install -y network-manager
        else
            apt-get install -y systemd-resolved 2>/dev/null || true
        fi
    fi

    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    locale-gen
    update-locale LANG=en_US.UTF-8

    apt-get autoremove -y
    apt-get clean
}

function finish_up() {
    normalize_sid_os_release
    rm -f /usr/sbin/policy-rc.d
    umount -lf /dev/pts 2>/dev/null || true
    umount -lf /sys 2>/dev/null || true
    umount -lf /proc 2>/dev/null || true
}

function chroot_main() {
    chroot_prepare
    install_pkg
    finish_up
}

function run_chroot() {
    ui_banner "Debian Easy Build: Run Chroot"
    run_hooks "pre-chroot"

    host_priv cp -f "$0" "$WORKSPACE_CHROOT/root/build-img.sh"
    host_priv chmod +x "$WORKSPACE_CHROOT/root/build-img.sh"

    host_priv mount --bind /dev "$WORKSPACE_CHROOT/dev"
    host_priv mount --bind /dev/pts "$WORKSPACE_CHROOT/dev/pts"
    host_priv mount -t proc proc "$WORKSPACE_CHROOT/proc"
    host_priv mount -t sysfs sysfs "$WORKSPACE_CHROOT/sys"

    host_priv chroot "$WORKSPACE_CHROOT" /usr/bin/env \
        DEBIAN_FRONTEND=noninteractive \
        LC_ALL=C \
        HOME=/root \
        DEB_IMAGE_KIND="$DEB_IMAGE_KIND" \
        TARGET_DEBIAN_RELEASE="$TARGET_DEBIAN_RELEASE" \
        TARGET_DEBIAN_MIRROR="$TARGET_DEBIAN_MIRROR" \
        TARGET_DEBIAN_SECURITY_MIRROR="$TARGET_DEBIAN_SECURITY_MIRROR" \
        TARGET_PROFILE="$TARGET_PROFILE" \
        TARGET_DESKTOP="$TARGET_DESKTOP" \
        TARGET_DESKTOP_RECOMMENDS="$TARGET_DESKTOP_RECOMMENDS" \
        TARGET_BROWSER_FIREFOX="$TARGET_BROWSER_FIREFOX" \
        TARGET_BROWSER_THUNDERBIRD="$TARGET_BROWSER_THUNDERBIRD" \
        TARGET_BROWSER_CHROMIUM="$TARGET_BROWSER_CHROMIUM" \
        TARGET_BROWSER_BRAVE="$TARGET_BROWSER_BRAVE" \
        TARGET_BROWSER_LIBREWOLF="$TARGET_BROWSER_LIBREWOLF" \
        TARGET_HOSTNAME="$TARGET_HOSTNAME" \
        TARGET_NETWORK_STACK="$TARGET_NETWORK_STACK" \
        TARGET_SSH_SERVER="$TARGET_SSH_SERVER" \
        /root/build-img.sh --chroot-internal

    host_priv rm -f "$WORKSPACE_CHROOT/root/build-img.sh"
    host_priv umount -lf "$WORKSPACE_CHROOT/sys" 2>/dev/null || true
    host_priv umount -lf "$WORKSPACE_CHROOT/proc" 2>/dev/null || true
    host_priv umount -lf "$WORKSPACE_CHROOT/dev/pts" 2>/dev/null || true
    host_priv umount -lf "$WORKSPACE_CHROOT/dev" 2>/dev/null || true

    ui_ok "Chroot customization complete."
}

function create_baked_user() {
    ui_info "Creating user '${TARGET_USERNAME}' in image"
    in_target useradd -m -s /bin/bash -c "${TARGET_USER_FULLNAME}" "$TARGET_USERNAME"
    local grp
    for grp in adm cdrom dip plugdev sudo audio video; do
        if in_target getent group "$grp" >/dev/null 2>&1; then
            in_target usermod -aG "$grp" "$TARGET_USERNAME"
        fi
    done
    printf "%s:%s\n" "$TARGET_USERNAME" "$TARGET_PASSWORD" | in_target chpasswd
}

function install_firstboot_user_wizard() {
    ui_info "Installing first-boot user setup wizard"
    host_priv tee "$IMG_MOUNT_DIR/usr/local/sbin/deb-firstboot-setup" >/dev/null <<WIZARD_EOF
#!/bin/bash
set -u
echo ""
echo "=================================================================="
echo "  Debian First Boot Setup: User Account Creation"
echo "=================================================================="
echo ""
username=""
while true; do
    read -r -p "Enter username: " username
    if [[ ! "\$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "Invalid username (use lowercase letters, numbers, '-' and '_')."
        continue
    fi
    if id "\$username" &>/dev/null; then
        echo "User '\$username' already exists."
        continue
    fi
    break
done
read -r -p "Full name [\${username}]: " fullname
fullname="\${fullname:-\$username}"
while true; do
    read -r -s -p "Password: " p1
    echo ""
    read -r -s -p "Confirm password: " p2
    echo ""
    if [[ "\$p1" != "\$p2" ]]; then
        echo "Passwords do not match."
        continue
    fi
    if [[ -z "\$p1" ]]; then
        echo "Password cannot be empty."
        continue
    fi
    break
done
useradd -m -s /bin/bash -c "\$fullname" "\$username"
for grp in adm cdrom dip plugdev sudo audio video; do
    if getent group "\$grp" >/dev/null 2>&1; then
        usermod -aG "\$grp" "\$username"
    fi
done
printf "%s:%s\n" "\$username" "\$p1" | chpasswd
systemctl disable deb-firstboot.service 2>/dev/null || true
rm -f /etc/systemd/system/deb-firstboot.service
echo "User '\$username' successfully created."
WIZARD_EOF
    host_priv chmod 0755 "$IMG_MOUNT_DIR/usr/local/sbin/deb-firstboot-setup"

    host_priv tee "$IMG_MOUNT_DIR/etc/systemd/system/deb-firstboot.service" >/dev/null <<SERVICE_EOF
[Unit]
Description=Debian First Boot User Setup
After=systemd-user-sessions.service plymouth-quit-wait.service
Before=getty.target

[Service]
Type=oneshot
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
ExecStart=/usr/local/sbin/deb-firstboot-setup

[Install]
WantedBy=multi-user.target
SERVICE_EOF
    in_target systemctl enable deb-firstboot.service || true
}

function export_vm_images() {
    local raw="$1"
    local formats="${TARGET_VM_FORMATS:-qcow2}"
    if [[ "$formats" == "none" ]] || [[ -z "$formats" ]]; then
        return 0
    fi
    local fmt out
    for fmt in ${formats//,/ }; do
        case "$fmt" in
            qcow2)
                out="${raw%.img}.qcow2"
                ui_info "Exporting QCOW2 format: $(basename "$out")"
                host_priv qemu-img convert -f raw -O qcow2 -c "$raw" "$out"
                OUTPUT_FILES+=("$out")
                ;;
            vdi)
                out="${raw%.img}.vdi"
                ui_info "Exporting VDI format: $(basename "$out")"
                host_priv qemu-img convert -f raw -O vdi "$raw" "$out"
                OUTPUT_FILES+=("$out")
                ;;
            vmdk)
                out="${raw%.img}.vmdk"
                ui_info "Exporting VMDK format: $(basename "$out")"
                host_priv qemu-img convert -f raw -O vmdk "$raw" "$out"
                OUTPUT_FILES+=("$out")
                ;;
            vhdx)
                out="${raw%.img}.vhdx"
                ui_info "Exporting VHDX format: $(basename "$out")"
                host_priv qemu-img convert -f raw -O vhdx "$raw" "$out"
                OUTPUT_FILES+=("$out")
                ;;
        esac
    done
}

function write_output_hashes() {
    local target="$1"
    local dir
    dir="$(dirname "$target")"
    local base
    base="$(basename "$target")"
    (cd "$dir" && sha1sum "$base" > "${base}.sha1")
    (cd "$dir" && sha256sum "$base" > "${base}.sha256")
    OUTPUT_FILES+=("${target}.sha1" "${target}.sha256")
}

function build_disk_image() {
    ui_banner "Debian Easy Build: Assembling Disk Image (${DEB_IMAGE_KIND})"

    local size_gb="${TARGET_DISK_SIZE_GB:-32}"
    local firmware="${TARGET_FIRMWARE:-uefi}"
    local esp_mib=512
    local swap_mib=4096
    if [[ "$size_gb" -lt 16 ]]; then
        swap_mib=2048
    fi

    local img_path="$WORKSPACE_IMAGE"
    IMG_MOUNT_DIR="$WORKSPACE_DIR/imgroot"

    host_priv rm -f "$img_path"
    ui_info "Allocating ${size_gb} GB disk image: $img_path"

    case "${TARGET_ALLOC_TOOL:-truncate}" in
        truncate)
            host_priv truncate -s "${size_gb}G" "$img_path"
            ;;
        fallocate)
            host_priv fallocate -l "${size_gb}G" "$img_path"
            ;;
        dd)
            host_priv dd if=/dev/zero of="$img_path" bs=1M count="$((size_gb * 1024))" status=progress
            ;;
    esac

    IMG_LOOP_DEV="$(host_priv losetup --show -f -P "$img_path")"
    ui_info "Loop device attached: $IMG_LOOP_DEV"

    local p_esp p_swap p_root
    if [[ "$firmware" == "uefi" ]]; then
        host_priv parted -s "$IMG_LOOP_DEV" \
            mklabel gpt \
            mkpart ESP fat32 1MiB "$((1 + esp_mib))MiB" \
            set 1 esp on \
            mkpart swap linux-swap "$((1 + esp_mib))MiB" "$((1 + esp_mib + swap_mib))MiB" \
            mkpart root ext4 "$((1 + esp_mib + swap_mib))MiB" 100%
        p_esp="${IMG_LOOP_DEV}p1"
        p_swap="${IMG_LOOP_DEV}p2"
        p_root="${IMG_LOOP_DEV}p3"
    else
        host_priv parted -s "$IMG_LOOP_DEV" \
            mklabel gpt \
            mkpart biosboot 1MiB 2MiB \
            set 1 bios_grub on \
            mkpart ESP fat32 2MiB "$((2 + esp_mib))MiB" \
            set 2 esp on \
            mkpart swap linux-swap "$((2 + esp_mib))MiB" "$((2 + esp_mib + swap_mib))MiB" \
            mkpart root ext4 "$((2 + esp_mib + swap_mib))MiB" 100%
        p_esp="${IMG_LOOP_DEV}p2"
        p_swap="${IMG_LOOP_DEV}p3"
        p_root="${IMG_LOOP_DEV}p4"
    fi

    host_priv partprobe "$IMG_LOOP_DEV" 2>/dev/null || true
    sleep 2

    ui_info "Formatting partitions (ESP, swap, root)"
    host_priv mkfs.vfat -F 32 -n ESP "$p_esp"
    host_priv mkswap -L swap "$p_swap"
    host_priv mkfs.ext4 -F -L root "$p_root"

    host_priv mkdir -p "$IMG_MOUNT_DIR"
    host_priv mount "$p_root" "$IMG_MOUNT_DIR"
    host_priv mkdir -p "$IMG_MOUNT_DIR/boot/efi"
    host_priv mount "$p_esp" "$IMG_MOUNT_DIR/boot/efi"

    ui_info "Copying root filesystem to disk image"
    host_priv rsync -aHAX \
        --exclude=/root/build.sh \
        --exclude=/root/build-img.sh \
        --exclude=/root/hooks \
        --exclude="/var/cache/apt/archives/*.deb" \
        "$WORKSPACE_CHROOT/" "$IMG_MOUNT_DIR/"

    local uuid_esp uuid_swap uuid_root
    uuid_esp="$(host_priv blkid -s UUID -o value "$p_esp")"
    uuid_swap="$(host_priv blkid -s UUID -o value "$p_swap")"
    uuid_root="$(host_priv blkid -s UUID -o value "$p_root")"

    host_priv tee "$IMG_MOUNT_DIR/etc/fstab" >/dev/null <<FSTAB_EOF
UUID=${uuid_root}  /          ext4  defaults,errors=remount-ro  0 1
UUID=${uuid_esp}  /boot/efi  vfat  umask=0077  0 1
UUID=${uuid_swap}  none       swap  sw  0 0
FSTAB_EOF

    echo "$TARGET_HOSTNAME" | host_priv tee "$IMG_MOUNT_DIR/etc/hostname" >/dev/null
    host_priv tee "$IMG_MOUNT_DIR/etc/hosts" >/dev/null <<HOSTS_EOF
127.0.0.1 localhost
127.0.1.1 ${TARGET_HOSTNAME}

::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
HOSTS_EOF

    if [[ "$TARGET_PROFILE" != "desktop" ]] && [[ "$TARGET_NETWORK_STACK" == "networkd" ]]; then
        host_priv mkdir -p "$IMG_MOUNT_DIR/etc/systemd/network"
        host_priv tee "$IMG_MOUNT_DIR/etc/systemd/network/80-dhcp.network" >/dev/null <<NET_EOF
[Match]
Name=en* eth*

[Network]
DHCP=yes
NET_EOF
    fi

    if [[ "$DEB_IMAGE_KIND" == "cloud" ]]; then
        host_priv mkdir -p "$IMG_MOUNT_DIR/etc/default/grub.d"
        host_priv tee "$IMG_MOUNT_DIR/etc/default/grub.d/50-cloudimg.cfg" >/dev/null <<CLOUD_GRUB_EOF
GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0,115200"
GRUB_TIMEOUT=0
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200"
CLOUD_GRUB_EOF
    fi

    host_priv mount --bind /dev "$IMG_MOUNT_DIR/dev"
    host_priv mount --bind /dev/pts "$IMG_MOUNT_DIR/dev/pts"
    host_priv mount -t proc proc "$IMG_MOUNT_DIR/proc"
    host_priv mount -t sysfs sysfs "$IMG_MOUNT_DIR/sys"

    ui_info "Installing GRUB bootloader"
    if [[ "$firmware" == "hybrid" ]]; then
        in_target grub-install --target=i386-pc --recheck "$IMG_LOOP_DEV"
    fi
    in_target grub-install --target=x86_64-efi --efi-directory=/boot/efi \
        --bootloader-id=debian --recheck --no-nvram
    in_target grub-install --target=x86_64-efi --efi-directory=/boot/efi \
        --bootloader-id=debian --removable --recheck --no-nvram
    in_target update-initramfs -u
    in_target update-grub

    if [[ "$TARGET_USER_MODE" == "build" ]]; then
        create_baked_user
    elif [[ "$DEB_IMAGE_KIND" == "vm" ]] || [[ "$DEB_IMAGE_KIND" == "removable" ]]; then
        install_firstboot_user_wizard
    fi

    detach_image_loop

    local final_img="$OUTPUT_DIR/${TARGET_NAME}.img"
    ui_info "Moving completed image to $final_img"
    host_priv mv "$img_path" "$final_img"
    OUTPUT_FILES+=("$final_img")
    write_output_hashes "$final_img"

    if [[ "$DEB_IMAGE_KIND" == "vm" ]]; then
        export_vm_images "$final_img"
    fi

    if [[ -n "${SUDO_USER:-}" ]]; then
        local target_uid
        target_uid="$(id -u "$SUDO_USER")"
        local target_gid
        target_gid="$(id -g "$SUDO_USER")"
        host_priv chown "${target_uid}:${target_gid}" "${OUTPUT_FILES[@]}" 2>/dev/null || true
    fi

    if [[ "$ADVANCED_MODE" -eq 0 ]]; then
        host_priv rm -rf "$WORKSPACE_DIR" 2>/dev/null || true
    fi

    ui_banner "Debian Easy Build: Build Complete"
    local f
    for f in "${OUTPUT_FILES[@]}"; do
        ui_kv "Output" "$f"
    done
}

function show_help() {
    cat <<EOF
build-img.sh -- Debian disk image builder (${DEB_IMAGE_KIND}).

Usage:
  $0 [options] [start_stage] [-] [end_stage]
  $0 --generate-config
  $0 --help

Options:
  --release=stable|testing|unstable   Debian release suite (default: stable)
  --mirror=URL                        Debian APT mirror (default: http://deb.debian.org/debian/)
  --security-mirror=URL               Debian security mirror (default: http://security.debian.org/debian-security)
  --profile=desktop|cli               Image profile (default: desktop)
  --desktop=gnome|xfce|kde|mate|...   Desktop environment (default: gnome)
  --firmware=uefi|hybrid              Firmware boot target (default: uefi, removable: hybrid)
  --disk-size=GB                      Disk image capacity in GB (default: 32, removable: 16)
  --alloc-tool=truncate|fallocate|dd  File allocation method (default: truncate)
  --network=networkd|network-manager  Network stack for CLI profile (default: networkd)
  --user-mode=build|deploy            User setup mode (build=bake credentials, deploy=first boot)
  --username=USER                     Username when user-mode=build (default: user)
  --password=PASS                     Password when user-mode=build (default: debian)
  --formats=qcow2,vdi,vmdk,vhdx|all   Export formats for VM kind (default: qcow2)
  --advanced                          Enable advanced workspace mode
  --output-dir=DIR                    Directory to place output image
  --auto                              Run non-interactively [same as --no-interactive]
  --no-interactive                    Run non-interactively
  --interactive                       Force interactive prompts
  --no-confirm                        Skip confirmation prompts
  --config=FILE                       Load configuration file
  -h, --help                          Show this help

Stages:
  Host:   setup_host -> debootstrap -> run_chroot -> build_disk_image
  Chroot: chroot_prepare -> install_pkg -> finish_up
EOF
}

function host_main() {
    trap host_build_exit_trap EXIT
    trap host_abort_cleanup SIGINT SIGTERM

    local start_stage=""
    local end_stage=""
    local seen_dash=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            --release=*)
                TARGET_DEBIAN_RELEASE="${1#--release=}"
                shift
                ;;
            --mirror=*)
                TARGET_DEBIAN_MIRROR="${1#--mirror=}"
                shift
                ;;
            --security-mirror=*)
                TARGET_DEBIAN_SECURITY_MIRROR="${1#--security-mirror=}"
                shift
                ;;
            --profile=*)
                TARGET_PROFILE="${1#--profile=}"
                shift
                ;;
            --desktop=*)
                TARGET_DESKTOP="${1#--desktop=}"
                shift
                ;;
            --firmware=*)
                TARGET_FIRMWARE="${1#--firmware=}"
                shift
                ;;
            --disk-size=*)
                TARGET_DISK_SIZE_GB="${1#--disk-size=}"
                shift
                ;;
            --alloc-tool=*)
                TARGET_ALLOC_TOOL="${1#--alloc-tool=}"
                shift
                ;;
            --network=*)
                TARGET_NETWORK_STACK="${1#--network=}"
                shift
                ;;
            --user-mode=*)
                TARGET_USER_MODE="${1#--user-mode=}"
                shift
                ;;
            --username=*)
                TARGET_USERNAME="${1#--username=}"
                shift
                ;;
            --password=*)
                TARGET_PASSWORD="${1#--password=}"
                shift
                ;;
            --formats=*)
                TARGET_VM_FORMATS="${1#--formats=}"
                shift
                ;;
            --advanced)
                ADVANCED_MODE=1
                shift
                ;;
            --auto|--no-interactive)
                INTERACTIVE_OVERRIDE=0
                shift
                ;;
            --interactive)
                INTERACTIVE_OVERRIDE=1
                shift
                ;;
            --no-confirm)
                NO_CONFIRM=1
                shift
                ;;
            --output-dir=*)
                DEB_OUTPUT_DIR="${1#--output-dir=}"
                shift
                ;;
            --output-dir)
                DEB_OUTPUT_DIR="$2"
                shift 2
                ;;
            --config=*)
                local cfg="${1#--config=}"
                if [[ -f "$cfg" ]]; then
                    source "$cfg"
                fi
                shift
                ;;
            -)
                seen_dash=1
                shift
                ;;
            *)
                if [[ "$seen_dash" -eq 0 ]] && [[ -z "$start_stage" ]]; then
                    start_stage="$1"
                elif [[ -z "$end_stage" ]]; then
                    end_stage="$1"
                fi
                shift
                ;;
        esac
    done

    set_defaults
    resolve_workspace_paths

    local stages=(setup_host debootstrap run_chroot build_disk_image)
    local start_idx=0
    local end_idx=$((${#stages[@]} - 1))

    if [[ -n "$start_stage" ]]; then
        local i
        for i in "${!stages[@]}"; do
            if [[ "${stages[$i]}" == "$start_stage" ]]; then
                start_idx=$i
                break
            fi
        done
    fi

    if [[ -n "$end_stage" ]]; then
        local i
        for i in "${!stages[@]}"; do
            if [[ "${stages[$i]}" == "$end_stage" ]]; then
                end_idx=$i
                break
            fi
        done
    elif [[ "$seen_dash" -eq 0 ]] && [[ -n "$start_stage" ]]; then
        end_idx=$start_idx
    fi

    local idx
    for ((idx=start_idx; idx<=end_idx; idx++)); do
        local stage="${stages[$idx]}"
        case "$stage" in
            setup_host)       setup_host ;;
            debootstrap)      debootstrap_stage ;;
            run_chroot)       run_chroot ;;
            build_disk_image) build_disk_image ;;
        esac
    done
}

if [[ "${1:-}" == "--chroot-internal" ]]; then
    chroot_main
else
    host_main "$@"
fi
