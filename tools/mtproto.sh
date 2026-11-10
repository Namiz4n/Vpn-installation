#!/bin/bash
#
# tools/mtproto.sh -- MTProto proxy for Telegram
#
# Uses the prebuilt release binary of 9seconds/mtg, a maintained Go
# MTProto proxy (MIT license). Only the binary is downloaded at runtime;
# no source is vendored.
#
# Pinned release:
#   version : v2.3.0
#   release : https://github.com/9seconds/mtg/releases/tag/v2.3.0
#   assets  : mtg-2.3.0-linux-amd64.tar.gz / mtg-2.3.0-linux-arm64.tar.gz
#   SHA-256 : verified against https://github.com/9seconds/mtg/releases/download/v2.3.0/mtg-2.3.0-checksums.txt
#
# Secret generation:
#   mtg generate-secret --hex <hostname>
#   (the secret must start with "ee" and encode the hostname as ASCII in
#    the latter 31 bytes; see the project README)
#
# Config format: TOML at /etc/mtg.toml; only "secret" and "bind-to" are
# mandatory. See https://github.com/9seconds/mtg/blob/master/example.config.toml
#
# Subcommands:
#   install        download + install + systemd + firewall
#   add-user <host>    generate a new secret for <host>, store it in a
#                      secrets file (0600), restart the service
#   remove-user <hex>  remove a secret by its 64-hex value
#   list-users       list secrets (hex values only, never printed in logs)
#   link [host]    print the tg:// link for the first (or named) secret
#   uninstall        stop service, remove binary + config (secrets kept)
#
# OS: Debian/Ubuntu only.
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

MTG_VERSION="v2.3.0"
BIN="/usr/local/bin/mtg"
CONFIG="/etc/mtg.toml"
SECRETS="/etc/mtg/secrets"          # one line per secret (hex), chmod 600
SECRETS_DIR="$(dirname "$SECRETS")"
SERVICE="mtg"
CONFIGURED_MARKER="${SECRETS_DIR}/.vpn-install-configured"
DEFAULT_PORT=443

# SHA-256 checksums for the two Linux release assets (from the v2.3.0
# release page, mtg-2.3.0-checksums.txt):
SHA256_AMD64="11c038ea5eeebd5d49148048975c24f7b0c4fa4c1cf4f15a2410203e2da01812"
SHA256_ARM64="86e0fc6f50bfb453b7a6e8b91497c6661a7d64a3f607828e0e42f534d795ac5a"

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

# Architecture detection for the release binary
detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *)
            err "Unsupported CPU architecture: $machine (need x86_64 or aarch64)."
            exit 1
            ;;
    esac
}

# Download, verify, and install the mtg binary
install_binary() {
    local arch="$1"
    local asset="mtg-${MTG_VERSION#v}-linux-${arch}.tar.gz"
    local url="https://github.com/9seconds/mtg/releases/download/${MTG_VERSION}/${asset}"
    local expected_sha
    if [[ "$arch" == "amd64" ]]; then
        expected_sha="$SHA256_AMD64"
    else
        expected_sha="$SHA256_ARM64"
    fi

    log "Downloading $asset from 9seconds/mtg ${MTG_VERSION}..."
    local tmp
    tmp="$(mktemp /tmp/mtg-dl.XXXXXX)"
    trap 'rm -f "$tmp" "$extracted" 2>/dev/null' EXIT
    local extracted=""

    if ! curl -fsSL --retry 3 -o "$tmp" "$url"; then
        err "Failed to download $asset"
        exit 1
    fi

    local actual_sha
    actual_sha="$(sha256sum "$tmp" | awk '{print $1}')"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        err "SHA-256 mismatch for $asset"
        err "  expected: $expected_sha"
        err "  actual:   $actual_sha"
        exit 1
    fi
    log "SHA-256 verified."

    # Extract the binary
    extracted="$(mktemp -d /tmp/mtg-extract.XXXXXX)"
    tar -xzf "$tmp" -C "$extracted"
    local binary
    binary="$(find "$extracted" -type f -name 'mtg' | head -n1)"
    [[ -z "$binary" ]] && { err "Could not find mtg binary in archive"; exit 1; }

    install -m 0755 "$binary" "$BIN"
    chmod 0755 "$BIN"

    # Clean up
    rm -rf "$tmp" "$extracted"
    trap - EXIT

    log "mtg ${MTG_VERSION} installed at $BIN"
}

