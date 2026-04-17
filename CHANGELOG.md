# Changelog

## v0.2.2 (2026-04-17)

### Added
- **One-shot uninstall script** `scripts/uninstall-all.sh` — removes pf2socks AND reverts xray dedicated-user setup
- **Uninstall / Restore section** in README (English + 中文) with three scenarios:
  - pf2socks only
  - Full uninstall
  - Only revert xray dedicated user

### Changed
- `install.sh uninstall` output now points users to full uninstall and xray undo commands

## v0.2.1 (2026-04-17)

### Added
- **Auto-elevation** in `tproxy` script — no need to type `sudo` prefix
- **sudoers config** (`/etc/sudoers.d/pf2socks`) — admin group members can run `tproxy` without password
- Installer validates sudoers syntax with `visudo -cf` before installing

### Changed
- `tproxy on/off/status/restart` — now called directly (no `sudo`)
- `install.sh` adds `install_sudoers` step
- Uninstall also removes `/etc/sudoers.d/pf2socks`

## v0.2.0 (2026-04-17)

### Added
- **TLS SNI / HTTP Host sniffing** (`sniff.go`) — logs show target domain, not just IP
- **install.sh** — one-line install: compile, create LaunchDaemon, install `tproxy` control script
- **`tproxy` control script** — `on/off/status/restart/log` subcommands
- **Dedicated user setup script** (`scripts/setup-xray-dedicated-user.sh`) — creates `_xray` user and converts brew-managed xray to LaunchDaemon
- **pf-transparent-user.conf.example** — pf rules with `user` filter to prevent proxy loops
- **Documentation** (`docs/`):
  - `full-setup-guide.md` — end-to-end setup with dedicated user
  - `architecture.md` — deep dive into how it works

### Changed
- README updated with setup-guide pointers
- pf example config clarified (shows which variables to adjust)

### Fixed
- Sniff timeout (200ms) prevents hang on non-TLS/HTTP TCP protocols

## v0.1.0 (2026-04-15)

Initial release.

- `main.go` — pf2socks core: DIOCNATLOOK query + SOCKS5 forward
- Verified working on macOS 15 (Tahoe), Apple Silicon
- Example pf rule file with `route-to` + `rdr on lo0` pattern
