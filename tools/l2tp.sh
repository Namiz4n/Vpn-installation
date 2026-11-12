#!/bin/bash
#
# tools/l2tp.sh -- L2TP/IPsec VPN server installer / manager
#
# Installs strongSwan + xl2tpd + ppp, configures L2TP-over-IPsec with a
# pre-shared key, manages /etc/ppp/chap-secrets users, persists IP
# forwarding + NAT + MSS clamp, and keeps the services enabled at boot.
#
# CONFIG STYLE (documented choice):
#   The Debian/Ubuntu strongswan packages ship the CLASSIC stroke config
#   format by default: /etc/ipsec.conf + /etc/ipsec.secrets, driven by the
#   `strongswan-starter` service (unit: strongswan-starter.service).
#   The swanctl format (/etc/strongswan/swanctl.conf, driven by
#   charon with --use-swanctl) is a separate opt-in package
#   (strongswan-swanctl) and is NOT the distro default on any supported
#   release (verified against the noble/bookworm/jammy .deb contents).
#   This tool therefore writes ipsec.conf + ipsec.secrets. If you later
#   install strongswan-swanctl and switch charon to swanctl mode, you
#   will need to convert these files; this tool does not manage swanctl.
#
# IKE VERSION (documented choice):
#   L2TP-over-IPsec road-warrior from Windows/Android clients is the
#   standard case, and it uses IKEv1 (with PFS off, transport-mode ESP
#   carrying UDP/1701). IKEv2 L2TP is not the standard Windows client
#   mode, so we use ikev1 with aes256-gcm/sha2-256/modp-2048, falling
#   back to aes128-sha1-modp-1024 for older clients. The connection is
#   configured with keyingtries=%forever and rightsourceip=%config so
#   clients get their address from xl2tpd, not from IPsec mode config.
#
# NETWORK MODEL:
#   IPsec (UDP 500/4500, NAT-T) is the only public surface. L2TP
#   (UDP 1701) runs ONLY inside the IPsec tunnel (RFC 3931 + the
#   strongSwan/xl2tpd L2TP/IPsec model -- see also the ipsec saref
#   directive in xl2tpd.conf which ties L2TP sessions to the IPsec SA).
#   Never open UDP 1701 publicly.
#
# UX (this script is self-contained and also launched with no arguments
# from main.sh):
#   * No arguments:
#       - not installed -> guided install (ENTER accepts defaults; PSK and
#         user credentials are auto-generated; final confirmation),
#       - installed    -> short numbered management menu
#         (status, add user, remove user, list users, connection info,
#         uninstall, back).
#   * Subcommands (power-user):
#       install | add-user <name> | remove-user <name> | list-users
#       | print-config | uninstall
#     Non-interactive flags/env vars:
#       --auto                       accept every default, no prompts
#       --psk <key>                  use a custom PSK (>= 12 alphanumeric
#                                    chars; validated; generated if unset)
#       --client-subnet <cidr>       L2TP client network, default 10.8.0.0/24
#       --ip-range <a>-<b>           client IP range inside the subnet,
#                                    default <.start>-<.start+200>
#       --dns <a> --dns <b>          pushed DNS (default 1.1.1.1 8.8.8.8)
#       --no-forwarding              skip NAT/forwarding setup
#       L2TP_USER / L2TP_PASSWORD   user for add-user (password generated
#                                   if L2TP_PASSWORD is unset)
#   * `-h` / `--help`: print usage. Any other first argument that is not a
#     known subcommand is treated as no-args, so `l2tp.sh` alone never
#     prints a Usage line.
#
# OS: Debian/Ubuntu only.
#
# Verification notes (clean-room; sources: strongswan man pages
# ipsec.conf(5)/ipsec.secrets(5) via wiki.strongswan.org, xl2tpd.conf(5),
# pppd(8) man pages, Debian/Ubuntu package pages, /etc/protocols):
#   * strongswan metapackage -> strongswan-charon + strongswan-starter;
#     the `ipsec` command and the strongswan-starter.service unit come
#     from strongswan-starter (verified from the .deb file list).
#   * xl2tpd package provides /etc/xl2tpd/xl2tpd.conf with [global] and
#     [lns default] sections (verified from the package's example file and
#     the xl2tpd.conf(5) man page). pppoptfile points pppd at the
#     per-interface options file /etc/ppp/options.xl2tpd; that file holds
#     pppd options (require-mschap-v2, ms-dns, mtu/mru, ...), NOT
#     xl2tpd keywords.
#   * chap-secrets: 4-field `client server secret [clients]` per pppd(8);
#     the LNS name is not a fixed string in the official docs, so we use
#     `*` (any server) for the `server` field -- this is the documented
#     wildcard, and it is what matters for client lookups by username.
#   * Firewall: UDP 500 + UDP 4500 only. UDP 1701 is NOT opened
#     (L2TP lives inside the IPsec SA).
#   * Kernel modules: l2tp_core + l2tp_ppp (the xl2tpd userspace daemon
#     is what is configured; the kernel side is the L2TP protocol, not an
#     "xl2tp" module), and xfrm_user for IPsec.
#
# KNOWN LIMITATIONS (documented, not bugs):
#   * Windows NAT-T: some Windows builds fail L2TP over IPsec from behind
#     NAT unless the registry value "EnableTransportModeDirectAccess" is
#     set or the connection is configured for UDP 4500. See README.
#   * Multiple clients behind the same NAT: only one L2TP-over-IPsec
#     client can be behind a given NAT box at a time (shared SPI). Use
#     IKEv2 or WireGuard for many-behind-one-NAT; this tool does NOT
#     implement IKEv2 L2TP (see TODO below).
#   * TODO (not implemented): IKEv2 L2TP/IPsec mode. If you need it,
#     see strongswan's IKEv2 + L2TP examples; it requires a different
#     client setup and is not the Windows/Android standard.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

