<div align="center">

# UbuntuServer Fast Configuration

---

![Ubuntu 24.04 | 26.04](https://img.shields.io/badge/Ubuntu-24.04%20%7C%2026.04-E95420?logo=ubuntu&logoColor=white)
![bash](https://img.shields.io/badge/bash-%3E%3D5.0-4EAA25?logo=gnubash&logoColor=white)
![license MIT](https://img.shields.io/badge/license-MIT-green)

</div>

<p align="center"><a href="README.md">🇷🇺 Русский</a> · <b>🇬🇧 English</b></p>

Every time you spin up a new VPS it's the same routine: get a decent `ls` going, install Docker, sort out swap on a small box, lock SSH down to keys only, remember UFW. So instead of doing the same setup by hand every time, I wrote a script with a 12-item menu that does all of it, asking only where the decision actually matters — not where it doesn't.

## Contents

- [Quick start](#quick-start)
- [What's inside](#whats-inside)
- [How it works](#how-it-works)
- [Customization](#customization)
- [Deliberately not automated](#deliberately-not-automated)
- [FAQ](#faq)
- [Contributing](#contributing)
- [Requirements](#requirements)
- [License](#license)

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh | sudo bash
```

Installs itself as the `usfc` command, quietly runs `apt update`, and opens the menu. `alias usfc='sudo usfc'` is added to `.bashrc` automatically on first run — after that just `usfc`, no `sudo` needed.

```
    #  Section    Item                      Status
  ────────────────────────────────────────────────────────
  [ 1]  base       Base packages             ○ missing: ...
  [ 2]  base       CLI tools + starship      ✓ installed
  [ 3]  base       fastfetch                 ✓ 2.66.0
  ...
  B/S/P/A — a whole section at once: base/services/hardening/everything
```

Inside the menu: a number (`5`, or several at once: `1 3 5` or `1,3,5`), a whole section (`B`/`S`/`P`), everything (`A`), or a combination (`B,S`). A batch of items asks once, then each runs through its own default answers without stopping. `H` — alias reference, `R` — rollback commands, `U` — remove `usfc` itself.

> Worth running on a test VPS at least once before a production box — not because something is guaranteed to break, but because the SSH hardening item could in theory lock you out if something goes sideways on the network during its self-test.

## What's inside

| # | Section | Item |
|---|---|---|
| 1 | base | Base packages |
| 2 | base | CLI tools + starship |
| 3 | base | fastfetch |
| 4 | base | tmux |
| 5 | services | Docker + Compose |
| 6 | services | nginx-full |
| 7 | hardening | Docker log rotation |
| 8 | hardening | fail2ban |
| 9 | hardening | unattended-upgrades |
| 10 | hardening | ZRAM + swap + sysctl + earlyoom |
| 11 | hardening | SSH hardening |
| 12 | hardening | UFW |

<details>
<summary>More detail on each item</summary>

**Base packages** — `micro`, `curl`, `wget`, `git`, `nano`, `certbot` + `python3-certbot-nginx`, `unzip`, `htop`, `jq`, `rsync`, and a few other things you'd normally install in the first minute on any server — including `software-properties-common`, without which `add-apt-repository` won't work, which the fastfetch PPA step needs. Deliberately item 1.

**CLI tools + starship** — modern replacements for the usual suspects (`eza` instead of `ls`, with icons; `bat`/`batcat` instead of `cat`, with syntax highlighting; `fd`/`fdfind` instead of `find`; `ripgrep`; `zoxide` — a smarter `cd`; `ncdu` for disk usage) plus the starship prompt — bundled together since it's all the same "what the terminal looks and feels like" layer. `.bashrc` aliases (`ls`/`ll`/`la`/`lt`/`cat`/`catp`/`scat`/`fd`) and the zoxide/starship `eval` lines are written by this same item, not a separate step later.

**fastfetch** — version 2.64.0 or newer (older releases don't support the padding syntax in format strings that the bundled `config.jsonc` relies on). The config and login autorun get written to `.bashrc` by this same item — no need to install fastfetch and then separately remember the config.

**tmux** — with a minimal config (mouse support, 10000-line history).

**Docker + Compose** — CE + Compose plugin from the official Docker repo (not the `docker.io` package from Ubuntu's own repos — that one's stale).

**nginx-full**, **Docker log rotation** (10 MB per file cap), **fail2ban** (on the server's actual SSH port, not hardcoded to 22), **unattended-upgrades**, **ZRAM + swap** (zram lz4 75% of RAM priority 100 + disk swapfile 1 GB priority 10 + `vm.swappiness=80`/`vm.vfs_cache_pressure=50`, optionally earlyoom), **SSH hardening**, **UFW** — the hardening section comes last on purpose: UFW scans actually-listening ports when it enables, and if Docker/nginx are already up, the firewall sees their ports immediately instead of only port 22.

System upgrade (`apt upgrade`) isn't a separate item — that decision is left to you; the script only runs `apt update` (just refreshing package lists) once on its own at startup.

</details>

## How it works

Every item is a pair of functions — one just reads the server's current state, the other applies changes. Every status gets re-checked before each menu redraw, so if something's already configured — including by hand, before you ever ran this script — it shows up immediately, and re-selecting the item won't blindly overwrite it.

<details>
<summary>How the SSH hardening self-test actually works</summary>

The riskiest item, and the only one where the script doesn't just apply a config and hope. Before disabling the password, it generates a one-time keypair right on the server, adds it to a temporary `authorized_keys`, and actually logs in via `ssh user@127.0.0.1` — once before touching `sshd_config`, and again after restarting `sshd` with the new config. If either check fails, it rolls back automatically: removes `/etc/ssh/sshd_config.d/10-hardening.conf`, restarts `sshd` with the old settings, password stays on.

The filename `10-hardening.conf` isn't arbitrary — configs in `sshd_config.d/` are read alphabetically, and a lot of cloud images already ship a `50-cloud-init.conf` with `PasswordAuthentication yes` that cloud-init can recreate on image rebuilds. `10` sorts before `50`, so ours wins the merge.

Your current SSH session never drops during any of this — restarting `sshd` doesn't kill already-open connections, it just stops accepting new ones.

</details>

<details>
<summary>Why UFW doesn't break services you're already running</summary>

Before enabling, the script parses `ss -tln` and shows what's actually listening — if something's already running on a non-standard port (VPN, proxy), you'll see it in the list before the firewall would have cut it off, not after.

</details>

## Customization

The fastfetch `config.jsonc` — edit and commit it, `setup.sh` pulls it from the raw URL on every run.

Your own fork — change `REPO_RAW_BASE` at the top of `install.sh` and `setup.sh`. Version checking runs off a separate `VERSION` file — if you edit `setup.sh`, bump it.

## Deliberately not automated

`apt upgrade` — you decide when. Changing the SSH port — too specific to a given setup. Locking the root password — redundant once `PermitRootLogin` is already `no`. Fine-grained UFW rules and setting up the actual VPN/proxy stack — separate, server-specific tasks.

## FAQ

<details>
<summary>New aliases didn't show up right after installing</summary>

The script runs in a child process — `source ~/.bashrc` run from inside it can't touch your current SSH session, a Unix limitation. Run `source ~/.bashrc` yourself, or reconnect via SSH.

</details>

<details>
<summary>Docker install fails with an error about the distro codename</summary>

The official Docker repo sometimes lags behind fresh Ubuntu releases — the script detects this and falls back to a compatible `noble`.

</details>

<details>
<summary>I want to reconsider SSH hardening or UFW without rebuilding the server</summary>

Run `usfc` again — for already-configured items the menu shows the current state and asks whether to change it.

</details>

## Contributing

Built primarily for my own servers, so some of the choices reflect what's convenient for me. Bugs and suggestions are welcome — open an issue.

## Requirements

Ubuntu 24.04 or 26.04, root access, outbound internet.

## License

[MIT](LICENSE)
