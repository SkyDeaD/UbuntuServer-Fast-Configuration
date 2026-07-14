<p align="center">
  <!-- Project logo — see "How to add a logo/screenshots" below -->
  <!-- <img src="https://github.com/user-attachments/assets/REPLACE-WITH-YOUR-ID" width="420" alt="UbuntuServer Fast Configuration"> -->
</p>

<h1 align="center">UbuntuServer Fast Configuration</h1>
<p align="center">CLI tools · Docker · nginx · zram/swap · fastfetch · hardening — one menu, zero commands typed by hand</p>

<p align="center">
  <a href="https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration/releases/latest"><img src="https://img.shields.io/github/v/release/SkyDeaD/UbuntuServer-Fast-Configuration?color=neon&label=version" alt="Latest Release"></a>
  <a href="https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration/stargazers"><img src="https://img.shields.io/github/stars/SkyDeaD/UbuntuServer-Fast-Configuration?style=social" alt="Stars"></a>
  <img src="https://img.shields.io/badge/Ubuntu-24.04%20%7C%2026.04-E95420?logo=ubuntu&logoColor=white" alt="Ubuntu 24.04 | 26.04">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

<p align="center"><a href="README.md">🇷🇺 Русский</a> · <b>🇬🇧 English</b></p>

---

Fresh Ubuntu VPS → working server, without googling the same commands every single time. Modern CLI tools, Docker, nginx, zram/swap on a battle-tested scheme, a nice `fastfetch` + `starship` setup, and optionally — SSH hardening that **tests itself** before it ever disables your password.

- ⚡️ A menu instead of a manual — 15 items, see what's already there and what isn't
- 🧠 Knows what you already configured by hand and won't silently overwrite it
- 🔒 Self-testing SSH hardening — never disables the password until it has confirmed the key actually works
- 📦 Apply by whole section (base / services / hardening) or everything at once — no need to click one at a time
- 🔄 Checks for updates and updates itself on command

> Built for myself so I wouldn't have to google the same setup steps on every new server — but suggestions and bug reports are welcome, open an issue.

## Quick start

1. Run the installer:

```bash
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh | sudo bash
```

2. A menu opens — pick items by number, by section (`B`/`S`/`P`), or all at once (`A`).
3. Done — the server is configured, back to work.

Open the menu again any time:

```bash
usfc
```

(the `alias usfc='sudo usfc'` is set automatically by item 8 — no need to type `sudo` yourself)

> **Before a production server** — test on a disposable/snapshot-able VPS first, especially if you plan to say yes to SSH hardening and UFW.

## What's inside

| Section | Items |
|---|---|
| **base** | system update · modern CLI tools (`eza`/`bat`/`fd`/`ripgrep`/`zoxide`/`ncdu`) · base package set (`micro`, `certbot`, `jq`, etc.) |
| **services** | Docker + Compose · nginx-full · fastfetch · starship · configs + `.bashrc` · tmux |
| **hardening** | Docker log rotation · fail2ban · unattended-upgrades · ZRAM + swap + sysctl + earlyoom · SSH hardening · UFW |

Full details per item live inside the menu itself (`H` also shows a reference for the aliases the script sets up: `ls`/`ll`/`la`/`lt`/`cat`/`catp`/`scat`/`fd`).

## How it works

- **Idempotent.** Every item checks whether it's already applied — and if it's configured differently than the guide (you tuned it by hand before), it shows the difference and asks, instead of silently overwriting.
- **Self-testing SSH hardening.** Before disabling the password, the script generates a one-time test key and actually logs in with it over localhost — both before and after applying the config. If it fails, automatic rollback; the password stays on, and the current session is never dropped at any point.
- **UFW without surprises.** Shows what's actually listening on the server first, then asks — if you already have a VPN on a non-standard port, you'll see it in the list before, not after, enabling the firewall.
- **`.bashrc` aliases don't break under sudo.** The zoxide/starship `eval` lines are conditional — install order never matters, no "command not found" errors.

## Screenshots

<p align="center">
  <!-- drop images here via drag&drop in the GitHub editor, see section below -->
  <!-- <img src="https://github.com/user-attachments/assets/REPLACE-1" width="700"> -->
</p>

### How to add a logo/screenshots

You don't need to commit files into the repo — GitHub hosts images pasted through the web editor for you:

1. Open `README.md` on github.com → the pencil icon (Edit).
2. Drag the image (or `Ctrl+V`) directly into the text editing box.
3. GitHub uploads it and inserts `![...](https://github.com/user-attachments/assets/...)` at the cursor.
4. Commit changes.

The link is permanent and works outside the repo too. For a logo/screenshots you don't want to route through a README commit, the same trick works in any Issue — you don't even need to save the issue, the image link stays valid regardless.

## Customization

Your own `fastfetch` config — just edit `config.jsonc` in the repo; `setup.sh` fetches it directly on every run.

Your own fork — change `REPO_RAW_BASE` at the top of `install.sh` and `setup.sh` to your repo/branch.

**Important:** whenever you edit `setup.sh`, bump the number in `VERSION` — that's what `usfc` checks to know an update exists.

## Deliberately not automated

- Changing the SSH port from 22
- Locking the root password — redundant once `PermitRootLogin` is off
- Finer-grained UFW rules (rate-limiting, specific IPs)
- Setting up the actual VPN/proxy stack — a separate, server-specific task

## FAQ

**New aliases didn't show up right after installing the configs.**
The script runs in a child process — it physically cannot change your current SSH session's environment (a fundamental Unix limitation, not a bug). At the end, the menu offers to open a fresh shell with the aliases already applied — say yes and there's nothing to do manually. Or just run `source ~/.bashrc` yourself, or reconnect via SSH.

**Docker install fails with an error about the distro codename.**
The official Docker repo sometimes lags behind fresh Ubuntu releases — the script detects this and falls back to a compatible `noble`.

**I want to reconsider SSH hardening/UFW without rebuilding the server.**
Run `usfc` again — for already-configured items the menu shows the current state and asks whether to change it.

## Requirements

Ubuntu 24.04 or 26.04, root access, outbound internet (apt, PPA, GitHub raw, download.docker.com, starship.rs).

## License

[MIT](LICENSE)