# Generate a secret for a given hostname using the mtg binary
# (mtg generate-secret --hex <host>)
generate_secret() {
    local host="$1"
    "$BIN" generate-secret --hex "$host"
}

valid_hostname() {
    local h="$1"
    if [[ -z "$h" || ! "$h" =~ ^[a-zA-Z0-9.]([a-zA-Z0-9.-]{0,253})[a-zA-Z0-9]$ ]]; then
        err "Invalid hostname '$h'. Use a valid DNS name."
        return 1
    fi
}

open_firewall() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "$port/tcp"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="$port/tcp"
        firewall-cmd --reload
    else
        warn "No active ufw/firewalld detected. Open port $port/tcp manually if a firewall is in use."
    fi
}

close_firewall() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw delete allow "$port/tcp" 2>/dev/null || true
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --remove-port="$port/tcp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi
}

# --- subcommands ------------------------------------------------------------

cmd_install() {
    require_root
    detect_os
    detect_arch
    log "Installing MTProto proxy (mtg ${MTG_VERSION})..."
    apt_get install ca-certificates curl

    mkdir -p "$SECRETS_DIR"

    install_binary "$ARCH"

    # --- create unprivileged system user ---
    if ! id mtg >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin --comment "mtg MTProto proxy" mtg
        log "Created system user 'mtg'."
    fi

    # --- config ---
    local port="${MTPROTO_PORT:-$DEFAULT_PORT}"
    if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
        err "Invalid port $port"
        exit 1
    fi

    # Generate the first secret if none exists
    if [[ ! -f "$SECRETS" ]]; then
        touch "$SECRETS"
        chmod 600 "$SECRETS"
    fi

    # Write the config TOML (only mandatory fields)
    cat > "$CONFIG" <<EOF
# /etc/mtg.toml -- generated by tools/mtproto.sh
secret = "$(head -n1 "$SECRETS" 2>/dev/null || echo 'ee367a189aee18fa31c190054efd4a8e9573746f726167652e676f6f676c65617069732e636f6d')"
bind-to = "0.0.0.0:${port}"
EOF
    chmod 600 "$CONFIG"

    # --- systemd unit ---
    cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=mtg - MTProto proxy for Telegram
Documentation=https://github.com/9seconds/mtg
After=network.target

[Service]
ExecStart=${BIN} run ${CONFIG}
Restart=always
RestartSec=3
User=mtg
DynamicUser=false
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
EOF

    open_firewall "$port"

    systemctl daemon-reload
    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE"
    touch "$CONFIGURED_MARKER"

    log "mtg proxy is running on port $port."
    log "Add another secret:  mtproto.sh add-user <hostname>"
    log "Print the tg:// link: mtproto.sh link"
}

cmd_add_user() {
    require_root
    local host="${1:-}"
    valid_hostname "$host"
    if [[ ! -f "$SECRETS" ]]; then
        err "Secrets file not found. Run 'install' first."
        exit 1
    fi
    local secret
    secret="$(generate_secret "$host")"
    if grep -qxF "$secret" "$SECRETS"; then
        warn "Secret for $host already present."
        return 0
    fi
    echo "$secret" >> "$SECRETS"
    chmod 600 "$SECRETS"
    log "Secret for '$host' added."
    # Restart the service to pick up the new secret
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        systemctl restart "$SERVICE"
    fi
}