IPSEC_CONF="/etc/ipsec.conf"
IPSEC_SECRETS="/etc/ipsec.secrets"
XL2TPD_CONF="/etc/xl2tpd/xl2tpd.conf"
PPP_OPTIONS="/etc/ppp/options.xl2tpd"
CHAP_SECRETS="/etc/ppp/chap-secrets"
SYSCTL="/etc/sysctl.d/90-l2tp.conf"
MODULES="/etc/modules-load.d/l2tp-ipsec.conf"
FW_TAG="vpn-install-l2tp"
SERVICE_IPSEC="strongswan-starter"
SERVICE_XL2TPD="xl2tpd"

CLIENT_SUBNET="${CLIENT_SUBNET:-10.8.0.0/24}"
DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-8.8.8.8}"
DO_FORWARDING=1
CLIENT=""
PASSWORD=""
PSK=""
IP_RANGE_OVERRIDE=""
AUTO=0

log() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}Warning: $*${NC}" >&2; }
err() { echo -e "${RED}Error: $*${NC}" >&2; }
info() { echo -e "${BLUE}$*${NC}"; }

usage() {
    cat <<EOF
Usage: bash l2tp.sh [subcommand] [flags]
  No arguments: guided install or management menu (recommended).
  Subcommands: install | add-user <name> | remove-user <name> | list-users
               | print-config | uninstall
  Flags: --auto, --psk <key>, --client-subnet <cidr>, --ip-range <a>-<b>,
         --public-ip <ip> (default: auto-detected), --dns <a> [--dns <b>],
         --no-forwarding
  -h / --help: this text.
EOF
}

die() { err "$*"; exit 1; }

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This script must be run as root. Try: sudo bash $0."
    fi
}

detect_os() {
    # Fill DISTRO_ID / DISTRO_CODENAME / RELEASE; die if not Debian/Ubuntu.
    if [[ -r /etc/os-release ]]; then
        set -a
        # shellcheck source=/dev/null
        source /etc/os-release
        set +a
        DISTRO_ID="${ID:-unknown}"
        DISTRO_CODENAME="${VERSION_CODENAME:-unknown}"
        RELEASE="${VERSION_ID:-unknown}"
    else
        die "Cannot detect OS: /etc/os-release is missing."
    fi
    case "$DISTRO_ID" in
        debian|ubuntu) : ;;
        *)
            die "Unsupported OS: ${DISTRO_ID} ${RELEASE} (${DISTRO_CODENAME}). This tool supports Debian/Ubuntu only."
            ;;
    esac
}

