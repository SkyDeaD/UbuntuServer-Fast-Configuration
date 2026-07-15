# UbuntuServer Fast Configuration

![Ubuntu 24.04 | 26.04](https://img.shields.io/badge/Ubuntu-24.04%20%7C%2026.04-E95420?logo=ubuntu&logoColor=white)
![bash](https://img.shields.io/badge/bash-%3E%3D5.0-4EAA25?logo=gnubash&logoColor=white)
![license MIT](https://img.shields.io/badge/license-MIT-green)
![last commit](https://img.shields.io/github/last-commit/SkyDeaD/UbuntuServer-Fast-Configuration)
![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)

<p align="center"><a href="README.md">🇷🇺 Русский</a> · <b>🇬🇧 English</b></p>

Every time you spin up a new VPS it's the same routine: get a decent `ls` going, install Docker, sort out swap on a small box, lock SSH down to keys only, remember UFW. So instead of doing the same setup by hand every time, I wrote a script with a 15-item menu that does all of it, asking only where the decision actually matters — not where it doesn't.

Suggestions and bug reports are welcome, open an issue — but this was built primarily for my own servers, so some of the choices (which exact packages, which defaults) reflect what's convenient for me.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh | sudo bash
```

Installs itself as the `usfc` command (symlinked into `/usr/local/bin`) and opens the menu right away. After that, just `usfc` — no more `sudo` needed, item 8 adds `alias usfc='sudo usfc'` to `.bashrc` for you.

Inside the menu: a number (`5`, or several at once separated by spaces/commas: `1 3 5`), or a whole section — `B` for base, `S` for services, `P` for hardening, `A` for everything. Anything applied as a batch asks once up front, then each item runs through its own default answers without stopping.

Worth running on a test VPS at least once before a production box — not because something is guaranteed to break, but because item 14 (SSH hardening) could in theory lock you out if something goes sideways on the network during its self-test.

## What's inside

**Base** — `apt update/upgrade`; modern replacements for the usual suspects (`eza` instead of `ls`, with icons; `bat`/`batcat` instead of `cat`, with syntax highlighting; `fd`/`fdfind` instead of `find`; `ripgrep`; `zoxide` — a smarter `cd` that learns your frequent directories; `ncdu` for disk usage); separately, a base package set — `micro`, `curl`, `wget`, `git`, `nano`, `certbot` + `python3-certbot-nginx`, `unzip`, `htop`, `jq`, `rsync`, and a few other things you'd normally install in the first minute on any server.

**Services** — Docker CE + Compose plugin from the official Docker repo (not the `docker.io` package from Ubuntu's own repos — that one's stale); nginx-full; fastfetch version 2.64.0 or newer (that version floor matters — older releases don't support the padding syntax in format strings that the bundled `config.jsonc` relies on); starship; the fastfetch config itself plus a batch of `.bashrc` aliases; tmux with a minimal config (mouse support, 10000-line history).

**Hardening** — Docker log rotation (10 MB per file cap — otherwise `journalctl`/`docker logs` will eat your disk within a couple of weeks on a small VPS if any container gets chatty); fail2ban on whatever the server's actual SSH port is (not hardcoded to 22); unattended-upgrades; zram (lz4, 75% of RAM, priority 100) paired with a disk swapfile (1 GB, priority 10 — only kicks in once zram is already full) plus `vm.swappiness=80` and `vm.vfs_cache_pressure=50` via `/etc/sysctl.d/99-zram.conf`, and optionally earlyoom; SSH hardening; UFW.

## How it actually works

Each menu item is a pair of functions — one just reads the server's current state, the other applies changes. Every status gets re-checked before each menu redraw, so if something's already configured — including by hand, before you ever ran this script — it shows up immediately, and re-selecting the item won't blindly overwrite it. If the current state differs from what the script considers correct (say, swap already exists but at a different priority), it shows you the difference and asks explicitly instead of deciding for you.

SSH hardening is the riskiest item, and the only one where the script doesn't just apply a config and hope. Before disabling the password, it generates a one-time keypair right on the server, adds it to a temporary `authorized_keys`, and actually logs in via `ssh user@127.0.0.1` — once before touching `sshd_config`, to confirm the baseline even works, and again after restarting `sshd` with the new config. If either check fails, it rolls back automatically: removes `/etc/ssh/sshd_config.d/10-hardening.conf`, restarts `sshd` with the old settings, password stays on. The filename `10-hardening.conf` isn't arbitrary — configs in `sshd_config.d/` are read alphabetically, and a lot of cloud images already ship a `50-cloud-init.conf` with `PasswordAuthentication yes` that cloud-init can recreate on image rebuilds. `10` sorts before `50`, so ours wins the merge. Your current SSH session never drops during any of this — restarting `sshd` doesn't kill already-open connections, it just stops accepting new ones, which is exactly what makes it safe to test blind without losing access.

UFW parses `ss -tln` and shows what's actually listening before it asks to enable — if something's already running on a non-standard port (VPN, proxy), you'll see it in the list before the firewall would have cut it off, not after.

## Customization

The fastfetch `config.jsonc` — edit and commit it, `setup.sh` pulls it from the raw URL on every run, nothing to keep in sync locally.

Your own fork — change `REPO_RAW_BASE` at the top of `install.sh` and `setup.sh`. Version checking runs off a separate `VERSION` file — if you edit `setup.sh`, bump it, or already-installed copies won't notice an update exists.

## Deliberately not automated

Changing the SSH port — too specific to a given setup. Locking the root password (`passwd -l root`) — redundant once `PermitRootLogin` is already `no`. Fine-grained UFW rules (rate-limiting, specific IPs) and setting up the actual VPN/proxy stack — separate, server-specific tasks, not a generic bootstrap.

## FAQ

**New aliases didn't show up right after installing the configs.**
The script runs in a child process — `source ~/.bashrc` run from inside it can't touch your current SSH session, a child process doesn't change its parent's environment. At the end, the menu offers to open a fresh shell (`sudo -u user -i`), which reads `.bashrc` via `.profile` — say yes and it's already working. Or just `source ~/.bashrc` yourself, or reconnect.

**Docker install fails with an error about the distro codename.**
The official Docker repo sometimes lags a couple weeks behind fresh Ubuntu releases. The script detects the missing packages for the current codename (`apt-cache policy docker-ce-cli`) and falls back to `noble` — fully compatible packages.

**I want to reconsider SSH hardening or UFW without rebuilding the server.**
Run `usfc` again — for already-configured items the menu shows the current state and asks whether to change it, rather than doing it silently.

## Requirements

Ubuntu 24.04 or 26.04 (untested elsewhere), root access, outbound internet for apt/PPA/GitHub raw/download.docker.com/starship.rs.

## License

[MIT](LICENSE)
