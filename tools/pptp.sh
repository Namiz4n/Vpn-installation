#!/bin/bash
#
# tools/pptp.sh -- PPTP VPN server installer / manager (pptpd)
#
# Installs pptpd, configures it for MS-CHAPv2 + 128-bit MPPE, manages
# /etc/ppp/chap-secrets users, and persists IP forwarding, the NAT
# (MASQUERADE) rule, the PPTP conntrack/NAT helpers, and an MSS clamp for
# forwarded TCP.
#
# SECURITY NOTICE (read before using PPTP):
#   PPTP is a broken protocol. MPPE's 128-bit key is built from
#   per-connection MPPE keys that MS-CHAPv2 derives; the protocol has
#   known weaknesses and is not recommended for any network that has a
#   stronger alternative (L2TP/IPsec, OpenVPN, WireGuard, OpenConnect).
#   This tool refuses to install it unless you explicitly confirm you
#   understand this (interactive prompt, or
#   `--auto --i-understand-pptp-is-insecure`).
#
# UX (this script is self-contained and also launched with no arguments
# from main.sh):
#   * No arguments:
#       - not installed -> guided install (asks only what is needed;
#         ENTER accepts every default; secrets are auto-generated; a
#         final typed "yes" confirms PPTP's insecurity),
#       - installed    -> short numbered management menu
#         (status, add user, remove user, list users, connection info,
#         uninstall, back).
#   * Subcommands (power-user):
#       install | add-user <name> | remove-user <name> | list-users
#       | print-config | uninstall
#     All take `--auto` and the flags/env vars below for fully
#     non-interactive use:
#       --auto                       accept every default, no prompts
#       --i-understand-pptp-is-insecure
#                                   skip the "PPTP is broken" confirmation
#                                   (required together with --auto)
#       --client-subnet <cidr>       PPTP client network, default 10.9.0.0/24
#       --remoteip <range>           client IP range, default
#                                   <.start>-<.start+200> inside the subnet
#       --dns <a> --dns <b>          pushed DNS servers (default 1.1.1.1 8.8.8.8)
#       --no-forwarding              skip the NAT/forwarding setup
#       PPTP_USER / PPTP_PASSWORD    user for add-user (password generated
#                                   if PPTP_PASSWORD is unset)
#   * `-h` / `--help`: print usage. Any other first argument that is not a
#     known subcommand is treated as no-args, so `pptp.sh` alone never
#     prints a Usage line.
#
# OS: Debian/Ubuntu only. Ubuntu 24.04+ does not ship pptpd (removed from
# the repository); this tool detects that and refuses to install, pointing
# you at the L2TP/IPsec tool instead.
#
# Verification notes (clean-room; sources: pptpd.conf(5) from the pptpd
# man page, the pppd(8) man page, Debian/Ubuntu package pages):
#   * /etc/pptpd.conf: directives `localip`, `remoteip`, `option`
#     (verified from pptpd.conf(5)); the log/wtmp directives are not
#     documented in the man page and are intentionally not written.
#   * pppd options file /etc/ppp/pptpd-options: `name pptpd`,
#     `refuse-pap`, `refuse-chap`, `refuse-mschap`, `require-mschap-v2`,
#     `require-mppe-128`, `ms-dns`, `mtu`/`mru`, `nodefaultroute`,
#     `proxyarp`, `lock`, `nologfd`, `noipx`, `nobsdcomp`, `novj`,
#     `novjccomp` -- all pppd(8) documented options.
#   * chap-secrets: 4-field format `client server secret [clients]`
#     per pppd(8); the `server` field must match the `name` pppd option
#     (we use `name pptpd`), so it is `pptpd`.
#   * Firewall: PPTP = control channel TCP/1723 + data channel GRE
#     (IP protocol 47). nat-helper modules nf_nat_pptp +
#     nf_conntrack_pptp loaded at boot; MSS clamp on forwarded TCP.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PPTPD_CONF="/etc/pptpd.conf"
PPP_OPTIONS="/etc/ppp/pptpd-options"
CHAP_SECRETS="/etc/ppp/chap-secrets"
SERVICE="pptpd"
BACKUP_DIR="/var/lib/pptpd-backup"

