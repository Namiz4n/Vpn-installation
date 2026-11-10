#!/bin/bash
#
# tools/tunnel.sh -- port-forward tunnel (iptables)
#
# Opens a local listening port on the VPS and forwards it (DNAT + MASQUERADE)
# to a destination IP:port over the protocol you choose.
#
# Subcommands:
#   add <local-port> <dest-ip> <dest-port> [tcp|udp]
#       add a forwarding rule (DNAT + MASQUERADE + FORWARD) and persist it
#   list
#       list the rules we added (tagged with our marker)
#   remove <local-port> <dest-ip> <dest-port> [tcp|udp]
#       remove the matching rule we added
#   uninstall
#       remove every rule we added, clear persistence, and disable ip_forward
#
# OS: Debian/Ubuntu only.
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

MARKER="vpn-install-tunnel"
SYSCONF="/etc/sysctl.d/99-vpn-install-forward.conf"
NAT_PERSIST="/etc/iptables-tunnel/nat.rules.v4"
NAT_PERSIST_DIR="$(dirname "$NAT_PERSIST")"

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

valid_ip() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        err "Invalid IP '$ip'. Expected dotted-quad IPv4."
        return 1
    fi
    local -a octets=()
    IFS='.' read -ra octets <<< "$ip"
    local o
    for o in "${octets[@]}"; do
        if [[ "$o" -gt 255 ]]; then
            err "Invalid octet '$o' in IP '$ip'."
            return 1
        fi
    done
    if [[ "$ip" =~ ^127\. || "$ip" =~ ^0\. || "$ip" =~ ^255\. ]]; then
        err "IP '$ip' is not a routable public address."
        return 1
    fi
}

valid_port() {
    local p="$1"
    if [[ ! "$p" =~ ^[0-9]+$ || "$p" -lt 1 || "$p" -gt 65535 ]]; then
        err "Invalid port '$p'. Must be 1-65535."
        return 1
    fi
}

enable_ip_forward() {
    echo "net.ipv4.ip_forward = 1" > "$SYSCONF"
    sysctl -p "$SYSCONF"
}

have_iptables() {
    command -v iptables >/dev/null 2>&1
}

# Each comment tag is unique per (proto,lport,dip,dport) so we can delete
# exactly one rule at a time.
tag() { printf '%s:%s:%s:%s:%s' "$MARKER" "$1" "$2" "$3" "$4"; }

# Persist our NAT rules across reboots.
persist_nat_rules() {
    mkdir -p "$NAT_PERSIST_DIR"
    iptables-save -t nat > "$NAT_PERSIST"
    # Enable the persist service so it loads on boot.
    if command -v systemctl >/dev/null 2>&1; then
        if [[ ! -f "/etc/systemd/system/iptables-tunnel-persist.service" ]]; then
            cat > "/etc/systemd/system/iptables-tunnel-persist.service" <<EOF
[Unit]
Description=Persist iptables tunnel rules
Before=network.target
After=systemd-sysv-generator.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/iptables-restore < ${NAT_PERSIST}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
        fi
        systemctl enable iptables-tunnel-persist.service
        systemctl start iptables-tunnel-persist.service
    fi
}

remove_persist() {
    rm -f "$NAT_PERSIST"
    if command -v systemctl >/dev/null 2>&1; then
        if [[ -f "/etc/systemd/system/iptables-tunnel-persist.service" ]]; then
            systemctl stop iptables-tunnel-persist.service 2>/dev/null || true
            systemctl disable iptables-tunnel-persist.service 2>/dev/null || true
            rm -f "/etc/systemd/system/iptables-tunnel-persist.service"
            systemctl daemon-reload
        fi
    fi
}

# --- subcommands ------------------------------------------------------------

cmd_add() {
    require_root
    detect_os
    local lport="$1" dip="$2" dport="$3" proto="${4:-tcp}"
    valid_port "$lport"
    valid_ip "$dip"
    valid_port "$dport"
    if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
        err "Protocol must be 'tcp' or 'udp'."
        exit 1
    fi
    have_iptables || { err "iptables not available. Install it (apt install iptables)." ; exit 1; }

    local t
    t="$(tag "$proto" "$lport" "$dip" "$dport")"

    enable_ip_forward

    # Idempotent: drop any existing identical rule first, then add.
    iptables -t nat -C PREROUTING -p "$proto" --dport "$lport" \
        -m comment --comment "$t" 2>/dev/null \
        && iptables -t nat -D PREROUTING -p "$proto" --dport "$lport" \
               -m comment --comment "$t"
    iptables -t nat -C POSTROUTING -s "${dip}/32" -p "$proto" --dport "$dport" \
        -m comment --comment "$t" 2>/dev/null \
        && iptables -t nat -D POSTROUTING -s "${dip}/32" -p "$proto" --dport "$dport" \
               -m comment --comment "$t"

    iptables -t nat -A PREROUTING -p "$proto" --dport "$lport" \
        -j DNAT --to-destination "${dip}:${dport}" \
        -m comment --comment "$t"
    iptables -t nat -A POSTROUTING -s "${dip}/32" -p "$proto" --dport "$dport" \
        -j MASQUERADE \
        -m comment --comment "$t"
    iptables -A FORWARD -d "${dip}/32" -p "$proto" --dport "$dport" \
        -m state --state RELATED,ESTABLISHED -j ACCEPT \
        -m comment --comment "$t"
    iptables -A FORWARD -d "${dip}/32" -p "$proto" --dport "$dport" \
        -j ACCEPT \
        -m comment --comment "$t"

    # Persist the NAT rules.
    persist_nat_rules

    log "Forwarding $proto/$lport -> ${dip}:${dport} (tag $t)."
    log "Rules persisted to $NAT_PERSIST and reloaded at boot."
}

