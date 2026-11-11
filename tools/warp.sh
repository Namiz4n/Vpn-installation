#!/bin/bash
#
# tools/warp.sh -- Cloudflare WARP client
#
# Installs the Cloudflare WARP client from Cloudflare's official repository
# (https://pkg.cloudflareclient.com), registers the device, connects to the
# Warp network, and manages the client lifecycle.
#
# UX (this script is self-contained and also launched with no arguments
# from main.sh):
#   * No arguments:
#       - not installed -> guided install (prompts only if you are
#         interactive; `--auto` skips every prompt),
#       - installed     -> short numbered management menu.
#   * Subcommands (power-user):
#       install | status | connect | disconnect | uninstall
#     -- these still work and take no prompts when combined with `--auto`.
#   * `-h` / `--help`: print usage. Any other first argument that is not a
#     known subcommand is treated as no-args, so running `warp.sh` alone
#     never prints a Usage line.
#
# OS: Debian/Ubuntu (apt) and RHEL/Fedora/CentOS (dnf/yum).
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

WARP_BIN="warp-cli"
WARP_SERVICE="warp-svc"
CONFIGURED_MARKER="/etc/warp/.vpn-install-configured"
KEYRING="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"

AUTO=0

log() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}Warning: $*${NC}" >&2; }
err() { echo -e "${RED}$*${NC}" >&2; }
info() { echo -e "${BLUE}$*${NC}"; }

usage() {
    cat <<EOF
Usage: bash warp.sh [subcommand] [flags]
  No arguments: guided install or management menu (recommended).
  Subcommands: install | status | connect | disconnect | uninstall
  Flags: --auto
  -h / --help: this text.
EOF
}

die() { err "$*"; exit 1; }

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        err "This script must be run as root. Try: sudo bash $0"
        exit 1
    fi
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    else
        err "No supported package manager found (need apt-get, dnf, or yum)."
        exit 1
    fi
}

install_deb_repo() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get -yqq update
    apt-get -yqq install ca-certificates curl
    # Cloudflare's official GPG key and apt source
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output "$KEYRING"
    # Detect the distro codename for the apt source line.
    local codename
    if codename="$(lsb_release -cs 2>/dev/null)" && [[ -n "$codename" ]]; then
        :
    elif [[ -f /etc/os-release ]]; then
        codename="$(grep -E '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"
        if [[ -z "$codename" ]]; then
            codename="$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | cut -d. -f1 || true)"
        fi
    fi
    if [[ -z "${codename:-}" ]]; then
        err "Could not determine the distro codename for the apt source."
        exit 1
    fi
    echo "deb [signed-by=${KEYRING}] https://pkg.cloudflareclient.com/ ${codename} main" \
        > /etc/apt/sources.list.d/cloudflare-warp.list
    apt-get -yqq update
    apt-get -yqq install cloudflare-warp
}

install_rpm_repo() {
    # Cloudflare's RPM repo file (single source for both dnf and yum)
    curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
        -o /etc/yum.repos.d/cloudflare-warp.repo
    if [[ "$PKG_MGR" == "dnf" ]]; then
        dnf -y install cloudflare-warp
    else
        yum -y install cloudflare-warp
    fi
}

# --- subcommands ------------------------------------------------------------

cmd_install() {
    require_root
    detect_package_manager
    case "$PKG_MGR" in
        apt)  install_deb_repo ;;
        dnf|yum) install_rpm_repo ;;
    esac
    mkdir -p "$(dirname "$CONFIGURED_MARKER")"
    touch "$CONFIGURED_MARKER"
    systemctl enable "$WARP_SERVICE"
    systemctl start "$WARP_SERVICE"
    log "Registering WARP device..."
    warp-cli register
    log "Setting mode to Warp (global)..."
    warp-cli set-mode warp
    warp-cli connect
    warp-cli status
    log "WARP installed and connected."
}