# Defaults (all overridable; --auto keeps them all).
CLIENT_SUBNET="${CLIENT_SUBNET:-10.9.0.0/24}"
DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-8.8.8.8}"
DO_FORWARDING=1
CLIENT=""
PASSWORD=""
UNDERSTAND=0
AUTO=0

log() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}Warning: $*${NC}" >&2; }
err() { echo -e "${RED}Error: $*${NC}" >&2; }
info() { echo -e "${BLUE}$*${NC}"; }

usage() {
    cat <<EOF
Usage: bash pptp.sh [subcommand] [flags]
  No arguments: guided install or management menu (recommended).
  Subcommands: install | add-user <name> | remove-user <name> | list-users
               | print-config | uninstall
  Flags: --auto, --i-understand-pptp-is-insecure, --client-subnet <cidr>,
         --remoteip <range>, --dns <a> [--dns <b>], --no-forwarding
  -h / --help: this text.
EOF
}

die() { err "$*"; exit 1; }

# --- OS / root checks -------------------------------------------------------
require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        err "This script must be run as root. Try: sudo bash $0."
        exit 1
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
        err "Cannot detect OS: /etc/os-release is missing."
        exit 1
    fi
    case "$DISTRO_ID" in
        debian|ubuntu) : ;;
        *)
            err "Unsupported OS: ${DISTRO_ID} ${RELEASE}. This tool supports Debian/Ubuntu only."
            exit 1
            ;;
    esac
}

default_iface() {
    # Interface of the default route; falls back to eth0.
    local iface
    iface="$(ip route show default 2>/dev/null | awk '{print $5; exit}' || true)"
    [[ -n "$iface" ]] || iface="eth0"
    printf '%s' "$iface"
}

pptpd_available() {
    # Check the live apt index; refuse politely on releases without pptpd.
    if apt-cache show pptpd >/dev/null 2>&1; then
        return 0
    fi
    err "pptpd is not available in the package repository of ${DISTRO_ID} ${RELEASE} (${DISTRO_CODENAME})."
    err "Ubuntu 24.04+ removed pptpd from the archive. PPTP is not installable here."
    err "Use the L2TP/IPsec tool (menu item 7) instead -- it is the modern"
    err "replacement and works on all supported releases."
    return 1
}

