```
╔══════════════════════════════════════════════════════════════════╗
║           UbuntuServer Fast Configuration                        ║
║   CLI tools · Docker · zram/swap · fastfetch · hardening          ║
╚══════════════════════════════════════════════════════════════════╝
```

<p align="center">
  <a href="README.md"><img src="https://img.shields.io/badge/README-Русский-blue" alt="Russian README"></a>
  <img src="https://img.shields.io/badge/bash-%3E%3D5.0-4EAA25?logo=gnubash&logoColor=white" alt="Bash 5+">
  <img src="https://img.shields.io/badge/Ubuntu-24.04%20%7C%2026.04-E95420?logo=ubuntu&logoColor=white" alt="Ubuntu 24.04 | 26.04">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

<p align="center"><a href="README.md">🇷🇺 Русский</a> · <b>🇬🇧 English</b></p>

---

One script that takes a fresh Ubuntu VPS to a working state: modern CLI tools, Docker, nginx, zram/swap on a battle-tested scheme, a nice `fastfetch` + `starship` setup, and optionally — SSH hardening with a built-in self-test (it never disables password login until it has actually verified key-based login works).

The menu shows the status of all 15 items at once — what's already applied, what isn't, what's configured differently than the guide recommends. Nothing is installed or overwritten silently.

## Contents