cmd_status() {
    if ! command -v "$WARP_BIN" >/dev/null 2>&1; then
        warn "warp-cli not found. Run 'install' first."
        return 0
    fi
    warp-cli status
}

cmd_connect() {
    if ! command -v "$WARP_BIN" >/dev/null 2>&1; then
        die "warp-cli not found. Run 'install' first."
    fi
    log "Connecting to WARP..."
    warp-cli connect
    sleep 2
    warp-cli status
}

cmd_disconnect() {
    if ! command -v "$WARP_BIN" >/dev/null 2>&1; then
        die "warp-cli not found. Run 'install' first."
    fi
    log "Disconnecting from WARP..."
    warp-cli disconnect
    warp-cli status
}

cmd_uninstall() {
    require_root
    detect_package_manager
    warn "Removing WARP client."
    if systemctl is-active --quiet "$WARP_SERVICE" 2>/dev/null; then
        systemctl stop "$WARP_SERVICE"
    fi
    systemctl disable "$WARP_SERVICE" 2>/dev/null || true
    case "$PKG_MGR" in
        apt)  apt-get -yqq purge cloudflare-warp ;;
        dnf)  dnf -y remove cloudflare-warp ;;
        yum)  yum -y remove cloudflare-warp ;;
    esac
    rm -f "$CONFIGURED_MARKER"
    log "WARP uninstalled."
}

# --- guided install / management menu ---------------------------------------
guided_install() {
    echo
    echo "Cloudflare WARP client setup"
    echo "  Package manager : $(detect_package_manager)"
    echo
    local yesno
    if [[ -t 0 && "$AUTO" -eq 0 ]]; then
        printf 'Proceed with WARP install? [Y/n] '
        read -r yesno || yesno="Y"
        if [[ "$yesno" =~ ^[Nn] ]]; then
            die "Aborted before writing anything."
        fi
    fi
    cmd_install
}

is_installed() {
    [[ -f "$CONFIGURED_MARKER" ]] && command -v "$WARP_BIN" >/dev/null 2>&1
}

management_menu() {
    local choice
    while true; do
        echo
        echo "WARP client management menu"
        echo "  1) Status"
        echo "  2) Connect"
        echo "  3) Disconnect"
        echo "  4) Uninstall"
        echo "  0) Back / exit"
        printf 'Choice [0-4]: '
        read -r choice || choice="0"
        case "$choice" in
            1) cmd_status ;;
            2) cmd_connect ;;
            3) cmd_disconnect ;;
            4)
                if ask_yes_no "Uninstall WARP client?" "n"; then
                    cmd_uninstall
                fi
                ;;
            0|*) break ;;
        esac
    done
}

ask_yes_no() {
    local prompt="$1" default="$2" reply=""
    if [[ -t 0 ]]; then
        printf '%s [%s] ' "$prompt" "$default"
        read -r reply || reply=""
        reply="${reply:-$default}"
        [[ "$reply" =~ ^[Yy] ]]
    else
        [[ "$default" =~ ^[Yy] ]]
    fi
}

# --- dispatch -----------------------------------------------------------------
cmd=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --auto) AUTO=1; shift ;;
        install) cmd="install"; shift ;;
        status) cmd="status"; shift ;;
        connect) cmd="connect"; shift ;;
        disconnect) cmd="disconnect"; shift ;;
        uninstall) cmd="uninstall"; shift ;;
        -*) warn "Unknown flag: $1 (ignored)"; shift ;;
        *) cmd="${cmd:-default}"; shift ;;
    esac
done

main() {
    case "$cmd" in
        install)    cmd_install ;;
        status)     cmd_status ;;
        connect)    cmd_connect ;;
        disconnect) cmd_disconnect ;;
        uninstall)  cmd_uninstall ;;
        default|"")
            if is_installed; then
                management_menu
            else
                guided_install
            fi
            ;;
        *)
            warn "Unknown subcommand '$cmd' (treated as no-args)."
            if is_installed; then
                management_menu
            else
                guided_install
            fi
            ;;
    esac
}

main