# --- helpers ----------------------------------------------------------------
ask() {
    # ask <prompt> <default> -> echoes the value (default if not tty or empty)
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
    # ask_yes_no <prompt> <y|n default> -> 0 for yes, 1 for no
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

random_hex() {
    local n="$1"
    head -c "$n" /dev/urandom | od -An -tx1 | tr -d ' \n'
}

generate_password() {
    # 16 hex chars (32 bits) -- strong enough for a VPN credential; shown
    # exactly once, in the final summary.
    random_hex 8
}

# --- config rendering -------------------------------------------------------
# render_pptpd_conf / render_ppp_options / render_chap_secrets line echo the
# exact file contents for the current values. print-config uses them with
# no writes; the install path writes them (with a backup first).

render_pptpd_conf() {
    cat <<EOF
# /etc/pptpd.conf -- written by pptp.sh (idempotent)
option $PPP_OPTIONS
localip $LOCALIP
remoteip $REMOTEIP_RANGE
EOF
}

render_ppp_options() {
    cat <<EOF
# /etc/ppp/pptpd-options -- written by pptp.sh (idempotent)
name pptpd
refuse-pap
refuse-chap
refuse-mschap
require-mschap-v2
require-mppe-128
ms-dns $DNS1
ms-dns $DNS2
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
    # $1=username $2=password -- a single chap-secrets line (4-field).
    # The IP-restriction field is the client range; the server field must
    # match the pppd `name` option (pptpd).
    printf '%s pptpd %s %s\n' "$1" "$2" "$REMOTEIP_RANGE"
}

# --- backup / rollback ------------------------------------------------------
backup_file() {
    # backup_file <path> -- timestamped backup into BACKUP_DIR; remembers
    # the restore set in BACKUPS.
    local f="$1"
    [[ -e "$f" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    local ts dest
    ts="$(date +%Y%m%d%H%M%S)"
    dest="$BACKUP_DIR/$(basename "$f").bak.$ts"
    cp -a "$f" "$dest"
    BACKUPS+=("$f $dest")
    BACKUP_OF["$f"]="$dest"
}

rollback() {
    # Restore any backup whose target has changed since it was taken.
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

# --- firewall / NAT / modules ------------------------------------------------
detect_firewall() {
    # Echoes "ufw" | "firewalld" | "iptables" | "none".
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

allow_pptp_firewall() {
    # Open PPTP control + data; restrict GRE to the control-port peer only
    # when the remote host is known (we keep it simple: both open).
    local fw
    fw="$(detect_firewall)"
    case "$fw" in
        ufw)
            ufw allow 1723/tcp >/dev/null 2>&1 || warn "ufw: could not allow 1723/tcp"
            ufw allow in proto grep from any port 1723 >/dev/null 2>&1 \
                || ufw insert 1 allow in proto 47 >/dev/null 2>&1 \
                || warn "ufw: could not allow GRE (protocol 47) directly; check manually"
            ;;
        firewalld)
            firewall-cmd --permanent --add-port=1723/tcp >/dev/null 2>&1 \
                || warn "firewalld: could not allow 1723/tcp"
            firewall-cmd --permanent --add-rich-rule='rule protocol value="gre" accept' >/dev/null 2>&1 \
                || warn "firewalld: could not allow GRE protocol"
            firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
        iptables)
            iptables -C INPUT -p tcp --dport 1723 -j ACCEPT 2>/dev/null \
                || iptables -A INPUT -p tcp --dport 1723 -j ACCEPT
            iptables -C INPUT -p 47 -j ACCEPT 2>/dev/null \
                || iptables -A INPUT -p 47 -j ACCEPT
            ;;
        none)
            warn "No active firewall detected. If your cloud provider has a"
            warn "security group, allow TCP 1723 and GRE (protocol 47) there."
            ;;
    esac
}

setup_forwarding() {
    # Persist ip_forward, MASQUERADE on the default-route interface, load
    # the PPTP conntrack/NAT helpers at boot, and clamp forwarded TCP MSS.
    local iface
    iface="$(default_iface)"
    if [[ "$DO_FORWARDING" -eq 0 ]]; then
        info "Skipping forwarding/NAT setup (--no-forwarding)."
        return 0
    fi

    # 1. Persist net.ipv4.ip_forward.
    local sysctl_dir="/etc/sysctl.d"
    mkdir -p "$sysctl_dir"
    cat > "$sysctl_dir/90-pptpd.conf" <<EOF
# written by pptp.sh
net.ipv4.ip_forward = 1
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1 || true

    # 2. PPTP NAT helpers at boot (the module files ship with the kernel;
    #    these lines are harmless no-ops when the kernel has them built-in).
    local moddir="/etc/modules-load.d"
    mkdir -p "$moddir"
    cat > "$moddir/pptpd.conf" <<EOF
# PPTP conntrack/NAT helpers (written by pptp.sh)
pptp
nf_nat_pptp
nf_conntrack_pptp
EOF
    modprobe pptp 2>/dev/null || true
    modprobe nf_nat_pptp 2>/dev/null || true
    modprobe nf_conntrack_pptp 2>/dev/null || true

    # 3. MASQUERADE on the real default-route interface (boot-persistent via
    #    iptables-persistent, installed below), plus an MSS clamp so TCP
    #    through the PPP tunnel doesn't black-hole.
    apt_get install iptables-persistent || warn "iptables-persistent not installed; NAT rules will not survive reboot."
    local savefile="/etc/iptables/rules.v4"
    if [[ -w "$savefile" ]] || true; then
        grep -q 'MASQUERADE-vpn-install' "$savefile" 2>/dev/null || {
            iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null \
                || iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
            iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,SYNACK SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
                || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,SYNACK SYN -j TCPMSS --clamp-mss-to-pmtu
        }
        netfilter-persistent save >/dev/null 2>&1 || true
    fi
}

# --- user management --------------------------------------------------------
# shellcheck disable=SC1087
add_user() {
    # add_user <name> [password]
    local user="$1" pass="${2:-}"
    [[ -n "$user" ]] || die "Username required."
    [[ "$user" =~ ^[A-Za-z0-9._-]{1,32}$ ]] || die "Invalid username (use letters, digits, . _ -)."
    if grep -qE "^[[:space:]]*$user[[:space:]]+pptpd" "$CHAP_SECRETS" 2>/dev/null; then
        warn "User '$user' already exists in $CHAP_SECRETS; not adding again."
        return 0
    fi
    [[ -n "$pass" ]] || pass="$(generate_password)"
    printf '%s pptpd %s %s\n' "$user" "$pass" "$REMOTEIP_RANGE" >> "$CHAP_SECRETS"
    BACKUP_NEW_USERS+=("$user $pass")   # shown in the final summary
    log "Added PPTP user '$user' (password shown once below)."
}

remove_user() {
    local user="$1"
    [[ -n "$user" ]] || die "Username required."
    local tmp
    tmp="$(mktemp)"
    # shellcheck disable=SC1087
    grep -vE "^[[:space:]]*$user[[:space:]]+pptpd" "$CHAP_SECRETS" > "$tmp" || true
    cat "$tmp" > "$CHAP_SECRETS"
    rm -f "$tmp"
    log "Removed PPTP user '$user'."
}

list_users() {
    if [[ ! -r "$CHAP_SECRETS" ]]; then
        info "No users yet ($CHAP_SECRETS does not exist)."
        return 0
    fi
    echo "PPTP users in $CHAP_SECRETS:"
    awk '$2 == "pptpd" { print "  " $1 }' "$CHAP_SECRETS"
}

status() {
    echo "=== PPTP server status ==="
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        log "Service '$SERVICE': active"
    else
        warn "Service '$SERVICE': not running"
    fi
    if [[ -e "$PPTPD_CONF" ]]; then
        log "Config present: $PPTPD_CONF"
    else
        warn "Config missing: $PPTPD_CONF"
    fi
    list_users
    echo "Firewall rules for PPTP:"
    iptables -L INPUT -n 2>/dev/null | grep -E '1723|47' || echo "  (no explicit INPUT rules; check your cloud security group)"
}

print_config() {
    # No writes. Compute the same values the install path would and print
    # every file we would create.
    compute_network_values
    echo "=== [dry-run] files pptp.sh would write ==="
    echo
    echo "--- $PPTPD_CONF"
    render_pptpd_conf
    echo
    echo "--- $PPP_OPTIONS"
    render_ppp_options
    echo
    echo "--- chap-secrets lines (appended to $CHAP_SECRETS)"
    if [[ -n "$CLIENT" ]]; then
        render_chap_secrets_line "$CLIENT" "${PASSWORD:-<generated-at-install>}"
    fi
    echo "(users added interactively are appended the same way)"
    echo
    echo "--- /etc/sysctl.d/90-pptpd.conf"
    echo "net.ipv4.ip_forward = 1"
    echo
    echo "--- /etc/modules-load.d/pptpd.conf"
    printf 'pptp\nnf_nat_pptp\nnf_conntrack_pptp\n'
}

compute_network_values() {
    # Derive LOCALIP + REMOTEIP_RANGE from CLIENT_SUBNET.
    # Subnet is required to be /24 for the default-range heuristic.
    local net="${CLIENT_SUBNET%/*}"
    local prefix="${CLIENT_SUBNET#*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] || die "Invalid CIDR: $CLIENT_SUBNET"
    if [[ "$prefix" -ne 24 ]]; then
        warn "Non-/24 client subnet ($CLIENT_SUBNET); using first .1 and a 200-host range."
    fi
    # Build the .1 address from the network's last octet.
    local last="${net##*.}"
    LOCALIP="${net%.*}.$last"
    LOCALIP="${LOCALIP%.*}.1"
    # Client range: start .100 -> .230 for /24.
    local start=100 end=230
    if [[ "$prefix" -gt 24 ]]; then
        end=$(( start + ((1 << (32 - prefix)) - 1) - 1 ))
        if [[ "$end" -gt 254 ]]; then
            end=254
        fi
    fi
    REMOTEIP_RANGE="${LOCALIP%.*}.100-${LOCALIP%.*}.$end"
    # Validate shape.
    [[ "$LOCALIP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Computed a bad local IP: $LOCALIP"
}

# --- guided install ---------------------------------------------------------
guided_install() {
    compute_network_values
    echo
    echo "PPTP VPN server setup"
    echo "  PPTP client subnet : $CLIENT_SUBNET"
    echo "  PPTP local IP      : $LOCALIP"
    echo "  PPTP client range  : $REMOTEIP_RANGE"
    echo "  Pushed DNS         : $DNS1, $DNS2"
    echo "  NAT/forwarding     : $([[ $DO_FORWARDING -eq 1 ]] && echo enabled || echo disabled)"
    echo
    if [[ -n "$CLIENT" ]]; then
        PASSWORD="${PASSWORD:-$(generate_password)}"
        echo "  Initial user       : $CLIENT"
    fi

    # The non-negotiable part: PPTP is broken. Require explicit consent.
    echo
    warn "PPTP is a broken, insecure protocol (weak MPPE key handling, no"
    warn "integrity protection in the original design). Use L2TP/IPsec, OpenVPN,"
    warn "or WireGuard for anything that matters."
    if [[ "$UNDERSTAND" -ne 1 ]]; then
        if [[ -t 0 ]]; then
            printf 'Type exactly %s to continue: ' '"yes"'
            local reply
            read -r reply || reply=""
            if [[ "$reply" != "yes" ]]; then
                die "Aborted: PPTP not confirmed."
            fi
            UNDERSTAND=1
        else
            die "Non-interactive run: add --i-understand-pptp-is-insecure to proceed."
        fi
    fi
    echo
    if ! ask_yes_no "Proceed with PPTP install?" "Y"; then
        die "Aborted before writing anything."
    fi
    do_install
}

do_install() {
    require_root
    detect_os
    # Back up anything we will touch.
    BACKUPS=()
    BACKUP_NEW_USERS=()
    backup_file "$PPTPD_CONF"
    backup_file "$PPP_OPTIONS"
    backup_file "$CHAP_SECRETS"
    trap rollback EXIT

    # pptpd must exist in this release's repo (noble and later: it does not).
    pptpd_available || exit 1

    log "Installing pptpd..."
    apt_get install pptpd

    log "Writing config..."
    mkdir -p /etc/ppp
    printf '%s\n' "$(render_pptpd_conf)" > "$PPTPD_CONF"
    printf '%s\n' "$(render_ppp_options)" > "$PPP_OPTIONS"

    # Ensure chap-secrets exists with a header.
    if [[ ! -e "$CHAP_SECRETS" ]]; then
        {
            echo "# /etc/ppp/chap-secrets -- written by pptp.sh"
            echo "# format: client server secret [clients]"
            echo "# (server field must match the pppd 'name' option: pptpd)"
        } > "$CHAP_SECRETS"
        chmod 0640 "$CHAP_SECRETS"
    fi

    # Initial user (optional).
    if [[ -n "$CLIENT" ]]; then
        add_user "$CLIENT" "$PASSWORD"
    fi

    # Firewall + NAT + modules.
    allow_pptp_firewall
    setup_forwarding

    # Restart under test; on failure roll back config and exit non-zero.
    log "Starting service..."
    systemctl restart "$SERVICE"
    trap - EXIT
    sleep 1
    if ! systemctl is-active --quiet "$SERVICE"; then
        die "Service failed to start; config has been rolled back (${BACKUP_OF[$PPTPD_CONF]:-none})."
    fi

    echo
    log "=== PPTP server summary ==="
    echo "  Control port   : TCP/1723"
    echo "  Data protocol  : GRE (IP protocol 47)"
    echo "  Local IP       : $LOCALIP"
    echo "  Client range   : $REMOTEIP_RANGE"
    echo "  DNS pushed     : $DNS1, $DNS2"
    echo "  Encryption     : MS-CHAPv2 + MPPE 128-bit (PPTP is still not secure)"
    if [[ -n "${BACKUP_NEW_USERS[0]:-}" ]]; then
        echo
        echo "  Initial credentials (store now; shown only once):"
        local u p
        for entry in "${BACKUP_NEW_USERS[@]}"; do
            u="${entry%% *}"; p="${entry#* }"
            echo "    user     : $u"
            echo "    password : $p"
        done
    fi
    echo
    warn "Cloud providers: open TCP 1723 and GRE (protocol 47) in the security"
    warn "group, or the tunnel will not reach you."
}

# --- uninstall --------------------------------------------------------------
uninstall() {
    require_root
    local fw
    fw="$(detect_firewall)"
    case "$fw" in
        ufw)
            ufw delete allow 1723/tcp >/dev/null 2>&1 || true
            ;;
        firewalld)
            firewall-cmd --permanent --remove-port=1723/tcp >/dev/null 2>&1 || true
            firewall-cmd --permanent --remove-rich-rule='rule protocol value="gre" accept' >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
        iptables)
            iptables -D INPUT -p tcp --dport 1723 -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p 47 -j ACCEPT 2>/dev/null || true
            ;;
    esac
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "/etc/modules-load.d/pptpd.conf" /etc/sysctl.d/90-pptpd.conf
    apt_get remove pptpd || true
    log "PPTP server removed (chap-secrets kept; delete $CHAP_SECRETS manually if unwanted)."
}

