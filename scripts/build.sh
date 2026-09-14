#!/bin/bash

set -e
set -o pipefail
set -u

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
WORKSPACE_DIR=""
WORKSPACE_CHROOT=""
WORKSPACE_IMAGE=""
OUTPUT_DIR=""
DEB_SYSTEM_WORKSPACE_PARENT="/var/cache/debian-easy-build"
HOST_ABORT_CLEANUP_DONE=0
DATE="$(TZ="UTC" date +"%y%m%d-%H%M%S")"
HOOKS_DIR=""

function ui_banner() {
    local title="$1"
    local bar="=================================================================="
    printf '\n%s\n  %s\n%s\n\n' "$bar" "$title" "$bar"
}

function ui_heading() {
    printf '\n--- %s ---\n' "$1"
}

function ui_step() {
    local n="$1" total="$2" name="$3"
    printf '\n[%d/%d] %s\n' "$n" "$total" "$name"
}

function ui_ok()   { printf '  OK    %s\n' "$1"; }
function ui_warn() { printf '  WARN  %s\n' "$1" >&2; }
function ui_err()  { printf '  ERROR %s\n' "$1" >&2; }
function ui_info() { printf '  info  %s\n' "$1"; }

function ui_kv() {
    printf '    %-24s %s\n' "$1" "$2"
}

function ui_confirm() {
    # If prompts are disabled, automatically accept the default.
    if ! prompts_enabled; then
        return 0
    fi
    local prompt="${1:-Proceed?}"
    local default="${2:-y}"
    local hint yn
    if [[ "$default" == "y" ]]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi
    while true; do
        read -r -p "  ${prompt} ${hint}: " yn
        yn="${yn,,}"
        [[ -z "$yn" ]] && yn="$default"
        case "$yn" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     echo "  Please answer y or n." ;;
        esac
    done
}

FORCE_INTERACTIVE=0

function prompts_enabled() {
    return 1
}

function assert_bool_var() {
    local name="$1" default="${2:-0}"
    local val="${!name:-$default}"
    case "$val" in
        0|1) ;;
        *)
            >&2 echo "${name} must be 0 or 1 (got: '${val}')."
            exit 1
            ;;
    esac
}

