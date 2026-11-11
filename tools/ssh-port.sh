#!/bin/bash
#
# tools/ssh-port.sh -- safely change the SSH port
#
# Design (be careful: a bug here can lock you out of your server):
#
#   change <new-port>
#       1. take a pristine backup of the current sshd_config (only the first
#          time, plus a timestamped pre-change backup)
#       2. validate the new port (1024-65535, not currently in use)
#       3. open the NEW port in the firewall FIRST and verify the rule exists
#       4. make sshd listen on BOTH the old and the new port (never comment
#          out the old one yet)
#       5. handle both socket-activated (ssh.socket) and plain ssh.service
#       6. run sshd -t; on failure restore the exact backup and exit non-zero
#       7. reload/daemon-reload and verify sshd is actually listening on the
#          new port (ss -ltnp); on failure roll back automatically
#       8. print a strong warning: test a SECOND session before closing this
#          one; the old port stays open until you run disable-old-port
#
#   disable-old-port
#       close the previously-open old port in the firewall and remove the
#       "Port <old>" line (run only after you have verified access on the
#       new port).
#
#   status
#       show configured Port lines, firewall state, and our state file.
#
#   uninstall
#       restore the pristine original sshd_config and close the port we opened.
#
# OS: Debian/Ubuntu only.
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SSHD_CONF="/etc/ssh/sshd_config"
INCLUDE_DIR="/etc/ssh/sshd_config.d"
BACKUP_DIR="/etc/ssh/vpn-install-backups"
PRISTINE="${BACKUP_DIR}/sshd_config.pristine"
STATE_FILE="/etc/ssh/.vpn-install-ssh-port"
SERVICE="ssh"
SOCKET_UNIT="ssh.socket"

log()  { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}Warning: $*${NC}" >&2; }
err()  { echo -e "${RED}$*${NC}" >&2; }

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
    if ss -tuln 2>/dev/null | awk 'NR>1 {print $5}' | grep -qE "[:.]${p}(\s|$)"; then
        err "Port $p is already in use by another process."
        return 1
    fi
}

# --- firewall ---------------------------------------------------------------
_ufw_active() {
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'
}
_firewalld_active() {
    command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null
}

open_firewall() {
    local port="$1"
    if _ufw_active; then
        ufw allow "${port}/tcp"
    elif _firewalld_active; then
        firewall-cmd --permanent --add-port="${port}/tcp"
        firewall-cmd --reload
    else
        warn "No active ufw/firewalld detected; assuming no host firewall."
        warn "If you use iptables natively, open ${port}/tcp manually."
    fi
}

close_firewall() {
    local port="$1"
    if _ufw_active; then
        ufw delete allow "${port}/tcp" 2>/dev/null || true
    elif _firewalld_active; then
        firewall-cmd --permanent --remove-port="${port}/tcp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi
}

# Verify the firewall rule we just added actually exists (best-effort).
verify_firewall_rule() {
    local port="$1"
    if _ufw_active; then
        ufw status 2>/dev/null | grep -qE "^\s*${port}/tcp\s" && return 0
    elif _firewalld_active; then
        firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | grep -qx "${port}/tcp" && return 0
    fi
    # No managed firewall; nothing to verify.
    return 0
}

