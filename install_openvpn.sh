#!/bin/bash
#
# install_openvpn.sh -- thin, safe wrapper around angristan/openvpn-install
#
# This wrapper:
#   1. checks that it is run as root
#   2. downloads the upstream installer from a pinned commit (REF)
#   3. optionally verifies the SHA-256 checksum (EXPECTED_SHA256)
#   4. runs the installer, defaulting to "interactive" when no args are given
#
# All OpenVPN client/server management commands are provided by upstream:
#   install, uninstall, client add|list|revoke|renew,
#   server status|renew, interactive
#
# This script intentionally does NOT print private keys, and does not leave
# any copy of the upstream installer in the current working directory.

set -euo pipefail

# Pinned upstream commit (angristan/openvpn-install, branch: master)
REF="ad22fd9eb0c8569a885f836ef6e37576d8702e9f"

# Optional: set to the expected SHA-256 of the downloaded installer to
# verify integrity before executing it. Leave empty to skip verification.
EXPECTED_SHA256=""

UPSTREAM_URL="https://raw.githubusercontent.com/angristan/openvpn-install/${REF}/openvpn-install.sh"

# Upstream keeps everything under /etc/openvpn/server/.
OVPN_DIR="/etc/openvpn/server"

# --- root check -------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: this script must be run as root." >&2
    echo "Try:  sudo bash $0 $*" >&2
    exit 1
fi

# --- temp-file cleanup -------------------------------------------------------
# Registered right after the temp file is created (see below). Defined up top
# so it is clearly reachable; invoked only via the EXIT trap.
# shellcheck disable=SC2329,SC2317  # invoked only via the EXIT trap
cleanup() { rm -f "$tmp_installer" 2>/dev/null || true; }

# --- show client info (safe: no private keys, validated name) ---------------
# Print a client's generated .ovpn config path and certificate location only.
# Private key files are never displayed.
show_client_info() {
    local client_name="$1"

    if [[ ! "$client_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "Invalid client name: '$client_name'." >&2
        echo "Client names may only contain A-Z, a-z, 0-9, '-' and '_'." >&2
        return 1
    fi

    local ovpn_cert="${OVPN_DIR}/easy-rsa/pki/issued/${client_name}.crt"
    local ovpn_key="${OVPN_DIR}/easy-rsa/pki/private/${client_name}.key"

    if [[ ! -f "$ovpn_cert" ]]; then
        echo "Client '$client_name' not found at $ovpn_cert." >&2
        echo "Run '$0 client list' to see configured clients." >&2
        return 1
    fi

    echo "=== Client: $client_name ==="
    echo
    echo "Certificate file: $ovpn_cert"

    # The .ovpn config is written to the user's home directory (or /root).
    for dir in /root /home/*; do
        if [[ -f "${dir}/${client_name}.ovpn" ]]; then
            echo "Client config (.ovpn): ${dir}/${client_name}.ovpn"
            echo
            echo "Private key is at: $ovpn_key (not displayed for security)."
            echo "Copy the .ovpn file to your device to connect."
            return 0
        fi
    done
    echo
    echo "No .ovpn file found in /root or /home. The client may have been"
    echo "added but the config was not written to a home directory yet."
    return 0
}

# --- dispatch before any network work ---------------------------------------
# If the user asked to inspect a client, do that locally without downloading.
if [[ "${1:-}" == "client-info" || "${1:-}" == "--client-info" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 client-info <client-name>" >&2
        exit 1
    fi
    show_client_info "$2"
    exit 0
fi

# --- download + verify + run ------------------------------------------------
tmp_installer="$(mktemp "${TMPDIR:-/tmp}/openvpn-install.XXXXXX")"
trap cleanup EXIT

echo "Downloading OpenVPN installer (commit ${REF:0:7})..." >&2
if ! curl -fsSL --retry 3 -o "$tmp_installer" "$UPSTREAM_URL"; then
    echo "Error: failed to download OpenVPN installer from $UPSTREAM_URL" >&2
    exit 1
fi

if [[ -n "$EXPECTED_SHA256" ]]; then
    actual_sha256="$(sha256sum "$tmp_installer" | awk '{print $1}')"
    if [[ "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
        echo "Error: SHA-256 mismatch!" >&2
        echo "  expected: $EXPECTED_SHA256" >&2
        echo "  actual:   $actual_sha256" >&2
        exit 1
    fi
    echo "SHA-256 verified OK." >&2
fi

# Run the installer; default to "interactive" when no arguments are supplied.
# We do NOT use `exec` here: exec would replace this shell and prevent the
# EXIT trap from running, leaking the temp file.
if [[ $# -eq 0 ]]; then
    bash "$tmp_installer" interactive
else
    bash "$tmp_installer" "$@"
fi
rc=$?
exit "$rc"
