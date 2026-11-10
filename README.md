# Vpn-installation

Bash helpers for installing and managing a **OpenVPN** server, a
**WireGuard** server, and a set of first-party VPN/proxy tools on a
Linux VPS.

- **OpenVPN** — installed through a pinned third-party installer script;
  its URL and commit are in `install_openvpn.sh`.
- **WireGuard** — a standalone installer based on a widely-used public
  WireGuard installer (see the header of `wireguard-install.sh` for the
  original copyright and license notice).
- **Toolkit** — seven self-contained scripts under `tools/` that you can
  run standalone or launch from the menu:
  - `tools/ocserv.sh` — OpenConnect VPN server (ocserv + ocpasswd)
  - `tools/mtproto.sh` — MTProto proxy for Telegram (pinned third-party
    binary: 9seconds/mtg, URL and version are in `tools/mtproto.sh`)
  - `tools/warp.sh` — Cloudflare WARP client
  - `tools/tunnel.sh` — port-forward tunnel (iptables)
  - `tools/reverse-proxy.sh` — nginx reverse proxy
  - `tools/ssl.sh` — TLS certificates with certbot
  - `tools/ssh-port.sh` — change the SSH port safely

Everything is designed to be run as `root` on a fresh VPS.

## What it does

- One command to **install** OpenVPN or WireGuard, or to launch any of
  the seven toolkit tools.
- **Add, list and revoke** VPN users/clients without re-running the
  installer.
- **Uninstall / revert** paths for each tool.
- No leftover temp files are written to your working directory.

## Menu

Running `main.sh` shows a menu:

| # | Tool |
|---|------|
| 1 | OpenVPN (pinned installer) |
| 2 | WireGuard (standalone installer) |
| 3 | OpenConnect VPN (ocserv) |
| 4 | MTProto proxy (Telegram) |
| 5 | Cloudflare WARP |
| 6 | Port-forward tunnel (iptables/nftables) |
| 7 | Nginx reverse proxy |
| 8 | SSL certificate (certbot) |
| 9 | Change SSH port |
| 0 | Quit |

## Supported operating systems

Each script checks the OS at start and refuses to run on an unsupported
distribution. What the scripts check, exactly:

- **`main.sh` / `install_openvpn.sh` / `wireguard-install.sh`** — detect
  the distro via `/etc/os-release` and `apt-get` / `dnf` / `yum`
  availability. WireGuard supports the distros it was originally written
  for (Ubuntu, Debian, Fedora, openSUSE, Rocky/Alma/CentOS). The OpenVPN
  installer supports a broad range of distros; consult its own output.
- **`tools/ocserv.sh`, `tools/mtproto.sh`, `tools/tunnel.sh`,
  `tools/reverse-proxy.sh`, `tools/ssl.sh`, `tools/ssh-port.sh`** —
  Debian/Ubuntu only (they check for `/etc/debian_version` or an
  `ID`/`ID_LIKE` value of `debian`/`ubuntu` and exit otherwise).
- **`tools/warp.sh`** — Debian/Ubuntu (apt) and RHEL-family
  (dnf/yum). It detects the package manager and installs the Cloudflare
  WARP client from Cloudflare's official repository.

## Usage

The quickest way to start is the interactive menu:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Namiz4n/Vpn-installation/refs/heads/main/main.sh)
```

The menu downloads each script on demand (into a temp file) and runs it,
so nothing is left behind in your current directory. Override the git
ref used to fetch this repo's own scripts with `VPN_INSTALL_REF`
(default: `main`):

```bash
VPN_INSTALL_REF=stable bash <(curl -Ls https://raw.githubusercontent.com/Namiz4n/Vpn-installation/refs/heads/main/main.sh)
```

### OpenVPN (pinned installer)

`install_openvpn.sh` is a thin wrapper that downloads a pinned upstream
installer and runs it, so any upstream flag works:

```bash
# Interactive install
bash install_openvpn.sh

# Install with a fixed port and protocol
bash install_openvpn.sh install --port 443 --protocol tcp

# Add / list / revoke / renew a client
bash install_openvpn.sh client add alice
bash install_openvpn.sh client list
bash install_openvpn.sh client revoke alice

# Uninstall
bash install_openvpn.sh uninstall
```

To download the upstream installer directly (manual step):

```bash
curl -fsSLO https://raw.githubusercontent.com/angristan/openvpn-install/ad22fd9eb0c8569a885f836ef6e37576d8702e9f/openvpn-install.sh
chmod +x openvpn-install.sh
./openvpn-install.sh install
```

The commit SHA above is pinned in `install_openvpn.sh` (`REF`).

### WireGuard (standalone)

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

### Toolkit tools

Each tool is a standalone script. Run it directly:

```bash
bash tools/ocserv.sh install
bash tools/ocserv.sh add-user alice

bash tools/mtproto.sh install
bash tools/mtproto.sh add-user <64-hex-key>

bash tools/warp.sh install
bash tools/warp.sh status
bash tools/warp.sh disconnect
bash tools/warp.sh uninstall

bash tools/tunnel.sh add 8080 203.0.113.10 80 tcp
bash tools/tunnel.sh list
bash tools/tunnel.sh remove 8080 203.0.113.10 80 tcp

bash tools/reverse-proxy.sh add example.com 203.0.113.10:8080
bash tools/reverse-proxy.sh remove example.com

bash tools/ssl.sh issue example.com
bash tools/ssl.sh status

bash tools/ssh-port.sh change 2222
# After this, sshd listens on BOTH 22 and 2222. Test a second session:
#   ssh -p 2222 user@host
# Only once that works, close the old port (the old port stays open until
# you run this explicitly):
bash tools/ssh-port.sh disable-old-port
```

Or launch any of them from the menu.

> **SSH port safety:** `ssh-port.sh change` keeps the old port open until
> you run `disable-old-port`. It opens the new port in the firewall first,
> verifies sshd is actually listening on the new port before finishing, and
> rolls back automatically if `sshd -t` or the listener check fails. Always
> test a second session before closing the first one.

## Security notes

- **Run as root.** Every script checks this and exits with an error if
  you are not root.
- **Pinned upstream versions.** The OpenVPN wrapper downloads a pinned
  commit; you may also set `EXPECTED_SHA256` in `install_openvpn.sh` to
  verify the download's integrity before it is executed.
- **Back up before use.** Config-editing tools (`ssh-port.sh`,
  `reverse-proxy.sh`, `ssl.sh`) back up the files they modify before
  changing them.
- **Keep client configs private.** Client `.ovpn` / `.conf` / key files
  embed private keys. Never commit them to version control or share
  them publicly, and keep their file permissions restrictive.

## License

This repository's own code is MIT-licensed (see `LICENSE`).

`wireguard-install.sh` contains code under its own MIT license; see the
file header for the original copyright notice and attribution.