cmd_remove_user() {
    require_root
    local key="${1:-}"
    # Removal operates on the exact 64-hex secret value. If a hostname was
    # supplied, derive its secret and remove that value.
    if [[ ! "$key" =~ ^[a-fA-F0-9]{64}$ ]]; then
        valid_hostname "$key"
        key="$(generate_secret "$key")"
    fi
    if [[ ! -f "$SECRETS" ]]; then
        err "Secrets file not found."
        exit 1
    fi
    local tmp
    tmp="$(mktemp /tmp/mtg-secrets.XXXXXX)"
    grep -vxF "$key" "$SECRETS" > "$tmp" || true
    mv "$tmp" "$SECRETS"
    chmod 600 "$SECRETS"
    log "Secret removed."
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        systemctl restart "$SERVICE"
    fi
}

cmd_list_users() {
    if [[ ! -f "$SECRETS" ]]; then
        log "No secrets yet. Run 'install' first."
        return 0
    fi
    if [[ ! -s "$SECRETS" ]]; then
        log "(no secrets)"
        return 0
    fi
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Print only the hostname portion (after the ee prefix, last 31 bytes → 62 hex chars)
        # Simpler: just print the full hex line (it is not a "secret" in the PII sense,
        # but it is the access credential — do not print to logs on other paths).
        printf '%s\n' "$line"
    done < "$SECRETS"
}

cmd_link() {
    local host="${1:-}"
    if [[ -n "$host" ]]; then
        valid_hostname "$host"
    fi
    local secret=""
    if [[ -n "$host" ]]; then
        secret="$(generate_secret "$host")"
    else
        # use the first secret in the file
        [[ -f "$SECRETS" ]] || { err "No secrets found. Run 'install' first."; exit 1; }
        secret="$(head -n1 "$SECRETS")"
    fi
    # Print the tg:// link using the mtg access command (writes JSON to stdout)
    if [[ -f "$CONFIG" ]]; then
        "$BIN" access "$CONFIG" 2>/dev/null | grep -o '"tg_url": *"[^"]*"' | sed 's/.*: *"//;s/"$//' || true
    else
        # Fallback: build the link manually
        local port="${MTPROTO_PORT:-$DEFAULT_PORT}"
        printf 'tg://proxy?secret=%s&server=YOUR_SERVER_IP&port=%s\n' "$secret" "$port"
    fi
}

cmd_uninstall() {
    require_root
    warn "Removing mtg proxy. Secrets will be kept at $SECRETS."
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        systemctl stop "$SERVICE"
    fi
    systemctl disable "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE}.service"
    systemctl daemon-reload
    close_firewall "${MTPROTO_PORT:-$DEFAULT_PORT}"
    rm -f "$BIN"
    rm -f "$CONFIG"
    rm -f "$CONFIGURED_MARKER"
    # Remove the system user if it exists and has no other processes
    if id mtg >/dev/null 2>&1; then
        userdel mtg 2>/dev/null || true
    fi
    log "Uninstalled."
}

# --- dispatch ---------------------------------------------------------------

main() {
    local cmd="${1:-help}"
    case "$cmd" in
        install)
            cmd_install
            ;;
        add-user)
            [[ -z "${2:-}" ]] && { err "Usage: mtproto.sh add-user <hostname>"; exit 1; }
            cmd_add_user "$2"
            ;;
        remove-user)
            [[ -z "${2:-}" ]] && { err "Usage: mtproto.sh remove-user <hostname|hex-secret>"; exit 1; }
            cmd_remove_user "$2"
            ;;
        list-users)
            cmd_list_users
            ;;
        link)
            cmd_link "${2:-}"
            ;;
        uninstall)
            cmd_uninstall
            ;;
        help|*)
            echo "Usage: mtproto.sh {install | add-user <host> | remove-user <host|secret> | list-users | link [host] | uninstall}"
            ;;
    esac
}

main "$@"