cmd_list() {
    have_iptables || { err "iptables not available."; exit 1; }
    echo "--- nat PREROUTING ---"
    iptables -t nat -L PREROUTING -n -v -Z 2>/dev/null | grep -F "$MARKER" || echo "(none)"
    echo "--- nat POSTROUTING ---"
    iptables -t nat -L POSTROUTING -n -v -Z 2>/dev/null | grep -F "$MARKER" || echo "(none)"
    echo "--- filter FORWARD ---"
    iptables -L FORWARD -n -v -Z 2>/dev/null | grep -F "$MARKER" || echo "(none)"
}

cmd_remove() {
    require_root
    local lport="$1" dip="$2" dport="$3" proto="${4:-tcp}"
    valid_port "$lport"
    valid_ip "$dip"
    valid_port "$dport"
    if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
        err "Protocol must be 'tcp' or 'udp'."
        exit 1
    fi
    have_iptables || { err "iptables not available."; exit 1; }

    local t
    t="$(tag "$proto" "$lport" "$dip" "$dport")"
    iptables -t nat -C PREROUTING -p "$proto" --dport "$lport" \
        -m comment --comment "$t" 2>/dev/null \
        && iptables -t nat -D PREROUTING -p "$proto" --dport "$lport" \
               -m comment --comment "$t"
    iptables -t nat -C POSTROUTING -s "${dip}/32" -p "$proto" --dport "$dport" \
        -m comment --comment "$t" 2>/dev/null \
        && iptables -t nat -D POSTROUTING -s "${dip}/32" -p "$proto" --dport "$dport" \
               -m comment --comment "$t"
    while iptables -C FORWARD -d "${dip}/32" -p "$proto" --dport "$dport" \
        -m state --state RELATED,ESTABLISHED -j ACCEPT \
        -m comment --comment "$t" 2>/dev/null; do
        iptables -D FORWARD -d "${dip}/32" -p "$proto" --dport "$dport" \
            -m state --state RELATED,ESTABLISHED -j ACCEPT \
            -m comment --comment "$t"
    done
    while iptables -C FORWARD -d "${dip}/32" -p "$proto" --dport "$dport" \
        -j ACCEPT -m comment --comment "$t" 2>/dev/null; do
        iptables -D FORWARD -d "${dip}/32" -p "$proto" --dport "$dport" \
            -j ACCEPT -m comment --comment "$t"
    done
    # Re-persist after removal
    persist_nat_rules
    log "Removed rules for $proto/$lport -> ${dip}:${dport}."
}

cmd_uninstall() {
    require_root
    warn "Removing tagged rules and disabling the ip_forward flag we set."
    local lines
    lines="$(iptables-save 2>/dev/null | grep -F "$MARKER" || true)"
    if [[ -n "$lines" ]]; then
        local t proto lport dip dport line
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            t="${line##--comment }"
            t="${t#"$MARKER":}"
            IFS=':' read -r proto lport dip dport <<< "$t"
            [[ -z "$proto" || -z "$lport" || -z "$dip" || -z "$dport" ]] && continue
            cmd_remove "$lport" "$dip" "$dport" "$proto" || warn "Could not remove $proto/$lport -> ${dip}:${dport}"
        done <<< "$lines"
    fi
    remove_persist
    rm -f "$SYSCONF"
    sysctl -w net.ipv4.ip_forward=0 2>/dev/null || true
    log "Tunnel uninstall complete."
}

# --- dispatch ---------------------------------------------------------------

main() {
    local cmd="${1:-help}"
    case "$cmd" in
        add)
            [[ $# -lt 4 ]] && { err "Usage: tunnel.sh add <local-port> <dest-ip> <dest-port> [tcp|udp]"; exit 1; }
            cmd_add "$2" "$3" "$4" "${5:-tcp}"
            ;;
        list)
            cmd_list
            ;;
        remove)
            [[ $# -lt 4 ]] && { err "Usage: tunnel.sh remove <local-port> <dest-ip> <dest-port> [tcp|udp]"; exit 1; }
            cmd_remove "$2" "$3" "$4" "${5:-tcp}"
            ;;
        uninstall)
            cmd_uninstall
            ;;
        help|*)
            echo "Usage: tunnel.sh {add <lport> <ip> <dport> [tcp|udp] | list | remove <lport> <ip> <dport> [tcp|udp] | uninstall}"
            ;;
    esac
}

main "$@"
