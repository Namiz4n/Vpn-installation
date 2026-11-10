#!/bin/bash
#
# tools/warp.sh -- Cloudflare WARP client
#
# Installs the Cloudflare WARP client from Cloudflare's official apt/yum
# repository, registers the device, connects to the Warp network, and
# manages the client lifecycle. Subcommands:
#
#   install      install WARP client + register + connect
#   status       show current WARP status
#   connect      connect to WARP
#   disconnect   disconnect from WARP
#   uninstall    stop client, remove package, clean up config
#
# OS: Debian/Ubuntu (apt) and RHEL/CentOS/Fedora/Alma/Rocky (yum/dnf).
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

WARP_BIN="warp-cli"
WARP_SERVICE="warp-svc"
REPO_DEB="https://pkg.cloudflareclient.com"
REPO_RPM="https://pkg.cloudflareclient.com/rpm"
CONFIGURED_MARKER="/etc/warp/.vpn-install-configured"

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
    # Cloudflare's repo setup (GPG key + apt source)
    curl -fsSL "$REPO_DEB/cloudflare-client-stable.gpg" | gpg --dearmor > /usr/share/keyrings/cloudflare-client-stable.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-client-stable.gpg] $REPO/ warp-stable main" > /etc/apt/sources.list.d/cloudflare-client.list
    apt-get -yqq update
    apt-get -yqq install cloudflare-warp
}

install_rpm_repo() {
    if [[ "$PKG_MGR" == "dnf" ]]; then
        dnf config-manager --add-repo "$REPO_RPM/cloudflare-warp-rpm.repo" 2>/dev/null || \
            curl -fsSL "$REPO_RPM/cloudflare-warp-rpm.repo" -o /etc/yum.repos.d/cloudflare-warp.repo
        dnf -y install cloudflare-warp
    else
        curl -fsSL "$REPO_RPM/cloudflare-warp-rpm.repo" -o /etc/yum.repos.d/cloudflare-warp.repo
        yum -y install cloudflare-warp
    fi
}

# --- subcommands ------------------------------------------------------------

cmd_install() {
    require_root
    detect_package_manager
    case "$PKG_MGR" in
        apt)
            install_deb_repo
            ;;
        dnf|yum)
            install_rpm_repo
            ;;
    esac
    # Create a state directory marker so we can detect "our" install
    mkdir -p "$(dirname "$CONFIGURED_MARKER")"
    touch "$CONFIGURED_MARKER"
    # Register and connect
    systemctl enable "$WARP_SERVICE"
    systemctl start "$WARP_SERVICE"
    log "Registering WARP device..."
    warp-cli register
    log "Setting mode to Warp (global)..."
    warp-cli set mode warp
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