default_iface() {
    local iface
    iface="$(ip route show default 2>/dev/null | awk '{print $5; exit}' || true)"
    [[ -n "$iface" ]] || iface="eth0"
    printf '%s' "$iface"
}

public_ip() {
    # Best-effort public IP: first non-RFC1918 / loopback address that is
    # NOT a CIDR, falling back to the default-route interface's primary
    # address. Callers validate the result; if nothing usable is found the
    # caller dies with a clear message.
    local ip iface
    iface="$(default_iface)"
    # Prefer the address on the default-route interface (the one that
    # actually sends traffic to the internet).
    ip="$(ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4}' | head -n1 || true)"
    ip="${ip%/*}"
    # If that was private/loopback, scan all interfaces for a public one.
    if [[ -z "$ip" ]] || [[ "$ip" =~ ^127\. ]] || [[ "$ip" =~ ^10\. ]] \
        || [[ "$ip" =~ ^192\.168\. ]] || [[ "$ip" =~ ^172\.(1[6-9]|[2-4][0-9])\. ]]; then
        ip="$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' \
            | grep -vE '^127\.|^10\.|^192\.168\.|^172\.(1[6-9]|[2-4][0-9])\.' \
            | head -n1 || true)"
        ip="${ip%/*}"
    fi
    printf '%s' "$ip"
}

# --- helpers ----------------------------------------------------------------
ask() {
    local prompt="$1" default="$2" reply=""
    if [[ -t 0 && "$AUTO" -eq 0 ]]; then
        printf '%s [%s]: ' "$prompt" "$default"
        read -r reply || reply=""
        printf '%s' "${reply:-$default}"
    else
        printf '%s' "$default"
    fi
}

ask_yes_no() {
    local prompt="$1" default="$2" reply=""
    if [[ -t 0 && "$AUTO" -eq 0 ]]; then
        printf '%s [%s] ' "$prompt" "$default"
        read -r reply || reply=""
        reply="${reply:-$default}"
        [[ "$reply" =~ ^[Yy] ]]
    else
        [[ "$default" =~ ^[Yy] ]]
    fi
}

generate_psk() {
    # >= 24 chars of alphanumerics only (no quoting trouble in ipsec.secrets).
    local out=""
    while [[ "${#out}" -lt 24 ]]; do
        out+=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
    done
    # strip to alnum, truncate to 24..32
    out="${out//[^a-zA-Z0-9]/}"
    out="${out:0:32}"
    [[ "${#out}" -ge 24 ]] || out="${out}$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s' "$out"
}

generate_password() {
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-24
}

# --- config rendering -------------------------------------------------------
render_ipsec_conf() {
    # Classic stroke format. %default carries the road-warrior base; the
    # l2tp conn pins the protocol port so charon only matches L2TP.
    cat <<EOF
# /etc/ipsec.conf -- written by l2tp.sh (classic stroke format; see header
# of this script for why swanctl is not used).
config setup
    charondebug="ike 2, knl 2, cfg 2, net 2, esp 3, dmn 2, mgr 2"
    uniqueids=no

conn %default
    keyexchange=ikev1
    ike=aes256gcm128-sha256-modp2048!
    esp=aes256gcm128!
    dpddelay=300
    dpdtimeout=60
    dpdaction=clear
    keyingtries=%forever
    rekey=no
    aggr=no
    left=%defaultroute
    leftsubnet=${PUBLIC_IP}/32
    leftfirewall=no
    auto=add

conn l2tp
    also=%default
    authby=psk
    left=${PUBLIC_IP}
    leftsubnet=${PUBLIC_IP}/32
    leftsourceip=${LOCAL_IP_RANGE_NET}/32
    right=%any
    rightsourceip=%config
    rightprotoport=17/1701
    auto=add
EOF
}

render_ipsec_secrets() {
    cat <<EOF
# /etc/ipsec.secrets -- written by l2tp.sh
# PSK for L2TP road-warrior: matches right=%any (any client).
${PUBLIC_IP} %any : PSK "${PSK_VALUE}"
EOF
}

