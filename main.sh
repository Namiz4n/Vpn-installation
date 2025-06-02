#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check if user is root
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root"
    sleep 0.5
    su -s /bin/bash -c "$0 $*" root
fi

clear
while true; do
    clear
    echo -e "${YELLOW}+------------------------------------------+${NC}"
    echo -e "${GREEN}|       VPN Installation Menu (Clean)      |${NC}"
    echo -e "${YELLOW}+------------------------------------------+${NC}"
    echo -e "${BLUE}|${YELLOW} 1.${NC} ${CYAN}Install OpenVPN${NC}                     ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW} 2.${NC} ${CYAN}Install WireGuard${NC}                  ${BLUE}|${NC}"
    echo -e "${BLUE}|${YELLOW} 0.${NC} ${RED}Quit${NC}                               ${BLUE}|${NC}"
    echo -e "${YELLOW}+------------------------------------------+${NC}"
    echo ""
    read -p "Enter option number: " choice

    case $choice in
        1)
            bash <(curl -Ls https://raw.githubusercontent.com/Namiz4n/Vpn-installation/refs/heads/main/install_openvpn.sh)
            ;;
        2)
            bash <(curl -Ls https://raw.githubusercontent.com/Namiz4n/wiregaurd)
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
