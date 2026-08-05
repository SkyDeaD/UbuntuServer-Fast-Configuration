<div align="center">

# UbuntuServer Fast Configuration

<img width="300" height="300" alt="logo" src="https://github.com/user-attachments/assets/d86c5588-d76f-4564-8c29-11b065033c46" />

---

![Ubuntu 24.04 | 26.04](https://img.shields.io/badge/Ubuntu-24.04%20%7C%2026.04-E95420?logo=ubuntu&logoColor=white)
![bash](https://img.shields.io/badge/bash-%3E%3D5.0-4EAA25?logo=gnubash&logoColor=white)
![license MIT](https://img.shields.io/badge/license-MIT-green)

</div>

<p align="center"><a href="README.md">🇷🇺 Русский</a> · <b>🇬🇧 English</b></p>

Every time you spin up a new VPS it's the same routine: get a decent `ls` going, install Docker, sort out swap on a small box, lock SSH down to keys only, remember UFW. So instead of doing the same setup by hand every time, I wrote a script with a 14-item menu that does all of it, asking only where the decision actually matters — not where it doesn't.

## Requirements

Ubuntu 24.04 or 26.04, root access, outbound internet.

## Contents

- [Quick start](#quick-start)
- [What each item does](#what-each-item-does)
- [Customization](#customization)
- [FAQ](#faq)
- [Contributing](#contributing)
- [License](#license)

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh | sudo bash && source ~/.bashrc
```

Installs itself as the `usfc` command and opens the menu right away — no waiting: `apt update` no longer runs at startup, it's pulled in lazily and only before an actual install. A `usfc()` shell function (not an alias) gets added to `.bashrc` automatically on first run — after that just `usfc`, no `sudo` needed, and once the menu closes it re-sources `.bashrc` into your own session automatically, so new aliases/prompt show up right away, no manual `source` or reconnect (more on this in the FAQ).

<div align="center">

<img width="300" height="252" alt="2026-07-15_23-02" src="https://github.com/user-attachments/assets/0d7c5bb1-16e0-42d0-a886-03467955772e" />
<img width="300" height="252" alt="2026-07-15_23-05" src="https://github.com/user-attachments/assets/4b808cbc-30d7-44f6-a1fc-ea20bcf9cebb" />
<img width="300" height="252" alt="2026-07-15_23-07" src="https://github.com/user-attachments/assets/debb0f28-dde0-4690-b39a-907119865a39" />
<img width="300" height="252" alt="2026-07-15_23-12" src="https://github.com/user-attachments/assets/97efbc16-fbce-4c3d-924b-70b7762cacb4" />
<img width="300" height="252" alt="2026-07-15_23-15" src="https://github.com/user-attachments/assets/e1d0b5a7-fff2-469f-8fe1-a036261b3844" />
<img width="300" height="252" alt="2026-07-15_23-20" src="https://github.com/user-attachments/assets/b85fe841-2482-49dd-b20c-32be47bc807a" />

</div>

Inside the menu: a number (`5`, or several at once: `1 3 5` or `1,3,5`), a whole section (`C`/`B`/`S`/`P`), everything (`A`), or a combination (`B,S`). A batch of items asks once, then each runs through its own default answers without stopping, and finishes with a summary of what got installed, what failed, and what was skipped. `H` — alias reference, `R` — rollback commands, `U` — remove `usfc` itself.

### Running on a bare server (root only)

Plenty of hosts hand you a VPS with nothing but `root`. The script notices and **offers to create a regular sudo user first** (defaults to yes):

```
[!] Скрипт запущен от имени root.
[i] РЕКОМЕНДУЮ создать обычного пользователя с sudo: ...

  Создать пользователя сейчас? [Y/n]:
```

It asks for a name and a password (hidden input, typed twice), adds the user to the `sudo` group, and offers to **copy the keys from `/root/.ssh/authorized_keys`** — without that the new user simply can't log in if you reach the server by key. An empty password is allowed: the account is then key-only.

The script then switches to the new user inside the running session, so aliases, fastfetch and tmux land in their home rather than `/root`. On exit it reminds you to reconnect as that user.

Decline and nothing breaks: item **1 "Пользователь + sudo"** stays available in the menu. Like SSH hardening and UFW, it is skipped by `A` ("install everything") — a name and a password can't be silently defaulted.

### Flags

```bash
usfc --help        # help
usfc --version     # version
usfc --no-update   # skip the usfc self-update check
usfc --verbose     # raw command output instead of the spinner
```

`USFC_APT_LOCK_TIMEOUT` (300 s by default) controls how long to wait for the dpkg lock. The wait is needed because on a freshly booted server `apt-daily.timer` starts `unattended-upgrades`, which holds `/var/lib/dpkg/lock-frontend` for minutes — without waiting, every install would fail instantly with `E: Could not get lock`.

A full log of every command run is always written to `/var/log/usfc.log`, even when the screen only shows a spinner.

Don't trust `curl | sudo bash` and want to reproduce the same thing by hand, item by item? — here's the [manual guide](docs/MANUAL.en.md).

## What each item does

<details>
<summary>Base, services, hardening — in order</summary>

**Пользователь + sudo (user + sudo)** — creates a regular sudo user, copies SSH keys over from `/root`, and points the rest of the setup at them. This is what you want when the server arrived with only `root`. See above.

**Base packages** — `micro`, `curl`, `wget`, `git`, `nano`, `unzip`, `htop`, `jq`, `rsync`, and a few other things you'd normally install in the first minute on any server — including `software-properties-common`, without which `add-apt-repository` won't work, which the fastfetch PPA step needs. `certbot` moved out into its own item (see below).

**CLI tools + starship** — modern replacements for the usual suspects (`eza` instead of `ls`, with icons; `bat`/`batcat` instead of `cat`, with syntax highlighting; `fd`/`fdfind` instead of `find`; `ripgrep`; `zoxide` — a smarter `cd`; `ncdu` for disk usage) plus the starship prompt — bundled together since it's all the same "what the terminal looks and feels like" layer. `.bashrc` aliases (`ls`/`ll`/`la`/`lt`/`cat`/`catp`/`scat`/`fd`) and the zoxide/starship `eval` lines are written by this same item, not a separate step later.

**fastfetch** — shows server info (OS, kernel, memory, disk, IP) on every SSH login. Version 2.64.0 or newer (older releases don't support the padding syntax in format strings that the bundled `config.jsonc` relies on). The config and login autorun get written to `.bashrc` by this same item.

**tmux** — a terminal multiplexer: keeps your session alive across disconnects (just reconnect over SSH and everything you had running is still there, including multiple windows/panes). Installed with a minimal config (mouse support, 10000-line history).

**Docker + Compose** — CE + Compose plugin from the official Docker repo (not the `docker.io` package from Ubuntu's own repos — that one's stale).

**nginx-full** — web server / reverse proxy.

> **About nginx and Docker autostart.** Both packages start their service themselves, from postinst. The script asks about that **before** installing, and the default answer is **no** — you don't always want the server up right now. So that "don't start it" means exactly that, rather than "start it and immediately kill it" (nginx would grab `:80` in between), the install is wrapped in `policy-rc.d`. A deliberately disabled service counts as a finished state in the menu, not an unfinished one, so it stops nagging. Start it later with `sudo systemctl enable --now nginx`.

**Certbot + plugins** — `certbot` itself, plus optionally the `nginx` plugin (HTTP-01, ordinary certificates) and the `dns-cloudflare` plugin (DNS-01, required for wildcards). For Cloudflare it offers to create `/root/.secrets/certbot/cloudflare.ini` with your API token (hidden input, mode `600`; the token needs `Zone:DNS:Edit`). Decline and the menu keeps showing `! токен CF не задан`, because the plugin is useless without that file.

> **About the python-cloudflare 2.20 WARNING.** The plugin declares `Depends: python3-cloudflare (<< 3.0)`, and Ubuntu 26.04's archive carries exactly one matching version — `2.20.0` — with the banner left intact. Verified on a live system: it fires from the client constructor, i.e. **when a certificate is actually issued**, not at install time — `apt install`, `certbot --version` and `certbot plugins` stay quiet. It cannot be turned off: `warn_warning_2_20()` calls `warnings.simplefilter('always', ...)` itself, overriding both `PYTHONWARNINGS` and `python3 -W ignore`. It does not affect issuance — the version is pinned by the package's own dependency, not dragged in by `pip`. The script warns about it up front so the banner doesn't look like a failure.

It also offers to drop `ssl-dhparams.pem` and `options-ssl-nginx.conf` into `/etc/letsencrypt/`. Only certbot's nginx *installer* creates those, and issuing a wildcard via `certbot certonly` never does — so a typical nginx config that references them takes the server down on start. Both files are copied out of the certbot package itself; nothing is generated or downloaded.

**Docker log rotation** — caps container logs at 10 MB per file: without this, Docker's logs are unbounded by default and can eventually fill up the disk.

**fail2ban** — bans an IP after a few failed SSH login attempts (brute-force protection). Configured for the server's actual SSH port, not hardcoded to 22.

**unattended-upgrades** — installs security updates on its own, no input needed from you.

**ZRAM + swap + earlyoom** — zram (compressed memory living in RAM itself; how much % of RAM to give it is now asked at install time, 75% by default) plus a backup swap file on disk at a lower priority, so it only kicks in once zram runs out. Its size is asked, and the default is computed as **`min(RAM, free/4)`**, clamped to 512–4096 MB: the file is a backstop *under* zram, so it scales with memory, while dividing by 4 keeps it from eating a tight disk. If a swap file already exists, the script shows its current size next to the recommended one and offers to recreate it — but only when they differ by more than 10%, and only for files: it does not touch partition or LVM sizes. Plus `vm.swappiness=80`/`vm.vfs_cache_pressure=50`, and optionally `earlyoom` — protection against the whole server locking up when memory runs out.

**SSH hardening** — switches login to key-only, disables password login and root login. The riskiest item in the menu, and the only one with a self-test before it applies anything: before disabling the password, it sets up a one-time key and actually verifies login with it — if that check fails, it automatically rolls back the config and leaves the password enabled.

**UFW** — a firewall: closes every port except the ones that matter (the SSH port, and whatever the server is already actually listening on at the time it's enabled).

The hardening section comes last on purpose: UFW scans actually-listening ports when it enables, and if Docker/nginx are already up, the firewall sees their ports immediately instead of only port 22.

</details>

## Customization

The fastfetch `src/config.jsonc` — edit and commit it, `src/setup.sh` pulls it from the raw URL on every run.

Your own fork — change `REPO_RAW_BASE` at the top of `install.sh` and `src/setup.sh`. Version checking runs off a separate `src/VERSION` file — if you edit `src/setup.sh`, bump it.

## FAQ

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
