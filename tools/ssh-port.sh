#!/bin/bash
#
# tools/ssh-port.sh -- safely change the SSH port
#
# Backs up the current sshd_config, validates the new port (1024-65535, not
# currently in use), opens the new port in the firewall BEFORE touching
# sshd, tests the new config with `sshd -t`, reloads sshd, and prints a
# clear warning to open a second session to verify access before closing
# the current one. The old port is NOT disabled until you explicitly run
# `disable-old-port`. Subcommands:
#
#   change <new-port>
#       back up + firewall + sshd -t + reload, keep old port open
#   disable-old-port
#       close the previously-open old SSH port in the firewall and remove
#       the "Port <old>" line from sshd_config (use only after you have
#       verified access on the new port)
#   status
#       show current Port lines in sshd_config and firewall state
#   uninstall
#       restore the backed-up sshd_config (original port) and close the
#       port we opened
#
# OS: Debian/Ubuntu only.
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SSHD_CONF="/etc/ssh/sshd_config"
BACKUP_DIR="/etc/ssh/sshd-config-backups"
STATE_FILE="/etc/ssh/.vpn-install-ssh-port"
SERVICE="ssh"

log() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}Warning: $*${NC}" >&2; }
err() { echo -e "${RED}$*${NC}" >&2; }

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        err "This script must be run as root. Try: sudo bash $0"
        exit 1
    fi
}

detect_os() {
    local id_like=""
    if [[ -f /etc/os-release ]]; then
        id_like="$(grep -E '^(ID|ID_LIKE)=' /etc/os-release || true)"
    fi
    if [[ -f /etc/debian_version || "$id_like" =~ (debian|ubuntu) ]]; then
        return 0
    fi
    err "Unsupported distribution. This script requires Debian or Ubuntu."
    exit 1
}

valid_port() {
    local p="$1"
    if [[ ! "$p" =~ ^[0-9]+$ || "$p" -lt 1024 || "$p" -gt 65535 ]]; then
        err "Invalid port '$p'. Must be 1024-65535."
        return 1
    fi
    # Must not already be in use by another process
    if ss -tuln 2>/dev/null | awk 'NR>1 {print $5}' | grep -qE "[:.]${p}\s*$"; then
        err "Port $p is already in use."
        return 1
    fi
}

open_firewall() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw is active >/dev/null 2>&1; then
        ufw allow "$port/tcp"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="$port/tcp"
        firewall-cmd --reload
    else
        warn "No active ufw/firewalld detected; assuming no host firewall. If you use iptables natively, open the port manually."
    fi
}

close_firewall() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw is active >/dev/null 2>&1; then
        ufw delete allow "$port/tcp" || true
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --remove-port="$port/tcp" || true
        firewall-cmd --reload || true
    fi
}

current_ports() {
    # Print the currently configured Port lines (one per line)
    grep -Ei '^\s*Port\s+' "$SSHD_CONF" | sed -E 's/^\s*Port\s+([0-9]+).*/\1/' || true
}

# --- subcommands ------------------------------------------------------------

cmd_change() {
    require_root
    detect_os
    local new_port="$1"
    valid_port "$new_port"

    # Back up the original config (only the first time, or overwrite)
    mkdir -p "$BACKUP_DIR"
    cp -n "$SSHD_CONF" "${BACKUP_DIR}/sshd_config.orig.$(date +%s)" 2>/dev/null || \
        cp "$SSHD_CONF" "${BACKUP_DIR}/sshd_config.orig.$(date +%s)"

    # Record the old port so we can close it later
    local old_port=""
    local first
    first="$(current_ports | head -n1)"
    old_port="${first:-22}"
    printf '%s\n%s\n' "$old_port" "$new_port" > "$STATE_FILE"

    # Open the NEW port in the firewall FIRST
    log "Opening firewall for port $new_port..."
    open_firewall "$new_port"

    # Edit sshd_config: comment out all existing Port lines, add the new one
    local tmp
    tmp="$(mktemp /tmp/sshd_config.XXXXXX)"
    # Back up the live file before we edit it
    cp "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%s)"
    sed -E 's/^\s*Port\s+/#&/' "$SSHD_CONF" > "$tmp"
    echo "Port $new_port" >> "$tmp"
    cat "$tmp" > "$SSHD_CONF"
    rm -f "$tmp"

    # Test before reloading
    log "Testing new sshd_config..."
    if ! sshd -t; then
        err "sshd -t failed. Restoring backup."
        local latest_bak
        latest_bak="$(find "$(dirname "$SSHD_CONF")" -maxdepth 1 -name "${SSHD_CONF}.bak.*" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)"
        [[ -n "$latest_bak" ]] && cat "$latest_bak" > "$SSHD_CONF"
        exit 1
    fi

    log "Reloading sshd..."
    systemctl reload "$SERVICE"

    echo ""
    warn "SSH is now also listening on port $new_port."
    warn "Open a SECOND terminal and test:  ssh -p $new_port user@host"
    warn "Only after that works, run 'disable-old-port' to close $old_port."
    warn "Do NOT close this session until you have confirmed access."
}