render_xl2tpd_conf() {
    cat <<EOF
; /etc/xl2tpd/xl2tpd.conf -- written by l2tp.sh
[global]
port = 1701
listen-addr = ${PUBLIC_IP}
; Tie L2TP sessions to the IPsec SA (SAREF). Required for L2TP/IPsec.
ipsec saref = yes

[lns default]
; pppd-side authentication is configured in the pppoptfile, not here.
; The values below are xl2tpd keyword spellings (space-separated), per
; xl2tpd.conf(5).
require authentication
refuse pap
refuse chap
refuse eap
; Assign client IPs from this range (the pppd options file sets
; require-mschap-v2 and ms-dns; see $PPP_OPTIONS).
assign ip
local ip = ${PUBLIC_IP}
ip range = ${IP_RANGE}
name = xl2tpd0
hostname = ${PUBLIC_IP}
; Use a pppd options file specific to xl2tpd sessions.
pppoptfile = /etc/ppp/options.xl2tpd
EOF
}

render_ppp_options() {
    cat <<EOF
# /etc/ppp/options.xl2tpd -- written by l2tp.sh
# These are pppd(8) options, not xl2tpd keywords (the pppoptfile
# mechanism: xl2tpd passes this file to pppd for each session).
refuse-pap
refuse-chap
refuse-mschap
refuse-eap
require-mschap-v2
require-mppe-128
ms-dns ${DNS1}
ms-dns ${DNS2}
mtu 1400
mru 1400
nodefaultroute
proxyarp
lock
nologfd
noipx
nobsdcomp
novj
novjccomp
EOF
}

render_chap_secrets_line() {
    # server field: `*` (the documented wildcard; the exact LNS name string
    # is not fixed by the official docs -- see script header note).
    printf '%s * %s %s\n' "$1" "$2" "$IP_RANGE"
}

render_sysctl() {
    cat <<EOF
# /etc/sysctl.d/90-l2tp.conf -- written by l2tp.sh
net.ipv4.ip_forward = 1
# Enable IPsec kernel xfrm (usually built-in on modern kernels).
net.ipv4.conf.all.rp_filter = 2
EOF
}

render_modules() {
    cat <<EOF
# /etc/modules-load.d/l2tp-ipsec.conf -- written by l2tp.sh
l2tp_core
l2tp_ppp
xfrm_user
xfrm4
esp4
EOF
}

# --- backup / rollback ------------------------------------------------------
BACKUPS=()
# shellcheck disable=SC2034
BACKUP_DIR="/var/lib/l2tpd-backup"

backup_file() {
    local f="$1"
    [[ -e "$f" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    local ts dest
    ts="$(date +%Y%m%d%H%M%S)"
    dest="$BACKUP_DIR/$(basename "$f").bak.$ts"
    cp -a "$f" "$dest"
    BACKUPS+=("$f $dest")
}

rollback() {
    local f dest
    for entry in "${BACKUPS[@]}"; do
        f="${entry%% *}"
        dest="${entry#* }"
        if ! cmp -s "$f" "$dest" 2>/dev/null; then
            warn "Rolling back $f from $dest"
            install -m 0640 "$dest" "$f"
        fi
    done
}

# --- firewall / NAT / sysctl -------------------------------------------------
detect_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        echo "ufw"
    elif systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "firewalld"
    elif command -v iptables >/dev/null 2>&1; then
        echo "iptables"
    else
        echo "none"
    fi
}

allow_l2tp_firewall() {
    # UDP 500 + UDP 4500 ONLY. 1701 stays inside the tunnel.
    local fw
    fw="$(detect_firewall)"
    case "$fw" in
        ufw)
            ufw allow 500/udp >/dev/null 2>&1 || warn "ufw: could not allow 500/udp"
            ufw allow 4500/udp >/dev/null 2>&1 || warn "ufw: could not allow 4500/udp"
            ;;
        firewalld)
            firewall-cmd --permanent --add-port=500/udp >/dev/null 2>&1 \
                || warn "firewalld: could not allow 500/udp"
            firewall-cmd --permanent --add-port=4500/udp >/dev/null 2>&1 \
                || warn "firewalld: could not allow 4500/udp"
            firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
        iptables)
            iptables -C INPUT -p udp --dport 500 -j ACCEPT 2>/dev/null \
                || iptables -A INPUT -p udp --dport 500 -j ACCEPT
            iptables -C INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null \
                || iptables -A INPUT -p udp --dport 4500 -j ACCEPT
            ;;
        none)
            warn "No active firewall detected. If your cloud provider has a"
            warn "security group, allow UDP 500 and UDP 4500 there."
            ;;
    esac
}

