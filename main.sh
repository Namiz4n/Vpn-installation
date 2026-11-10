#!/bin/bash
#
# main.sh -- VPN Installation & Toolkit Menu
#
# Presents a menu to install/manage OpenVPN (via the pinned angristan
# installer), WireGuard (via the standalone wireguard-install.sh in this
# repo), and a set of first-party VPN/proxy tools that live in this
# repository's tools/ directory (OpenConnect, MTProto, Cloudflare WARP,
# port-forward tunnel, nginx reverse proxy, SSL certificate, SSH port).
#
# All child scripts are downloaded to a temp file and executed so nothing
# is left behind in the current working directory.
#
# One-liner:
#   bash <(curl -Ls https://raw.githubusercontent.com/Namiz4n/Vpn-installation/refs/heads/main/main.sh)
#
# Override the repo ref used to fetch this repo's own child scripts:
#   VPN_INSTALL_REF=my-branch bash <(curl -Ls ...)

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- configuration ----------------------------------------------------------
REPO="Namiz4n/Vpn-installation"
REF="${VPN_INSTALL_REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/refs/heads/${REF}"

# --- root check -------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}Error: this script must be run as root.${NC}" >&2
    echo "Try:  sudo bash $0" >&2
    exit 1
fi

# --- helpers ----------------------------------------------------------------
# Download a remote script to a temp file, run it, then clean up.
# Usage: run_remote_script <url>
#
# No EXIT trap is used here: a trap registered inside a function would
# outlive the function and reference a local that is out of scope at
# shell exit ("tmp: unbound variable"), leaking the temp file. Instead the
# temp file is removed explicitly on both the failure and success paths.
run_remote_script() {
    local url="$1"
    local filename
    filename="${url##*/}"
    local tmp
    tmp="$(mktemp /tmp/vpn-install.XXXXXX)"

    echo -e "${GREEN}Fetching ${filename}...${NC}" >&2
    if ! curl -fsSL --retry 3 -o "$tmp" "$url"; then
        echo -e "${RED}Error: failed to download ${filename} from ${url}${NC}" >&2
        rm -f "$tmp"
        echo ""
        echo -e "${YELLOW}Press ENTER to return to the menu...${NC}"
        read -rsn 1 _ || true
        return 1
    fi

    bash "$tmp"
    rm -f "$tmp"
    echo ""
    echo -e "${YELLOW}Press ENTER to return to the menu...${NC}"
    read -rsn 1 _ || true
    return 0
}

# --- main menu loop ---------------------------------------------------------
while true; do
    clear
    echo -e "${YELLOW}+--------------------------------------------------------+${NC}"
    echo -e "${GREEN}|            VPN Installation & Toolkit Menu             |${NC}"
    echo -e "${YELLOW}+--------------------------------------------------------+${NC}"
    echo -e "${BLUE}|${YELLOW}  1.${NC} ${CYAN}OpenVPN (pinned angristan installer)${NC}               ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW}  2.${NC} ${CYAN}WireGuard (standalone installer)${NC}                   ${BLUE}|${NC}"
    echo -e "${YELLOW}+--------------------------------------------------------+${NC}"
    echo -e "${BLUE}|${YELLOW}  3.${NC} ${CYAN}OpenConnect VPN (ocserv)${NC}                           ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW}  4.${NC} ${CYAN}MTProto proxy (Telegram)${NC}                           ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW}  5.${NC} ${CYAN}Cloudflare WARP${NC}                                    ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW}  6.${NC} ${CYAN}Port-forward tunnel (iptables/nftables)${NC}            ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW}  7.${NC} ${CYAN}Nginx reverse proxy${NC}                                ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW}  8.${NC} ${CYAN}SSL certificate (certbot)${NC}                          ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW}  9.${NC} ${CYAN}Change SSH port${NC}                                    ${BLUE}|${NC}"
    echo -e "${YELLOW}+--------------------------------------------------------+${NC}"
    echo -e "${BLUE}|${YELLOW}  0.${NC} ${RED}Quit${NC}                                               ${BLUE}|${NC}"
    echo -e "${YELLOW}+--------------------------------------------------------+${NC}"
    echo ""
    read -rp "Enter option number: " choice

    case "$choice" in
        1)
            run_remote_script "${RAW_BASE}/install_openvpn.sh"
            ;;
        2)
            run_remote_script "${RAW_BASE}/wireguard-install.sh"
            ;;
        3)
            run_remote_script "${RAW_BASE}/tools/ocserv.sh"
            ;;
        4)
            run_remote_script "${RAW_BASE}/tools/mtproto.sh"
            ;;
        5)
            run_remote_script "${RAW_BASE}/tools/warp.sh"
            ;;
        6)
            run_remote_script "${RAW_BASE}/tools/tunnel.sh"
            ;;
        7)
            run_remote_script "${RAW_BASE}/tools/reverse-proxy.sh"
            ;;
        8)
            run_remote_script "${RAW_BASE}/tools/ssl.sh"
            ;;
        9)
            run_remote_script "${RAW_BASE}/tools/ssh-port.sh"
            ;;
        0)
            echo -e "${GREEN}Exiting...${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option. Try again.${NC}"
            sleep 1
            ;;
    esac
done
