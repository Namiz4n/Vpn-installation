#!/bin/bash
#
# tools/ssl.sh -- obtain a TLS certificate with certbot
#
# Subcommands:
#   issue <domain> [domain...]
#       run certbot (standalone by default, webroot if --webroot <path> is
#       given). Backs up any existing certificate before replacing it.
#   status
#       print expiry for the certbot-managed certs we have.
#   renew
#       run certbot renew and print the result.
#   uninstall
#       delete the certbot-managed certs (keeps the webroot).
#
# OS: Debian/Ubuntu only.
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIGURED_MARKER="/etc/letsencrypt/.vpn-install-managed"
CERT_LIVE_DIR="/etc/letsencrypt/live"

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

apt_get() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get -yqq "$@"
}

valid_domain() {
    local d="$1"
    if [[ ! "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,62})[a-zA-Z0-9]$ ]]; then
        err "Invalid domain '$d'."
        return 1
    fi
}

ensure_certbot() {
    if ! command -v certbot >/dev/null 2>&1; then
        log "Installing certbot..."
        apt_get update
        apt_get install certbot
    fi
}

# --- subcommands ------------------------------------------------------------

cmd_issue() {
    require_root
    detect_os
    local domains=()
    local mode="standalone"
    local webroot=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --webroot)
                mode="webroot"
                webroot="${2:-}"
                [[ -z "$webroot" ]] && { err "--webroot requires a path."; exit 1; }
                [[ ! -d "$webroot" ]] && { err "Webroot directory '$webroot' does not exist."; exit 1; }
                shift 2
                ;;
            *)
                valid_domain "$1"
                domains+=("$1")
                shift
                ;;
        esac
    done
    [[ ${#domains[@]} -eq 0 ]] && { err "At least one domain required."; exit 1; }

    ensure_certbot
    # Back up existing cert (if any) before re-issuing
    if [[ -d "${CERT_LIVE_DIR}/${domains[0]}" ]]; then
        local backup_dir
        backup_dir="/root/letsencrypt-backup-$(date +%s)"
        mkdir -p "$backup_dir"
        cp -a "${CERT_LIVE_DIR}/${domains[0]}" "$backup_dir/" 2>/dev/null || true
        warn "Existing certificate backed up to $backup_dir"
    fi

    local args=()
    args+=(--non-interactive --agree-tos)
    # Register an account only when one does not already exist.
    if ! ls /etc/letsencrypt/accounts/*/directory/*.json >/dev/null 2>&1; then
        local email="${EMAIL:-admin@${domains[0]}}"
        args+=("--email" "$email" "--no-redirect")
    fi
    if [[ "$mode" == "webroot" ]]; then
        args+=(--webroot)
        args+=("--webroot-path")
        args+=("$webroot")
    fi
    for d in "${domains[@]}"; do
        args+=(-d "$d")
    done

    log "Running certbot issue (mode=$mode) for: ${domains[*]}"
    certbot certonly "${args[@]}"

    # Make sure automated renewal is active (systemd timer on modern
    # Debian/Ubuntu, cron otherwise).
    if command -v systemctl >/dev/null 2>&1 && [[ -f /etc/systemd/system/timers.target.wants/certbot.timer ]]; then
        systemctl enable --now certbot.timer 2>/dev/null || true
        log "Renewal timer enabled (certbot.timer)."
    elif command -v certbot >/dev/null 2>&1; then
        certbot renew --dry-run >/dev/null 2>&1 || true
        log "Renewal available via 'certbot renew' (enable the timer or a cron job)."
    fi
    touch "$CONFIGURED_MARKER"
    log "Certificate issued."
}

cmd_status() {
    if [[ ! -d "$CERT_LIVE_DIR" ]]; then
        log "No certs in $CERT_LIVE_DIR yet."
        return 0
    fi
    local live
    for live in "$CERT_LIVE_DIR"/*/; do
        [[ -d "$live" ]] || continue
        local name
        name="$(basename "$live")"
        if [[ -f "${live}/cert.pem" ]]; then
            local expiry
            expiry="$(openssl x509 -checkend 0 -noout -in "${live}/cert.pem" 2>/dev/null && echo "not expired" || echo "EXPIRED")"
            local expiry_date
            expiry_date="$(openssl x509 -in "${live}/cert.pem" -noout -enddate 2>/dev/null | sed 's/notAfter=//')"
            printf '%s: %s (notAfter: %s)\n' "$name" "$expiry" "$expiry_date"
        fi
    done
    # Report whether automated renewal is active.
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet certbot.timer 2>/dev/null; then
        log "Renewal: certbot.timer is active."
    elif [[ -f /etc/cron.d/certbot ]]; then
        log "Renewal: cron job present (/etc/cron.d/certbot)."
    else
        warn "Renewal: no active renewal timer or cron job found. Run 'ssl.sh renew' manually."
    fi
}

cmd_renew() {
    require_root
    ensure_certbot
    log "Renewing all managed certificates..."
    certbot renew
    log "Renewal complete."
}

cmd_uninstall() {
    require_root
    warn "Removing managed certificates. Webroot is kept."
    local d
    for d in "$CERT_LIVE_DIR"/*/; do
        [[ -d "$d" ]] || continue
        certbot delete --cert-name "$(basename "$d")" 2>/dev/null || true
    done
    rm -f "$CONFIGURED_MARKER"
    log "Managed certificates removed."
}

# --- dispatch ---------------------------------------------------------------

main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
        issue)
            cmd_issue "$@"
            ;;
        status)
            cmd_status
            ;;
        renew)
            cmd_renew
            ;;
        uninstall)
            cmd_uninstall
            ;;
        help|*)
            echo "Usage: ssl.sh {issue <domain> [..] [--webroot <path>] | status | renew | uninstall}"
            ;;
    esac
}

main "$@"
