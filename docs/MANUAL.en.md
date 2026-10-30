# USFC — manual guide

<p align="center"><a href="MANUAL.md">🇷🇺 Русский</a> · <b>🇬🇧 English</b></p>

If you'd rather not run someone else's `curl | sudo bash` on your server, here
are the same 19 [usfc](../README.en.md) menu items done by hand, as commands.
The order matches the menu, and that's deliberate: the hardening section comes
last so UFW sees Docker and nginx already running (see item 19).

The guide describes Ubuntu. Debian differences:

- Docker has its own repository path: `/linux/debian` instead of
  `/linux/ubuntu`;
- the fastfetch PPA does not exist: Debian 13 has the package in its regular
  repositories, Debian 12 has none at all;
- the login greeting shows no count of pending updates: that cache only exists
  on Ubuntu.

Every command below runs as a user with `sudo`, except item 1.

## Contents

- [1. User + sudo](#1-user--sudo)
- [2. Hostname, time, NTP](#2-hostname-time-ntp)
- [3. TCP BBR](#3-tcp-bbr)
- [4. Base packages](#4-base-packages)
- [5. CLI tools + starship](#5-cli-tools--starship)
- [6. fastfetch](#6-fastfetch)
- [7. Login greeting](#7-login-greeting)
- [8. tmux](#8-tmux)
- [9. Docker + Compose](#9-docker--compose)
- [10. nginx-full](#10-nginx-full)
- [11. Certbot + plugins](#11-certbot--plugins)
- [12. Docker log rotation](#12-docker-log-rotation)
- [13. systemd journal cap](#13-systemd-journal-cap)
- [14. fail2ban](#14-fail2ban)
- [15. Telegram alerts](#15-telegram-alerts)
- [16. unattended-upgrades](#16-unattended-upgrades)
- [17. ZRAM + swap + earlyoom](#17-zram--swap--earlyoom)
- [18. SSH hardening](#18-ssh-hardening)
- [19. UFW firewall](#19-ufw-firewall)
- [FAQ](#faq)

## 1. User + sudo

Only needed if the server came with nothing but `root` — the usual case with
VPS hosts. Carrying on as root is a bad idea: SSH hardening (item 18) does not
work at all without a separate user, and everything that goes into a home
directory (aliases, fastfetch, tmux, starship) would land in `/root`.

```bash
# create a user with a home directory and a proper shell
useradd -m -s /bin/bash admin
passwd admin                      # or passwd -l admin — key-only login

# grant sudo
usermod -aG sudo admin
```

Next comes **the most important and most often forgotten part**. If you log
in with an SSH key, that key lives in `/root/.ssh/authorized_keys`, and the
new user does not have it. Without copying it they cannot log in at all — and
if you apply SSH hardening after that, you lose access to the server:

```bash
install -d -o admin -g admin -m 700 /home/admin/.ssh
install -o admin -g admin -m 600 /root/.ssh/authorized_keys /home/admin/.ssh/authorized_keys
```

Check that login works **without closing your current session**:

```bash
ssh admin@<server-ip> 'id && sudo -n true && echo SUDO_OK'
```

Replace `admin` with your user name and `<server-ip>` with the server address.

A user without a password (`passwd -l`) cannot run `sudo`: the `sudo` group
rule asks for a password. Such a user needs passwordless sudo. usfc offers it
itself and puts the rule in a separate file, checking it with `visudo` before
writing:

```bash
echo 'admin ALL=(ALL) NOPASSWD:ALL' > /tmp/90-usfc-admin
visudo -cf /tmp/90-usfc-admin && install -m 440 /tmp/90-usfc-admin /etc/sudoers.d/90-usfc-admin
```

sudo silently skips files with a dot in the name, so for `john.doe` the file
is `90-usfc-john_doe`.

Only once the check passes, log back in as the new user and continue from
item 2.

## 2. Hostname, time, NTP

The server name:

```bash
sudo hostnamectl set-hostname web-1
```

Replace `web-1` with your name. Make the `127.0.1.1` line in `/etc/hosts`
match — otherwise sudo and some services stall on name lookups on every call:

```text
127.0.1.1 web-1
```

If cloud-init is installed, it may reset the name on reboot. Prevent that with
`/etc/cloud/cloud.cfg.d/99-usfc-hostname.cfg`:

```yaml
preserve_hostname: true
```

Time zone and time synchronisation:

```bash
timedatectl list-timezones | grep -i mosc
sudo timedatectl set-timezone Europe/Moscow
sudo apt install -y systemd-timesyncd
sudo timedatectl set-ntp true
```

If chrony or another NTP daemon is already installed, don't install
`systemd-timesyncd`: they conflict.

## 3. TCP BBR

The BBR congestion control together with the `fq` queue. The default cubic
treats every lost packet as congestion and slows down; BBR works from measured
bandwidth and delay. Most useful for proxies, VPNs and file serving.

First check that the kernel supports BBR:

```bash
modinfo tcp_bbr >/dev/null && echo yes
```

`/etc/sysctl.d/60-usfc-bbr.conf`:

```text
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
```

`/etc/modules-load.d/usfc-bbr.conf` — so the module loads at boot:

```text
tcp_bbr
```

```bash
sudo modprobe tcp_bbr
sudo sysctl -p /etc/sysctl.d/60-usfc-bbr.conf
sysctl net.ipv4.tcp_congestion_control   # should say bbr
```

In a container (LXC, OpenVZ) the kernel belongs to the host — this won't work
there. In a container the usfc item writes nothing and says so.

## 4. Base packages

```bash
sudo apt update
sudo apt install -y micro curl wget git nano unzip htop bind9-dnsutils jq \
    software-properties-common ca-certificates gnupg rsync
```

`software-properties-common` is there for `add-apt-repository` — without it
the fastfetch PPA (item 6) won't install. `bind9-dnsutils` is the real package
behind the virtual `dnsutils` on Ubuntu 26.04.

## 5. CLI tools + starship

```bash
sudo apt install -y eza bat fd-find ripgrep zoxide ncdu btop
curl -fsSL https://starship.rs/install.sh | sh -s -- -y
```

Then, in `~/.bashrc`:

```bash
alias ls='eza --icons --group-directories-first'
alias ll='eza -lah --icons --group-directories-first'
alias la='eza -a --icons --group-directories-first'
alias lt='eza --tree --icons --level=2 --group-directories-first'
alias cat='batcat --paging=never'
alias catp='batcat'
alias scat='sudo batcat --paging=never'
alias fd='fdfind'
command -v zoxide &>/dev/null && eval "$(zoxide init bash)"
command -v starship &>/dev/null && eval "$(starship init bash)"
```

usfc adds four functions to the same block. The two most useful:

```bash
# ports: listening TCP/UDP ports with their process
ports() { sudo ss -tulpn; }

# dps: compact docker ps
dps() { docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' "$@"; }
```

These are simplified versions: in usfc `ports` formats the `ss` output, and
there are also `extract` (unpacks an archive by its extension) and `myip`
(external and local addresses).

The prompt look lives in `~/.config/starship.toml`. usfc writes one of three
presets there: `minimal` (user@host, directory), `git` (plus branch, status,
time, command duration) and `powerline` (coloured segments). usfc never
overwrites a `starship.toml` it did not create. starship's own presets are in
its documentation: `starship preset --list`.

Create `~/.config` as the user, not through `sudo`: if it ends up owned by
root, btop and other programs cannot keep their settings there. To fix an
already broken one:

```bash
sudo chown "$USER": ~/.config
```

## 6. fastfetch

```bash
sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
sudo apt update
sudo apt install -y fastfetch
```

You need version ≥ 2.40.4 — on older ones this repository's
[`config.jsonc`](../src/config.jsonc) does not look right:

```bash
mkdir -p ~/.config/fastfetch
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/src/config.jsonc \
    -o ~/.config/fastfetch/config.jsonc
```

Autorun goes in `~/.bashrc`. The conditions match usfc: only on an SSH login,
only in a login shell (otherwise every `bash` inside the session would print
the summary), not inside tmux, and not when the item 7 card is installed:

```bash
if [ -n "${SSH_CONNECTION:-}" ] && [ -z "${TMUX:-}" ] \
   && shopt -q login_shell && [ ! -x /etc/update-motd.d/01-usfc ] \
   && command -v fastfetch >/dev/null 2>&1; then
    fastfetch
fi
```

## 7. Login greeting

The text shown on SSH login is assembled by `pam_motd`: it runs every
executable script in `/etc/update-motd.d/` in order and then shows the static
`/etc/motd`. This is also where provider ads come from.

See what's there:

```bash
ls -l /etc/update-motd.d/
cat /etc/motd
```

To switch a script off without deleting it, remove its execute bit:

```bash
sudo chmod -x /etc/update-motd.d/10-help-text /etc/update-motd.d/50-motd-news
```

To bring it back — `sudo chmod +x` on the same files. The static text:

```bash
sudo cp /etc/motd /etc/motd.orig
sudo truncate -s 0 /etc/motd
```

In place of what it switched off, usfc installs its own server card —
`/etc/update-motd.d/01-usfc`: the server name in large letters, OS, kernel,
virtualisation, IP, uptime, load, vCPUs, RAM and disk bars, swap, container
count and warnings:

```text

 ███╗   ██╗ ██████╗ ██████╗ ███████╗       ██████╗  ██╗
 ████╗  ██║██╔═══██╗██╔══██╗██╔════╝      ██╔═████╗███║
 ██╔██╗ ██║██║   ██║██║  ██║█████╗  █████╗██║██╔██║╚██║
 ██║╚██╗██║██║   ██║██║  ██║██╔══╝  ╚════╝████╔╝██║ ██║
 ██║ ╚████║╚██████╔╝██████╔╝███████╗      ╚██████╔╝ ██║
 ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝       ╚═════╝  ╚═╝

 Ubuntu 24.04.5 LTS · 6.8.0-147 · kvm · 2 vCPU
 203.0.113.10 · uptime 3 h · load 0.12 0.08 0.05

 RAM   ▰▰▱▱▱▱▱▱▱▱▱▱  20%  397M / 1.9G
 Disk  ▰▰▰▰▰▱▱▱▱▱▱▱  44%  4.7G / 10.6G
 Swap  zram 0M / 1.4G · disk 0M / 1.9G
```

The name is drawn in the same font as the usfc logo in the menu, with the
same colour gradient. A name wider than 76 columns (roughly more than 9
characters) falls back to a compact two-line font; a name that fits neither,
or one with a character the font lacks (Latin letters, digits, `-`, `.`, `_`
are supported), is printed in plain bold, and so is any name under the C
locale. A card from an earlier usfc is marked "outdated" in the menu:
choosing the item again installs the new one. The script
makes no network calls: the update count comes from the
`/var/lib/update-notifier/updates-available` cache. usfc records what it
switched off in `/etc/usfc/motd-disabled`, so choosing the item again restores
everything (the item asks for confirmation). usfc doesn't switch off symlinked
scripts with `chmod` (on Ubuntu `50-landscape-sysinfo` points into
`/usr/share`), so the package's file stays untouched: it removes the link
itself and recreates it on restore. You don't have to reproduce the card by hand — fastfetch (item 6)
does the job too.

## 8. tmux

```bash
sudo apt install -y tmux
```

`~/.tmux.conf`:

```tmux
set -g mouse on
set -g history-limit 10000
set -g status-bg colour234
set -g status-fg colour250
set -g status-left '#[fg=colour39,bold]#S '
set -g status-right '%H:%M %d-%b-%y'
setw -g automatic-rename on
```

## 9. Docker + Compose

The official Docker repository, not `docker.io` from Ubuntu's — that one is
stale:

```bash
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# codename — usually noble (24.04) or your current one; if Docker has no
# packages for your codename yet, use noble — it is compatible
CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${CODENAME} stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"   # log out and back in to use it without sudo
```

To switch Docker off for good you need **both** units: while `docker.socket`
is alive, the daemon starts itself on the first access to
`/var/run/docker.sock`:

```bash
sudo systemctl disable --now docker.socket docker.service
```

Optional: lazydocker, a terminal UI for containers, logs and images. usfc
fetches it from the `jesseduffield/lazydocker` GitHub release and checks its
sha256 against the same release's `checksums.txt`. By hand — download the
archive for your architecture from the releases page, check it with
`sha256sum` and put the binary in `/usr/local/bin`.

## 10. nginx-full

```bash
sudo apt install -y nginx-full
sudo systemctl enable --now nginx     # if you need it running right now
```

The package starts the service itself, from postinst. If you don't want it
running yet, don't "install and stop" (nginx gets to grab `:80` first, and
the install complains on a busy port too) — block the start during the install
the standard Debian way:

```bash
printf '#!/bin/sh\nexit 101\n' | sudo tee /usr/sbin/policy-rc.d >/dev/null
sudo chmod +x /usr/sbin/policy-rc.d
sudo apt install -y nginx-full
sudo rm -f /usr/sbin/policy-rc.d      # REQUIRED: otherwise every future
                                      # install fails to start its services
sudo systemctl disable nginx
```

## 11. Certbot + plugins

TLS is a service with its own plugins and secrets, and not every server needs
it, so it is an item of its own.

```bash
sudo apt install -y certbot

# HTTP-01 — ordinary certificates through an already running nginx
sudo apt install -y python3-certbot-nginx

# DNS-01 — required for wildcards (*.example.com)
sudo apt install -y python3-certbot-dns-cloudflare
```

> **About the python-cloudflare 2.20 WARNING.** The plugin declares
> `Depends: python3-cloudflare (<< 3.0)`, and Ubuntu 26.04's archive carries
> exactly one matching version — `2.20.0`, with the banner left intact
> (`/usr/lib/python3/dist-packages/CloudFlare/warning_2_20.py` is there).
>
> Verified on a live system: it fires from the client constructor
> (`CloudFlare/cloudflare.py`), i.e. **when a certificate is actually issued**.
> `apt install`, `certbot --version` and `certbot plugins` stay quiet.
>
> It cannot be turned off: `warn_warning_2_20()` calls
> `warnings.simplefilter('always', PendingDeprecationWarning)` itself and
> overrides both `PYTHONWARNINGS=ignore` and `python3 -W ignore`. It is
> harmless though: the version is pinned by the package's own dependency, and
> the banner does not affect issuance. No need to patch distro files for
> silence.

The Cloudflare plugin needs an API token with **Zone:DNS:Edit** permissions:

```bash
sudo install -d -m 700 /root/.secrets/certbot
sudo sh -c 'umask 077; echo "dns_cloudflare_api_token = YOUR_TOKEN" > /root/.secrets/certbot/cloudflare.ini'
```

Replace `YOUR_TOKEN` with the token. The mode matters: certbot refuses to use
the file if it is more permissive. Issuing a wildcard certificate:

```bash
sudo certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini \
  -d example.com -d "*.example.com"
```

### TLS boilerplate for nginx

`/etc/letsencrypt/ssl-dhparams.pem` and `/etc/letsencrypt/options-ssl-nginx.conf`
are created only by certbot's nginx *installer* (that is, `certbot --nginx`).
Issuing via `certbot certonly` — precisely what you install DNS-01 for — never
creates them, so a typical nginx config referencing them takes the server down
on start.

There is no need to generate `dhparam` with `openssl`: it is the same standard
ffdhe2048 group that already ships inside the certbot package. Just copy it:

```bash
sudo install -d -m 755 /etc/letsencrypt
sudo install -m 644 "$(find /usr/lib/python3/dist-packages -name ssl-dhparams.pem | head -1)" \
    /etc/letsencrypt/ssl-dhparams.pem
sudo install -m 644 "$(find /usr/lib/python3/dist-packages -name options-ssl-nginx.conf | head -1)" \
    /etc/letsencrypt/options-ssl-nginx.conf
```

## 12. Docker log rotation

Caps container logs: 10 MB per file, 3 files at most. If
`/etc/docker/daemon.json` already exists, add the keys to it without wiping
the rest:

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

```bash
sudo mkdir -p /etc/docker
sudo systemctl restart docker   # restarts ALL containers along with the daemon
```

The setting only applies to containers created after the restart.

If `daemon.json` already sets another `log-driver` (`syslog`, `gelf`,
`journald`, and so on), the item leaves it alone and is skipped: the
`max-size` and `max-file` limits don't suit those drivers. The `local` driver
is kept and the limits are added to it. The item needs `python3` to edit the
file.

## 13. systemd journal cap

By default journald may take up to 10% of the disk (but not more than 4 GB).
usfc sets 5% of the disk, no less than 100 and no more than 1000 MB.

`/etc/systemd/journald.conf.d/usfc.conf` (example — 500 MB):

```ini
[Journal]
SystemMaxUse=500M
```

```bash
sudo systemctl restart systemd-journald
sudo journalctl --vacuum-size=500M   # trim what has already piled up
journalctl --disk-usage
```

journald cannot work in under 50 MB.

## 14. fail2ban

Find the actual SSH port:

```bash
sudo sshd -T | grep '^port '
```

```bash
sudo apt install -y fail2ban
```

Use a file of your own in `jail.d`, not `jail.local`: that one stays yours to
edit. `/etc/fail2ban/jail.d/usfc-sshd.local` (replace `22` with the port):

```ini
[sshd]
enabled = true
port = 22
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd + _COMM=sshd-session
maxretry = 5
findtime = 10m
bantime = 1h
```

`backend = systemd` is needed on Debian 12: there is no `/var/log/auth.log`
there, and without it the jail finds no log.

```bash
sudo fail2ban-client -t                # check the config
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

## 15. Telegram alerts

You need a bot from @BotFather (that's the token) and a `chat_id` — where to
write. To find the `chat_id`: send the bot `/start`, then open
`https://api.telegram.org/bot<token>/getUpdates` and look for
`"chat":{"id":…}`.

Keep the token in a file with mode `600` and never pass it as a command
argument — arguments are visible in `ps`. usfc hands the URL with the token to
curl through stdin:

```bash
sudo install -d -m 700 /etc/usfc
sudo sh -c 'umask 077; printf "TG_TOKEN=%s\nTG_CHAT=%s\n" "TOKEN" "CHAT_ID" > /etc/usfc/notify.conf'
```

Replace `TOKEN` and `CHAT_ID`. A test message:

```bash
sudo bash -c '. /etc/usfc/notify.conf
  printf "url = \"https://api.telegram.org/bot%s/sendMessage\"\n" "$TG_TOKEN" \
  | curl -sS --connect-timeout 5 --max-time 10 --config - \
      --data-urlencode "chat_id=$TG_CHAT" --data-urlencode "text=test"'
```

usfc builds the rest from three events, each one optional:

- **SSH login** — a line in `/etc/pam.d/sshd`:
  `session optional pam_exec.so quiet /usr/local/sbin/usfc-notify-ssh`.
  `optional` matters: a failed send does not block the login. The script has
  to go to the background and exit `0` at once, or the login waits for the
  network;
- **fail2ban ban** — a dedicated action in
  `/etc/fail2ban/action.d/usfc-telegram.conf`;
- **reboot required** — a daily `usfc-notify-reboot.timer` that checks
  `/var/run/reboot-required`.

By hand this is noticeably more work than the other items; the full set of
scripts is easier to get from item 15 in usfc. If alerts don't arrive, see
[TROUBLESHOOTING.en.md](TROUBLESHOOTING.en.md#telegram-alerts-dont-arrive).

## 16. unattended-upgrades

```bash
sudo apt install -y unattended-upgrades
```

`/etc/apt/apt.conf.d/20auto-upgrades`:

```text
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

```bash
sudo systemctl enable --now unattended-upgrades
```

Optional: a reboot window. Some updates (kernel, libc) only take effect after
a reboot. Use a file of your own rather than editing `50unattended-upgrades` —
a package update rewrites that one. `/etc/apt/apt.conf.d/52usfc-reboot`:

```text
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
```

`WithUsers "false"` means no reboot while someone is logged in over SSH. Check
that no file later in alphabetical order overrides the key:

```bash
apt-config dump | grep Automatic-Reboot
```

## 17. ZRAM + swap + earlyoom

In usfc both the zram `PERCENT` and the backup swap file size are asked for.
For zram the default is 75%; for the swap file it's `min(RAM, free/4)`,
clamped to 512–4096 MB: swap here is a backup *underneath* zram, so it's sized
from memory, and dividing by 4 keeps it from eating a cramped disk.

```bash
sudo apt install -y zram-tools
```

In `/etc/default/zramswap` change three keys (leave the rest alone; example —
75%):

```text
ALGO=lz4
PERCENT=75
PRIORITY=100
```

```bash
sudo systemctl restart zramswap
```

If `systemd-zram-generator` is already running on the server, don't install
zram-tools on top: you'd end up with two zram devices. In that case the usfc
item configures the generator: in `/etc/systemd/zram-generator.conf` it
changes only `zram-size`, `compression-algorithm`, and `swap-priority` in the
`[zram0]` section and leaves other sections and options alone.

If there are several on-disk swaps (for example, `/swap.img` and a provider
partition), each needs priority 10: the item fixes all of them.

A backup swap file on disk (example — 1 GB). Priority 10 is lower than zram's,
so it only gets used once zram is full:

```bash
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
echo "/swapfile none swap sw,pri=10 0 0" | sudo tee -a /etc/fstab
sudo swapon -a
swapon --show                     # /swapfile should have PRIO 10
```

On btrfs `fallocate` produces a file with holes, unusable as swap — there,
replace the first line with `sudo dd if=/dev/zero of=/swapfile bs=1M count=1024`.

**The priority has to be in `/etc/fstab`**, not only in `swapon -p`: otherwise
after a reboot swap comes up with the default priority and gets used before
zram. If a swap line already exists (`defaults`, `sw,nofail`, `UUID=…`),
append `,pri=10` to its fourth field instead of adding a second line.

### Resizing an existing swap file

Ubuntu cloud images ship their own `/swap.img`, and its size rarely matches
what you need:

```bash
swapon --show                     # path, size, and how much is USED
free -m                           # how much free memory there is
```

**First make sure what's in swap fits back into RAM**: `swapoff` pages
everything back into memory, and if there isn't enough you get an OOM with
killed processes. usfc won't switch swap off if the used part is at least the
available memory minus 200 MB. Then:

```bash
sudo swapoff /swap.img
sudo rm -f /swap.img
sudo fallocate -l 2G /swap.img    # your size
sudo chmod 600 /swap.img
sudo mkswap /swap.img
sudo swapon -a                    # priority is taken from /etc/fstab
```

Keep the same path. If you create a file under a new name and add a second
line to `/etc/fstab`, both swaps come up together after a reboot.

Recommended sysctl — `/etc/sysctl.d/99-zram.conf`:

```text
vm.swappiness=80
vm.vfs_cache_pressure=50
```

```bash
sudo sysctl --system
sudo apt install -y earlyoom
sudo systemctl enable --now earlyoom
```

## 18. SSH hardening

**Doing this by hand, you lose the self-test usfc runs**: a one-time key, a
real login via `ssh user@127.0.0.1` before and after the `sshd` restart, and
an automatic rollback on failure. Here you check everything yourself.
**Before turning the password off, make sure key login works**, and keep your
current session open until a new one connects.

1. Add your public key:

   ```bash
   mkdir -p ~/.ssh && chmod 700 ~/.ssh
   touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
   echo "ssh-ed25519 AAAA...your-public-key..." >> ~/.ssh/authorized_keys
   ```

2. In a separate, new terminal, check key login:

   ```bash
   ssh -i /path/to/private/key your_user@server_ip
   ```

3. Find foreign settings that would override yours. In sshd the **first**
   value of a key wins: everything in `sshd_config` before the `Include` line,
   and `sshd_config.d/*.conf` files that sort before yours:

   ```bash
   sudo grep -rn -iE 'PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication|PubkeyAuthentication' \
       /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
   ```

   Comment out a provider line with a different value (`#` at the start of the
   line), keeping a copy of the file.

4. Create `/etc/ssh/sshd_config.d/00-usfc-hardening.conf`. The `00` makes it
   sort before provider files and `50-cloud-init.conf`:

   ```text
   PermitRootLogin no
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   PubkeyAuthentication yes
   ```

   Add `AllowUsers your_user` only if you deliberately want to lock every
   other account out of SSH.

5. Check the syntax and restart:

   ```bash
   sudo sshd -t
   sudo systemctl restart ssh
   ```

6. Check what sshd actually applies:

   ```bash
   sudo sshd -T | grep -E 'passwordauthentication|permitrootlogin|kbdinteractive|pubkeyauthentication'
   ```

   Expected: `passwordauthentication no`, `permitrootlogin no`,
   `kbdinteractiveauthentication no`, `pubkeyauthentication yes`. If not,
   some file still overrides it — go back to step 3. If `/etc/ssh/sshd_config`
   has no `Include /etc/ssh/sshd_config.d/*.conf` line, the drop-in is not read
   at all.

7. Again in a separate terminal, make sure key login still works.

Rollback:

```bash
sudo rm -f /etc/ssh/sshd_config.d/00-usfc-hardening.conf
sudo systemctl restart ssh
```

### Changing the SSH port

Change the port in two steps so you don't lose access. The `Port` directive in
sshd **adds up** across files: `Port 22` in `sshd_config` and `Port 2222` in a
drop-in mean two ports.

1. Open the new port in advance — in UFW, in fail2ban (`port =` in
   `jail.d/usfc-sshd.local`) and in the provider firewall, if there is one:

   ```bash
   sudo ufw allow 2222/tcp
   ```

2. Put both ports in `00-usfc-hardening.conf` and comment out `Port` in other
   files:

   ```text
   Port 22
   Port 2222
   ```

3. Restart. On Ubuntu 22.10+ with socket activation the port is held by
   `ssh.socket`, which needs a `daemon-reload`:

   ```bash
   sudo sshd -t
   sudo systemctl daemon-reload
   sudo systemctl restart ssh.socket   # if it exists: systemctl status ssh.socket
   sudo systemctl restart ssh
   ```

4. From your own machine, check login on the new port: `ssh -p 2222 user@server`.
5. Only then remove `Port 22`, repeat step 3 and close the old port:
   `sudo ufw delete allow 22/tcp`.

Replace `2222` with your port. A `ListenAddress` line with an explicit port
(`ListenAddress 0.0.0.0:22`) beats `Port` — remove the port from it.

## 19. UFW firewall

First look at what is actually listening — otherwise you risk cutting off
something that already works (a VPN on UDP, a proxy on a non-standard port):

```bash
sudo ss -tulpn
```

```bash
sudo apt install -y ufw
sudo ufw allow 22/tcp                 # your SSH port — first, before enable
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 443/tcp                # and so on for every port you need
sudo ufw allow 51820/udp              # UDP separately: WireGuard, Hysteria
sudo ufw enable
sudo ufw status verbose
```

Access to a port from one address only:

```bash
sudo ufw allow from 203.0.113.10 to any port 5432 proto tcp
```

### Not answering ping

In `/etc/ufw/before.rules`, in the `# ok icmp codes for INPUT` and
`# ok icmp code for FORWARD` blocks, change the `-j ACCEPT` ending of the
`-p icmp` lines to `-j DROP` and add at the end of the INPUT block:

```text
-A ufw-before-input -p icmp --icmp-type source-quench -j DROP
```

```bash
sudo ufw reload
```

Replies to your own connections (including "fragmentation needed" for PMTU)
pass through the conntrack rule above these blocks, so outgoing connections
keep working. In `before6.rules` change only `echo-request`: neighbour
discovery runs on the rest of ICMPv6, and IPv6 stops working without it.

### Docker bypassing UFW

Docker publishes ports (`-p 8080:80`) with its own iptables rules, past UFW's
chains: with the firewall on, the port is still open to the world. usfc fixes
this with the [ufw-docker](https://github.com/chaifeng/ufw-docker) scheme: a
block at the end of `/etc/ufw/after.rules` routes the `DOCKER-USER` chain into
`ufw route` rules:

```text
# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward

-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -m conntrack --ctstate INVALID -j DROP
-A DOCKER-USER -i docker0 -o docker0 -j ACCEPT

-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16

-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 192.168.0.0/16

-A DOCKER-USER -j RETURN

-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

COMMIT
# END UFW AND DOCKER
```

```bash
sudo ufw reload
sudo ufw route allow proto tcp from any to any port 80
```

The route rule names the **container** port: for `-p 8080:80` that's `80`.
The scheme only works for IPv4 and Docker's iptables backend; with
`"firewall-backend": "nftables"` in `daemon.json` there is no `DOCKER-USER`
chain.

## FAQ

### Why the CPU in a VM shows up as "Xeon (Skylake, IBRS)"

Inside a virtual machine the CPU model is set by the provider's hypervisor,
not by the hardware. QEMU/KVM can present a named CPU model to the guest —
for example `Skylake-Server-IBRS` — and then the `/proc/cpuinfo` line reads
`Intel Xeon Processor (Skylake, IBRS)`. `IBRS` in the name marks the model
variant with the Spectre v2 mitigation, not a separate processor. Providers
pick a generic model so the VM can move between hosts with different
processors, so physically the server may run on newer hardware.

fastfetch and the usfc card show what the kernel sees. That can't be changed
from inside the VM. To see how many cores and which instructions you actually
have:

```bash
nproc
grep -o -w -E 'avx2|avx512f|aes' /proc/cpuinfo | sort -u
```

### Where the provider's login greeting comes from and how to remove it

The login text is assembled from the scripts in `/etc/update-motd.d/` and the
static `/etc/motd`. Providers drop their own scripts and ads there; cloud-init
may write to motd too. How to switch it off without deleting — see
[item 7](#7-login-greeting).

### Something doesn't match how usfc behaves

Open an issue: this file is meant to reflect the code as it is, no surprises.