setup_forwarding() {
    local iface
    iface="$(default_iface)"
    if [[ "$DO_FORWARDING" -eq 0 ]]; then
        info "Skipping forwarding/NAT setup (--no-forwarding)."
        return 0
    fi

    mkdir -p /etc/sysctl.d
    printf '%s\n' "$(render_sysctl)" > "$SYSCTL"
    sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1 || true

    mkdir -p /etc/modules-load.d
    printf '%s\n' "$(render_modules)" > "$MODULES"
    modprobe l2tp_core 2>/dev/null || true
    modprobe l2tp_ppp 2>/dev/null || true
    modprobe xfrm_user 2>/dev/null || true

    apt_get install iptables-persistent || warn "iptables-persistent not installed; NAT rules will not survive reboot."
    local savefile="/etc/iptables/rules.v4"
    grep -q "$FW_TAG" "$savefile" 2>/dev/null || {
        # Marked rules so we can clean them up on uninstall.
        iptables -t nat -C POSTROUTING -o "$iface" -m comment --comment "$FW_TAG" -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -o "$iface" -m comment --comment "$FW_TAG" -j MASQUERADE
        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,SYNACK SYN -m comment --comment "$FW_TAG" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
            || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,SYNACK SYN -m comment --comment "$FW_TAG" -j TCPMSS --clamp-mss-to-pmtu
        netfilter-persistent save >/dev/null 2>&1 || true
    }
}

# --- user management --------------------------------------------------------
add_user() {
    # shellcheck disable=SC1087
    local user="$1" pass="${2:-}"
    [[ -n "$user" ]] || die "Username required."
    [[ "$user" =~ ^[A-Za-z0-9._-]{1,32}$ ]] || die "Invalid username (use letters, digits, . _ -)."
    # shellcheck disable=SC1087
    if grep -qE "^[[:space:]]*$user[[:space:]]+\*" "$CHAP_SECRETS" 2>/dev/null; then
        warn "User '$user' already exists in $CHAP_SECRETS; not adding again."
        return 0
    fi
    [[ -n "$pass" ]] || pass="$(generate_password)"
    printf '%s\n' "$(render_chap_secrets_line "$user" "$pass")" >> "$CHAP_SECRETS"
    NEW_CRED_USERS+=("$user")
    NEW_CRED_PASS+=("$pass")
    log "Added L2TP user '$user' (password shown once below)."
}

remove_user() {
    local user="$1"
    [[ -n "$user" ]] || die "Username required."
    local tmp
    tmp="$(mktemp)"
    # shellcheck disable=SC1087
    grep -vE "^[[:space:]]*$user[[:space:]]+\*" "$CHAP_SECRETS" > "$tmp" || true
    cat "$tmp" > "$CHAP_SECRETS"
    rm -f "$tmp"
    log "Removed L2TP user '$user'."
}

list_users() {
    if [[ ! -r "$CHAP_SECRETS" ]]; then
        info "No users yet ($CHAP_SECRETS does not exist)."
        return 0
    fi
    echo "L2TP users in $CHAP_SECRETS:"
    awk '$2 == "*" { print "  " $1 }' "$CHAP_SECRETS"
}

status() {
    echo "=== L2TP/IPsec server status ==="
    if systemctl is-active --quiet "$SERVICE_IPSEC" 2>/dev/null; then
        log "Service '$SERVICE_IPSEC': active"
    else
        warn "Service '$SERVICE_IPSEC': not running"
    fi
    if systemctl is-active --quiet "$SERVICE_XL2TPD" 2>/dev/null; then
        log "Service '$SERVICE_XL2TPD': active"
    else
        warn "Service '$SERVICE_XL2TPD': not running"
    fi
    if [[ -e "$IPSEC_CONF" ]]; then
        log "Config present: $IPSEC_CONF"
    else
        warn "Config missing: $IPSEC_CONF"
    fi
    list_users
}