cmd_disable_old_port() {
    require_root
    detect_os
    if [[ ! -f "$STATE_FILE" ]]; then
        err "No state file at $STATE_FILE. Run 'change' first."
        exit 1
    fi
    local old_port new_port
    old_port="$(sed -n '1p' "$STATE_FILE")"
    new_port="$(sed -n '2p' "$STATE_FILE")"
    [[ -z "$new_port" ]] && { err "State file is incomplete."; exit 1; }

    warn "Closing old SSH port $old_port. Make sure you can still reach $new_port."
    close_firewall "$old_port"
    # Remove the old Port line from sshd_config
    local tmp
    tmp="$(mktemp /tmp/sshd_config.XXXXXX)"
    grep -vE "^\s*Port\s+${old_port}\s*$" "$SSHD_CONF" > "$tmp" || true
    cat "$tmp" > "$SSHD_CONF"
    rm -f "$tmp"
    if ! sshd -t; then
        err "sshd -t failed after closing old port. Re-add the old port line."
        local tmp2
        tmp2="$(mktemp /tmp/sshd_config.XXXXXX)"
        grep -vE "^\s*Port\s+${old_port}\s*$" "$SSHD_CONF" > /dev/null 2>&1 || true
        rm -f "$tmp2"
        echo "Port $old_port" >> "$SSHD_CONF"
        exit 1
    fi
    systemctl reload "$SERVICE"
    log "Old port $old_port closed. New port $new_port remains open."
}

cmd_status() {
    local ports
    ports="$(current_ports)"
    if [[ -n "$ports" ]]; then
        log "Configured SSH port(s): $(echo "$ports" | tr '\n' ' ')"
    else
        log "No explicit Port line in sshd_config (default: 22)."
    fi
    if [[ -f "$STATE_FILE" ]]; then
        log "State file: old=$(sed -n '1p' "$STATE_FILE") new=$(sed -n '2p' "$STATE_FILE")"
    else
        log "No state file (nothing has been changed yet)."
    fi
}

cmd_uninstall() {
    require_root
    detect_os
    warn "Restoring the original sshd_config from $BACKUP_DIR and closing the port we opened."
    local latest
    latest="$(find "$BACKUP_DIR" -maxdepth 1 -name 'sshd_config.orig.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2- || true)"
    if [[ -n "$latest" && -f "$latest" ]]; then
        cp "$latest" "$SSHD_CONF"
        log "Restored sshd_config from $latest."
    else
        warn "No backup found in $BACKUP_DIR; leaving sshd_config as-is."
    fi
    if [[ -f "$STATE_FILE" ]]; then
        local new_port
        new_port="$(sed -n '2p' "$STATE_FILE")"
        [[ -n "$new_port" ]] && close_firewall "$new_port"
        rm -f "$STATE_FILE"
    fi
    systemctl reload "$SERVICE"
    log "Reverted. Verify your SSH still works on the original port."
}

# --- dispatch ---------------------------------------------------------------

main() {
    local cmd="${1:-help}"
    case "$cmd" in
        change)
            [[ -z "${2:-}" ]] && { err "Usage: ssh-port.sh change <new-port>"; exit 1; }
            cmd_change "$2"
            ;;
        disable-old-port)
            cmd_disable_old_port
            ;;
        status)
            cmd_status
            ;;
        uninstall)
            cmd_uninstall
            ;;
        help|*)
            echo "Usage: ssh-port.sh {change <new-port> | disable-old-port | status | uninstall}"
            ;;
    esac
}

main "$@"
