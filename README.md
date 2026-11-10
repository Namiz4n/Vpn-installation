# Vpn-installation

Bash helpers for installing and managing an **OpenVPN** server, a
**WireGuard** server, and the popular **Astro** VPN/proxy toolkit on a
Linux VPS.

- **OpenVPN** — powered by
  [angristan/openvpn-install](https://github.com/angristan/openvpn-install)
  (MIT), pinned to a fixed commit SHA.
- **WireGuard** — a standalone installer based on
  [Nyr/wireguard-install](https://github.com/Nyr/wireguard-install) and
  [hwdsl2/wireguard-install](https://github.com/hwdsl2/wireguard-install)
  (MIT).
- **Astro toolkit** — a launcher that downloads and runs individual
  [Soroushnk/Astro](https://github.com/Soroushnk/Astro) scripts at
  runtime (Cisco/OpenConnect, IPsec, Outline, MTProto, V2Ray/Xray,
  Reality.ez, X-UI, Liberta, WARP, SSH panel, IPtables tunnel, reverse
  proxy, SSL). No Astro code is included in this repo; only its scripts
  are downloaded and executed.

Everything is designed to be run as `root` on a fresh VPS.

## Features

- One command to **install** OpenVPN, WireGuard or any Astro tool.
- **Add, list and revoke** VPN clients without re-running the installer.
- **Uninstall** to cleanly remove a VPN and all of its configuration.
- Pinned, checksum-verifiable upstream OpenVPN installer.
- Pinned Astro ref (auto-updated weekly via a GitHub Action).
- No leftover temp files are written to your working directory.

## Supported operating systems

**OpenVPN** (from angristan/openvpn-install):
Debian, Ubuntu, Fedora, openSUSE, CentOS / Rocky Linux / AlmaLinux,
Oracle Linux, Amazon Linux 2023 and Arch Linux.

**WireGuard** (from the bundled `wireguard-install.sh`):
Ubuntu (20.04+), Debian (11+), AlmaLinux, Rocky Linux, CentOS (8+),
Fedora and openSUSE.

**Astro tools** (from Soroushnk/Astro):
Ubuntu 20.04+ (per its README).

Run the installer on your VPS's primary OS. Both installers will refuse
to run on an unsupported distribution.

## Usage

The quickest way to start is the interactive menu:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Namiz4n/Vpn-installation/refs/heads/main/main.sh)
```

The menu downloads the OpenVPN / WireGuard / Astro scripts on demand
(into a temp file) and runs them, so nothing is left behind in your
current directory. You can override the git refs used to fetch those
scripts with the `VPN_INSTALL_REF` (default: `main`) and `ASTRO_REF`
(default: a pinned SHA; set to `main` to always follow Astro's latest
main branch) environment variables:

```bash
VPN_INSTALL_REF=stable ASTRO_REF=main \
  bash <(curl -Ls https://raw.githubusercontent.com/Namiz4n/Vpn-installation/refs/heads/main/main.sh)
```

### OpenVPN (non-interactive examples)

The OpenVPN helper is a thin wrapper that downloads and runs the
upstream installer, so any upstream flag works. It is *not* a
single-command installer like WireGuard — you must either use the menu
or pass subcommands explicitly:

```bash
# Interactive install
bash install_openvpn.sh

# Install with a fixed port and protocol
bash install_openvpn.sh install --port 443 --protocol tcp

# Add / list / revoke / renew a client
bash install_openvpn.sh client add alice
bash install_openvpn.sh client list
bash install_openvpn.sh client revoke alice
bash install_openvpn.sh client renew alice

# Show connected clients / renew the server cert
bash install_openvpn.sh server status
bash install_openvpn.sh server renew

# Uninstall
bash install_openvpn.sh uninstall
```

You can also download the upstream installer directly:

```bash
curl -fsSLO https://raw.githubusercontent.com/angristan/openvpn-install/ad22fd9eb0c8569a885f836ef6e37576d8702e9f/openvpn-install.sh
chmod +x openvpn-install.sh
./openvpn-install.sh install
```

### WireGuard (non-interactive examples)

`wireguard-install.sh` is self-contained:

```bash
# Interactive setup
bash wireguard-install.sh

# Automatic install with defaults
bash wireguard-install.sh --auto

# Add / list / remove a client
bash wireguard-install.sh --addclient "laptop"
bash wireguard-install.sh --listclients
bash wireguard-install.sh --removeclient "laptop"

# Uninstall
bash wireguard-install.sh --uninstall
```

### Astro tools (via the menu)

The menu's Astro section downloads and runs each tool's own script
from Soroushnk/Astro's `main` branch (or the pinned ref). No Astro
code ships with this repository.

## Security notes

- **Run as root.** Both installers and every Astro tool require root.
  The scripts check this and exit with an error if you are not root;
  they never re-execute via `su`.
- **Pinned upstream versions.** The OpenVPN wrapper downloads
  angristan/openvpn-install at a fixed commit SHA. The Astro launcher
  pins Astro's main branch at a fixed SHA (auto-bumped weekly). Re-pin
  the `REF` / `ASTRO_REF` variables whenever you update them. You may
  also set `EXPECTED_SHA256` in `install_openvpn.sh` to verify the
  download before it is executed.
- **Keep client configs private.** Client `.ovpn` / `.conf` files
  embed private keys. Never commit them to version control or share
  them publicly, and restrict their file permissions on the server
  (the installers set `chmod 600`).
- **Astro scripts are third-party.** They are not bundled with this
  repository and are run as root from Soroushnk/Astro. Review their
  source before use; they are GPL-3.0 licensed.

## Credits & licenses

This repository's own code is MIT-licensed (see `LICENSE`).

- [angristan/openvpn-install](https://github.com/angristan/openvpn-install)
  — MIT. The OpenVPN installer used by `install_openvpn.sh`.
- [Nyr/wireguard-install](https://github.com/Nyr/wireguard-install) and
  [hwdsl2/wireguard-install](https://github.com/hwdsl2/wireguard-install)
  — MIT. The basis for the bundled `wireguard-install.sh`.
- [Soroushnk/Astro](https://github.com/Soroushnk/Astro) by Soroush
  Nekoozadeh — GPL-3.0. Only *launched* at runtime from its own
  repository; we do not include or modify its code. See
  [its LICENSE](https://github.com/Soroushnk/Astro/blob/main/LICENSE).