function cmd_find_index() {
    local cmd="$1" arr_name="$2" help_fn="$3"
    local -n _arr="$arr_name"
    local i
    if [[ "$cmd" == "setup_host" ]]; then
        cmd="build_workspace"
    fi
    for ((i=0; i<${#_arr[*]}; i++)); do
        if [[ "${_arr[i]}" == "$cmd" ]]; then
            index=$i
            return
        fi
    done
    "$help_fn" "Command not found: $cmd"
}

function parse_cmd_range() {
    local arr_name="$1" help_fn="$2"
    shift 2
    local -n _arr="$arr_name"

    if [[ $# == 0 ]]; then
        set -- "-"
    fi
    if [[ $# -gt 3 ]]; then
        "$help_fn"
    fi

    if [[ $# -eq 2 && "$1" != "-" && "$2" != "-" ]]; then
        cmd_find_index "$1" "$arr_name" "$help_fn"
        start_index=$index
        cmd_find_index "$2" "$arr_name" "$help_fn"
        end_index=$((index + 1))
        if [[ $end_index -le $start_index ]]; then
            "$help_fn" "Invalid range: end command '${_arr[end_index-1]}' comes before start command '${_arr[start_index]}'."
        fi
        return
    fi

    local dash_flag=false
    start_index=0
    end_index=${#_arr[*]}
    local ii
    for ii in "$@"; do
        if [[ $ii == "-" ]]; then
            dash_flag=true
            continue
        fi
        cmd_find_index "$ii" "$arr_name" "$help_fn"
        if [[ $dash_flag == false ]]; then
            start_index=$index
        else
            end_index=$((index + 1))
        fi
    done
    if [[ $dash_flag == false ]]; then
        end_index=$((start_index + 1))
    fi
    if [[ $end_index -le $start_index ]]; then
        "$help_fn" "Invalid range: end command '${_arr[end_index-1]}' comes before start command '${_arr[start_index]}'."
    fi
}

HOST_CMD=(build_workspace debootstrap run_chroot build_iso)
CHROOT_CMD=(chroot_prepare install_pkg build_image finish_up)

function host_priv() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

SUDO_KEEPALIVE_PID=""

function setup_sudo_keepalive() {
    if [[ "${LAUNCHED_FROM_START_HERE:-0}" -eq 1 ]] || [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    echo "=====> Requesting sudo credentials ..."
    if ! sudo -v; then
        >&2 echo "ERROR: Failed to obtain sudo credentials. The build requires sudo access."
        exit 1
    fi
    (while sudo -v -n 2>/dev/null; do sleep 60; done) &
    SUDO_KEEPALIVE_PID=$!
}

function cleanup_sudo_keepalive() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    SUDO_KEEPALIVE_PID=""
}

function run_hooks() {
    local subdir="$1"
    local hooks_base="${HOOKS_DIR:-$SCRIPT_DIR/hooks}"
    local hooks_path="$hooks_base/$subdir"

    if [[ ! -d "$hooks_path" ]]; then
        return 0
    fi

    local hook_files=()
    local prev_nullglob
    prev_nullglob="$(shopt -p nullglob || true)"
    shopt -s nullglob
    hook_files=("$hooks_path"/*.sh)
    eval "$prev_nullglob"

    if [[ ${#hook_files[@]} -eq 0 ]]; then
        return 0
    fi

    echo "=====> Loading hooks: $subdir (${#hook_files[@]} found)"
    local i=0
    for f in "${hook_files[@]}"; do
        i=$((i + 1))
        local name
        name="$(basename "$f")"
        if [[ ! -x "$f" ]]; then
            echo "  WARN  [hook $i/${#hook_files[@]}] $name skipped (not executable)"
            continue
        fi
        echo "  info  [hook $i/${#hook_files[@]}] Loading: $name"
        bash -e "$f"
        echo "  OK    [hook $i/${#hook_files[@]}] $name"
    done
}

function run_pre_chroot_hooks() {
    run_hooks pre-chroot
}

function run_chroot_hooks() {
    run_hooks chroot
}

function default_target_package_remove() {
    echo "calamares casper caper discover laptop-detect os-prober"
}

function set_defaults() {
    export DEBIAN_RELEASE="${DEBIAN_RELEASE:-stable}"
    export DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian/}"
    export DEBIAN_SECURITY_MIRROR="${DEBIAN_SECURITY_MIRROR:-http://security.debian.org/debian-security}"
    export DEBIAN_COMPONENTS="${DEBIAN_COMPONENTS:-main contrib non-free non-free-firmware}"
    export TARGET_KERNEL_PACKAGE="${TARGET_KERNEL_PACKAGE:-linux-image-amd64}"
    export TARGET_INSTALLER="${TARGET_INSTALLER:-calamares}"
    export TARGET_DESKTOP="${TARGET_DESKTOP:-xfce}"
    export TARGET_KDE_PACKAGE="${TARGET_KDE_PACKAGE:-kde-standard}"
    export TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
    if ! prompts_enabled; then
        export TARGET_WEB_SERVER="${TARGET_WEB_SERVER:-0}"
        export TARGET_SSH_SERVER="${TARGET_SSH_SERVER:-0}"
        export TARGET_COCKPIT="${TARGET_COCKPIT:-0}"
        export TARGET_LAPTOP="${TARGET_LAPTOP:-0}"
        export TARGET_PACSTALL="${TARGET_PACSTALL:-0}"
        export TARGET_DEB_MULTIMEDIA="${TARGET_DEB_MULTIMEDIA:-0}"
        export TARGET_DEB_MULTIMEDIA_PACKAGES="${TARGET_DEB_MULTIMEDIA_PACKAGES:-0}"
    fi
    export TARGET_FWUPD=0
    export TARGET_BROWSER="none"
    export TARGET_BRAVE_CHANNEL="none"
    export TARGET_LIBREWOLF=0
    export TARGET_FIREFOX=0
    export TARGET_FIREFOX_ESR=0
    export TARGET_THUNDERBIRD=0
    export TARGET_CHROMIUM=0
    export TARGET_NAME="${TARGET_NAME:-}"
    export GRUB_LIVEBOOT_LABEL="${GRUB_LIVEBOOT_LABEL:-Try Debian before installing}"
    export GRUB_TTY_ONLY="${GRUB_TTY_ONLY:-0}"
    export CAPER_SRC_DIR="${CAPER_SRC_DIR:-/home/jimedrand/Git/caper}"
    export CAPER_DEB_PATH="${CAPER_DEB_PATH:-}"
    export CAPER_DEB_DIR="${CAPER_DEB_DIR:-$REPO_ROOT/caper-deb}"
}

function set_installer_and_manifest_defaults() {
    export TARGET_WEB_SERVER="${TARGET_WEB_SERVER:-0}"
    export TARGET_SSH_SERVER="${TARGET_SSH_SERVER:-0}"
    export TARGET_COCKPIT="${TARGET_COCKPIT:-0}"
    export TARGET_LAPTOP="${TARGET_LAPTOP:-0}"
    export TARGET_PACSTALL="${TARGET_PACSTALL:-0}"
    export TARGET_DEB_MULTIMEDIA="${TARGET_DEB_MULTIMEDIA:-0}"
    export TARGET_DEB_MULTIMEDIA_PACKAGES="${TARGET_DEB_MULTIMEDIA_PACKAGES:-0}"
    export TARGET_INSTALLER="${TARGET_INSTALLER:-calamares}"
    case "${TARGET_INSTALLER}" in
        calamares) ;;
        *)
            >&2 echo "TARGET_INSTALLER must be calamares (got: '${TARGET_INSTALLER}')."
            exit 1
            ;;
    esac
    export TARGET_PACKAGE_REMOVE="${TARGET_PACKAGE_REMOVE:-$(default_target_package_remove)}"
}

function normalize_release() {
    case "${1,,}" in
        stable)       echo "stable" ;;
        testing)      echo "testing" ;;
        unstable|sid) echo "unstable" ;;
        *)            echo "$1" ;;
    esac
}

function assert_supported_release() {
    local rel
    rel="$(normalize_release "${DEBIAN_RELEASE:-}")"
    case "$rel" in
        stable|testing|unstable)
            export DEBIAN_RELEASE="$rel"
            return 0
            ;;
        *)
            >&2 echo "DEBIAN_RELEASE must be stable, testing, or unstable (got: '${DEBIAN_RELEASE:-}')."
            return 1
            ;;
    esac
}

function normalize_desktop_variant() {
    case "${TARGET_DESKTOP:-xfce}" in
        desktop|gnome|xfce|gnome-flashback|kde|kde-plasma|cinnamon|mate|lxde|lxqt|lomiri|lomiri-tablet|phosh|none|cli) ;;
        *)
            >&2 echo "TARGET_DESKTOP must be desktop, gnome, xfce, gnome-flashback, kde-plasma, cinnamon, mate, lxde, lxqt, lomiri, lomiri-tablet, phosh, or none (got: '${TARGET_DESKTOP:-}')."
            exit 1
            ;;
    esac
}

function block_snapd() {
    echo "=====> Blocking snapd via APT pinning ..."
    install -d /etc/apt/preferences.d
    cat <<'EOF' > /etc/apt/preferences.d/no-snapd.pref
Package: snapd snapd:* gnome-software-plugin-snap
Pin: release *
Pin-Priority: -1
EOF
}

function block_fwupd() {
    install -d /etc/apt/preferences.d
    cat <<'EOF' > /etc/apt/preferences.d/no-fwupd.pref
Package: fwupd fwupd:*
Pin: release *
Pin-Priority: -1
EOF
}

function resolve_workspace_paths() {
    local target_ws="${DEBIAN_WORKSPACE:-}"
    local default_ws="$DEB_SYSTEM_WORKSPACE_PARENT"
    WORKSPACE_DIR="${target_ws:-$default_ws}"
    WORKSPACE_CHROOT="$WORKSPACE_DIR/chroot"
    WORKSPACE_IMAGE="$WORKSPACE_DIR/image"

    local user_home
    user_home="$(eval echo "~${SUDO_USER:-$USER}")"
    OUTPUT_DIR="${DEB_OUTPUT_DIR:-$user_home}"
}

function chroot_exit_teardown() {
    [[ -z "${WORKSPACE_CHROOT:-}" ]] && return 0
    local _mp _rc
    for _mp in "$WORKSPACE_CHROOT/dev/pts" "$WORKSPACE_CHROOT/proc" "$WORKSPACE_CHROOT/sys" "$WORKSPACE_CHROOT/run" "$WORKSPACE_CHROOT/dev"; do
        if mountpoint -q "$_mp" 2>/dev/null; then
            _rc=0
            host_priv umount -l "$_mp" 2>/dev/null || _rc=$?
            if [[ $_rc -ne 0 ]]; then
                echo "  WARN  umount -l '$_mp' failed (exit $_rc); mount may be stale" >&2
            fi
        fi
    done
}

function clean_workspace() {
    chroot_exit_teardown || true
    if [[ -d "$WORKSPACE_DIR" ]]; then
        echo "=====> Cleaning workspace: $WORKSPACE_DIR"
        host_priv rm -rf "$WORKSPACE_DIR"
    fi
}

function host_abort_cleanup() {
    if [[ "${HOST_ABORT_CLEANUP_DONE:-0}" -eq 1 ]]; then
        return 0
    fi
    HOST_ABORT_CLEANUP_DONE=1
    chroot_exit_teardown || true
    echo "=====> unmounting chroot bind mounts and removing workspace ..." >&2
    if [[ -n "${WORKSPACE_DIR:-}" ]]; then
        clean_workspace || true
    fi
}

function host_build_exit_trap() {
    local _st=$?
    cleanup_sudo_keepalive || true
    if [[ "$_st" -ne 0 ]] && [[ "${HOST_ABORT_CLEANUP_DONE:-0}" -eq 0 ]]; then
        host_abort_cleanup
    fi
    exit "$_st"
}

function host_build_signal_trap() {
    local code="$1"
    if [[ "${HOST_ABORT_CLEANUP_DONE:-0}" -eq 1 ]]; then
        exit "$code"
    fi
    host_abort_cleanup
    exit "$code"
}

function ensure_workspace_root() {
    host_priv mkdir -p "$WORKSPACE_DIR"
}

function ensure_output_dir() {
    mkdir -p "$OUTPUT_DIR"
}

function write_iso_hashes() {
    pushd "$OUTPUT_DIR" >/dev/null
    echo "=====> Calculating SHA1 and SHA256 hashes ..."
    sha1sum "$TARGET_NAME.iso" > "$TARGET_NAME.iso.sha1"
    sha256sum "$TARGET_NAME.iso" > "$TARGET_NAME.iso.sha256"
    popd >/dev/null
}

function fix_output_ownership() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        local user_group
        user_group="$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")"
        chown "$SUDO_USER:$user_group"             "$OUTPUT_DIR/$TARGET_NAME.iso"             "$OUTPUT_DIR/$TARGET_NAME.iso.sha1"             "$OUTPUT_DIR/$TARGET_NAME.iso.sha256" 2>/dev/null || true
    fi
}

function check_settings() {
    assert_supported_release || exit 1
    normalize_desktop_variant
    if [[ ! "${DEBIAN_MIRROR:-}" =~ ^https?://[^[:space:]]+$ ]]; then
        >&2 echo "DEBIAN_MIRROR must be a valid http:// or https:// URL (got: '${DEBIAN_MIRROR:-}')."
        exit 1
    fi
    if [[ ! "${DEBIAN_SECURITY_MIRROR:-}" =~ ^https?://[^[:space:]]+$ ]]; then
        >&2 echo "DEBIAN_SECURITY_MIRROR must be a valid http:// or https:// URL (got: '${DEBIAN_SECURITY_MIRROR:-}')."
        exit 1
    fi
    assert_bool_var TARGET_GNOME_INSTALL_RECOMMENDS
    case "${TARGET_KDE_PACKAGE:-kde-standard}" in
        kde-full|kde-standard|kde-plasma-desktop) ;;
        *)
            >&2 echo "TARGET_KDE_PACKAGE must be kde-full, kde-standard, or kde-plasma-desktop (got: '${TARGET_KDE_PACKAGE:-}')."
            exit 1
            ;;
    esac
    case "${TARGET_BRAVE_CHANNEL:-none}" in
        none|release|origin) ;;
        *)
            >&2 echo "TARGET_BRAVE_CHANNEL must be none, release, or origin (got: '${TARGET_BRAVE_CHANNEL:-}')."
            exit 1
            ;;
    esac
    assert_bool_var TARGET_LIBREWOLF
    assert_bool_var TARGET_FIREFOX
    assert_bool_var TARGET_FIREFOX_ESR
    assert_bool_var TARGET_THUNDERBIRD
    assert_bool_var TARGET_CHROMIUM
    assert_bool_var TARGET_PACSTALL
    assert_bool_var TARGET_FWUPD
    assert_bool_var TARGET_OPENSSH_SERVER
    assert_bool_var TARGET_COCKPIT
    assert_bool_var TARGET_WEB_SERVER
    assert_bool_var TARGET_SSH_SERVER
    assert_bool_var TARGET_LAPTOP
    if [[ "${TARGET_DESKTOP:-}" == "mate" ]]; then
        case "${TARGET_MATE_PACKAGE:-mate-desktop-environment}" in
            full) export TARGET_MATE_PACKAGE="mate-desktop-environment" ;;
            core) export TARGET_MATE_PACKAGE="mate-desktop-environment-core" ;;
        esac
        assert_bool_var TARGET_MATE_EXTRAS
    fi
}

function host_help() {
    if [ -z "${1+x}" ]; then
        echo "This script builds a bootable Debian live ISO image."
        echo
    else
        echo "$1"
        echo
    fi
    echo "Usage: $0 [options] [start_cmd] [-] [end_cmd]"
    echo
    echo "Host commands:"
    echo "  build_workspace  Create and initialize the build workspace directory"
    echo "  debootstrap      Bootstrap minimal Debian base"
    echo "  run_chroot       Run customization inside chroot"
    echo "  build_iso        Compress chroot and assemble bootable hybrid ISO"
    echo
    echo "Options:"
    echo "  --release=REL    Debian suite (stable | testing | unstable) [default: stable]"
    echo "  --mirror=URL     Debian mirror URL [default: http://deb.debian.org/debian/]"
    echo "  --security-mirror=URL Debian security mirror [default: http://security.debian.org/debian-security]"
    echo "  --kernel=PKG     Kernel metapackage [default: linux-image-amd64]"
    echo "  --desktop=DE     Desktop environment: xfce, kde-plasma, gnome, gnome-flashback,"
    echo "                   cinnamon, mate, lxde, lxqt, lomiri, lomiri-tablet, phosh,"
    echo "                   task-desktop, none [default: xfce]"
    echo "  --installer=INST Installer engine (calamares) [default: calamares]"
    echo "  --deb-multimedia Enable deb-multimedia repository (http://www.deb-multimedia.org/)"
    echo "  --no-deb-multimedia Skip deb-multimedia repository [default]"
    echo "  --deb-multimedia-packages Install codecs, multimedia player, and tools"
    echo "  --no-deb-multimedia-packages Skip deb-multimedia packages [default]"
    echo "  --multimedia-tools Enable deb-multimedia repo and install packages"
    echo "  --web-server     Pre-install web server task (task-web-server)"
    echo "  --ssh-server     Pre-install SSH server task (task-ssh-server)"
    echo "  --cockpit        Pre-install Cockpit web console"
    echo "  --laptop         Pre-install laptop support task (task-laptop)"
    echo "  --pacstall       Pre-install Pacstall package manager"
    echo "  --caper-src=DIR  Directory containing Caper source code"
    echo "  --caper-deb=PATH Pre-built Caper deb file"
    echo "  --target-name=N  Output base ISO name"
    echo "  --grub-label=TEXT Live boot entry label [default: \"Try Debian before installing\"]"
    echo "  --grub-tty-only   Generate CLI/TTY-only GRUB boot configuration"
    echo "  --no-interactive Run non-interactively"
    echo "  --config=FILE    Load configuration file"
    echo "  --generate-config Generate configuration file"
    echo "  -h, --help       Show this help"
    exit 1
}

function resolve_release_choice() {
    if [[ -n "${DEBIAN_RELEASE:-}" ]] && ! prompts_enabled; then
        DEBIAN_RELEASE="$(normalize_release "$DEBIAN_RELEASE")"
        ui_ok "DEBIAN_RELEASE=$DEBIAN_RELEASE"
        return 0
    fi

    if prompts_enabled; then
        ui_heading "Debian Release"
        echo "  1) stable    Tracks the latest Debian Stable release [default]"
        echo "  2) testing   Tracks the upcoming Debian Testing release"
        echo "  3) unstable  Tracks Debian Unstable (sid)"
        local choice
        while true; do
            read -r -p "  Release [1/2/3, Enter=1]: " choice
            case "${choice,,}" in
                ""|1|s|stable)
                    export DEBIAN_RELEASE="stable"
                    break
                    ;;
                2|t|testing)
                    export DEBIAN_RELEASE="testing"
                    break
                    ;;
                3|u|unstable|sid)
                    export DEBIAN_RELEASE="unstable"
                    break
                    ;;
                *)
                    echo "  Invalid selection: '${choice}'."
                    ;;
            esac
        done
        ui_ok "DEBIAN_RELEASE=$DEBIAN_RELEASE"
    else
        export DEBIAN_RELEASE="stable"
        ui_ok "DEBIAN_RELEASE=$DEBIAN_RELEASE"
    fi
}

function resolve_mirror_choice() {
    if [[ -n "${DEBIAN_MIRROR:-}" ]] && ! prompts_enabled; then
        ui_ok "DEBIAN_MIRROR=$DEBIAN_MIRROR"
        return 0
    fi

    if prompts_enabled; then
        ui_heading "Debian Mirror"
        echo "  Default: http://deb.debian.org/debian/"
        local choice
        read -r -p "  Enter mirror URL [Enter for default]: " choice
        if [[ -n "$choice" ]]; then
            export DEBIAN_MIRROR="$choice"
        else
            export DEBIAN_MIRROR="http://deb.debian.org/debian/"
        fi
        ui_ok "DEBIAN_MIRROR=$DEBIAN_MIRROR"
    else
        export DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian/}"
        ui_ok "DEBIAN_MIRROR=$DEBIAN_MIRROR"
    fi
}

function resolve_desktop_selection() {
    if [[ -n "${TARGET_DESKTOP:-}" ]] && ! prompts_enabled; then
        normalize_desktop_variant
        ui_ok "TARGET_DESKTOP=$TARGET_DESKTOP"
        return 0
    fi

    if prompts_enabled; then
        ui_heading "Desktop Environment"
        echo "  1) XFCE                      task-xfce-desktop [default]"
        echo "  2) KDE Plasma                task-kde-desktop"
        echo "  3) GNOME                     task-gnome-desktop"
        echo "  4) GNOME Flashback           task-gnome-flashback-desktop"
        echo "  5) Cinnamon                  task-cinnamon-desktop"
        echo "  6) MATE                      task-mate-desktop"
        echo "  7) LXDE                      task-lxde-desktop"
        echo "  8) LXQt                      task-lxqt-desktop"
        echo "  9) Lomiri                    task-lomiri-desktop"
        echo "  10) Lomiri Tablet            task-lomiri-tablet"
        echo "  11) Phosh                    task-phosh-desktop"
        echo "  12) Standard Desktop         task-desktop"
        echo "  13) None                     CLI only (no desktop stack)"
        local choice
        while true; do
            read -r -p "  Desktop [1-13, Enter=1]: " choice
            case "${choice,,}" in
                ""|1|xfce)                   export TARGET_DESKTOP="xfce";                   break ;;
                2|kde|plasma|kde-plasma)     export TARGET_DESKTOP="kde-plasma";             break ;;
                3|gnome)                     export TARGET_DESKTOP="gnome";                  break ;;
                4|flashback|gnome-flashback) export TARGET_DESKTOP="gnome-flashback";        break ;;
                5|cinnamon)                  export TARGET_DESKTOP="cinnamon";               break ;;
                6|mate)                      export TARGET_DESKTOP="mate";                   break ;;
                7|lxde)                      export TARGET_DESKTOP="lxde";                   break ;;
                8|lxqt)                      export TARGET_DESKTOP="lxqt";                   break ;;
                9|lomiri)                    export TARGET_DESKTOP="lomiri";                 break ;;
                10|lomiri-tablet)            export TARGET_DESKTOP="lomiri-tablet";          break ;;
                11|phosh)                    export TARGET_DESKTOP="phosh";                  break ;;
                12|standard|task-desktop)    export TARGET_DESKTOP="task-desktop";           break ;;
                13|none|cli)                 export TARGET_DESKTOP="none";                   break ;;
                *) echo "  Invalid selection: '${choice}'." ;;
            esac
        done
        ui_ok "TARGET_DESKTOP=$TARGET_DESKTOP"
    else
        export TARGET_DESKTOP="xfce"
        ui_ok "TARGET_DESKTOP=$TARGET_DESKTOP"
    fi
}

function interactive_toggle_pick() {
    local var_name="$1" heading="$2" install_label="$3" skip_label="$4" prompt_label="$5"

    # When prompts are disabled, fall back to environment variable value or default to 0.
    if ! prompts_enabled; then
        # Use existing env var if set, otherwise default to 0 (disabled).
        if [[ -z "${!var_name}" ]]; then
            export "$var_name"="0"
        else
            export "$var_name"="${!var_name}"
        fi
        ui_ok "${var_name}=${!var_name} (auto)"
        return
    fi

    ui_heading "$heading"
    echo "    1) ${install_label}"
    echo "    2) ${skip_label}  [default]"

    local choice
    while true; do
        read -r -p "  ${prompt_label} [1/2, Enter=2]: " choice
        case "${choice,,}" in
            ""|2|n|no|off|skip|s|none)
                export "$var_name"="0"
                break
                ;;
            1|y|yes|install|pre|on)
                export "$var_name"="1"
                break
                ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "${var_name}=${!var_name}"
}

function resolve_browser_selection() {
    export TARGET_BRAVE_CHANNEL="none"
    export TARGET_LIBREWOLF=0
    export TARGET_FIREFOX=0
    export TARGET_FIREFOX_ESR=0
    export TARGET_THUNDERBIRD=0
    export TARGET_CHROMIUM=0
}

function resolve_pacstall_choice() {
    if [[ -n "${TARGET_PACSTALL+x}" ]]; then
        export TARGET_PACSTALL="${TARGET_PACSTALL:-0}"
        return 0
    fi

    if prompts_enabled; then
        interactive_toggle_pick TARGET_PACSTALL \
            "Pacstall" \
            "Install Pacstall (AUR-like package manager for Debian/Ubuntu from https://pacstall.dev)" \
            "Skip Pacstall" \
            "Pacstall"
    else
        export TARGET_PACSTALL=0
    fi
}

function resolve_deb_multimedia_choices() {
    if [[ -z "${TARGET_DEB_MULTIMEDIA+x}" ]]; then
        if prompts_enabled; then
            interactive_toggle_pick TARGET_DEB_MULTIMEDIA \
                "Deb-multimedia repository" \
                "Enable deb-multimedia repository (http://www.deb-multimedia.org/)" \
                "Skip deb-multimedia repository" \
                "Deb-multimedia"
        else
            export TARGET_DEB_MULTIMEDIA=0
        fi
    fi

    if [[ "${TARGET_DEB_MULTIMEDIA:-0}" == "1" ]]; then
        if [[ -z "${TARGET_DEB_MULTIMEDIA_PACKAGES+x}" ]]; then
            if prompts_enabled; then
                interactive_toggle_pick TARGET_DEB_MULTIMEDIA_PACKAGES \
                    "Deb-multimedia codecs and tools" \
                    "Install codecs, multimedia player, and tools (ffmpeg, libdvdcss2, gstreamer, mpv)" \
                    "Skip multimedia packages (repository only)" \
                    "Multimedia packages"
            else
                export TARGET_DEB_MULTIMEDIA_PACKAGES=0
            fi
        fi
    else
        export TARGET_DEB_MULTIMEDIA_PACKAGES=0
    fi

    export TARGET_DEB_MULTIMEDIA="${TARGET_DEB_MULTIMEDIA:-0}"
    export TARGET_DEB_MULTIMEDIA_PACKAGES="${TARGET_DEB_MULTIMEDIA_PACKAGES:-0}"
}

function resolve_optional_service_choices() {
    export TARGET_FWUPD=0

    if [[ -z "${TARGET_WEB_SERVER+x}" ]]; then
        if prompts_enabled; then
            interactive_toggle_pick TARGET_WEB_SERVER \
                "Web server (Apache task-web-server)" \
                "Pre-install web server task" \
                "Skip web server" \
                "Web server"
        else
            export TARGET_WEB_SERVER=0
        fi
    fi

    if [[ -z "${TARGET_SSH_SERVER+x}" ]]; then
        if prompts_enabled; then
            interactive_toggle_pick TARGET_SSH_SERVER \
                "SSH server (task-ssh-server)" \
                "Pre-install SSH server task" \
                "Skip SSH server" \
                "SSH server"
        else
            export TARGET_SSH_SERVER=0
        fi
    fi

    if [[ -z "${TARGET_COCKPIT+x}" ]]; then
        if prompts_enabled; then
            interactive_toggle_pick TARGET_COCKPIT \
                "Cockpit (web admin console)" \
                "Pre-install cockpit" \
                "Skip Cockpit" \
                "Cockpit"
        else
            export TARGET_COCKPIT=0
        fi
    fi

    if [[ -z "${TARGET_LAPTOP+x}" ]]; then
        if prompts_enabled; then
            interactive_toggle_pick TARGET_LAPTOP \
                "Laptop support (task-laptop)" \
                "Pre-install laptop support task" \
                "Skip laptop support" \
                "Laptop support"
        else
            export TARGET_LAPTOP=0
        fi
    fi

    export TARGET_WEB_SERVER="${TARGET_WEB_SERVER:-0}"
    export TARGET_SSH_SERVER="${TARGET_SSH_SERVER:-0}"
    export TARGET_COCKPIT="${TARGET_COCKPIT:-0}"
    export TARGET_LAPTOP="${TARGET_LAPTOP:-0}"
}

function review_settings_and_confirm() {
    ui_heading "Build Summary"
    ui_kv "Debian Release"     "${DEBIAN_RELEASE}"
    ui_kv "Mirror"             "${DEBIAN_MIRROR}"
    if [[ "${DEBIAN_RELEASE}" != "unstable" && "${DEBIAN_RELEASE}" != "sid" ]]; then
        ui_kv "Security Mirror"    "${DEBIAN_SECURITY_MIRROR}"
    fi
    ui_kv "Kernel"             "${TARGET_KERNEL_PACKAGE}"
    ui_kv "Desktop"            "${TARGET_DESKTOP}"
    if [[ "${TARGET_DESKTOP}" == "none" ]]; then
        ui_kv "Installer"          "cli-installer"
    else
        ui_kv "Installer"          "calamares and cli-installer"
    fi
    ui_kv "Web server"         "${TARGET_WEB_SERVER:-0}"
    ui_kv "SSH server"         "${TARGET_SSH_SERVER:-0}"
    ui_kv "Cockpit"            "${TARGET_COCKPIT:-0}"
    ui_kv "Laptop support"     "${TARGET_LAPTOP:-0}"
    ui_kv "Deb-multimedia"     "${TARGET_DEB_MULTIMEDIA:-0} (codecs/tools: ${TARGET_DEB_MULTIMEDIA_PACKAGES:-0})"
    ui_kv "Pacstall"           "${TARGET_PACSTALL:-0}"
    ui_kv "Snapd Policy"       "Blocked (APT priority -1)"
    ui_kv "Flatpak"            "Mandatory"
    ui_kv "Workspace"          "${WORKSPACE_DIR}"
    ui_kv "Output Directory"   "${OUTPUT_DIR}"
    echo

    if [[ "${NO_CONFIRM:-0}" == "1" ]] || ! prompts_enabled; then
        return 0
    fi

    if ! ui_confirm "Ready to start the build?" y; then
        echo "Build cancelled by user."
        exit 0
    fi
}

function load_config_file() {
    local config_path="$1"
    if [[ ! -f "$config_path" ]]; then
        ui_err "Config file not found: $config_path"
        exit 1
    fi
    ui_info "Loading config: $config_path"
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        line="${line%%[[:space:]]\#*}"
        if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val#\"}" ; val="${val%\"}"
            val="${val#\'}" ; val="${val%\'}"
            val="${val## }" ; val="${val%% }"
            case "$key" in
                DEBIAN_RELEASE|DEBIAN_MIRROR|DEBIAN_SECURITY_MIRROR|DEBIAN_COMPONENTS|\
                TARGET_KERNEL_PACKAGE|TARGET_DESKTOP|TARGET_KDE_PACKAGE|\
                TARGET_MATE_PACKAGE|TARGET_MATE_EXTRAS|TARGET_BROWSER|\
                TARGET_BRAVE_CHANNEL|TARGET_LIBREWOLF|TARGET_FIREFOX|\
                TARGET_FIREFOX_ESR|TARGET_THUNDERBIRD|TARGET_CHROMIUM|\
                TARGET_PACSTALL|TARGET_FWUPD|TARGET_OPENSSH_SERVER|TARGET_COCKPIT|\
                TARGET_WEB_SERVER|TARGET_SSH_SERVER|TARGET_LAPTOP|\
                TARGET_DEB_MULTIMEDIA|TARGET_DEB_MULTIMEDIA_PACKAGES|\
                TARGET_GNOME_INSTALL_RECOMMENDS|TARGET_NAME|\
                TARGET_LOCALE|TARGET_KEYBOARD_LAYOUT|TARGET_KEYBOARD_VARIANT|\
                TARGET_INSTALLER|TARGET_PACKAGE_REMOVE|\
                GRUB_LIVEBOOT_LABEL|GRUB_TTY_ONLY|WORKSPACE_PARENT|OUTPUT_DIR|NO_CONFIRM|\
                INTERACTIVE|HOOKS_DIR|CAPER_SRC_DIR|CAPER_DEB_PATH)
                    export "$key=$val"
                    ;;
                *)
                    ui_warn "Config: ignoring unknown key '$key'"
                    ;;
            esac
        fi
    done < "$config_path"
}

function generate_config_wizard() {
    ui_heading "Generate Configuration File"
    local out_file="${SCRIPT_DIR}/build.cfg"
    if [[ -f "$out_file" ]]; then
        if ! ui_confirm "Overwrite existing $out_file?" n; then
            echo "Aborted."
            exit 0
        fi
    fi

    cat <<EOF > "$out_file"
DEBIAN_RELEASE=stable
DEBIAN_MIRROR=http://deb.debian.org/debian/
DEBIAN_SECURITY_MIRROR=http://security.debian.org/debian-security
DEBIAN_COMPONENTS="main contrib non-free non-free-firmware"
TARGET_KERNEL_PACKAGE=linux-image-amd64
TARGET_INSTALLER=calamares
TARGET_DESKTOP=xfce
TARGET_KDE_PACKAGE=kde-standard
TARGET_MATE_PACKAGE=mate-desktop-environment
TARGET_MATE_EXTRAS=0
TARGET_GNOME_INSTALL_RECOMMENDS=0
TARGET_BROWSER=none
TARGET_BRAVE_CHANNEL=none
TARGET_LIBREWOLF=0
TARGET_FIREFOX=0
TARGET_FIREFOX_ESR=0
TARGET_THUNDERBIRD=0
TARGET_CHROMIUM=0
TARGET_PACSTALL=0
TARGET_FWUPD=0
TARGET_COCKPIT=0
TARGET_WEB_SERVER=0
TARGET_SSH_SERVER=0
TARGET_LAPTOP=0
TARGET_DEB_MULTIMEDIA=0
TARGET_DEB_MULTIMEDIA_PACKAGES=0
TARGET_LOCALE=en_US.UTF-8
TARGET_KEYBOARD_LAYOUT=us
TARGET_KEYBOARD_VARIANT=
TARGET_NAME=
GRUB_LIVEBOOT_LABEL="Try Debian before installing"
GRUB_TTY_ONLY=0
WORKSPACE_PARENT=
OUTPUT_DIR=
HOOKS_DIR=
INTERACTIVE=0
NO_CONFIRM=0
CAPER_SRC_DIR=/home/jimedrand/Git/caper
CAPER_DEB_PATH=
EOF
    ui_ok "Configuration generated at: $out_file"
    exit 0
}

function parse_host_cli_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --release=*)         export DEBIAN_RELEASE="${1#--release=}" ;;
            --mirror=*)          export DEBIAN_MIRROR="${1#--mirror=}" ;;
            --security-mirror=*) export DEBIAN_SECURITY_MIRROR="${1#--security-mirror=}" ;;
            --kernel=*)          export TARGET_KERNEL_PACKAGE="${1#--kernel=}" ;;
            --desktop=*)       export TARGET_DESKTOP="${1#--desktop=}" ;;
            --installer=*)     export TARGET_INSTALLER="${1#--installer=}" ;;
            --caper-src=*)     export CAPER_SRC_DIR="${1#--caper-src=}" ;;
            --caper-deb=*)     export CAPER_DEB_PATH="${1#--caper-deb=}" ;;
            --firefox-esr)     export TARGET_FIREFOX_ESR=1 ;;
            --no-firefox-esr)  export TARGET_FIREFOX_ESR=0 ;;
            --firefox)         export TARGET_FIREFOX=1 ;;
            --no-firefox)      export TARGET_FIREFOX=0 ;;
            --thunderbird)     export TARGET_THUNDERBIRD=1 ;;
            --no-thunderbird)  export TARGET_THUNDERBIRD=0 ;;
            --chromium)        export TARGET_CHROMIUM=1 ;;
            --no-chromium)     export TARGET_CHROMIUM=0 ;;
            --brave=*)         export TARGET_BRAVE_CHANNEL="${1#--brave=}" ;;
            --browser=*)       export TARGET_BRAVE_CHANNEL="${1#--browser=}" ;;
            --librewolf)       export TARGET_LIBREWOLF=1 ;;
            --no-librewolf)    export TARGET_LIBREWOLF=0 ;;
            --pacstall)        export TARGET_PACSTALL=1 ;;
            --no-pacstall)     export TARGET_PACSTALL=0 ;;
            --fwupd)           export TARGET_FWUPD=1 ;;
            --no-fwupd)        export TARGET_FWUPD=0 ;;
            --openssh)         export TARGET_SSH_SERVER=1 ;;
            --no-openssh)      export TARGET_SSH_SERVER=0 ;;
            --openssh-server)  export TARGET_SSH_SERVER=1 ;;
            --no-openssh-server) export TARGET_SSH_SERVER=0 ;;
            --ssh-server)      export TARGET_SSH_SERVER=1 ;;
            --no-ssh-server)   export TARGET_SSH_SERVER=0 ;;
            --web-server)      export TARGET_WEB_SERVER=1 ;;
            --no-web-server)   export TARGET_WEB_SERVER=0 ;;
            --laptop)          export TARGET_LAPTOP=1 ;;
            --no-laptop)       export TARGET_LAPTOP=0 ;;
            --cockpit)         export TARGET_COCKPIT=1 ;;
            --no-cockpit)      export TARGET_COCKPIT=0 ;;
            --deb-multimedia)          export TARGET_DEB_MULTIMEDIA=1 ;;
            --no-deb-multimedia)       export TARGET_DEB_MULTIMEDIA=0 ;;
            --deb-multimedia-packages) export TARGET_DEB_MULTIMEDIA_PACKAGES=1 ;;
            --no-deb-multimedia-packages) export TARGET_DEB_MULTIMEDIA_PACKAGES=0 ;;
            --multimedia-tools)        export TARGET_DEB_MULTIMEDIA=1 TARGET_DEB_MULTIMEDIA_PACKAGES=1 ;;
            --target-name=*)   export TARGET_NAME="${1#--target-name=}" ;;
            --grub-label=*)    export GRUB_LIVEBOOT_LABEL="${1#--grub-label=}" ;;
            --grub-tty-only)   export GRUB_TTY_ONLY=1 ;;
            --workspace=*)     export DEBIAN_WORKSPACE="${1#--workspace=}" ;;
            --output-dir=*)    export DEB_OUTPUT_DIR="${1#--output-dir=}" ;;
            --no-interactive)  FORCE_INTERACTIVE=0 ;;
            --interactive)     FORCE_INTERACTIVE=1 ;;
            --no-confirm)      export NO_CONFIRM=1 ;;
            --config=*)        load_config_file "${1#--config=}" ;;
            --generate-config) generate_config_wizard ;;
            -h|--help)         host_help ;;
            --)                shift; break ;;
            -*)
                ui_err "Unknown option: $1"
                host_help
                ;;
            *)
                break
                ;;
        esac
        shift
    done
    REMAINING_ARGS=("$@")
}

function host_stage_build_workspace() {
    ui_step 1 4 "Build workspace directory"
    resolve_workspace_paths
    ensure_workspace_root
    run_pre_chroot_hooks
}

function host_stage_setup_host() {
    host_stage_build_workspace
}

function host_stage_debootstrap() {
    ui_step 2 4 "Debootstrap Debian (${DEBIAN_RELEASE})"
    ensure_workspace_root
    chroot_exit_teardown || true
    host_priv rm -rf "$WORKSPACE_CHROOT"
    host_priv mkdir -p "$WORKSPACE_CHROOT"

    local comp_csv="${DEBIAN_COMPONENTS// /,}"
    local debootstrap_args=(
        --arch=amd64
        --variant=minbase
        --components="$comp_csv"
    )
    if [[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]]; then
        debootstrap_args+=(--keyring=/usr/share/keyrings/debian-archive-keyring.gpg)
    fi

    host_priv debootstrap "${debootstrap_args[@]}" "$DEBIAN_RELEASE" "$WORKSPACE_CHROOT" "$DEBIAN_MIRROR"
}

function host_stage_run_chroot() {
    ui_step 3 4 "Customize chroot environment"

    host_priv mkdir -p "$WORKSPACE_CHROOT/etc"
    host_priv cp -L /etc/resolv.conf "$WORKSPACE_CHROOT/etc/resolv.conf"

    host_priv mkdir -p "$WORKSPACE_CHROOT/dev" "$WORKSPACE_CHROOT/proc" "$WORKSPACE_CHROOT/sys" "$WORKSPACE_CHROOT/run"
    host_priv mount --bind /dev "$WORKSPACE_CHROOT/dev"
    host_priv mount --bind /dev/pts "$WORKSPACE_CHROOT/dev/pts"
    host_priv mount -t proc proc "$WORKSPACE_CHROOT/proc"
    host_priv mount -t sysfs sysfs "$WORKSPACE_CHROOT/sys"
    host_priv mount -t tmpfs tmpfs "$WORKSPACE_CHROOT/run"

    if [[ ! -e "$WORKSPACE_CHROOT/dev/fd" ]]; then
        host_priv ln -sf /proc/self/fd "$WORKSPACE_CHROOT/dev/fd" 2>/dev/null || true
    fi

    if [[ -d "$SCRIPT_DIR/calamares" ]]; then
        host_priv rm -rf "$WORKSPACE_CHROOT/root/calamares-config"
        host_priv mkdir -p "$WORKSPACE_CHROOT/root/calamares-config"
        host_priv cp -a "$SCRIPT_DIR/calamares/." "$WORKSPACE_CHROOT/root/calamares-config/"
    fi

    if [[ -f "$SCRIPT_DIR/cli-installer/install-system" ]]; then
        host_priv mkdir -p "$WORKSPACE_CHROOT/usr/local/bin"
        host_priv cp "$SCRIPT_DIR/cli-installer/install-system" "$WORKSPACE_CHROOT/usr/local/bin/install-system"
        host_priv chmod 0755 "$WORKSPACE_CHROOT/usr/local/bin/install-system"
    fi

    if [[ -f "$SCRIPT_DIR/setup-grub-modes" ]]; then
        host_priv mkdir -p "$WORKSPACE_CHROOT/usr/local/sbin"
        host_priv cp "$SCRIPT_DIR/setup-grub-modes" "$WORKSPACE_CHROOT/usr/local/sbin/setup-grub-modes"
        host_priv chmod 0755 "$WORKSPACE_CHROOT/usr/local/sbin/setup-grub-modes"
    fi

    host_priv cp "$SCRIPT_DIR/build.sh" "$WORKSPACE_CHROOT/tmp/build-internal.sh"
    host_priv chmod +x "$WORKSPACE_CHROOT/tmp/build-internal.sh"

    local chroot_env=(
        LC_ALL=C
        DEBIAN_FRONTEND=noninteractive
        DEBIAN_RELEASE="${DEBIAN_RELEASE}"
        DEBIAN_MIRROR="${DEBIAN_MIRROR}"
        DEBIAN_SECURITY_MIRROR="${DEBIAN_SECURITY_MIRROR}"
        DEBIAN_COMPONENTS="${DEBIAN_COMPONENTS}"
        TARGET_KERNEL_PACKAGE="${TARGET_KERNEL_PACKAGE}"
        TARGET_INSTALLER="${TARGET_INSTALLER}"
        TARGET_DESKTOP="${TARGET_DESKTOP}"
        TARGET_KDE_PACKAGE="${TARGET_KDE_PACKAGE}"
        TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE}"
        TARGET_MATE_EXTRAS="${TARGET_MATE_EXTRAS:-0}"
        TARGET_GNOME_INSTALL_RECOMMENDS="${TARGET_GNOME_INSTALL_RECOMMENDS:-0}"
        TARGET_FIREFOX="${TARGET_FIREFOX:-0}"
        TARGET_FIREFOX_ESR="${TARGET_FIREFOX_ESR:-0}"
        TARGET_THUNDERBIRD="${TARGET_THUNDERBIRD:-0}"
        TARGET_CHROMIUM="${TARGET_CHROMIUM:-0}"
        TARGET_BRAVE_CHANNEL="${TARGET_BRAVE_CHANNEL:-none}"
        TARGET_LIBREWOLF="${TARGET_LIBREWOLF:-0}"
        TARGET_PACSTALL="${TARGET_PACSTALL:-0}"
        TARGET_FWUPD="${TARGET_FWUPD:-0}"
        TARGET_OPENSSH_SERVER="${TARGET_OPENSSH_SERVER:-0}"
        TARGET_COCKPIT="${TARGET_COCKPIT:-0}"
        TARGET_WEB_SERVER="${TARGET_WEB_SERVER:-0}"
        TARGET_SSH_SERVER="${TARGET_SSH_SERVER:-0}"
        TARGET_LAPTOP="${TARGET_LAPTOP:-0}"
        TARGET_DEB_MULTIMEDIA="${TARGET_DEB_MULTIMEDIA:-0}"
        TARGET_DEB_MULTIMEDIA_PACKAGES="${TARGET_DEB_MULTIMEDIA_PACKAGES:-0}"
        TARGET_LOCALE="${TARGET_LOCALE:-}"
        TARGET_KEYBOARD_LAYOUT="${TARGET_KEYBOARD_LAYOUT:-}"
        TARGET_KEYBOARD_VARIANT="${TARGET_KEYBOARD_VARIANT:-}"
        GRUB_LIVEBOOT_LABEL="${GRUB_LIVEBOOT_LABEL}"
        GRUB_TTY_ONLY="${GRUB_TTY_ONLY:-0}"
    )

    host_priv env "${chroot_env[@]}" chroot "$WORKSPACE_CHROOT" /bin/bash /tmp/build-internal.sh --chroot-internal chroot_prepare - install_pkg

    manage_caper_packaging_host_or_chroot

    host_priv env "${chroot_env[@]}" chroot "$WORKSPACE_CHROOT" /bin/bash /tmp/build-internal.sh --chroot-internal build_image - finish_up

    host_priv rm -f "$WORKSPACE_CHROOT/tmp/build-internal.sh"

    chroot_exit_teardown
}

function manage_caper_packaging_host_or_chroot() {
    local caper_deb_dir="$REPO_ROOT/caper-deb"
    mkdir -p "$caper_deb_dir"

    local existing_deb=""
    existing_deb="$(find "$caper_deb_dir" -maxdepth 1 -name "caper*.deb" 2>/dev/null | head -n 1)"
    if [[ -n "${CAPER_DEB_PATH:-}" && -f "$CAPER_DEB_PATH" ]]; then
        existing_deb="$CAPER_DEB_PATH"
    fi

    if [[ -n "$existing_deb" && -f "$existing_deb" ]]; then
        ui_info "Found Caper debian package: $existing_deb"
        host_priv cp "$existing_deb" "$WORKSPACE_CHROOT/tmp/caper.deb"
        host_priv chroot "$WORKSPACE_CHROOT" apt-get install -y /tmp/caper.deb
        host_priv rm -f "$WORKSPACE_CHROOT/tmp/caper.deb"
        return 0
    fi

    local src_dir="${CAPER_SRC_DIR:-/home/jimedrand/Git/caper}"
    if [[ ! -d "$src_dir" ]]; then
        ui_err "Caper source directory not found: $src_dir and no package in $caper_deb_dir"
        exit 1
    fi

    local is_host_debian=0
    if [[ -f /etc/debian_version ]] && command -v dpkg-buildpackage &>/dev/null; then
        is_host_debian=1
    fi

    if [[ "$is_host_debian" -eq 1 ]]; then
        ui_info "Building Caper package directly on Debian host"
        (
            cd "$src_dir"
            dpkg-buildpackage -us -uc -b
        )
        local built_deb
        built_deb="$(find "$(dirname "$src_dir")" -maxdepth 1 -name "caper*.deb" 2>/dev/null | head -n 1)"
        if [[ -z "$built_deb" || ! -f "$built_deb" ]]; then
            ui_err "Failed to build Caper package on host"
            exit 1
        fi
        cp "$built_deb" "$caper_deb_dir/"
        host_priv cp "$built_deb" "$WORKSPACE_CHROOT/tmp/caper.deb"
        host_priv chroot "$WORKSPACE_CHROOT" apt-get install -y /tmp/caper.deb
        host_priv rm -f "$WORKSPACE_CHROOT/tmp/caper.deb"
    else
        ui_info "Building Caper package inside debootstrap chroot (non-Debian host detected)"
        host_priv rm -rf "$WORKSPACE_CHROOT/tmp/caper-build"
        host_priv mkdir -p "$WORKSPACE_CHROOT/tmp/caper-build"
        host_priv cp -a "$src_dir/." "$WORKSPACE_CHROOT/tmp/caper-build/"

        host_priv chroot "$WORKSPACE_CHROOT" apt-get update
        host_priv chroot "$WORKSPACE_CHROOT" apt-get install -y --no-install-recommends debhelper pkg-config libplymouth-dev build-essential
        host_priv chroot "$WORKSPACE_CHROOT" bash -c "cd /tmp/caper-build && dpkg-buildpackage -us -uc -b"

        local chroot_deb
        chroot_deb="$(find "$WORKSPACE_CHROOT/tmp" -maxdepth 1 -name "caper*.deb" 2>/dev/null | head -n 1)"
        if [[ -z "$chroot_deb" || ! -f "$chroot_deb" ]]; then
            ui_err "Failed to build Caper deb inside chroot"
            exit 1
        fi

        host_priv cp "$chroot_deb" "$caper_deb_dir/"
        host_priv chroot "$WORKSPACE_CHROOT" bash -c "apt-get install -y /tmp/caper*.deb"
        host_priv chroot "$WORKSPACE_CHROOT" apt-get purge -y --autoremove debhelper pkg-config libplymouth-dev build-essential
        host_priv rm -rf "$WORKSPACE_CHROOT/tmp/caper"*
    fi
}

function host_stage_build_iso() {
    ui_step 4 4 "Assemble bootable hybrid ISO"

    ensure_workspace_root
    host_priv rm -rf "$WORKSPACE_IMAGE"
    host_priv mv "$WORKSPACE_CHROOT/image" "$WORKSPACE_IMAGE"
    host_priv ln -sfn casper "$WORKSPACE_IMAGE/caper"

    host_priv mksquashfs "$WORKSPACE_CHROOT" "$WORKSPACE_IMAGE/casper/filesystem.squashfs" \
        -noappend -no-duplicates -no-recovery \
        -wildcards \
        -comp xz -b 1M -Xdict-size 100% \
        -e "var/cache/apt/archives/*" \
        -e "root/*" \
        -e "root/.*" \
        -e "tmp/*" \
        -e "tmp/.*" \
        -e "swapfile" \
        -e "image"

    printf "%s" "$(host_priv du -sx --block-size=1 \
        --exclude="$WORKSPACE_CHROOT/root" \
        --exclude="$WORKSPACE_CHROOT/tmp" \
        --exclude="$WORKSPACE_CHROOT/var/cache/apt/archives" \
        --exclude="$WORKSPACE_CHROOT/swapfile" \
        "$WORKSPACE_CHROOT" | cut -f1)" | host_priv tee "$WORKSPACE_IMAGE/casper/filesystem.size" >/dev/null

    local boot_hybrid_img="$WORKSPACE_CHROOT/usr/lib/grub/i386-pc/boot_hybrid.img"
    if [[ ! -f "$boot_hybrid_img" ]]; then
        >&2 echo "Missing $boot_hybrid_img (grub-pc-bin missing in chroot). Cannot assemble hybrid ISO."
        exit 1
    fi

    if [[ -z "${TARGET_NAME:-}" ]]; then
        TARGET_NAME="debian-${DEBIAN_RELEASE}-${TARGET_DESKTOP}-amd64-${DATE}"
    fi

    local iso_volid
    iso_volid="$(printf '%s' "$TARGET_NAME" \
        | tr '[:lower:]' '[:upper:]' \
        | tr -c 'A-Z0-9_' '_' \
        | cut -c1-32)"

    ensure_output_dir

    pushd "$WORKSPACE_IMAGE" >/dev/null

    local esp_type_guid="28732ac11ff8d211ba4b00a0c93ec93b"
    local iso_mbr_type_guid="a2a0d0ebe5b9334487c068b6b72699c7"

    host_priv xorriso \
        -as mkisofs \
        -r -V "$iso_volid" \
        -J -joliet-long \
        -l \
        -iso-level 3 \
        -full-iso9660-filenames \
        -o "$OUTPUT_DIR/$TARGET_NAME.iso" \
        \
        --grub2-mbr "$boot_hybrid_img" \
        -partition_offset 16 \
        --mbr-force-bootable \
        -append_partition 2 "$esp_type_guid" boot/grub/efiboot.img \
        -appended_part_as_gpt \
        -iso_mbr_part_type "$iso_mbr_type_guid" \
        \
        -c boot.catalog \
        -b boot/grub/bios.img \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            --grub2-boot-info \
        -eltorito-alt-boot \
        -e '--interval:appended_partition_2:all::' \
            -no-emul-boot \
        \
        .

    popd >/dev/null

    write_iso_hashes
    fix_output_ownership
    clean_workspace
    ui_ok "Build complete: $OUTPUT_DIR/$TARGET_NAME.iso"
}

function chroot_prepare() {
    local comp="${DEBIAN_COMPONENTS:-main contrib non-free non-free-firmware}"
    local sources_file="/etc/apt/sources.list"
    local mirror="${DEBIAN_MIRROR%/}/"
    local sec_mirror="${DEBIAN_SECURITY_MIRROR%/}"

    case "${DEBIAN_RELEASE:-stable}" in
        stable)
            cat <<EOF > "$sources_file"
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
            cat <<EOF > "$sources_file"
deb ${mirror} testing $comp
deb-src ${mirror} testing $comp

deb ${sec_mirror} testing-security $comp
deb-src ${sec_mirror} testing-security $comp

deb ${mirror} testing-updates $comp
deb-src ${mirror} testing-updates $comp
EOF
            ;;
        unstable|sid)
            cat <<EOF > "$sources_file"
deb ${mirror} unstable $comp
deb-src ${mirror} unstable $comp
EOF
            ;;
    esac

    apt-get update

    block_snapd
    block_fwupd

    apt-get install -y libterm-readline-gnu-perl systemd-sysv

    dbus-uuidgen > /etc/machine-id
    ln -fs /etc/machine-id /var/lib/dbus/machine-id

    dpkg-divert --local --rename --add /sbin/initctl
    ln -sf /bin/true /sbin/initctl
}

function apply_calamares_custom_config() {
    if [[ ! -d /root/calamares-config ]] || [[ ! -f /root/calamares-config/settings.conf ]]; then
        ui_err "Internal error: scripts/calamares must include settings.conf."
        exit 1
    fi
    install -d /etc/calamares/modules
    cp -a /root/calamares-config/settings.conf /etc/calamares/settings.conf
    cp -a /root/calamares-config/modules/. /etc/calamares/modules/

    if [[ -f /root/calamares-config/i18n/SUPPORTED ]]; then
        install -d /usr/share/i18n
        cp /root/calamares-config/i18n/SUPPORTED /usr/share/i18n/SUPPORTED
    fi

    if [[ -d /root/calamares-config/branding/debian ]]; then
        install -d /etc/calamares/branding/debian
        cp -a /root/calamares-config/branding/debian/. /etc/calamares/branding/debian/
        sed -e "s|@VERSION@|${DEBIAN_RELEASE}|g" \
            -e "s|@CODENAME@|${DEBIAN_RELEASE}|g" \
            /root/calamares-config/branding/debian/branding.desc \
            > /etc/calamares/branding/debian/branding.desc
    fi
}

function customize_image() {
    block_snapd
    block_fwupd

    case "${TARGET_DESKTOP:-xfce}" in
        gnome)
            if [[ "${TARGET_GNOME_INSTALL_RECOMMENDS:-0}" == "1" ]]; then
                apt-get install -y task-gnome-desktop
            else
                apt-get install -y --no-install-recommends task-gnome-desktop
            fi
            ;;
        gnome-flashback)
            apt-get install -y task-gnome-flashback-desktop
            ;;
        xfce)
            apt-get install -y task-xfce-desktop
            ;;
        kde-plasma)
            case "${TARGET_KDE_PACKAGE:-kde-standard}" in
                kde-full|kde-standard|kde-plasma-desktop)
                    apt-get install -y "${TARGET_KDE_PACKAGE:-kde-standard}"
                    ;;
                *)
                    apt-get install -y task-kde-desktop
                    ;;
            esac
            apt-get install -y --no-install-recommends sddm sddm-theme-breeze
            install -d /etc/sddm.conf.d
            cat <<'EOF' > /etc/sddm.conf.d/10-debian-breeze.conf
[Theme]
Current=breeze
EOF
            cat <<'EOF' > /etc/apt/preferences.d/no-slick-sddm.pref
Package: *slick*sddm* *sddm*slick*
Pin: release *
Pin-Priority: -1
EOF
            apt-get install -y plasma-discover plasma-discover-backend-flatpak
            ;;
        cinnamon)
            apt-get install -y task-cinnamon-desktop
            ;;
        mate)
            apt-get install -y task-mate-desktop
            if [[ "${TARGET_MATE_EXTRAS:-0}" == "1" ]]; then
                apt-get install -y mate-desktop-environment-extras
            fi
            ;;
        lxde)
            apt-get install -y task-lxde-desktop
            ;;
        lxqt)
            apt-get install -y task-lxqt-desktop
            ;;
        lomiri)
            apt-get install -y task-lomiri-desktop
            ;;
        lomiri-tablet)
            apt-get install -y task-lomiri-tablet
            ;;
        phosh)
            apt-get install -y task-phosh-desktop
            ;;
        task-desktop|standard-desktop)
            apt-get install -y task-desktop
            ;;
        none|cli)
            ;;
    esac

    if [[ "${TARGET_DESKTOP:-xfce}" == "none" || "${TARGET_DESKTOP:-xfce}" == "cli" ]]; then
        systemctl set-default multi-user.target 2>/dev/null || true
    else
        systemctl set-default graphical.target 2>/dev/null || true
    fi

    install_optional_services
}

function setup_deb_multimedia() {
    if [[ "${TARGET_DEB_MULTIMEDIA:-0}" != "1" ]]; then
        return 0
    fi

    local keyring_deb="/tmp/deb-multimedia-keyring.deb"
    local keyring_url="https://www.deb-multimedia.org/pool/main/d/deb-multimedia-keyring/deb-multimedia-keyring_2024.9.1_all.deb"
    local expected_hash="8dc6cbb266c701cfe58bd1d2eb9fe2245a1d6341c7110cfbfe3a5a975dcf97ca"

    curl -fsSL "$keyring_url" -o "$keyring_deb"
    local actual_hash
    actual_hash="$(sha256sum "$keyring_deb" | awk '{print $1}')"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "ERROR: deb-multimedia-keyring checksum mismatch"
        rm -f "$keyring_deb"
        return 1
    fi

    dpkg -i "$keyring_deb" || true
    rm -f "$keyring_deb"

    local dmo_suite
    case "${DEBIAN_RELEASE:-stable}" in
        stable|trixie)       dmo_suite="trixie" ;;
        testing|forky)       dmo_suite="forky" ;;
        unstable|sid)        dmo_suite="unstable" ;;
        bookworm|oldstable)  dmo_suite="bookworm" ;;
        *)                   dmo_suite="${DEBIAN_RELEASE}" ;;
    esac

    cat <<EOF > /etc/apt/sources.list.d/dmo.sources
Types: deb
URIs: https://www.deb-multimedia.org
Suites: ${dmo_suite}
Components: main non-free
Signed-By: /usr/share/keyrings/deb-multimedia-keyring.pgp
Enabled: yes
EOF

    apt-get update

    if [[ "${TARGET_DEB_MULTIMEDIA_PACKAGES:-0}" == "1" ]]; then
        local dmo_pkgs=(ffmpeg libdvdcss2 gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav)
        if [[ "${TARGET_DESKTOP}" != "none" && "${TARGET_DESKTOP}" != "cli" ]]; then
            dmo_pkgs+=(mpv)
        fi
        apt-get install -y --no-install-recommends "${dmo_pkgs[@]}" || apt-get install -y "${dmo_pkgs[@]}"
    fi
}

function install_optional_services() {
    setup_deb_multimedia

    if [[ "${TARGET_WEB_SERVER:-0}" == "1" ]]; then
        apt-get install -y task-web-server
    fi

    if [[ "${TARGET_SSH_SERVER:-0}" == "1" ]]; then
        apt-get install -y task-ssh-server
    fi

    if [[ "${TARGET_COCKPIT:-0}" == "1" ]]; then
        apt-get install -y cockpit
    fi

    if [[ "${TARGET_LAPTOP:-0}" == "1" ]]; then
        apt-get install -y task-laptop
    fi

    systemctl disable ssh sshd cockpit.socket 2>/dev/null || true

    if [[ "${TARGET_PACSTALL:-0}" == "1" ]]; then
        bash -c "$(curl -fsSL https://pacstall.dev/packages/install.sh)" || true
    fi

    apt-get install -y flatpak
    case "${TARGET_DESKTOP:-xfce}" in
        gnome|gnome-flashback|cinnamon)
            apt-get install -y --no-install-recommends gnome-software-plugin-flatpak 2>/dev/null || true
            ;;
        kde-plasma)
            apt-get install -y --no-install-recommends plasma-discover-backend-flatpak 2>/dev/null || true
            ;;
    esac
}

function install_pkg() {
    if ! grep -q "non-free-firmware" /etc/apt/sources.list 2>/dev/null; then
        chroot_prepare
    fi

    apt-get update
    apt-get -y upgrade

    apt-get install -y \
        sudo \
        tasksel \
        locales \
        libpam-systemd \
        network-manager \
        net-tools \
        grub-common \
        grub-pc \
        grub-pc-bin \
        grub2-common \
        grub-efi-amd64-signed \
        shim-signed \
        mtools \
        unzip \
        binutils \
        dosfstools \
        e2fsprogs \
        btrfs-progs \
        xfsprogs \
        ntfs-3g \
        parted \
        discover \
        laptop-detect \
        os-prober \
        curl \
        wget \
        squashfs-tools \
        gnupg

    if [[ "${TARGET_DESKTOP}" != "none" && "${TARGET_DESKTOP}" != "cli" ]]; then
        apt-get install -y gparted 2>/dev/null || true
    fi

    tasksel install standard

    apt-get install -y "$TARGET_KERNEL_PACKAGE" linux-headers-amd64

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

    case "${TARGET_INSTALLER}" in
        calamares)
            if [[ "${TARGET_DESKTOP}" != "none" && "${TARGET_DESKTOP}" != "cli" ]]; then
                apt-get install -y --no-install-recommends calamares
                apply_calamares_custom_config
            fi
            ;;
    esac

    customize_image
    run_chroot_hooks

    apt-get autoremove -y

    if [[ -n "${TARGET_LOCALE:-}" ]]; then
        sed -i "s/^# *${TARGET_LOCALE}/${TARGET_LOCALE}/" /etc/locale.gen 2>/dev/null || true
        echo "${TARGET_LOCALE}" >> /etc/locale.gen
        sort -u -o /etc/locale.gen /etc/locale.gen
        echo "locales locales/default_environment_locale select ${TARGET_LOCALE}" | debconf-set-selections
        echo "locales locales/locales_to_be_generated multiselect ${TARGET_LOCALE}" | debconf-set-selections
        dpkg-reconfigure --frontend=noninteractive locales 2>/dev/null || locale-gen || true
    fi

    if [[ -n "${TARGET_KEYBOARD_LAYOUT:-}" ]]; then
        apt-get install -y keyboard-configuration console-setup 2>/dev/null || true
        cat <<EOF > /etc/default/keyboard
XKBMODEL="pc105"
XKBLAYOUT="${TARGET_KEYBOARD_LAYOUT}"
XKBVARIANT="${TARGET_KEYBOARD_VARIANT:-}"
XKBOPTIONS=""
EOF
    fi

    apt-get clean -y
}

function build_image() {
    rm -rf /image
    mkdir -p /image/{casper,boot/grub,install,EFI/boot,EFI/debian}
    ln -sfn casper /image/caper

    pushd /image >/dev/null

    local vmlinuz_src initrd_src
    vmlinuz_src="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)"
    initrd_src="$(ls -1 /boot/initrd.img-* 2>/dev/null | sort -V | tail -1)"
    if [[ -z "${vmlinuz_src:-}" || ! -f "$vmlinuz_src" ]]; then
        echo "No /boot/vmlinuz-* found." >&2
        exit 1
    fi
    if [[ -z "${initrd_src:-}" || ! -f "$initrd_src" ]]; then
        echo "No /boot/initrd.img-* found." >&2
        exit 1
    fi
    cp "$vmlinuz_src" casper/vmlinuz
    cp "$initrd_src" casper/initrd

    local _memtest_url="https://memtest.org/download/v7.00/mt86plus_7.00.binaries.zip"
    wget -q "$_memtest_url" -O install/memtest86.zip || true
    if [[ -f install/memtest86.zip ]]; then
        unzip -p install/memtest86.zip memtest64.bin > install/memtest86+.bin 2>/dev/null || true
        unzip -p install/memtest86.zip memtest64.efi > install/memtest86+.efi 2>/dev/null || true
        rm -f install/memtest86.zip
    fi

    touch debian
    cat <<EOF > boot/grub/grub.cfg

search --set=root --file /debian

insmod all_video

set default="0"
set timeout=30
EOF

    if [[ "${GRUB_TTY_ONLY:-0}" == "1" || "${TARGET_DESKTOP}" == "none" || "${TARGET_DESKTOP}" == "cli" ]]; then
        cat <<EOF >> boot/grub/grub.cfg

menuentry "$GRUB_LIVEBOOT_LABEL (CLI/TTY mode)" {
    linux /casper/vmlinuz boot=casper systemd.unit=multi-user.target ---
    initrd /casper/initrd
}
EOF
    else
        cat <<EOF >> boot/grub/grub.cfg

menuentry "$GRUB_LIVEBOOT_LABEL" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}

menuentry "$GRUB_LIVEBOOT_LABEL (CLI/TTY mode)" {
    linux /casper/vmlinuz boot=casper systemd.unit=multi-user.target ---
    initrd /casper/initrd
}
EOF
    fi

    cat <<EOF >> boot/grub/grub.cfg

menuentry "Check the disc for defects" {
    linux /casper/vmlinuz boot=casper integrity-check quiet splash ---
    initrd /casper/initrd
}

if [ "\$grub_platform" = "efi" ]; then
menuentry "UEFI firmware settings" {
    fwsetup
}

if [ -f /install/memtest86+.efi ]; then
menuentry "Test memory with Memtest86+ (UEFI)" {
    linux /install/memtest86+.efi
}
fi
else
if [ -f /install/memtest86+.bin ]; then
menuentry "Test memory with Memtest86+ (BIOS)" {
    linux16 /install/memtest86+.bin
}
fi
fi
EOF

    dpkg-query -W --showformat='${Package} ${Version}\n' | tee casper/filesystem.manifest >/dev/null
    cp -v casper/filesystem.manifest casper/filesystem.manifest-desktop

    local pkg pkg_re
    for pkg in ${TARGET_PACKAGE_REMOVE:-$(default_target_package_remove)}; do
        pkg_re="$(printf '%s' "$pkg" | sed 's/[][\\.*^$/]/\\&/g')"
        sed -i "/^${pkg_re} /d" casper/filesystem.manifest-desktop
    done

    printf '%s\n' \
        "#define DISKNAME  ${GRUB_LIVEBOOT_LABEL}" \
        "#define TYPE  binary" \
        "#define TYPEbinary  1" \
        "#define ARCH  amd64" \
        "#define ARCHamd64  1" \
        "#define DISKNUM  1" \
        "#define DISKNUM1  1" \
        "#define TOTALNUM  0" \
        "#define TOTALNUM0  1" > README.diskdefines

    local _efi_src
    for _efi_src in /usr/lib/shim/shimx64.efi.signed /usr/lib/shim/mmx64.efi /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed; do
        if [[ ! -f "$_efi_src" ]]; then
            echo "ERROR: Required EFI binary '$_efi_src' not found." >&2
            exit 1
        fi
    done
    cp /usr/lib/shim/shimx64.efi.signed EFI/boot/bootx64.efi
    cp /usr/lib/shim/mmx64.efi EFI/boot/mmx64.efi
    cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed EFI/boot/grubx64.efi
    cp boot/grub/grub.cfg EFI/debian/grub.cfg

    (
        cd boot/grub
        dd if=/dev/zero of=efiboot.img bs=1M count=10
        mkfs.vfat -F 16 efiboot.img
        LC_CTYPE=C mmd -i efiboot.img efi efi/debian efi/boot
        LC_CTYPE=C mcopy -i efiboot.img ../../EFI/boot/bootx64.efi ::efi/boot/bootx64.efi
        LC_CTYPE=C mcopy -i efiboot.img ../../EFI/boot/mmx64.efi ::efi/boot/mmx64.efi
        LC_CTYPE=C mcopy -i efiboot.img ../../EFI/boot/grubx64.efi ::efi/boot/grubx64.efi
        LC_CTYPE=C mcopy -i efiboot.img ./grub.cfg ::efi/debian/grub.cfg
    )

    grub-mkstandalone \
      --format=i386-pc \
      --output=boot/grub/core.img \
      --install-modules="linux16 linux normal iso9660 biosdisk memdisk search tar ls" \
      --modules="linux16 linux normal iso9660 biosdisk search" \
      --locales="" \
      --fonts="" \
      "boot/grub/grub.cfg=boot/grub/grub.cfg"

    cat /usr/lib/grub/i386-pc/cdboot.img boot/grub/core.img > boot/grub/bios.img

    find . -type f -print0 \
        | xargs -0 md5sum \
        | grep -v -e 'boot/grub/efiboot.img' -e 'boot/grub/bios.img' -e 'md5sum.txt' \
        > md5sum.txt

    popd >/dev/null
}

function finish_up() {
    rm -f /etc/ssh/ssh_host_*
    truncate -s 0 /etc/machine-id
    rm -f /sbin/initctl
    dpkg-divert --rename --remove /sbin/initctl 2>/dev/null || true
}

function host_main() {
    set_defaults

    parse_host_cli_args "$@"
    set_defaults

    resolve_release_choice
    resolve_mirror_choice
    resolve_desktop_selection
    resolve_pacstall_choice
    resolve_optional_service_choices
    resolve_deb_multimedia_choices
    set_installer_and_manifest_defaults
    check_settings

    resolve_workspace_paths
    review_settings_and_confirm

    setup_sudo_keepalive
    trap host_build_exit_trap EXIT
    trap 'host_build_signal_trap 130' INT
    trap 'host_build_signal_trap 143' TERM

    parse_cmd_range HOST_CMD host_help "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"

    local i
    for ((i=start_index; i<end_index; i++)); do
        "host_stage_${HOST_CMD[i]}"
    done
}

function chroot_main() {
    set_defaults
    parse_cmd_range CHROOT_CMD chroot_help "$@"

    local i
    for ((i=start_index; i<end_index; i++)); do
        "${CHROOT_CMD[i]}"
    done
}

function chroot_help() {
    echo "Internal chroot commands: ${CHROOT_CMD[*]}"
    exit 1
}

if [[ "${1:-}" == "--chroot-internal" ]]; then
    shift
    chroot_main "$@"
else
    host_main "$@"
fi