- [Quick start](#quick-start)
- [What the script does](#what-the-script-does)
- [Using the menu](#using-the-menu)
- [How it works](#how-it-works)
  - [Idempotency](#idempotency)
  - [Self-testing SSH hardening](#self-testing-ssh-hardening)
  - [UFW without surprises](#ufw-without-surprises)
  - [ZRAM + swap](#zram--swap)
- [Screenshots](#screenshots)
- [Repository layout](#repository-layout)
- [Customization](#customization)
- [Requirements](#requirements)
- [Deliberately not automated](#deliberately-not-automated)
- [FAQ / known gotchas](#faq--known-gotchas)
- [License](#license)

---

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh | sudo bash
```

The script installs itself as the **`vsu`** command (symlinked into `/usr/local/bin`), checks for updates, and opens a menu. Run it again any time:

```bash
sudo vsu
```

> **Before running on a production box** — test on a disposable/snapshot-able VPS first, especially if you plan to say yes to SSH hardening and UFW.

---

## What the script does

| # | Group | Item | Installs / configures |
|---|---|---|---|
| 1 | base | System update | `apt update && apt upgrade` |
| 2 | base | CLI tools | `eza`, `bat`, `fd-find`, `ripgrep`, `zoxide`, `ncdu` |
| 3 | base | Base packages | `micro`, `curl`, `wget`, `git`, `nano`, `certbot`, `python3-certbot-nginx`, `unzip`, `htop`, `bind9-dnsutils`, `jq`, `software-properties-common`, `ca-certificates`, `gnupg`, `rsync` |
| 4 | services | Docker + Compose | official Docker repo, auto-fallback to `noble` if packages for the codename aren't published yet |
| 5 | services | nginx-full | installs and enables on boot |
| 6 | services | fastfetch | PPA `zhangsongcui3371/fastfetch`, version ≥ 2.64.0 |
| 7 | services | starship | prompt |
| 8 | services | fastfetch config + .bashrc | `fastfetch/config.jsonc` + aliases/hooks |
| 9 | services | tmux | + minimal `.tmux.conf` |
| 10 | hardening | Docker log rotation | `max-size=10m`, `max-file=3` in `daemon.json` |
| 11 | hardening | fail2ban | jail on the actual SSH port |
| 12 | hardening | unattended-upgrades | automatic security patches |
| 13 | hardening | ZRAM + swap + sysctl + earlyoom | per the [guide](#zram--swap) |
| 14 | hardening | SSH hardening | keys instead of passwords, no root login, passwordless sudo |
| 15 | hardening | UFW | firewall allowing actually-used ports |

`bind9-dnsutils` instead of `dnsutils` isn't a typo: on Ubuntu 26.04 `dnsutils` became a virtual alias package — `apt install` resolves it fine, but `dpkg -s dnsutils` finds nothing because `bind9-dnsutils` is what's actually installed.

---

## Using the menu

```
    #  Item                                             Status
  ──────────────────────────────────────────────────────────────
  ── base ──
    1  System update                                    (action)
    2  CLI tools (eza/bat/fd/ripgrep/zoxide/ncdu)        ○ missing: eza, bat
    3  Base packages (micro/curl/git/certbot/...)        ✓ installed
  ── services ──
    4  Docker + Compose                                  ✓ installed (29.6.1)
    ...
  ── hardening ──
   14  SSH hardening                                     ✓ applied (password off)
   15  UFW firewall                                      ✓ enabled
  ──────────────────────────────────────────────────────────────

  5 / 1 3 5 / 1,3,5   apply one item or several at once
  A                   apply everything not yet applied
  R                   show rollback commands (reference only, executes nothing)
  U                   remove vsu itself from the system
  Q                   quit
```

- **A single number** (`5`) applies exactly that item, interactively, with its own questions as usual.
- **Multiple numbers** (`1 3 5` or `1,3,5`) — one upfront confirmation ("apply all selected at once?"), then each item applies with its own default answers, no per-item interruption.
- **Re-selecting an already-applied item** from the "hardening" group (Docker log rotation, fail2ban, unattended-upgrades, ZRAM, UFW) — the menu offers to disable it, no separate syntax needed.
- **`A`** — same "one confirmation → no interruptions" flow, for everything not yet applied.
- **`R`** — prints ready-to-run rollback commands for whatever doesn't auto-revert (packages, Docker, nginx, fastfetch, starship, configs, SSH hardening). Never executes anything itself — just shows, with explicit warnings where a command is destructive.
- **`U`** — removes `vsu` itself (`/opt/vps-setup` + the command) from the system. Doesn't touch anything it installed on the system.

---

## How it works

### Idempotency

Each menu item is a pair of functions: `status_*` (read-only) and `apply_*`/`disable_*` (the action). The menu re-queries every `status_*` before each redraw:

- package already installed → `✓`, re-selecting won't re-ask about what's already there;
- `.bashrc` block already present (via the `# >>> vps-setup >>>` / `# <<< vps-setup <<<` marker) → not duplicated;
- `zram`/`swapfile`/`sysctl` match the guide → `✓`;
- configured **differently** (someone — most likely you — already tuned it by hand) → `!`, shows the difference and asks explicitly, defaulting to **not** overwriting.

Swap is detected as "any non-zram swap entry", not by a specific filename — `/swapfile`, `/swap.img`, and other names are all recognized correctly.

### Self-testing SSH hardening

The riskiest item is disabling password and root login over SSH. A mistake here means losing access if there's no console from the provider. Item 14 doesn't just "apply and hope":

1. Asks for a public key (or uses whatever is already in `authorized_keys`).
2. Generates a **one-time test keypair on the server itself**, temporarily adds it, and actually logs in via `ssh user@127.0.0.1` — **before** touching `sshd_config` at all.
3. Only if that succeeds does it write `/etc/ssh/sshd_config.d/10-hardening.conf` (sorted before `50-cloud-init.conf`, which cloud-init can recreate), check `sshd -t`, and restart `sshd`.
4. **Tests key login again after the restart.** Fails → automatic rollback.
5. The test key is always removed at the end — only your real key remains.

Your current SSH session is never dropped: restarting `sshd` doesn't kill open connections, only stops accepting new ones.

### UFW without surprises

If the server already runs a VPN/proxy on a non-standard port, enabling a firewall that only allows port 22 will silently kill it. Item 15 first shows the list of actually-listening TCP ports, then asks — defaulting to **no**.

### ZRAM + swap

```
RAM
 │
 ▼
zram (~75% of RAM, lz4, priority 100)   ← used first
 │
 ▼
disk swap (1 GB, priority 10)           ← only if zram is already full
 │
 ▼
earlyoom (optional)                     ← kills the hungriest process
                                            before the kernel OOM killer does it blindly
```

Plus `sysctl`: `vm.swappiness=80` and `vm.vfs_cache_pressure=50`.

---

## Screenshots

> Placeholder — add images to `assets/` and wire them up here:

- [ ] `assets/fastfetch.png` — final `fastfetch` output
- [ ] `assets/menu.png` — `vsu` main menu, table-formatted status view
- [ ] `assets/ssh-hardening.png` — self-testing SSH hardening output

```markdown
![fastfetch](assets/fastfetch.png)
```

---

## Repository layout

```
UbuntuServer-Fast-Configuration/
├── install.sh       # thin bootstrapper — downloads setup.sh, installs it as the vsu command
├── setup.sh         # main script: menu, self-update, everything described above
├── config.jsonc     # fastfetch config (border, icons, colors)
├── VERSION          # current version, checked on every run
├── README.md         # Russian version
├── README.en.md      # this file
└── LICENSE
```

## Customization

Your own `fastfetch` config — edit `config.jsonc` and commit; `setup.sh` fetches it from the raw URL on every run.

Your own fork — change `REPO_RAW_BASE` at the top of `install.sh` and `setup.sh`:

```bash
REPO_RAW_BASE="https://raw.githubusercontent.com/<your-user>/<your-fork>/<branch-or-tag>"
```

**Important:** whenever you edit `setup.sh`, bump the number in `VERSION` — that's what `vsu` checks to know an update exists. Forget it, and already-installed copies won't see the change.

## Requirements

- Ubuntu 24.04 or 26.04 (untested elsewhere)
- root access (`sudo`)
- outbound internet access (apt, PPA, GitHub raw, download.docker.com, starship.rs)

## Deliberately not automated

- Changing the SSH port from 22
- Locking the root password (`passwd -l root`) — redundant once `PermitRootLogin` is off
- Finer-grained UFW rules (rate-limiting, specific IPs)
- Setting up the actual VPN/proxy stack — that's a separate, server-specific task

## FAQ / known gotchas

**New aliases didn't show up after installing the configs.**
The script runs in its own subprocess — `source ~/.bashrc` executed FROM the script can't affect your current interactive session (a child process can't change its parent's environment). Run `source ~/.bashrc` yourself in your own terminal, or just reconnect via SSH.

**Docker install fails with an error about the distro codename.**
The official Docker repo sometimes lags behind fresh Ubuntu releases. The script detects this and falls back to `noble` — the packages are compatible.

**After the zram item, `swapon --show` doesn't show what I expected.**
Check `journalctl -u zramswap` — often the old device didn't release cleanly. `sudo swapoff -a && sudo systemctl restart zramswap` usually fixes it.

**I want to reconsider SSH hardening/UFW without rebuilding the server.**
Run `sudo vsu` again — for already-configured items the menu shows the current state and asks whether to change it.

**`/etc/sysctl.conf` doesn't exist on the server.**
Normal for many cloud images. The script uses `/etc/sysctl.d/99-zram.conf` — the officially recommended approach on modern Ubuntu/Debian.

## License

[MIT](LICENSE)
