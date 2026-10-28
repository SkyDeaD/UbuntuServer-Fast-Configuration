<div align="center">

# UbuntuServer Fast Configuration

<img width="300" height="300" alt="logo" src="https://github.com/user-attachments/assets/d86c5588-d76f-4564-8c29-11b065033c46" />

---

![Ubuntu 24.04 | 26.04](https://img.shields.io/badge/Ubuntu-24.04%20%7C%2026.04-E95420?logo=ubuntu&logoColor=white)
![Debian 12 | 13](https://img.shields.io/badge/Debian-12%20%7C%2013-A81D33?logo=debian&logoColor=white)
![bash](https://img.shields.io/badge/bash-%3E%3D4.0-4EAA25?logo=gnubash&logoColor=white)
![license MIT](https://img.shields.io/badge/license-MIT-green)

</div>

<p align="center"><a href="README.md">🇷🇺 Русский</a> · <b>🇬🇧 English</b></p>

Every time you spin up a new VPS it's the same routine: get a decent `ls` going, install Docker, sort out swap on a small box, lock SSH down to keys only, remember UFW. So instead of doing the same setup by hand every time, I wrote a script with a 19-item menu that does all of it, asking only where the decision actually matters to you — not where it doesn't.

It works on Ubuntu and Debian, speaks Russian and English, and besides the menu it can set up a server with one command from cloud-init or Ansible, show a dry run, check the server with an audit and snapshot configs before changing them.

## Requirements

Ubuntu 24.04/26.04 or Debian 12/13, root access, outbound internet.

On anything else the script refuses to act: it checks the distribution at startup and says so plainly, instead of failing somewhere in the middle.

## Contents

- [Quick start](#quick-start)
- [Menu items](#menu-items)
- [Server audit](#server-audit)
- [Config snapshots and rollback](#config-snapshots-and-rollback)
- [Interface language](#interface-language)
- [Documentation](#documentation)
- [Customization](#customization)
- [FAQ](#faq)
- [Contributing](#contributing)
- [License](#license)

## Quick start

### The menu

```bash
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh | sudo bash && source ~/.bashrc
```

Installs itself as the `usfc` command and opens the menu right away — no waiting: `apt update` does not run at startup, it's pulled in lazily and only before an actual install. A `usfc()` shell function (not an alias) gets added to `.bashrc` automatically on first run — after that just `usfc`, no `sudo` needed, and once the menu closes it re-sources `.bashrc` into your own session, so new aliases and the prompt show up right away.

On the very first run it asks a single question — "what is this server for?" — and turns the answer into a ready-made profile. You can decline right away: the fifth option opens the regular menu.

<div align="center">

<img width="300" height="252" alt="2026-07-15_23-02" src="https://github.com/user-attachments/assets/0d7c5bb1-16e0-42d0-a886-03467955772e" />
<img width="300" height="252" alt="2026-07-15_23-05" src="https://github.com/user-attachments/assets/4b808cbc-30d7-44f6-a1fc-ea20bcf9cebb" />
<img width="300" height="252" alt="2026-07-15_23-07" src="https://github.com/user-attachments/assets/debb0f28-dde0-4690-b39a-907119865a39" />
<img width="300" height="252" alt="2026-07-15_23-12" src="https://github.com/user-attachments/assets/97efbc16-fbce-4c3d-924b-70b7762cacb4" />
<img width="300" height="252" alt="2026-07-15_23-15" src="https://github.com/user-attachments/assets/e1d0b5a7-fff2-469f-8fe1-a036261b3844" />
<img width="300" height="252" alt="2026-07-15_23-20" src="https://github.com/user-attachments/assets/b85fe841-2482-49dd-b20c-32be47bc807a" />

</div>

Inside the menu: a number (`5`), several at once (`1 3 5` or `1,3,5`), a range (`1-5`), a whole section (`C`/`B`/`S`/`P`), everything (`A`), or a combination (`B,S`). For a batch, every question is asked up front in one block with explanations. Then the items run without stopping, and it finishes with a summary of what got installed, what failed, and what was skipped and why. `V 5` — preview: shows what an item would do, changing nothing. `I` (or `?`) — per-item help and rollback, `H` — alias reference, `D` — audit, `U` — remove `usfc` itself.

Items marked with `⇄` switch off by picking them again: the script sees the setting is applied and offers the opposite action. For items with settings, `unattended` and `notify`, picking them again first asks "set it up again?", and only "no" turns the item off. The rest are rolled back by hand — the commands sit on the `I` screen under each item.

### One command, no menu

The same installer takes a command and runs it without a terminal — that's how a server gets set up from cloud-init:

```bash
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh \
  | sudo bash -s -- apply basepkgs,cli,docker,zram,ufw --allow 443,51820/udp --swap 2048 --yes
```

`apply` takes item ids, their numbers or profiles (`minimal`, `web`, `dockerhost`, `secure`) in any mix. Answers to item questions come from flags or an answers file. To see what would be done without changing anything, add `--dry-run`.

Every command, flag, answers-file key and exit code is in the [CLI reference](docs/CLI.en.md). Coming from 4.x, where it was `--apply` and `--audit`? Read the [migration guide](docs/MIGRATION-5.en.md).

### Running on a bare server (root only)

Plenty of hosts hand you a VPS with nothing but `root`. The script notices and **offers to create a regular sudo user first** (defaults to yes): working as root is unsafe, SSH hardening doesn't work at all without a separate user, and aliases, fastfetch and tmux would land in `/root`.

It asks for a name and a password (hidden input, typed twice), adds the user to the `sudo` group, and offers to **copy the keys from `/root/.ssh/authorized_keys`** — without that the new user simply can't log in if you reach the server by key. Passwords shorter than 8 characters are rejected: the server faces the internet, and brute-forcing runs around the clock. An empty password is allowed — the account is then key-only.

The script then switches to the new user inside the running session, so aliases, fastfetch and tmux land in their home rather than `/root`. On exit it reminds you to reconnect as that user.

Decline and nothing breaks: item **1 "User + sudo"** stays available in the menu. In a batch it goes first, before the other questions. `usfc apply` does not run it: a name and a password can't be silently defaulted.

## Menu items

| # | id | Item | What it does | ⇄ |
|---|---|---|---|---|
| 1 | `newuser` | User + sudo | creates a normal sudo user on a bare VPS | |
| 2 | `hostname` | Hostname, time, NTP | server name, time zone, time synchronisation | |
| 3 | `bbr` | TCP BBR | faster, steadier TCP on lossy links | ⇄ |
| 4 | `basepkgs` | Base packages | micro, curl, git, htop, jq and the usual basics | |
| 5 | `cli` | CLI tools + starship | modern ls/cat/find replacements plus a prompt | |
| 6 | `fastfetch` | fastfetch | server summary on every SSH login | |
| 7 | `motd` | Login greeting | a server card instead of the stock greeting | ⇄ |
| 8 | `tmux` | tmux | multiplexer: sessions survive a dropped link | |
| 9 | `docker` | Docker + Compose | Docker CE + Compose from the official repository | ⇄ |
| 10 | `nginx` | nginx-full | web server and reverse proxy | ⇄ |
| 11 | `certbot` | Certbot + plugins | TLS certificates, wildcard included via DNS | |
| 12 | `dockerlog` | Docker log rotation | caps container logs so they cannot eat the disk | ⇄ |
| 13 | `journald` | systemd journal cap | caps journald size so it cannot eat the disk | ⇄ |
| 14 | `fail2ban` | fail2ban | bans SSH password guessing | ⇄ |
| 15 | `notify` | Telegram alerts | SSH logins, fail2ban bans, reboot required | ⇄ |
| 16 | `unattended` | unattended-upgrades | installs security updates on its own | ⇄ |
| 17 | `zram` | ZRAM + swap + earlyoom | compressed memory, backup swap, OOM protection | ⇄ |
| 18 | `sshhardening` | SSH hardening | key-only login, root login disabled | |
| 19 | `ufw` | UFW firewall | closes everything except what is needed | ⇄ |

Sections: "system" — 1–3, "base" — 4–8, "services" — 9–11, "hardening" — 12–19. The hardening section comes last on purpose: UFW suggests its port list from what the server is actually listening on, and if Docker and nginx came up earlier, their ports are already in the list.

<details>
<summary>What each item does — in detail</summary>

**User + sudo** — creates a regular sudo user, copies SSH keys over from `/root`, and points the rest of the setup at them. This is what you want when the server arrived with only `root`. See above.

**Hostname, time, NTP** — sets the server name with `hostnamectl` and makes the `127.0.1.1` line in `/etc/hosts` match it, otherwise sudo and some services stall on name lookups. When cloud-init is installed it is told not to reset the name on reboot. The time zone can be found by part of its name ("mosc"). Time is synchronised by `systemd-timesyncd`; an already running chrony is left alone.

**TCP BBR** — turns on the BBR congestion control together with the `fq` queue. The default cubic treats every lost packet as congestion and slows down; BBR works from measured bandwidth and delay, so throughput on international and mobile links is noticeably steadier. Most useful for proxies, VPNs and file serving. Only works when the kernel supports BBR.

**Base packages** — `micro`, `curl`, `wget`, `git`, `nano`, `unzip`, `htop`, `jq`, `rsync`, and a few other things you'd normally install in the first minute on any server. After the install a list is printed: what arrived just now, what was already there, and a one-line note on why each package is there — including `software-properties-common`, without which `add-apt-repository` won't work, which the fastfetch PPA step needs.

**CLI tools + starship** — modern replacements for the usual suspects (`eza` instead of `ls`, with icons; `bat`/`batcat` instead of `cat`, with syntax highlighting; `fd`/`fdfind` instead of `find`; `ripgrep`; `zoxide` — a smarter `cd`; `ncdu` for disk usage) plus the starship prompt — bundled together since it's all the same "what the terminal looks and feels like" layer. `.bashrc` gets the aliases, the functions `ports`, `dps`, `extract`, `myip`, and the zoxide/starship `eval` lines. The prompt is one of three presets: `minimal`, `git` or `powerline`.

**fastfetch** — shows server info (OS, kernel, memory, disk, IP) on SSH login. Runs only on an SSH login, not inside tmux, and not when the "Login greeting" item is installed — so the summary isn't printed twice.

**Login greeting** — a server card of its own instead of the stock motd: name, OS, kernel, virtualisation, IP, uptime, load, vCPUs, RAM and disk bars, swap, the number of running containers and warnings (updates available, reboot required). No network calls. The stock greeting and provider scripts in `/etc/update-motd.d` are listed and switched off with your consent; choosing the item again restores everything.

**tmux** — a terminal multiplexer: keeps your session alive across disconnects (just reconnect over SSH and everything you had running is still there, including multiple windows and panes). Installed with a minimal config (mouse support, 10000-line history).

**Docker + Compose** — CE + Compose plugin from the official Docker repo (not the `docker.io` package from the distribution's repos — that one's stale). Optionally lazydocker, a terminal UI for containers, from the GitHub release with its sha256 verified.

**nginx-full** — web server and reverse proxy.

> **About nginx and Docker autostart.** Both packages start their service themselves, from postinst. The script asks about that **before** installing, and the default answer is **no** — you don't always want the server up right now. So that "don't start it" means exactly that, rather than "start it and immediately kill it" (nginx would grab `:80` in between), the install is wrapped in `policy-rc.d`. A deliberately disabled service counts as a finished state in the menu, not an unfinished one, so it stops nagging.
>
> **You can change your mind later.** On an installed system both items act as switches: they show the current state and offer the opposite — stop a running service, or start a stopped one along with its autostart. For Docker both units go down together, `docker.service` and `docker.socket`: without the second one the daemon comes back on the first request to the socket, and "autostart disabled" would be a lie.

**Certbot + plugins** — `certbot` itself, plus optionally the `nginx` plugin (HTTP-01, ordinary certificates) and the `dns-cloudflare` plugin (DNS-01, required for wildcards). For Cloudflare it offers to create `/root/.secrets/certbot/cloudflare.ini` with your API token (hidden input, mode `600`; the token needs `Zone:DNS:Edit`). Decline and the menu keeps showing `! CF token not set`, because the plugin is useless without that file.

> **About the python-cloudflare 2.20 WARNING.** The plugin declares `Depends: python3-cloudflare (<< 3.0)`, and Ubuntu 26.04's archive carries exactly one matching version — `2.20.0` — with the banner left intact. Verified on a live system: it fires from the client constructor, i.e. **when a certificate is actually issued**, not at install time — `apt install`, `certbot --version` and `certbot plugins` stay quiet. It cannot be turned off: `warn_warning_2_20()` calls `warnings.simplefilter('always', ...)` itself, overriding both `PYTHONWARNINGS` and `python3 -W ignore`. It does not affect issuance — the version is pinned by the package's own dependency, not dragged in by `pip`. The script warns about it up front so the banner doesn't look like a failure.

It also offers to drop `ssl-dhparams.pem` and `options-ssl-nginx.conf` into `/etc/letsencrypt/`. Only certbot's nginx *installer* creates those, and issuing a wildcard via `certbot certonly` never does — so a typical nginx config that references them takes the server down on start. Both files are copied out of the certbot package itself; nothing is generated or downloaded.

**Docker log rotation** — caps container logs (10 MB per file, 3 files): without this, Docker's logs are unbounded by default and can eventually fill up the disk. An existing `daemon.json` is extended, not overwritten. The setting takes effect after Docker restarts — the item offers that, warning that the containers restart along with the daemon.

**systemd journal cap** — by default journald may take up to 10% of the disk (but not more than 4 GB). On a small VPS that is gigabytes of logs nobody reads. The item sets `SystemMaxUse`: 5% of the disk, between 100 and 1000 MB, and trims the journal to the cap right away.

**fail2ban** — bans an IP after a few failed SSH login attempts (brute-force protection). Configured for the server's actual SSH port, not hardcoded to 22, and writes its own file in `jail.d`, leaving `jail.local` alone.

**Telegram alerts** — three kinds of messages to pick from: an SSH login, a fail2ban ban, a reboot needed after updates. You need a bot from @BotFather; usfc can find the `chat_id` itself. The token lives only in `/etc/usfc/notify.conf` (mode `600`) — not in the log, not in command arguments, not in `usfc export`. The alert never delays an SSH login, and a failed send never breaks it.

**unattended-upgrades** — installs security updates on its own, no input needed from you. Optionally a reboot window: some updates (kernel, libc) only take effect after a reboot, and usfc can allow a reboot at a set time, say 04:00. By default it won't reboot while someone is logged in over SSH.

**ZRAM + swap + earlyoom** — zram (compressed memory living in RAM itself; how much % of RAM to give it is now asked at install time, 75% by default) plus a backup swap file on disk at a lower priority, so it only kicks in once zram runs out. Its size is asked, and the default is computed as **`min(RAM, free/4)`**, clamped to 512–4096 MB: the file is a backstop *under* zram, so it scales with memory, while dividing by 4 keeps it from eating a tight disk. If a swap file already exists, the script shows its current size next to the recommended one and offers to recreate it — but only when they differ by more than 10%, and only for files: it does not touch partition or LVM sizes. Plus `vm.swappiness=80`/`vm.vfs_cache_pressure=50`, and optionally `earlyoom` — protection against the whole server locking up when memory runs out.

**SSH hardening** — switches login to key-only, disables password login (keyboard-interactive included) and root login. The riskiest item in the menu, hence the self-test: before disabling the password, it sets up a one-time key and actually verifies login with it — if that check fails, it automatically rolls back the config and leaves the password enabled. Foreign settings that would override ours (say, a provider drop-in `00-*.conf` or `50-cloud-init.conf` with `PasswordAuthentication yes`) are found up front: the script shows the file and line and comments them out with your consent. Also here: moving SSH to another port in two steps — the old port closes only once you confirm a login on the new one.

**UFW** — a firewall: blocks incoming connections to every port except SSH and the ones you allow. The list is suggested from what the server listens on right now — TCP and UDP, with the process name — and you can edit it: add the port of a service that isn't running yet (`443`, `51820/udp`, `1000:2000/tcp`) or drop one. Also here: ping replies and, if Docker is installed, tying it to UFW: Docker publishes container ports **past** UFW, so without this `-p 8080:80` is open to the world even with the firewall on. Change ports later with `usfc firewall`.

</details>

## Server audit

The script doesn't just set things up — it also answers "what's going on with this server right now". The `D` key in the menu, or `sudo usfc audit`. Sample output (shortened):

```text
Network
! Public ports: 22
    The firewall is off, so all of them are reachable. Item 19

Access
! Password login is allowed
    SSH brute-forcing runs around the clock. Item 18
! fail2ban is not running
    Item 14
```

It checks disk space and inodes (they run out before space does and look like "no space left" with gigabytes free), memory and swap, failed systemd units, public ports against UFW rules, Docker ports past the firewall, password and root login, foreign sshd configs that override hardening, pending security updates, whether a reboot is needed, and certificate expiry.

`usfc audit --json` gives the same in machine-readable form — for monitoring. With critical findings the command exits with code `1`.

The audit **only reads**. That is not a promise but a checked property: CI has a test that compares a snapshot of `/etc`, dpkg, `passwd/group` and swap before and after the run.

## Config snapshots and rollback

Before overwriting any system file, the script copies it into `/var/backups/usfc/<label>`:

```bash
sudo usfc backups                       # what is there
sudo usfc restore 20261023-040000-3691  # put it back
```

Replace `20261023-040000-3691` with a label from the list.

Snapshots are taken automatically, and only for the files the script itself edits: `sshd_config.d/00-usfc-hardening.conf`, `fstab`, `daemon.json`, `before.rules`, `.bashrc` and the rest. Files that did not exist before usfc are removed on rollback. Restoring takes another snapshot first — undoing the undo has to be possible too.

A full log of every command run is always written to `/var/log/usfc.log`, even when the screen only shows a spinner.

## Interface language

On the very first run the script asks in both languages at once, because at that point there is no way to know which one you read. The choice is remembered and survives updates. Change it later with the `L` key in the menu. The `--lang en` flag applies to a single run and saves nothing: running once in another language should not quietly re-teach the tool.

## Documentation

| Document | What for |
|---|---|
| [docs/CLI.en.md](docs/CLI.en.md) | Reference: commands, flags, answers file, exit codes, environment variables |
| [docs/MIGRATION-5.en.md](docs/MIGRATION-5.en.md) | Moving from 4.x: old flags → new commands, what changes on configured servers |
| [docs/TROUBLESHOOTING.en.md](docs/TROUBLESHOOTING.en.md) | What to do if password login still works, swap has no priority, Telegram is silent |
| [docs/MANUAL.en.md](docs/MANUAL.en.md) | Manual guide: the same by hand, item by item, without `curl \| sudo bash` |
| [CHANGELOG.en.md](CHANGELOG.en.md) | What changed between versions |

## Customization

The fastfetch `src/config.jsonc` — edit and commit it, `src/setup.sh` pulls it from the raw URL on every run.

Your own fork — the `USFC_REPO_RAW_BASE` environment variable overrides where updates and modules are fetched from; no code change needed. Version checking runs off a separate `src/VERSION` file.

### How the code is laid out

Since 4.0.0 this is not a single file but an entry point plus modules:

```text
src/setup.sh        loader: bootstrap, self-healing, module loading
src/MODULES         manifest — also the load order and the menu order
src/lib/*.sh        core by layers: logging, layout, apt, updates, audit…
src/lib/items/*.sh  one file per menu item
```

**Adding an item means one new file in `src/lib/items/` and one line in `MODULES`.** An item registers itself:

```bash
usfc_item docker сервисы "Docker + Compose" "Docker CE + Compose из официального репозитория" \
    "Docker + Compose" "Docker CE + Compose from the official repository"
usfc_item_toggle docker
usfc_item_full docker "Russian description" "English description"
usfc_item_rollback docker "removal commands" "removal commands"

status_docker()  { ...; }
apply_docker()   { ...; }
disable_docker() { ...; }
```

The English variant is optional: until it exists, the Russian text is shown.

## FAQ

<details>
<summary>Icons/fonts in the terminal look like boxes or garbled characters</summary>

That's your local terminal's (the client's) font, not the server's — the Nerd Font that renders `eza`/`fastfetch` icons is installed and configured in whatever app you SSH from; the script has no way to affect that. The starship prompt in any of usfc's three presets needs no Nerd Font — this only concerns `eza` icons.

</details>

<details>
<summary>Docker install fails with an error about the distro codename</summary>

The official Docker repo sometimes lags behind fresh Ubuntu releases — the script detects this and falls back to a compatible `noble`. There is deliberately no such fallback on Debian: `noble` is a different branch of the repository built against different library versions, so the item stops honestly instead of installing packages that are known not to fit.

</details>

<details>
<summary>What does not work on Debian</summary>

Almost everything works. The differences:

- **Debian 12 (bookworm)** — no `eza` and no `fastfetch` in the repositories. `eza` simply drops out of the CLI set, and the `ls`/`ll`/`la`/`lt` aliases are not written to `.bashrc` (they would break `ls`). The fastfetch item explains that the package is missing and points at the `.deb` on GitHub.
- **Debian 13 (trixie)** — everything is there except `software-properties-common`, which is only needed for PPAs, i.e. only on Ubuntu.
- **Login greeting** on Debian shows no count of pending updates: that cache only exists on Ubuntu.

</details>

<details>
<summary>Why the CPU in a VM shows up as "Xeon (Skylake, IBRS)"</summary>

Inside a virtual machine the CPU model is set by the provider's hypervisor, not by the hardware. Providers often give guests a generic CPU model so the VM can move between hosts with different processors — hence "Skylake" on a server that physically runs on newer hardware. The script shows what the kernel sees, and that can't be changed from inside the VM. More in the [manual guide](docs/MANUAL.en.md#faq).

</details>

<details>
<summary>Where the provider's login greeting comes from and how to remove it</summary>

The login text is assembled from the scripts in `/etc/update-motd.d/` and the static `/etc/motd`. Providers drop their own scripts and ads there, and cloud-init may write to motd too. Item **7 "Login greeting"** lists everything it finds and, with your consent, switches it off without deleting: choosing the item again puts it back.

</details>

<details>
<summary>I want to reconsider SSH hardening or UFW without rebuilding the server</summary>

Run `usfc` again — for already-configured items the menu shows the current state and asks whether to change it. Firewall ports change without the menu too: `sudo usfc firewall --allow 8443`.

</details>

## Contributing

Built primarily for my own servers, so some of the choices reflect what's convenient for me. Bugs and suggestions are welcome — open an issue.

## License

[MIT](LICENSE.en)
