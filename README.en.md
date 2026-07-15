<div align="center">

# UbuntuServer Fast Configuration

---

![Ubuntu 24.04 | 26.04](https://img.shields.io/badge/Ubuntu-24.04%20%7C%2026.04-E95420?logo=ubuntu&logoColor=white)
![bash](https://img.shields.io/badge/bash-%3E%3D5.0-4EAA25?logo=gnubash&logoColor=white)
![license MIT](https://img.shields.io/badge/license-MIT-green)

</div>

<p align="center"><a href="README.md">🇷🇺 Русский</a> · <b>🇬🇧 English</b></p>

Every time you spin up a new VPS it's the same routine: get a decent `ls` going, install Docker, sort out swap on a small box, lock SSH down to keys only, remember UFW. So instead of doing the same setup by hand every time, I wrote a script with a 12-item menu that does all of it, asking only where the decision actually matters — not where it doesn't.

## Requirements

Ubuntu 24.04 or 26.04, root access, outbound internet.

## Contents

- [Quick start](#quick-start)
- [What each item does](#what-each-item-does)
- [How it works](#how-it-works)
- [Customization](#customization)
- [Deliberately not automated](#deliberately-not-automated)
- [FAQ](#faq)
- [Contributing](#contributing)
- [License](#license)

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh | sudo bash && source ~/.bashrc
```

Installs itself as the `usfc` command, quietly runs `apt update`, and opens the menu. A `usfc()` shell function (not an alias) gets added to `.bashrc` automatically on first run — after that just `usfc`, no `sudo` needed, and once the menu closes it re-sources `.bashrc` into your own session automatically, so new aliases/prompt show up right away, no manual `source` or reconnect (more on this in the FAQ).

```
  ┌─────┬────────────┬────────────────────────────┬────────────────────────────┐
  │ #   │ Section    │ Item                       │ Status                     │
  ├─────┼────────────┼────────────────────────────┼────────────────────────────┤
  │ 1   │ base       │ Base packages              │ ○ missing: micro, curl,…  │
  │ 2   │ base       │ CLI tools + starship       │ ✓ installed                │
  │ 3   │ base       │ fastfetch                  │ ✓ 2.66.0                   │
  │ 4   │ base       │ tmux                       │ ! installed, no config     │
  │ 5   │ services   │ Docker + Compose           │ ○ not installed            │
  │ 6   │ services   │ nginx-full                 │ ○ not installed            │
  │ 7   │ hardening  │ Docker log rotation        │ — (needs Docker)           │
  │ 8   │ hardening  │ fail2ban                   │ ○ not running              │
  │ 9   │ hardening  │ unattended-upgrades        │ ✓ enabled                  │
  │ 10  │ hardening  │ ZRAM + swap + earlyoom     │ ○ not configured           │
  │ 11  │ hardening  │ SSH hardening              │ ○ not applied              │
  │ 12  │ hardening  │ UFW firewall               │ ○ disabled                 │
  └─────┴────────────┴────────────────────────────┴────────────────────────────┘

  ┌────────────────────────────────────────────────────────────────────────────┐
  │ Choose:   5 / 1 3 5 / 1,3,5 — one item or several at once                  │
  │           section letters can combine too (B,S); a re-selected applied ha… │
  │ Sections: B base          S services      P hardening     A all            │
  │ Commands: H aliases       R rollback      U remove        Q quit           │
  └────────────────────────────────────────────────────────────────────────────┘
```

Inside the menu: a number (`5`, or several at once: `1 3 5` or `1,3,5`), a whole section (`B`/`S`/`P`), everything (`A`), or a combination (`B,S`). A batch of items asks once, then each runs through its own default answers without stopping. `H` — alias reference, `R` — rollback commands, `U` — remove `usfc` itself.

Don't trust `curl | sudo bash` and want to reproduce the same thing by hand, item by item? — here's the [manual guide](docs/MANUAL.en.md).

## What each item does

<details>
<summary>Base, services, hardening — in order</summary>

**Base packages** — `micro`, `curl`, `wget`, `git`, `nano`, `certbot` + `python3-certbot-nginx`, `unzip`, `htop`, `jq`, `rsync`, and a few other things you'd normally install in the first minute on any server — including `software-properties-common`, without which `add-apt-repository` won't work, which the fastfetch PPA step needs. Deliberately item 1.

**CLI tools + starship** — modern replacements for the usual suspects (`eza` instead of `ls`, with icons; `bat`/`batcat` instead of `cat`, with syntax highlighting; `fd`/`fdfind` instead of `find`; `ripgrep`; `zoxide` — a smarter `cd`; `ncdu` for disk usage) plus the starship prompt — bundled together since it's all the same "what the terminal looks and feels like" layer. `.bashrc` aliases (`ls`/`ll`/`la`/`lt`/`cat`/`catp`/`scat`/`fd`) and the zoxide/starship `eval` lines are written by this same item, not a separate step later.

**fastfetch** — shows server info (OS, kernel, memory, disk, IP) on every SSH login. Version 2.64.0 or newer (older releases don't support the padding syntax in format strings that the bundled `config.jsonc` relies on). The config and login autorun get written to `.bashrc` by this same item.

**tmux** — a terminal multiplexer: keeps your session alive across disconnects (just reconnect over SSH and everything you had running is still there, including multiple windows/panes). Installed with a minimal config (mouse support, 10000-line history).

**Docker + Compose** — CE + Compose plugin from the official Docker repo (not the `docker.io` package from Ubuntu's own repos — that one's stale).

**nginx-full** — web server / reverse proxy.

**Docker log rotation** — caps container logs at 10 MB per file: without this, Docker's logs are unbounded by default and can eventually fill up the disk.

**fail2ban** — bans an IP after a few failed SSH login attempts (brute-force protection). Configured for the server's actual SSH port, not hardcoded to 22.

**unattended-upgrades** — installs security updates on its own, no input needed from you.

**ZRAM + swap + earlyoom** — zram (compressed memory living in RAM itself; how much % of RAM to give it is now asked at install time, 75% by default) plus a backup swap file on disk (its size is asked too — the script suggests something sensible based on free disk space, not a flat 1 GB for every server) at a lower priority, so it only kicks in once zram runs out. Plus `vm.swappiness=80`/`vm.vfs_cache_pressure=50`, and optionally `earlyoom` — protection against the whole server locking up when memory runs out.

**SSH hardening** — switches login to key-only, disables password login and root login. The riskiest item in the menu, and the only one with a self-test before it applies anything — details below, under "How it works".

**UFW** — a firewall: closes every port except the ones that matter (the SSH port, and whatever the server is already actually listening on at the time it's enabled).

The hardening section comes last on purpose: UFW scans actually-listening ports when it enables, and if Docker/nginx are already up, the firewall sees their ports immediately instead of only port 22.

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

The fastfetch `src/config.jsonc` — edit and commit it, `src/setup.sh` pulls it from the raw URL on every run.

Your own fork — change `REPO_RAW_BASE` at the top of `install.sh` and `src/setup.sh`. Version checking runs off a separate `src/VERSION` file — if you edit `src/setup.sh`, bump it.

## Deliberately not automated

`apt upgrade` — you decide when. Changing the SSH port — too specific to a given setup. Locking the root password — redundant once `PermitRootLogin` is already `no`. Fine-grained UFW rules and setting up the actual VPN/proxy stack — separate, server-specific tasks.

## FAQ

<details>
<summary>New aliases didn't show up right after installing</summary>

If you installed with the Quick Start command as-is (ending in `&& source ~/.bashrc`), this shouldn't happen — that tail runs in your own shell and picks up `.bashrc` right away, even on the very first install. Starting from the second time you run `usfc` (once the wrapper function exists in `.bashrc`), it re-sources `.bashrc` on its own right after the menu closes, without that tail.

If it still didn't show up, you likely installed without `&& source ~/.bashrc` (e.g. copied only part of the command). The script runs under `sudo` and can't touch your current shell from the inside — a Unix limitation, not a bug. Run `source ~/.bashrc` yourself once, or reconnect via SSH — from then on `usfc` handles it on its own.

</details>

<details>
<summary>Icons/fonts in the terminal look like boxes or garbled characters</summary>

That's your local terminal's (the client's) font, not the server's — the Nerd Font that renders `eza`/`starship`/`fastfetch` icons is installed and configured in whatever app you SSH from; the script has no way to affect that.

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

## License

[MIT](LICENSE.en)
