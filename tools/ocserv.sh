#!/bin/bash
#
# tools/ocserv.sh -- OpenConnect VPN server (ocserv) installer / manager
#
# Installs ocserv (which bundles ocpasswd) from the distro package manager,
# generates a certificate (self-signed by default, or an existing one you
# point to), and manages user accounts via ocpasswd.
#
# UX (this script is self-contained and also launched with no arguments
# from main.sh):
#   * No arguments:
#       - not installed -> guided install (asks only the cert choice if
#         interactive; `--auto` takes the default self-signed cert),
#       - installed    -> short numbered management menu.
#   * Subcommands (power-user):
#       install [existing <cert-path>]
#       add-user <name> [password]
#       remove-user <name>
#       list-users
#       print-config
#       uninstall
#     Flags:
#       --auto                 accept the default (self-signed) cert,
#                              no prompts
#       --cert <path>          use an existing certificate (implies
#                              "existing" mode; the .key next to it is
#                              picked up if present)
#       --tcp-port <n> / --udp-port <n>  (default 443 each; env vars
#                              VPN_TCP_PORT / VPN_UDP_PORT also work)
#   * `-h` / `--help`: print usage. Any other first argument that is not a
#     known subcommand is treated as no-args, so running `ocserv.sh`
#     alone never prints a Usage line.
#
# OS: Debian/Ubuntu only (refuses to run otherwise).
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONF="/etc/ocserv/ocserv.conf"
PASSWORD_FILE="/etc/ocserv/ocpasswd"
SERVICE="ocserv"
CERT_DIR="/etc/ocserv/ssl"
CERT="${CERT_DIR}/server-cert.pem"
KEY="${CERT_DIR}/server-key.pem"
SELF_SIGNED_MARKER="${CERT_DIR}/.self-signed"
CONFIGURED_MARKER="/etc/ocserv/.vpn-install-configured"
NAT_SERVICE="vpn-install-ocserv-nat"
DEFAULT_TCP_PORT=443
DEFAULT_UDP_PORT=443
SUBNET="192.168.1.0"
NETMASK="255.255.255.0"

AUTO=0
CERT_MODE="self"
CERT_PATH=""
TCP_PORT="${VPN_TCP_PORT:-$DEFAULT_TCP_PORT}"
UDP_PORT="${VPN_UDP_PORT:-$DEFAULT_UDP_PORT}"

log()  { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}Warning: $*${NC}" >&2; }
err()  { echo -e "${RED}$*${NC}" >&2; }
info() { echo -e "${BLUE}$*${NC}"; }

usage() {
    cat <<EOF
Usage: bash ocserv.sh [subcommand] [flags]
  No arguments: guided install or management menu (recommended).
  Subcommands: install [existing <cert-path>] | add-user <name> [password]
               | remove-user <name> | list-users | print-config | uninstall
  Flags: --auto, --cert <path>, --tcp-port <n>, --udp-port <n>
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

apt_get() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get -yqq "$@"
}

