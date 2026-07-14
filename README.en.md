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

One script that takes a fresh Ubuntu VPS to a working state: modern CLI tools, Docker, zram/swap on a battle-tested scheme, a nice `fastfetch` + `starship` setup, and optionally — SSH hardening with a built-in self-test (it never disables password login until it has actually verified key-based login works).

Every item is its own yes/no question. Nothing is installed or overwritten silently. If something is already configured — including by hand, outside this script — the script detects that and won't touch it without explicit confirmation.

## Contents

- [Quick start](#quick-start)
- [What the script does](#what-the-script-does)
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

The script installs itself as the `vps-setup` command (symlinked into `/usr/local/bin`), checks for updates, and opens a menu. Run it again any time:

```bash
sudo vps-setup
```

On every run, `vps-setup` first compares its own version against [`VERSION`](VERSION) in the repo — if there's a newer one, it offers to update and restarts itself as the new version. The menu shows the status of all 15 items at once (✓ applied / ○ not applied / ! differs from the recommended values), picking an item by number applies it, `A` applies everything not yet applied, and `d<number>` disables whatever is safe to disable (see [below](#idempotency)).

> **Before running on a production box** — test on a disposable/snapshot-able VPS first, especially if you plan to say yes to SSH hardening and UFW. The script is written defensively (see [below](#self-testing-ssh-hardening)), but it's still root access and network rules.

---

## What the script does

| # | Step | Installs / configures | Auto-skipped when |
|---|---|---|---|
| 1 | System update | `apt update && apt upgrade` | — (always asks) |
| 2 | CLI tools | `eza`, `bat`, `fd-find`, `ripgrep`, `zoxide`, `ncdu` | — |
| 3 | Base packages | `micro`, `curl`, `wget`, `git`, `nano`, `certbot`, `python3-certbot-nginx`, `unzip`, `htop`, `dnsutils`, `jq`, `software-properties-common`, `ca-certificates`, `gnupg`, `rsync` | — |
| 4 | Docker | Docker CE + Compose plugin from the official repo, auto-fallback to `noble` if packages for the current codename aren't published yet | already installed |
| 5 | nginx-full | installs and enables on boot | already installed and running |
| 6 | fastfetch | from PPA `zhangsongcui3371/fastfetch`, version ≥ 2.64.0 | version already suitable |
| 7 | starship | prompt | already installed |
| 8 | Configs | `fastfetch/config.jsonc` + aliases/hooks in `.bashrc` | `.bashrc` block already present (marker) |
| 9 | tmux | + minimal `.tmux.conf` (mouse, history, status bar) | `.tmux.conf` already exists |
| 10 | Docker log rotation | `max-size=10m`, `max-file=3` in `daemon.json` | already configured |
| 11 | fail2ban | jail on the actual SSH port | already running |
| 12 | unattended-upgrades | automatic security patches | already enabled |
| 13 | zram + swap + sysctl + earlyoom | per the [guide](#zram--swap) | already matches recommended values |
| 14 | SSH hardening | keys instead of passwords, no root login, passwordless sudo | target user couldn't be determined (see below) |
| 15 | UFW | firewall allowing actually-used ports | already enabled |

`python3-certbot-nginx` in base packages wasn't literally requested, but added deliberately: without that plugin `certbot --nginx` can't wire SSL into nginx configs automatically — you'd have to issue the cert separately and hook it up by hand. Since `nginx-full` is now part of the script too, the plugin earns its place.

---

## How it works

### Idempotency

Each of the 14 menu items is actually a pair of functions: `status_*` (read-only, just checks current state) and `apply_*` (the action). The menu re-queries every `status_*` before each redraw, so:

- package already installed → shown as `✓` right in the menu, re-selecting it won't re-ask about what's already there;
- `.bashrc` block already present (detected via the `# >>> vps-setup >>>` / `# <<< vps-setup <<<` marker) → not duplicated;
- `zram`/`swapfile`/`sysctl` already match the guide's recommended values → `✓`;
- configured **differently** from the guide (meaning someone — most likely you — already tuned it by hand) → `!`, and selecting the item shows the difference and asks explicitly, defaulting to **not** overwriting.

**Disabling (`d<number>`)** is only supported for what's safe to turn off in one action: Docker log rotation, fail2ban, unattended-upgrades, zram, UFW. Everything else (package installs, Docker, SSH hardening) deliberately has no scripted rollback — it's either harmless to leave as-is, or too risky to auto-revert behind a single keypress; the menu will point you to the manual steps instead.

### Self-testing SSH hardening

The riskiest step in the whole script is disabling password and root login over SSH. A mistake here means losing access to the server if there's no console access from the provider. So step 13 doesn't just "apply and hope" — it actually verifies on a live connection:

1. Asks for a public key to paste (or uses whatever is already in `authorized_keys`).
2. Generates a **one-time test keypair on the server itself**, temporarily adds it, and actually logs in via `ssh user@127.0.0.1` — **before** touching `sshd_config` at all. This catches permission issues on `~/.ssh` before anything becomes irreversible.
3. Only if that baseline login succeeds does it write a separate `/etc/ssh/sshd_config.d/10-hardening.conf` (the filename is chosen specifically to sort lexically before `50-cloud-init.conf`, which cloud-init can recreate on image rebuilds and which ships with `PasswordAuthentication yes` — a real gotcha found during testing on live VPS instances), checks syntax with `sshd -t`, and restarts `sshd`.
4. **Tests key login again, after the restart.** If it fails — automatic rollback: `10-hardening.conf` is removed, `sshd` is restarted with the old config, password login stays enabled.
5. The one-time test key is always removed from `authorized_keys` at the end — only your real key remains.

Your current SSH session is never dropped at any point: restarting `sshd` doesn't kill already-open connections, it only stops accepting new ones — which is exactly what allows the script to test safely in the background without losing access if something goes wrong.

If the script is run directly as root (without a regular user via `sudo`), it will refuse to run this step: locking down root login when root is the only user left to log in as would just lock you out.

### UFW without surprises

If the server already runs a VPN/proxy on a non-standard port (a common case), enabling a firewall that only allows port 22 will silently kill those services. So step 14 first prints the list of actually-listening TCP ports (`ss -tln`), and only then asks — defaulting to **no**. If confirmed, it allows the SSH port plus every detected port, not just 22.

### ZRAM + swap

Two-tier scheme: `zram` (compressed swap in RAM, fast) as the primary layer, plus a disk `swapfile` as a fallback cushion in case `zram` fills up.

```
RAM
 │
 ▼
zram (~75% of RAM, lz4, priority 100)   ← used first
 │
 ▼
disk swapfile (1 GB, priority 10)       ← only if zram is already full
 │
 ▼
earlyoom (optional)                     ← kills the most memory-hungry process
                                            before the kernel OOM killer does it blindly
```

Plus `sysctl`: `vm.swappiness=80` (the system leans into zram more eagerly — it's cheap, it's RAM) and `vm.vfs_cache_pressure=50` (balance against file cache on a small VPS).

---

## Screenshots

> Placeholder — add images to `assets/` and wire them up here:

- [ ] `assets/fastfetch.png` — final `fastfetch` output (border, icons, colors)
- [ ] `assets/eza.png` — `eza --icons -la` in action
- [ ] `assets/setup-run.png` — `vps-setup` mid-run (colored `[i]`/`[✓]`/`[!]` steps)
- [ ] `assets/ssh-hardening.png` — output of the self-testing SSH hardening step

```markdown
![fastfetch](assets/fastfetch.png)
```

---

## Repository layout

```
UbuntuServer-Fast-Configuration/
├── install.sh       # thin bootstrapper — downloads setup.sh, installs it as the vps-setup command
├── setup.sh         # main script: menu, self-update, everything described above
├── config.jsonc     # fastfetch config (border, icons, colors)
├── VERSION          # current setup.sh version, checked on every run
├── README.md         # Russian version
├── README.en.md      # this file
└── LICENSE
```

## Customization

Your own `fastfetch` config — just edit `config.jsonc` in the repo and commit; `setup.sh` fetches it directly from the raw URL on every run.

Your own fork — change `REPO_RAW_BASE` at the top of both `install.sh` and `setup.sh`:

```bash
REPO_RAW_BASE="https://raw.githubusercontent.com/<your-user>/<your-fork>/<branch-or-tag>"
```

A specific tag is recommended over `main` — that way you can update the config in the repo without risking an unexpected change on servers that already ran the script.

**Important:** whenever you edit `setup.sh` in the repo, bump the number in the `VERSION` file — that's what `vps-setup` checks to know an update exists. If `VERSION` isn't bumped, already-installed copies won't see the change.

## Requirements

- Ubuntu 24.04 or 26.04 (untested on other versions)
- root access (`sudo`)
- outbound internet access (apt, PPA, GitHub raw, download.docker.com, starship.rs)

## Deliberately not automated

- Changing the SSH port from 22 to something non-standard
- Locking the root password (`passwd -l root`) — redundant once `PermitRootLogin` is disabled
- Finer-grained UFW rules (rate-limiting, specific IPs)
- Setting up the actual VPN/proxy stack (Xray, MTProto, etc.) — that's a separate, server-specific task, not a generic bootstrap

## FAQ / known gotchas

**Docker install fails with an error about the distro codename.**
The official Docker repository sometimes lags a few weeks behind fresh Ubuntu releases. The script detects the missing packages for the current codename and falls back to `noble` (24.04) — the packages are compatible. If that still doesn't help, check manually: `apt-cache policy docker-ce-cli`.

**After the `zram` step, `swapon --show` doesn't show what I expected.**
Check `journalctl -u zramswap` — often the old device just didn't release cleanly. `sudo swapoff -a && sudo systemctl restart zramswap` usually fixes it.

**I want to reconsider the SSH hardening/UFW decision without rebuilding the server.**
Just run `sudo vps-setup` again — for already-configured items the script shows the current state and asks whether to change it.

**`/etc/sysctl.conf` doesn't exist on the server.**
Normal for many cloud images (Oracle Cloud, etc.). The script uses `/etc/sysctl.d/99-zram.conf` instead — that's the officially recommended approach on modern Ubuntu/Debian, no need to create `/etc/sysctl.conf`.

## License

[MIT](LICENSE)