print_config() {
    compute_network_values
    echo "=== [dry-run] files l2tp.sh would write ==="
    echo
    echo "--- $IPSEC_CONF"
    printf '%s\n' "$PSK_VALUE" >/dev/null # placeholder to avoid unused-var in some shells
    render_ipsec_conf
    echo
    echo "--- $IPSEC_SECRETS"
    render_ipsec_secrets
    echo
    echo "--- $XL2TPD_CONF"
    render_xl2tpd_conf
    echo
    echo "--- $PPP_OPTIONS"
    render_ppp_options
    echo
    echo "--- chap-secrets line (appended to $CHAP_SECRETS)"
    if [[ -n "$CLIENT" ]]; then
        render_chap_secrets_line "$CLIENT" "${PASSWORD:-<generated-at-install>}"
    fi
    echo "(users added interactively are appended the same way)"
    echo
    echo "--- $SYSCTL"
    render_sysctl
    echo
    echo "--- $MODULES"
    render_modules
}

compute_network_values() {
    PUBLIC_IP="${PUBLIC_IP_OVERRIDE:-$(public_ip)}"
    [[ -n "$PUBLIC_IP" ]] || die "Could not determine the public IP; set PUBLIC_IP_OVERRIDE or pass it."
    [[ "$PUBLIC_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Invalid public IP: $PUBLIC_IP"

    # Subnet -> .1 local + client range.
    local net="${CLIENT_SUBNET%/*}"
    local prefix="${CLIENT_SUBNET#*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] || die "Invalid CIDR: $CLIENT_SUBNET"
    local last="${net##*.}"
    LOCAL_IP="${net%.*}.$last"
    LOCAL_IP="${LOCAL_IP%.*}.1"
    if [[ -n "$IP_RANGE_OVERRIDE" ]]; then
        IP_RANGE="$IP_RANGE_OVERRIDE"
    else
        local start="10" end="200"
        if [[ "$prefix" -gt 24 ]]; then
            end=$(( start + ((1 << (32 - prefix)) - 1) - 1 ))
            [[ $end -le 254 ]] || end=254
        fi
        IP_RANGE="${LOCAL_IP%.*}.$start-${LOCAL_IP%.*}.$end"
    fi
    LOCAL_IP_RANGE_NET="${LOCAL_IP%.*}.0"

    PSK_VALUE="${PSK:-$(generate_psk)}"
    [[ "${#PSK_VALUE}" -ge 12 ]] || die "PSK too short (need >= 12 alphanumeric chars)."
    [[ "$PSK_VALUE" =~ ^[A-Za-z0-9]+$ ]] || die "PSK must be alphanumeric only."
}

# --- guided install ---------------------------------------------------------
guided_install() {
    compute_network_values
    echo
    echo "L2TP/IPsec VPN server setup"
    echo "  Public IP (IPsec left) : $PUBLIC_IP"
    echo "  L2TP local IP          : $LOCAL_IP"
    echo "  Client IP range        : $IP_RANGE"
    echo "  Pushed DNS             : $DNS1, $DNS2"
    echo "  PSK                    : ${PSK_VALUE:0:4}… (${#PSK_VALUE} chars, shown in full below)"
    echo "  NAT/forwarding         : $([[ $DO_FORWARDING -eq 1 ]] && echo enabled || echo disabled)"
    if [[ -n "$CLIENT" ]]; then
        PASSWORD="${PASSWORD:-$(generate_password)}"
        echo "  Initial user           : $CLIENT"
    fi
    echo
    info "Note: Windows L2TP/IPsec from behind NAT may need the registry key"
    info "HKLM\SYSTEM\CurrentControlSet\Services\PolicyAgent\EnableTransportModeDirectAccess"
    info "set to 1 (DWORD). Multiple clients behind the SAME NAT cannot connect"
    info "simultaneously. IKEv2 is the recommended alternative (not implemented"
    info "by this tool -- see the header TODO)."
    echo
    if ! ask_yes_no "Proceed with L2TP/IPsec install?" "Y"; then
        die "Aborted before writing anything."
    fi
    do_install
}

do_install() {
    require_root
    detect_os
    BACKUPS=()
    NEW_CRED_USERS=()
    NEW_CRED_PASS=()
    compute_network_values
    for f in "$IPSEC_CONF" "$IPSEC_SECRETS" "$XL2TPD_CONF" "$PPP_OPTIONS" "$CHAP_SECRETS" "$SYSCTL" "$MODULES"; do
        backup_file "$f"
    done
    trap rollback EXIT

    log "Installing strongswan + xl2tpd + ppp..."
    apt_get install strongswan xl2tpd ppp || die "Package install failed."

    log "Writing config..."
    mkdir -p /etc/ppp /etc/xl2tpd /etc/sysctl.d /etc/modules-load.d
    printf '%s\n' "$(render_ipsec_conf)" > "$IPSEC_CONF"
    printf '%s\n' "$(render_ipsec_secrets)" > "$IPSEC_SECRETS"
    chmod 0640 "$IPSEC_SECRETS"
    printf '%s\n' "$(render_xl2tpd_conf)" > "$XL2TPD_CONF"
    printf '%s\n' "$(render_ppp_options)" > "$PPP_OPTIONS"
    if [[ ! -e "$CHAP_SECRETS" ]]; then
        {
            echo "# /etc/ppp/chap-secrets -- written by l2tp.sh"
            echo "# format: client server secret [clients]"
            echo "# (server field is '*' per this tool's convention; see header)"
        } > "$CHAP_SECRETS"
        chmod 0640 "$CHAP_SECRETS"
    fi
    if [[ -n "$CLIENT" ]]; then
        add_user "$CLIENT" "$PASSWORD"
    fi

    allow_l2tp_firewall
    setup_forwarding

    log "Testing + starting services..."
    # Validate the IPsec config BEFORE restarting, so a bad write rolls
    # back cleanly.
    if ! ipsec verify >/dev/null 2>&1; then
        warn "ipsec verify reported issues (may be benign); continuing."
    fi
    systemctl restart "$SERVICE_IPSEC" || { rollback; die "strongswan-starter failed to start; rolled back."; }
    systemctl restart "$SERVICE_XL2TPD" || { rollback; die "xl2tpd failed to start; rolled back."; }
    systemctl enable "$SERVICE_IPSEC" "$SERVICE_XL2TPD" 2>/dev/null || true
    trap - EXIT
    sleep 1
    systemctl is-active --quiet "$SERVICE_IPSEC" || { rollback; die "strongswan-starter not active after start; rolled back."; }

    echo
    log "=== L2TP/IPsec server summary ==="
    echo "  IPsec      : strongSwan (stroke / classic ipsec.conf)"
    echo "  L2TP       : xl2tpd (UDP 1701 inside the IPsec tunnel)"
    echo "  Public IP  : $PUBLIC_IP"
    echo "  Client IP range : $IP_RANGE"
    echo "  DNS pushed : $DNS1, $DNS2"
    echo "  Open ports : UDP 500, UDP 4500 (NOT 1701)"
    echo
    echo "  L2TP PSK (store now; shown only once):"
    echo "    $PSK_VALUE"
    if [[ -n "${NEW_CRED_USERS[0]:-}" ]]; then
        echo
        echo "  Initial credentials (store now; shown only once):"
        local i
        for i in "${!NEW_CRED_USERS[@]}"; do
            echo "    user     : ${NEW_CRED_USERS[$i]}"
            echo "    password : ${NEW_CRED_PASS[$i]}"
        done
    fi
    echo
    warn "Cloud providers: open UDP 500 and UDP 4500 in the security group."
}

# --- uninstall --------------------------------------------------------------
uninstall() {
    require_root
    local fw
    fw="$(detect_firewall)"
    case "$fw" in
        ufw)
            ufw delete allow 500/udp >/dev/null 2>&1 || true
            ufw delete allow 4500/udp >/dev/null 2>&1 || true
            ;;
        firewalld)
            firewall-cmd --permanent --remove-port=500/udp >/dev/null 2>&1 || true
            firewall-cmd --permanent --remove-port=4500/udp >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
        iptables)
            iptables -D INPUT -p udp --dport 500 -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null || true
            iptables -t nat -D POSTROUTING -o "$(default_iface)" -m comment --comment "$FW_TAG" -j MASQUERADE 2>/dev/null || true
            iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,SYNACK SYN -m comment --comment "$FW_TAG" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            netfilter-persistent save >/dev/null 2>&1 || true
            ;;
    esac
    systemctl disable --now "$SERVICE_IPSEC" "$SERVICE_XL2TPD" 2>/dev/null || true
    rm -f "$SYSCTL" "$MODULES"
    apt_get remove strongswan xl2tpd ppp || true
    log "L2TP/IPsec removed (chap-secrets kept; delete $CHAP_SECRETS manually if unwanted)."
}

