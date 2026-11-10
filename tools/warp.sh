#!/bin/bash
#
# tools/warp.sh -- Cloudflare WARP client
#
# Installs the Cloudflare WARP client from Cloudflare's official repository
# (https://pkg.cloudflareclient.com), registers the device, connects to the
# Warp network, and manages the client lifecycle. Subcommands:
#
#   install      install WARP client + register + connect
#   status       show current WARP status
#   connect      connect to WARP
#   disconnect   disconnect from WARP
#   uninstall    stop client, remove package, clean up config
#
# OS: Debian/Ubuntu (apt) and RHEL/Fedora/CentOS (dnf/yum).
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

WARP_BIN="warp-cli"
WARP_SERVICE="warp-svc"
CONFIGURED_MARKER="/etc/warp/.vpn-install-configured"
KEYRING="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"

log() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}Warning: $*${NC}" >&2; }
err() { echo -e "${RED}$*${NC}" >&2; }

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
        err "warp-cli not found. Run 'install' first."
        exit 1
    fi
    warp-cli status
}

cmd_connect() {
    if ! command -v "$WARP_BIN" >/dev/null 2>&1; then
        err "warp-cli not found. Run 'install' first."
        exit 1
    fi
    log "Connecting to WARP..."
    warp-cli connect
    sleep 2
    warp-cli status
}

cmd_disconnect() {
    if ! command -v "$WARP_BIN" >/dev/null 2>&1; then
        err "warp-cli not found. Run 'install' first."
        exit 1
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

# --- dispatch ---------------------------------------------------------------

main() {
    local cmd="${1:-help}"
    case "$cmd" in
        install)    cmd_install ;;
        status)     cmd_status ;;
        connect)    cmd_connect ;;
        disconnect) cmd_disconnect ;;
        uninstall)  cmd_uninstall ;;
        help|*)
            echo "Usage: warp.sh {install | status | connect | disconnect | uninstall}"
            ;;
    esac
}

main "$@"
