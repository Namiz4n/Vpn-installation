# Vpn-installation

Bash helpers for installing and managing a **OpenVPN** server, a
**WireGuard** server, and a set of first-party VPN/proxy tools on a
Linux VPS. Everything is designed to be run as `root` on a fresh Debian
or Ubuntu system.

## Quick start

```bash
sudo bash <(curl -Ls https://raw.githubusercontent.com/Namiz4n/Vpn-installation/refs/heads/main/main.sh)
```

Pick a menu item. Each tool can also be run standalone:

```bash
sudo bash tools/ocserv.sh        # guided install or management menu
sudo bash tools/pptp.sh
sudo bash tools/l2tp.sh
sudo bash tools/gre.sh
```

Run a tool with **no arguments** to get a guided install (or a short
management menu when it is already installed). Subcommands remain
available for power users; `-h` / `--help` prints usage.

## Menu

| # | Tool | What it installs |
|---|------|------------------|
| 1 | OpenVPN | The pinned angristan OpenVPN installer (URL + commit in `install_openvpn.sh`) |
| 2 | WireGuard | The standalone `wireguard-install.sh` in this repo |
| 3 | OpenConnect | `ocserv` (OpenConnect VPN server) + `ocpasswd` user database |
| 4 | MTProto proxy | A pinned `mtg` binary (9seconds/mtg, SHA-256 verified) behind a systemd unit |
| 5 | Cloudflare WARP | The Cloudflare WARP client from Cloudflare's official repo |
| 6 | PPTP | `pptpd` (MS-CHAPv2 + 128-bit MPPE) |
| 7 | L2TP/IPsec | `strongswan` + `xl2tpd` + `ppp` (PSK road-warrior) |
| 8 | GRE | An `iproute2` GRE P2P tunnel + systemd persistence |
| 0 | Quit | — |

## Supported OS (per tool)

- **Debian / Ubuntu only** (the tool detects the distro and refuses
  otherwise): `ocserv.sh`, `pptp.sh`, `l2tp.sh`, `gre.sh`.
- **Debian/Ubuntu + RHEL/Fedora/CentOS**: `warp.sh`.
- **`install_openvpn.sh` and `wireguard-install.sh`**: whatever their
  upstream installers support (OpenVPN's pinned installer targets
  Debian/Ubuntu; the WireGuard installer targets Debian/Ubuntu).

`pptpd` is **not shipped on Ubuntu 24.04+**; the PPTP tool detects that
and refuses to install, pointing you at L2TP/IPsec instead.

## Security notes

- **PPTP is a broken protocol** (weak MPPE key handling). The installer
  refuses to proceed unless you explicitly confirm
  (`yes`, or `--auto --i-understand-pptp-is-insecure`).
- **GRE is NOT encrypted.** Traffic is plaintext on the underlay. Use it
  only inside a trusted network. (GRE-over-IPsec secure mode is not
  implemented.)
- **L2TP is only safe with IPsec.** This tool always wraps L2TP in
  IPsec (UDP 500/4500); UDP 1701 is never exposed publicly.
- **Everything runs as `root`.** Back up your server before using these
  tools; the tools take timestamped config backups and roll back on
  failure, but a fresh server is still the safest starting point.

## License

See `LICENSE`.