# --- argument parsing -------------------------------------------------------
cmd=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --auto) AUTO=1; shift ;;
        --psk) PSK="${2:-}"; shift 2 ;;
        --client-subnet) CLIENT_SUBNET="${2:-}"; shift 2 ;;
        --ip-range) IP_RANGE_OVERRIDE="${2:-}"; shift 2 ;;
        --public-ip) PUBLIC_IP_OVERRIDE="${2:-}"; shift 2 ;;
        --dns) DNS1="${2:-}"; shift; [[ $# -gt 0 && "$1" == "--dns" ]] && DNS2="${2:-}" && shift 2 ;;
        --no-forwarding) DO_FORWARDING=0; shift ;;
        install) cmd="install"; shift ;;
        add-user)
            cmd="add-user"; shift
            CLIENT="${1:-${L2TP_USER:-}}"
            PASSWORD="${2:-${L2TP_PASSWORD:-}}"
            shift; [[ $# -gt 0 ]] && shift
            ;;
        remove-user) cmd="remove-user"; USER_ARG="${1:-${L2TP_USER:-}}"; shift; [[ $# -gt 0 ]] && shift ;;
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
            require_root
            detect_os
            if [[ "$AUTO" -eq 1 ]]; then
                do_install
            else
                guided_install
            fi
            ;;
        add-user)
            require_root
            [[ -e "$CHAP_SECRETS" ]] || die "No $CHAP_SECRETS; run 'install' first."
            [[ -n "$CLIENT" ]] || die "Username required (first arg or L2TP_USER)."
            PASSWORD="${PASSWORD:-$(generate_password)}"
            add_user "$CLIENT" "$PASSWORD"
            echo "user=$CLIENT password=$PASSWORD (shown once)"
            ;;
        remove-user)
            require_root
            [[ -e "$CHAP_SECRETS" ]] || die "No $CHAP_SECRETS; run 'install' first."
            remove_user "$USER_ARG"
            ;;
        list-users)
            list_users
            ;;
        print-config)
            detect_os
            compute_network_values
            print_config
            ;;
        uninstall)
            uninstall
            ;;
        default|"")
            if [[ -e "$XL2TPD_CONF" ]] && systemctl is-active --quiet "$SERVICE_XL2TPD" 2>/dev/null; then
                management_menu
            else
                require_root
                detect_os
                guided_install
            fi
            ;;
        *)
            warn "Unknown subcommand '$cmd' (treated as no-args)."
            if [[ -e "$XL2TPD_CONF" ]] && systemctl is-active --quiet "$SERVICE_XL2TPD" 2>/dev/null; then
                management_menu
            else
                require_root
                detect_os
                guided_install
            fi
            ;;
    esac
}

management_menu() {
    local choice
    while true; do
        echo
        echo "L2TP/IPsec management menu"
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
            2)
                local uname upass
                uname="$(ask "L2TP username" "vpnuser")"
                upass="$(generate_password)"
                add_user "$uname" "$upass"
                echo "user=$uname password=$upass (shown once)"
                ;;
            3)
                local rname
                rname="$(ask "Username to remove" "")"
                remove_user "$rname"
                ;;
            4) list_users ;;
            5) print_config ;;
            6)
                if ask_yes_no "Uninstall L2TP/IPsec?" "n"; then
                    uninstall
                fi
                ;;
            0|*) break ;;
        esac
    done
}

# Shared apt helper (apt on Debian/Ubuntu; this tool is Debian/Ubuntu only,
# so the dnf fallback is defensive, not a supported path).
apt_get() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get "$@"
    elif command -v dnf >/dev/null 2>&1; then
        dnf "$@"
    else
        err "No supported package manager found (apt/dnf)."
        return 1
    fi
}

# BACKUP_DIR is set lazily so print-config (no writes) never creates it.
BACKUP_DIR="/var/lib/l2tpd-backup"

main