valid_user() {
    local name="$1"
    if [[ -z "$name" ]]; then
        err "Username must not be empty."
        return 1
    fi
    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        err "Invalid username '$name'. Allowed: letters, digits, . _ -"
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

# Detect the outbound interface that carries the default route so NAT can
# masquerade on the right device. Fall back to the first non-loopback one.
default_route_iface() {
    local iface
    iface="$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'dev [^ ]+' | awk '{print $2}' | head -n1 || true)"
    if [[ -z "${iface:-}" || "$iface" == "lo" ]]; then
        iface="$(ip -o link show 2>/dev/null | awk '{print $2}' | grep -v '^lo$' | head -n1 || true)"
    fi
    printf '%s\n' "${iface:-}"
}

_ufw_active() {
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'
}

_firewalld_active() {
    command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null
}

# open_firewall <port> <tcp|udp|both>
open_firewall() {
    local port="$1" proto="${2:-both}" p
    for p in $( [[ "$proto" == "tcp" || "$proto" == "both" ]] && printf 'tcp ' )$( [[ "$proto" == "udp" || "$proto" == "both" ]] && printf 'udp' ); do
        if _ufw_active; then
            ufw allow "${port}/${p}"
        elif _firewalld_active; then
            firewall-cmd --permanent --add-port="${port}/${p}"
            firewall-cmd --reload
        fi
    done
}

# close_firewall <port> <tcp|udp|both>
close_firewall() {
    local port="$1" proto="${2:-both}" p
    for p in $( [[ "$proto" == "tcp" || "$proto" == "both" ]] && printf 'tcp ' )$( [[ "$proto" == "udp" || "$proto" == "both" ]] && printf 'udp' ); do
        if _ufw_active; then
            ufw delete allow "${port}/${p}" 2>/dev/null || true
        elif _firewalld_active; then
            firewall-cmd --permanent --remove-port="${port}/${p}" 2>/dev/null || true
            firewall-cmd --reload 2>/dev/null || true
        fi
    done
}

# Emit the ocserv config to stdout. No file writes; the caller redirects.
# This is the single source of truth for both the on-disk config and the
# CI-tested print-config mode.
emit_config() {
    local tcp_port="$1" udp_port="$2"
    cat <<EOF
# /etc/ocserv/ocserv.conf -- generated by tools/ocserv.sh
# Authentication via a plaintext password file managed with ocpasswd.
auth = "plain[passwd=${PASSWORD_FILE}]"

# TCP and UDP port numbers
tcp-port = ${tcp_port}
udp-port = ${udp_port}

# Server certificate and key
server-cert = ${CERT}
server-key  = ${KEY}

# Pool of addresses to lease to clients
ipv4-network = ${SUBNET}
ipv4-netmask = ${NETMASK}

# DNS servers handed to clients
dns = 1.1.1.1
dns = 8.8.8.8

# IPC socket between the main and worker processes. This option is
# required for ocserv --test-config to succeed; /run is the
# package-standard location for it (see the ocserv sample config).
socket-file = /run/ocserv.socket

# Client limits
max-clients = 64
max-same-clients = 4

# Push the default route to clients
route = default

# The virtual network interface ocserv creates
device = vpns

# Run as an unprivileged user
run-as-user = ocserv
run-as-group = ocserv
EOF
}

write_config() {
    local tcp_port="$1" udp_port="$2"
    local backup=""
    if [[ -f "$CONF" ]]; then
        backup="${CONF}.bak.$(date +%s)"
        cp "$CONF" "$backup"
        log "Backed up existing $CONF to $backup"
    fi
    emit_config "$tcp_port" "$udp_port" > "$CONF"
    chmod 640 "$CONF"
}

cmd_print_config() {
    valid_port "$TCP_PORT"
    valid_port "$UDP_PORT"
    emit_config "$TCP_PORT" "$UDP_PORT"
}

generate_password() {
    # 16 hex chars, shown once at the end of an interactive add.
    head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

add_user_interactive() {
    local name pass
    name="$(prompt_text "ocserv username" "vpnuser")"
    valid_user "$name"
    pass="$(generate_password)"
    ocpasswd -n -c "$PASSWORD_FILE" "$name" <<< "$pass"
    log "User '$name' added (password shown once below)."
    echo "user=$name password=$pass"
}

prompt_text() {
    local prompt="$1" default="$2" reply=""
    if [[ -t 0 ]]; then
        printf '%s [%s]: ' "$prompt" "$default"
        read -r reply || reply=""
        printf '%s' "${reply:-$default}"
    else
        printf '%s' "$default"
    fi
}

cmd_install() {
    require_root
    detect_os
    valid_port "$TCP_PORT"
    valid_port "$UDP_PORT"
    log "Installing ocserv..."
    apt_get update
    # ocserv bundles ocpasswd; openssl for self-signed certs
    apt_get install ocserv openssl

    mkdir -p "$CERT_DIR"

    # --- certificate ----------------------------------------------------------
    if [[ "$CERT_MODE" == "existing" && -n "$CERT_PATH" ]]; then
        if [[ ! -f "$CERT_PATH" ]]; then
            die "Certificate not found at $CERT_PATH"
        fi
        log "Using existing certificate: $CERT_PATH"
        cp "$CERT_PATH" "$CERT"
        local key_guess="${CERT_PATH%.crt}.key"
        key_guess="${CERT_PATH%.pem}.key"
        if [[ -f "$key_guess" ]]; then
            cp "$key_guess" "$KEY"
        else
            key_guess="${CERT_PATH%.pem}.key"
            warn "Private key not found at $key_guess; ocserv will not start until one is placed there."
        fi
        rm -f "$SELF_SIGNED_MARKER"
        chmod 644 "$CERT"
        chmod 600 "$KEY"
    else
        log "Generating self-signed certificate (CN=vpn.local)..."
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -keyout "$KEY" -out "$CERT" \
            -subj "/CN=vpn.local" \
            -addext "keyUsage=digitalSignature,keyEncipherment" \
            -addext "extendedKeyUsage=serverAuth"
        touch "$SELF_SIGNED_MARKER"
        chmod 600 "$KEY"
        chmod 644 "$CERT"
    fi

    # --- users file -----------------------------------------------------------
    if [[ ! -f "$PASSWORD_FILE" ]]; then
        touch "$PASSWORD_FILE"
        chmod 640 "$PASSWORD_FILE"
    fi

    # --- main config ----------------------------------------------------------
    if [[ -f "$CONFIGURED_MARKER" ]]; then
        log "Already configured ($CONFIGURED_MARKER present); not rewriting $CONF."
    else
        write_config "$TCP_PORT" "$UDP_PORT"
        touch "$CONFIGURED_MARKER"
    fi

    # --- IP forwarding --------------------------------------------------------
    local sysctl_conf="/etc/sysctl.d/99-ocserv-forward.conf"
    echo "net.ipv4.ip_forward = 1" > "$sysctl_conf"
    sysctl -p "$sysctl_conf"

    # --- NAT (MASQUERADE on the real default-route interface, persisted) ------
    local iface
    iface="$(default_route_iface)"
    if [[ -z "$iface" ]]; then
        warn "Could not detect the default-route interface; skipping NAT setup."
    else
        log "Enabling NAT on interface $iface."
        # A small systemd service that applies the MASQUERADE rule at boot.
        cat > "/etc/systemd/system/${NAT_SERVICE}.service" <<EOF
[Unit]
Description=MASQUERADE for ocserv VPN client traffic (${SUBNET})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/iptables -t nat -A POSTROUTING -s ${SUBNET} -o ${iface} -j MASQUERADE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        # Apply it now (idempotent: drop an identical rule first).
        if iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$iface" -j MASQUERADE 2>/dev/null; then
            log "NAT rule already present."
        else
            iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$iface" -j MASQUERADE
        fi
        systemctl enable "$NAT_SERVICE"
        systemctl start "$NAT_SERVICE"
    fi

    # --- firewall port (tcp + udp) -------------------------------------------
    open_firewall "$TCP_PORT" tcp
    open_firewall "$UDP_PORT" udp

    # --- enable service -------------------------------------------------------
    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE"

    log "ocserv is running on TCP $TCP_PORT / UDP $UDP_PORT."
    log "Server domain for clients: vpn.local (or your configured domain)."
    log "Add a user with:  ocserv.sh add-user <name>"
}

cmd_add_user() {
    require_root
    local name="${1:-}"
    valid_user "$name"
    if [[ ! -f "$PASSWORD_FILE" ]]; then
        die "User database not found. Run 'install' first."
    fi
    if [[ -n "${2:-}" ]]; then
        ocpasswd -n -c "$PASSWORD_FILE" "$name" <<< "${2}"
    elif [[ -t 0 && "$AUTO" -eq 0 ]]; then
        ocpasswd -c "$PASSWORD_FILE" "$name"
    else
        local pass
        pass="$(generate_password)"
        ocpasswd -n -c "$PASSWORD_FILE" "$name" <<< "$pass"
        echo "user=$name password=$pass (shown once)"
    fi
    log "User '$name' added."
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        systemctl restart "$SERVICE"
    fi
}

cmd_remove_user() {
    require_root
    local name="${1:-}"
    valid_user "$name"
    if [[ ! -f "$PASSWORD_FILE" ]]; then
        die "User database not found."
    fi
    local tmp
    tmp="$(mktemp /tmp/ocserv-pw.XXXXXX)"
    grep -v "^${name}:" "$PASSWORD_FILE" > "$tmp" || true
    mv "$tmp" "$PASSWORD_FILE"
    chmod 640 "$PASSWORD_FILE"
    log "User '$name' removed."
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        systemctl restart "$SERVICE"
    fi
}

cmd_list_users() {
    if [[ ! -f "$PASSWORD_FILE" ]]; then
        log "No user database yet. Run 'install' first."
        return 0
    fi
    if [[ ! -s "$PASSWORD_FILE" ]]; then
        log "(no users)"
        return 0
    fi
    cut -d: -f1 "$PASSWORD_FILE"
}

status() {
    echo "=== ocserv status ==="
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        log "Service '$SERVICE': active"
    else
        warn "Service '$SERVICE': not running"
    fi
    if [[ -e "$CONF" ]]; then
        log "Config present: $CONF"
    else
        warn "Config missing: $CONF"
    fi
    cmd_list_users
}

cmd_uninstall() {
    require_root
    detect_os
    warn "Purging ocserv. Certificate and user database will be kept."
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        systemctl stop "$SERVICE"
    fi
    systemctl disable "$SERVICE" 2>/dev/null || true
    if systemctl is-enabled "$NAT_SERVICE" 2>/dev/null; then
        systemctl stop "$NAT_SERVICE" 2>/dev/null || true
        systemctl disable "$NAT_SERVICE" 2>/dev/null || true
    fi
    rm -f "/etc/systemd/system/${NAT_SERVICE}.service"
    systemctl daemon-reload
    apt_get purge ocserv
    close_firewall "$TCP_PORT" tcp
    close_firewall "$UDP_PORT" udp
    rm -f "$CONFIGURED_MARKER"
    log "Uninstalled. $CONF, $CERT and $PASSWORD_FILE were left in place."
}

# --- guided install -----------------------------------------------------------
guided_install() {
    if [[ -f "$CONFIGURED_MARKER" ]]; then
        info "ocserv already configured; running management menu instead."
        management_menu
        return 0
    fi
    echo
    echo "OpenConnect VPN (ocserv) server setup"
    if [[ -t 0 && "$AUTO" -eq 0 ]]; then
        local answer
        printf 'Certificate: [1] self-signed (default)  [2] existing cert path: '
        read -r answer || answer="1"
        case "$answer" in
            2|existing)
                CERT_MODE="existing"
                CERT_PATH="$(prompt_text "Path to certificate" "")"
                [[ -n "$CERT_PATH" ]] || die "No certificate path given."
                ;;
            *) CERT_MODE="self" ;;
        esac
    fi
    echo
    echo "  TCP port : $TCP_PORT"
    echo "  UDP port : $UDP_PORT"
    echo "  Subnet   : $SUBNET ($NETMASK)"
    echo
    local yesno
    printf 'Proceed with ocserv install? [Y/n] '
    read -r yesno || yesno="Y"
    if [[ "$yesno" =~ ^[Nn] ]]; then
        die "Aborted before writing anything."
    fi
    cmd_install
}