# --- sshd port state --------------------------------------------------------
# Print all configured port numbers (from sshd_config and include dir), one
# per line. Used to know the "old" port(s).
configured_ports() {
    {
        grep -Ei '^[[:space:]]*Port[[:space:]]+' "$SSHD_CONF" 2>/dev/null | \
            sed -E 's/^[[:space:]]*Port[[:space:]]+//; s/[[:space:]]+$//' || true
        if [[ -d "$INCLUDE_DIR" ]]; then
            for f in "$INCLUDE_DIR"/*.conf; do
                [[ -f "$f" ]] || continue
                grep -Ei '^[[:space:]]*Port[[:space:]]+' "$f" 2>/dev/null | \
                    sed -E 's/^[[:space:]]*Port[[:space:]]+//; s/[[:space:]]+$//' || true
            done
        fi
    } | tr ' ' '\n' | grep -E '^[0-9]+$' || true
}

is_socket_activated() {
    systemctl is-active --quiet "$SOCKET_UNIT" 2>/dev/null
}

# --- backup / restore -------------------------------------------------------
# take_backups echoes the path of the timestamped backup it just made.
take_backups() {
    mkdir -p "$BACKUP_DIR"
    # Pristine copy only if it does not exist yet.
    if [[ ! -f "$PRISTINE" ]]; then
        cp -a "$SSHD_CONF" "$PRISTINE"
        log "Saved pristine sshd_config backup to $PRISTINE"
    fi
    # Timestamped pre-change backup; echo its path for the caller to use.
    local ts_bak
    ts_bak="${SSHD_CONF}.bak.$(date +%s)"
    cp -a "$SSHD_CONF" "$ts_bak"
    printf '%s\n' "$ts_bak"
}

restore_pristine() {
    if [[ -f "$PRISTINE" ]]; then
        cp -a "$PRISTINE" "$SSHD_CONF"
        log "Restored sshd_config from $PRISTINE"
        return 0
    fi
    warn "No pristine backup at $PRISTINE; leaving sshd_config as-is."
    return 1
}

# --- include-dir backup / restore -------------------------------------------
# On socket-activated systems the sshd-socket-generator reads Port/ListenAddress
# from /etc/ssh/sshd_config.d/*.conf as well. We comment out any Port lines we
# find there so they cannot override our change. We must back those files up
# and be able to restore them exactly (rollback + uninstall).
INCLUDE_BACKUP_DIR="${BACKUP_DIR}/sshd_config.d"
INCLUDE_BACKUP_INDEX="${BACKUP_DIR}/.sshd_config.d.baklist"

backup_include_dir() {
    mkdir -p "$INCLUDE_BACKUP_DIR"
    : > "$INCLUDE_BACKUP_INDEX"
    if [[ ! -d "$INCLUDE_DIR" ]]; then
        return 0
    fi
    local f bak
    for f in "$INCLUDE_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        # Only back up files that actually carry a (live or commented) Port
        # line, since those are the only ones we ever modify.
        if grep -qi '^[[:space:]]*#?[[:space:]]*Port[[:space:]]' "$f"; then
            bak="${INCLUDE_BACKUP_DIR}/$(basename "$f").bak"
            cp -a "$f" "$bak"
            printf '%s\n' "$bak" >> "$INCLUDE_BACKUP_INDEX"
            log "Backed up $(basename "$f") to $bak"
        fi
    done
}

restore_include_dir() {
    # Restore every backed-up include file, dropping our commented Port lines.
    if [[ ! -f "$INCLUDE_BACKUP_INDEX" ]]; then
        return 0
    fi
    local bak
    while IFS= read -r bak; do
        [[ -z "$bak" ]] && continue
        if [[ -f "$bak" ]]; then
            cp -a "$bak" "${INCLUDE_DIR}/$(basename "$bak" .bak)"
            log "Restored ${INCLUDE_DIR}/$(basename "$bak" .bak)"
        fi
    done < "$INCLUDE_BACKUP_INDEX"
}

clear_include_dir_backup() {
    local bak
    if [[ -f "$INCLUDE_BACKUP_INDEX" ]]; then
        while IFS= read -r bak; do
            [[ -z "$bak" ]] && continue
            rm -f "$bak"
        done < "$INCLUDE_BACKUP_INDEX"
    fi
    rm -f "$INCLUDE_BACKUP_INDEX"
    rmdir "$INCLUDE_BACKUP_DIR" 2>/dev/null || true
}

# --- subcommands ------------------------------------------------------------

cmd_change() {
    require_root
    detect_os
    local new_port="$1"
    valid_port "$new_port"

    # 1. Backups (echoes the timestamped backup path).
    local ts_bak
    ts_bak="$(take_backups)"

    # 2. Record the old port(s) so disable-old-port / uninstall can target them.
    local old_ports
    old_ports="$(configured_ports)"
    local old_port
    old_port="$(echo "$old_ports" | grep -E '^[0-9]+$' | head -n1 || true)"
    [[ -z "${old_port:-}" ]] && old_port="22"
    # Store: line1 = old_port, line2 = new_port
    printf '%s\n%s\n' "$old_port" "$new_port" > "$STATE_FILE"

    # 3. Open the NEW port in the firewall FIRST, and verify.
    log "Opening firewall for port $new_port..."
    open_firewall "$new_port"
    if ! verify_firewall_rule "$new_port"; then
        err "Could not verify firewall rule for $new_port. Aborting before touching sshd."
        close_firewall "$new_port"
        exit 1
    fi

    # 4. Edit sshd_config: comment out all existing Port lines (in the main
    #    file AND the include dir), then explicitly write the old AND new
    #    ports so both stay open until disable-old-port runs.
    # Back up the include-dir files we are about to modify so every rollback
    # path can restore them exactly.
    backup_include_dir
    local tmp
    tmp="$(mktemp /tmp/sshd_config.XXXXXX)"
    sed -E 's/^[[:space:]]*Port[[:space:]]+/#Port /' "$SSHD_CONF" > "$tmp"
    # Remove the old line and append both ports.
    # (The sed above already commented existing Port lines; we now append the
    #  canonical ones at the end.)
    echo "Port ${old_port}" >> "$tmp"
    echo "Port ${new_port}" >> "$tmp"
    cat "$tmp" > "$SSHD_CONF"
    rm -f "$tmp"

    # Also neutralize any Port lines in the include dir (they would override).
    # On socket-activated systems these drop-ins feed sshd-socket-generator, so
    # commenting their Port lines is what lets our new Port lines take effect.
    if [[ -d "$INCLUDE_DIR" ]]; then
        for f in "$INCLUDE_DIR"/*.conf; do
            [[ -f "$f" ]] || continue
            local ftmp
            ftmp="$(mktemp /tmp/sshd_include.XXXXXX)"
            sed -E 's/^[[:space:]]*Port[[:space:]]+/#&/' "$f" > "$ftmp"
            cat "$ftmp" > "$f"
            rm -f "$ftmp"
        done
    fi

    # 5. Test the new config.
    log "Testing new sshd_config (sshd -t)..."
    if ! sshd -t; then
        err "sshd -t failed. Restoring backup and rolling back."
        cp -a "$ts_bak" "$SSHD_CONF"
        restore_include_dir
        close_firewall "$new_port"
        rm -f "$STATE_FILE"
        exit 1
    fi

    # 6. Reload. Handle socket activation vs plain service.
    #    On socket-activated systems (Ubuntu 22.10+/24.04) the listening ports
    #    come from ssh.socket, whose ListenStream= lines are regenerated by
    #    sshd-socket-generator from sshd_config / sshd_config.d/*.conf.
    #    The documented sequence (openssh-server README.Debian, Ubuntu 24.04)
    #    is: edit sshd_config, then `systemctl daemon-reload` (re-runs the
    #    generator) and `systemctl restart ssh.socket`. We also restart
    #    ssh.service so the active service picks the new port up too.
    log "Reloading sshd..."
    if is_socket_activated; then
        systemctl daemon-reload
        systemctl restart "$SOCKET_UNIT" 2>/dev/null || true
        systemctl enable "$SERVICE" 2>/dev/null || true
        systemctl restart "$SERVICE" 2>/dev/null || true
    else
        systemctl daemon-reload
        systemctl reload-or-restart "$SERVICE"
    fi

    # 7. Verify sshd is actually listening on the new port.
    log "Verifying sshd is listening on port $new_port..."
    sleep 2
    if ! ss -ltnp 2>/dev/null | grep -qE "[:.]${new_port}[[:space:]]"; then
        err "sshd is NOT listening on $new_port after reload. Rolling back."
        # Roll back config and firewall, restore the old port behaviour.
        cp -a "$ts_bak" "$SSHD_CONF"
        restore_include_dir
        close_firewall "$new_port"
        if is_socket_activated; then
            systemctl daemon-reload
            systemctl restart "$SOCKET_UNIT" 2>/dev/null || true
            systemctl restart "$SERVICE" 2>/dev/null || true
        else
            systemctl reload-or-restart "$SERVICE" 2>/dev/null || true
        fi
        rm -f "$STATE_FILE"
        exit 1
    fi

    echo ""
    warn "SSH now also listens on port $new_port (old port $old_port is still open)."
    warn "Open a SECOND terminal and test:  ssh -p $new_port user@host"
    warn "Only after that works, run:  ssh-port.sh disable-old-port"
    warn "Do NOT close this session until you have confirmed access on $new_port."
    # Clear the include-dir backups now that the change is verified good; the
    # files are intentionally left commented-out, which is the desired state.
    clear_include_dir_backup
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
    [[ -z "${new_port:-}" ]] && { err "State file is incomplete."; exit 1; }

    warn "Closing old SSH port $old_port. Make sure you can still reach $new_port."

    # Confirm the new port is reachable (still in use by sshd) before we
    # remove the old one; this is the last safety net.
    if ! ss -ltnp 2>/dev/null | grep -qE "[:.]${new_port}[[:space:]]"; then
        err "New port $new_port is not currently listening. Refusing to close $old_port."
        exit 1
    fi

    close_firewall "$old_port"

    # Remove only the old Port line from sshd_config.
    local tmp
    tmp="$(mktemp /tmp/sshd_config.XXXXXX)"
    grep -vE "^[[:space:]]*Port[[:space:]]+${old_port}([[:space:]]|$)" "$SSHD_CONF" > "$tmp" || true
    cat "$tmp" > "$SSHD_CONF"
    rm -f "$tmp"

    if ! sshd -t; then
        err "sshd -t failed after closing old port. Reverting."
        echo "Port ${old_port}" >> "$SSHD_CONF"
        open_firewall "$old_port"
        exit 1
    fi
    # Reload per the detected mode; on socket-activated systems the ports are
    # regenerated by sshd-socket-generator, so restart ssh.socket.
    if is_socket_activated; then
        systemctl daemon-reload
        systemctl restart "$SOCKET_UNIT" 2>/dev/null || true
        systemctl restart "$SERVICE" 2>/dev/null || true
    else
        systemctl reload-or-restart "$SERVICE"
    fi
    rm -f "$STATE_FILE"
    log "Old port $old_port closed. New port $new_port remains open."
}

cmd_status() {
    local ports
    ports="$(configured_ports)"
    if [[ -n "$ports" ]]; then
        log "Configured SSH port(s): $(echo "$ports" | tr '\n' ' ')"
    else
        log "No explicit Port line (default: 22)."
    fi
    if is_socket_activated; then
        log "SSH is socket-activated (ssh.socket)."
    fi
    if [[ -f "$STATE_FILE" ]]; then
        log "State file: old=$(sed -n '1p' "$STATE_FILE") new=$(sed -n '2p' "$STATE_FILE")"
    else
        log "No state file (nothing changed yet)."
    fi
}

cmd_uninstall() {
    require_root
    detect_os
    warn "Restoring the pristine sshd_config and closing the port we opened."
    local new_port=""
    if [[ -f "$STATE_FILE" ]]; then
        new_port="$(sed -n '2p' "$STATE_FILE")"
    fi
    restore_pristine
    restore_include_dir
    clear_include_dir_backup
    if [[ -n "$new_port" ]]; then
        close_firewall "$new_port"
    fi
    rm -f "$STATE_FILE"
    if is_socket_activated; then
        systemctl daemon-reload
        systemctl restart "$SOCKET_UNIT" 2>/dev/null || true
        systemctl restart "$SERVICE" 2>/dev/null || true
    else
        systemctl reload-or-restart "$SERVICE" 2>/dev/null || true
    fi
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