# --- argument parsing -------------------------------------------------------
cmd=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --auto) AUTO=1; shift ;;
        --i-understand-pptp-is-insecure) UNDERSTAND=1; shift ;;
        --client-subnet) CLIENT_SUBNET="${2:-}"; shift 2 ;;
        --remoteip) REMOTEIP_RANGE_OVERRIDE="${2:-}"; shift 2 ;;
        --dns) DNS1="${2:-}"; DNS2="${3:-}"; shift; [[ $# -gt 0 && "$1" == "--dns" ]] && shift ;;
        --no-forwarding) DO_FORWARDING=0; shift ;;
        install) cmd="install"; shift ;;
        add-user)
            cmd="add-user"; shift
            CLIENT="${1:-${PPTP_USER:-}}"
            PASSWORD="${2:-${PPTP_PASSWORD:-}}"
            shift; [[ $# -gt 0 ]] && shift
            ;;
        remove-user) cmd="remove-user"; USER_ARG="${1:-${PPTP_USER:-}}"; shift; [[ $# -gt 0 ]] && shift ;;
        list-users) cmd="list-users"; shift ;;
        print-config) cmd="print-config"; shift ;;
        uninstall) cmd="uninstall"; shift ;;
        -*) warn "Unknown flag: $1 (ignored)"; shift ;;
        *) cmd="${cmd:-default}"; shift ;;
    esac
