#!/bin/bash
#
# main.sh -- VPN Installation & Toolkit Menu
#
# Presents a menu to install/manage OpenVPN (via angristan/openvpn-install),
# WireGuard (via the standalone wireguard-install.sh in this repo) and the
# Soroushnk/Astro toolkit (VPN/proxy tooling).
#
# All child scripts are downloaded to a temp file and executed so nothing is
# left behind in the current working directory.
#
# One-liner:
#   bash <(curl -Ls https://raw.githubusercontent.com/Namiz4n/Vpn-installation/refs/heads/main/main.sh)
#
# Override the repo ref used to fetch this repo's own child scripts:
#   VPN_INSTALL_REF=my-branch bash <(curl -Ls ...)
#
# Override the Astro ref used to fetch Soroushnk/Astro scripts:
#   ASTRO_REF=<sha> or "main" (follows Astro's latest main)

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

# Pinned Astro commit SHA. Set ASTRO_REF=main to always follow Astro's
# latest main branch.
ASTRO_REF="${ASTRO_REF:-84e235e12b673f92080fb254f7168a50b5e2567e}"
ASTRO_BASE="https://raw.githubusercontent.com/Soroushnk/Astro/${ASTRO_REF}"

# --- root check -------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}Error: this script must be run as root.${NC}" >&2
    echo "Try:  sudo bash $0" >&2
    exit 1
fi

# --- helpers ----------------------------------------------------------------
# Download a remote script to a temp file, run it, then clean up.
# Usage: run_remote_script <url>
run_remote_script() {
    local url="$1"
    local filename
    filename="${url##*/}"
    local tmp
    tmp="$(mktemp /tmp/vpn-install.XXXXXX)"
    trap 'rm -f "$tmp" 2>/dev/null || true' EXIT

    echo -e "${GREEN}Fetching ${filename}...${NC}" >&2
    if ! curl -fsSL --retry 3 -o "$tmp" "$url"; then
        echo -e "${RED}Error: failed to download ${filename} from ${url}${NC}" >&2
        return 1
    fi

    bash "$tmp"
    echo ""
    echo -e "${YELLOW}Press ENTER to return to the menu...${NC}"
    read -s -n 1 -r _ || true
    return 0
}

# --- main menu loop ---------------------------------------------------------
while true; do
    clear
    echo -e "${YELLOW}+------------------------------------------------------------+${NC}"
    echo -e "${GREEN}|          VPN Installation & Toolkit Menu                    |${NC}"
    echo -e "${YELLOW}+------------------------------------------------------------+${NC}"
    echo -e "${BLUE}|${YELLOW}  1.${NC} ${GREEN}OpenVPN (angristan installer)${NC}                         ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW}  2.${NC} ${GREEN}WireGuard (standalone installer)${NC}                      ${BLUE}|${NC}"
    echo -e "${YELLOW}+------------------------------------------------------------+${NC}"
    echo -e "${BLUE}|${YELLOW}  Astro tools (Soroushnk/Astro, GPL-3.0, run as root):        ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW}  3.${NC} ${CYAN}Cisco / OpenConnect VPN${NC}                            ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW}  4.${NC} ${CYAN}IPsec VPN (L2TP/IKEv2)${NC}                             ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW}  5.${NC} ${CYAN}Outline VPN${NC}                                      ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW}  6.${NC} ${CYAN}MTProto proxy${NC}                                    ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW}  7.${NC} ${CYAN}V2Ray / Xray panels${NC}                              ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW}  8.${NC} ${CYAN}Reality.ez${NC}                                       ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW}  9.${NC} ${CYAN}X-UI manager${NC}                                     ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW} 10.${NC} ${CYAN}Liberta panel${NC}                                    ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW} 11.${NC} ${CYAN}WARP (WireGuard + WARP)${NC}                          ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW} 12.${NC} ${CYAN}SSH panel${NC}                                        ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW} 13.${NC} ${CYAN}IPtables tunnel${NC}                                  ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW} 14.${NC} ${CYAN}Reverse proxy${NC}                                    ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW} 15.${NC} ${CYAN}SSL certificate${NC}                                  ${BLUE}|${NC}"
    echo -e "${YELLOW}+------------------------------------------------------------+${NC}"
    echo -e "${BLUE}|${YELLOW}  A.${NC} ${GREEN}Open the full Astro toolkit (Astro-main.sh)${NC}         ${BLUE}|${NC}"
    echo -e "${YELLOW}+------------------------------------------------------------+${NC}"
    echo -e "${BLUE}|${YELLOW}  0.${NC} ${RED}Quit${NC}                                               ${BLUE}|${NC}"
    echo -e "${YELLOW}+------------------------------------------------------------+${NC}"
    echo -e "${YELLOW}  Astro scripts pinned to commit ${ASTRO_REF:0:7} (set ASTRO_REF=main for latest).${NC}"
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
            run_remote_script "${ASTRO_BASE}/managed/cisco_vpn.sh"
            ;;
        4)
            run_remote_script "${ASTRO_BASE}/managed/IPsec.sh"
            ;;
        5)
            run_remote_script "${ASTRO_BASE}/managed/install_outline.sh"
            ;;
        6)
            run_remote_script "${ASTRO_BASE}/managed/mtproto.sh"
            ;;
        7)
            run_remote_script "${ASTRO_BASE}/managed/v2ray_pannel.sh"
            ;;
        8)
            run_remote_script "${ASTRO_BASE}/managed/reallity_ez.sh"
            ;;
        9)
            run_remote_script "${ASTRO_BASE}/managed/xui_manager.sh"
            ;;
        10)
            run_remote_script "${ASTRO_BASE}/managed/liberta.sh"
            ;;
        11)
            run_remote_script "${ASTRO_BASE}/managed/install-warp.sh"
            ;;
        12)
            run_remote_script "${ASTRO_BASE}/managed/ssh_panel.sh"
            ;;
        13)
            run_remote_script "${ASTRO_BASE}/managed/tunnel.sh"
            ;;
        14)
            run_remote_script "${ASTRO_BASE}/managed/reverse-proxy.sh"
            ;;
        15)
            run_remote_script "${ASTRO_BASE}/managed/ssl_get.sh"
            ;;
        a|A)
            run_remote_script "${ASTRO_BASE}/Astro-main.sh"
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