management_menu() {
    local choice
    while true; do
        echo
        echo "ocserv management menu"
        echo "  1) Status"
        echo "  2) Add user"
        echo "  3) Remove user"
        echo "  4) List users"
        echo "  5) Print config (dry-run)"
        echo "  6) Uninstall"
        echo "  0) Back / exit"
        printf 'Choice [0-6]: '
        read -r choice || choice="0"
        case "$choice" in
            1) status ;;
            2) add_user_interactive ;;
            3)
                local rname
                rname="$(prompt_text "Username to remove" "")"
                cmd_remove_user "$rname"
                ;;
            4) cmd_list_users ;;
            5) cmd_print_config ;;
            6)
                if ask_yes_no "Uninstall ocserv?" "n"; then
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

# --- argument parsing ---------------------------------------------------------
cmd=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --auto) AUTO=1; shift ;;
        --cert) CERT_MODE="existing"; CERT_PATH="${2:-}"; shift 2 ;;
        --tcp-port) TCP_PORT="${2:-}"; shift 2 ;;
        --udp-port) UDP_PORT="${2:-}"; shift 2 ;;
        install)
            cmd="install"
            if [[ "${2:-}" == "existing" ]]; then
                CERT_MODE="existing"
                CERT_PATH="${3:-}"
                shift 3
            else
                shift
            fi
            ;;
        add-user)
            cmd="add-user"; shift
            CMD_USER="${1:-}"; CMD_PASS="${2:-}"
            shift; [[ $# -gt 0 ]] && shift
            ;;
        remove-user)
            cmd="remove-user"; CMD_USER="${1:-}"; shift; [[ $# -gt 0 ]] && shift
            ;;
        list-users) cmd="list-users"; shift ;;
        print-config) cmd="print-config"; shift ;;
        uninstall) cmd="uninstall"; shift ;;
        -*) warn "Unknown flag: $1 (ignored)"; shift ;;
        *) cmd="${cmd:-default}"; shift ;;
    esac
done

main() {
    case "$cmd" in
        install)
            cmd_install
            ;;
        add-user)
            [[ -n "${CMD_USER:-}" ]] || die "Username required for add-user."
            cmd_add_user "$CMD_USER" "${CMD_PASS:-}"
            ;;
        remove-user)
            [[ -n "${CMD_USER:-}" ]] || die "Username required for remove-user."
            cmd_remove_user "$CMD_USER"
            ;;
        list-users)
            cmd_list_users
            ;;
        print-config)
            cmd_print_config
            ;;
        uninstall)
            cmd_uninstall
            ;;
        default|"")
            if [[ -f "$CONFIGURED_MARKER" ]] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
                management_menu
            else
                require_root
                detect_os
                guided_install
            fi
            ;;
        *)
            warn "Unknown subcommand '$cmd' (treated as no-args)."
            if [[ -f "$CONFIGURED_MARKER" ]] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
                management_menu
            else
                require_root
                detect_os
                guided_install
            fi
            ;;
    esac
}

main