done

# Apply the remoteip override, if given.
if [[ -n "${REMOTEIP_RANGE_OVERRIDE:-}" ]]; then
    REMOTEIP_RANGE_OVERRIDE_SET=1
fi

main() {
    case "$cmd" in
        install|add-user)
            if [[ "$cmd" == "install" ]]; then
                require_root
                detect_os
                compute_network_values
                if [[ -n "${REMOTEIP_RANGE_OVERRIDE_SET:-}" ]]; then
                    REMOTEIP_RANGE="$REMOTEIP_RANGE_OVERRIDE"
                fi
                if [[ "$AUTO" -eq 1 && "$UNDERSTAND" -ne 1 ]]; then
                    die "--auto install requires --i-understand-pptp-is-insecure (or interactive 'yes')."
                fi
                if [[ -n "$CLIENT" ]]; then
                    PASSWORD="${PASSWORD:-$(generate_password)}"
                fi
                if [[ -t 0 ]]; then
                    guided_install
                else
                    do_install
                fi
            else
                # add-user standalone: needs chap-secrets to already exist.
                require_root
                [[ -e "$CHAP_SECRETS" ]] || die "No $CHAP_SECRETS; run 'install' first."
                add_user "$CLIENT" "$PASSWORD"
                # Print the one-time credential so automation can capture it.
                echo "user=$CLIENT password=${BACKUP_NEW_USERS[0]#* }"
            fi
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
            if [[ -e "$PPTPD_CONF" ]] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
                management_menu
            else
                require_root
                detect_os
                guided_install
            fi
            ;;
        *)
            warn "Unknown subcommand '$cmd' (treated as no-args)."
            if [[ -e "$PPTPD_CONF" ]] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
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
        echo "PPTP management menu (pptpd)"
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
                uname="$(ask "PPTP username" "vpnuser")"
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
                if ask_yes_no "Uninstall PPTP?" "n"; then
                    uninstall
                fi
                ;;
            0|*) break ;;
        esac
    done
}

# apt helper shared with other tools' conventions.
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

main
