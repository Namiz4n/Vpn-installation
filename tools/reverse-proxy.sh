#!/bin/bash
#
# tools/reverse-proxy.sh -- nginx reverse proxy
#
# Creates an nginx server block that listens on a chosen domain:port and
# forwards to an upstream host:port. Subcommands:
#
#   add <domain> <upstream-host:port> [listen-port]
#       write /etc/nginx/sites-available/<domain>, enable it, nginx -t, reload
#   remove <domain>
#       disable the site, remove the config, nginx -t, reload
#   list
#       list sites we manage
#   print-config <domain> <upstream-host:port> [listen-port]
#       print a minimal full nginx.conf (events+http) wrapping the generated
#       server block, for CI / offline `nginx -t` testing. No files written.
#   uninstall
#       disable every site we added and clean up
#
# OS: Debian/Ubuntu only (nginx via apt).
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SITE_DIR="/etc/nginx/sites-available"
ENABLED_DIR="/etc/nginx/sites-enabled"
MARKER_FILE="/etc/nginx/.vpn-install-managed"

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

apt_get() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get -yqq "$@"
}

valid_domain() {
    local d="$1"
    # Hostname or IP; must not contain characters nginx would reject in a
    # server_name / filename.
    if [[ ! "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,61})[a-zA-Z0-9]$ ]]; then
        err "Invalid domain '$d'."
        return 1
    fi
    # Refuse a domain that could collide with an nginx directive keyword.
    case "$d" in
        http|https|include|server|location|events|worker_processes)
            err "Domain '$d' collides with an nginx directive. Choose another."
            return 1
            ;;
    esac
}

valid_upstream() {
    local u="$1"
    # host:port (port required), IPv4 or IPv6 in brackets.
    if [[ "$u" =~ ^(\[[0-9a-fA-F:.]+\]|[a-zA-Z0-9.-]+):([0-9]{1,5})$ ]]; then
        local port="${BASH_REMATCH[2]}"
        if [[ "$port" -gt 65535 ]]; then
            err "Upstream port $port out of range."
            return 1
        fi
        return 0
    fi
    err "Invalid upstream '$u'. Expected host:port or [ipv6]:port."
    return 1
}

valid_port() {
    local p="$1"
    if [[ ! "$p" =~ ^[0-9]+$ || "$p" -lt 1 || "$p" -gt 65535 ]]; then
        err "Invalid port '$p'. Must be 1-65535."
        return 1
    fi
}

ensure_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        log "Installing nginx..."
        apt_get update
        apt_get install nginx
    fi
    systemctl enable nginx
}

# --- firewall (shared) ------------------------------------------------------
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
        warn "No active ufw/firewalld detected. Open ${port}/tcp manually if a firewall is in use."
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

# Print the server-block body for a given domain/upstream/port (no file IO).
server_block() {
    local domain="$1" upstream="$2" listen_port="$3"
    cat <<EOF
server {
    listen ${listen_port};
    server_name ${domain};

    location / {
        proxy_pass http://${upstream};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
}

# --- subcommands ------------------------------------------------------------

cmd_add() {
    require_root
    detect_os
    local domain="$1" upstream="$2" listen_port="${3:-80}"
    valid_domain "$domain"
    valid_upstream "$upstream"
    valid_port "$listen_port"
    ensure_nginx

    local site_file="${SITE_DIR}/${domain}"
    local enabled_link="${ENABLED_DIR}/${domain}"

    if [[ -f "$site_file" ]]; then
        warn "$site_file already exists; not overwriting (remove it first if you want a fresh one)."
        exit 1
    fi

    mkdir -p "$SITE_DIR" "$ENABLED_DIR"
    server_block "$domain" "$upstream" "$listen_port" > "$site_file"
    ln -sf "$site_file" "$enabled_link"
    grep -qxF "$domain" "$MARKER_FILE" 2>/dev/null || echo "$domain" >> "$MARKER_FILE"

    # Open the port in the firewall
    open_firewall "$listen_port"

    # Test before reloading
    if ! nginx -t; then
        err "nginx config test failed. Rolling back."
        rm -f "$enabled_link"
        rm -f "$site_file"
        sed -i "/^${domain}\$/d" "$MARKER_FILE" 2>/dev/null || true
        exit 1
    fi
    systemctl reload nginx

    log "Reverse proxy for $domain -> $upstream is live on port $listen_port."
}

cmd_remove() {
    require_root
    local domain="$1"
    valid_domain "$domain"
    local site_file="${SITE_DIR}/${domain}"
    local enabled_link="${ENABLED_DIR}/${domain}"
    rm -f "$enabled_link"
    rm -f "$site_file"
    sed -i "/^${domain}\$/d" "$MARKER_FILE" 2>/dev/null || true
    if command -v nginx >/dev/null 2>&1; then
        if ! nginx -t; then
            err "nginx config test failed after removing $domain."
            exit 1
        fi
        systemctl reload nginx
    fi
    log "Site '$domain' removed."
}

cmd_list() {
    if [[ ! -f "$MARKER_FILE" ]]; then
        log "No sites managed by this script yet."
        return 0
    fi
    if [[ ! -s "$MARKER_FILE" ]]; then
        log "(empty)"
        return 0
    fi
    cat "$MARKER_FILE"
}

# Print a minimal, self-contained nginx.conf that contains the generated
# server block inline, so CI can run `nginx -t -c <file>` without a full
# nginx setup. No files are written.
cmd_print_config() {
    local domain="${1:-example.com}" upstream="${2:-127.0.0.1:8080}" listen_port="${3:-8080}"
    valid_domain "$domain"
    valid_upstream "$upstream"
    valid_port "$listen_port"
    cat <<EOF
worker_processes 1;
pid /tmp/nginx-ci.pid;
events {}
http {
    access_log off;
    include mime.types;

$(server_block "$domain" "$upstream" "$listen_port" | sed 's/^/    /')
}
EOF
}

cmd_uninstall() {
    require_root
    warn "Removing every site this script added."
    if [[ -f "$MARKER_FILE" ]]; then
        local d
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            cmd_remove "$d"
        done < "$MARKER_FILE"
    fi
    rm -f "$MARKER_FILE"
    log "All managed sites removed."
}

# --- dispatch ---------------------------------------------------------------

main() {
    local cmd="${1:-help}"
    case "$cmd" in
        add)
            [[ $# -lt 3 ]] && { err "Usage: reverse-proxy.sh add <domain> <upstream> [port]"; exit 1; }
            cmd_add "$2" "$3" "${4:-80}"
            ;;
        remove)
            [[ -z "${2:-}" ]] && { err "Usage: reverse-proxy.sh remove <domain>"; exit 1; }
            cmd_remove "$2"
            ;;
        list)
            cmd_list
            ;;
        print-config)
            cmd_print_config "${2:-}" "${3:-}" "${4:-}"
            ;;
        uninstall)
            cmd_uninstall
            ;;
        help|*)
            echo "Usage: reverse-proxy.sh {add <domain> <upstream> [port] | remove <domain> | list | print-config [domain] [upstream] [port] | uninstall}"
            ;;
    esac
}

main "$@"
