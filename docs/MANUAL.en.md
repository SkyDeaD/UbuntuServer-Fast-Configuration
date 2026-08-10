<div align="center">

# USFC — manual guide

> This guide describes Ubuntu. On Debian there are exactly two differences:
> Docker has its own repository path (`/linux/debian` instead of
> `/linux/ubuntu`), and the fastfetch PPA does not exist — Debian 13 ships
> the package in its normal repositories, Debian 12 does not have it at all.

---

</div>

<p align="center"><a href="MANUAL.md">🇷🇺 Русский</a> · <b>🇬🇧 English</b></p>

If you'd rather not run someone else's `curl | sudo bash` on your server —
here are the same 14 menu items from [usfc](../README.en.md), but by hand,
as commands. The order matches the menu on purpose: the "hardening" section
comes last, so UFW sees Docker/nginx already listening (see item 14).

## Contents

- [1. User + sudo](#1-user--sudo)
- [2. Base packages](#2-base-packages)
- [3. CLI tools + starship](#3-cli-tools--starship)
- [4. fastfetch](#4-fastfetch)
- [5. tmux](#5-tmux)
- [6. Docker + Compose](#6-docker--compose)
- [7. nginx-full](#7-nginx-full)
- [8. Certbot + plugins](#8-certbot--plugins)
- [9. Docker log rotation](#9-docker-log-rotation)
- [10. fail2ban](#10-fail2ban)
- [11. unattended-upgrades](#11-unattended-upgrades)
- [12. ZRAM + swap + earlyoom](#12-zram--swap--earlyoom)
- [13. SSH hardening](#13-ssh-hardening)
- [14. UFW firewall](#14-ufw-firewall)

## 1. User + sudo

Only needed when the server came with nothing but `root` — the usual case with
VPS hosts. Staying on root is a bad idea: SSH hardening (item 13) cannot work
without a separate user at all, and anything written to a home directory
(aliases, fastfetch, tmux, starship) lands in `/root` and disappears from view
the moment you reconnect as a normal account.

```bash
# create the user with a home directory and a real shell
useradd -m -s /bin/bash admin
passwd admin                      # or: passwd -l admin — key-only login

# grant sudo
usermod -aG sudo admin
```

Now the part **most often forgotten**. If you reach the server over an SSH key,
that key lives in `/root/.ssh/authorized_keys` and the new user doesn't have it.
Without copying it they cannot log in at all — and applying SSH hardening after
that locks you out of the server for good:

```bash
install -d -o admin -g admin -m 700 /home/admin/.ssh
install -o admin -g admin -m 600 /root/.ssh/authorized_keys /home/admin/.ssh/authorized_keys
```

Verify the login works **without closing your current session**:

```bash
ssh admin@<server-ip> 'id && sudo -n true && echo SUDO_OK'
```

Only once that succeeds, reconnect as the new user and carry on from item 2.

## 2. Base packages

```bash
sudo apt update
sudo apt install -y micro curl wget git nano unzip htop bind9-dnsutils jq \
    software-properties-common ca-certificates gnupg rsync
```

`software-properties-common` is there for `add-apt-repository` — without it
the fastfetch PPA (item 4) won't install. `certbot` is no longer part of this set — it moved to item 8. `bind9-dnsutils` is the real
package name behind the virtual `dnsutils` on Ubuntu 26.04.

## 3. CLI tools + starship

```bash
sudo apt install -y eza bat fd-find ripgrep zoxide ncdu
curl -sS https://starship.rs/install.sh | sh -s -- -y
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

`eza`/`bat` work fine without the aliases too: `eza --icons -la`, `batcat file.txt`.

## 4. fastfetch

```bash
sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
sudo apt update
sudo apt install -y fastfetch
```

You need version ≥ 2.64.0 — older releases don't support the padding syntax
in format strings that this repo's [`config.jsonc`](../src/config.jsonc) relies on:

```bash
mkdir -p ~/.config/fastfetch
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/src/config.jsonc \
    -o ~/.config/fastfetch/config.jsonc
```

And login autorun — in `~/.bashrc`:

```bash
if [ -x "$(command -v fastfetch)" ]; then
    fastfetch
fi
```

## 5. tmux

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

## 6. Docker + Compose

The official Docker repo, not the `docker.io` package from Ubuntu's own
repos — that one's stale:

```bash
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# codename — usually noble (24.04) or your current one; if Docker doesn't
# have packages for your codename yet, use noble — it's compatible
CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${CODENAME} stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"   # re-login for this to apply without sudo

# To really turn Docker off you need BOTH units: while docker.socket is alive,
# the daemon comes back on the first request to /var/run/docker.sock
sudo systemctl disable --now docker.socket docker.service
```

## 7. nginx-full

```bash
sudo apt install -y nginx-full
sudo systemctl enable --now nginx
```

## 8. Certbot + plugins

`certbot` moved out of the base packages into its own item: TLS is a service
with its own plugins and secrets, and not every server needs it.

```bash
apt-get install -y certbot

# HTTP-01 — ordinary certificates through an already running nginx
apt-get install -y python3-certbot-nginx

# DNS-01 — required for wildcards (*.example.com)
apt-get install -y python3-certbot-dns-cloudflare
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
> overrides both `PYTHONWARNINGS=ignore` and `python3 -W ignore` — neither
> works, I tested. It is harmless though: the complaint does not apply to an
> apt install (the version is pinned by the package's own dependency, not
> dragged in by `pip`), and it does not affect issuance. No need to patch
> distro files for silence.

The Cloudflare plugin needs an API token with **Zone:DNS:Edit** permissions:

```bash
install -d -m 700 /root/.secrets/certbot
umask 077
echo 'dns_cloudflare_api_token = YOUR_TOKEN' > /root/.secrets/certbot/cloudflare.ini
chmod 600 /root/.secrets/certbot/cloudflare.ini
```

The mode matters: certbot refuses to use the file if it is more permissive.
Issuing a wildcard certificate:

```bash
certbot certonly --dns-cloudflare \
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
install -d -m 755 /etc/letsencrypt
install -m 644 "$(find /usr/lib/python3/dist-packages -name ssl-dhparams.pem | head -1)" \
    /etc/letsencrypt/ssl-dhparams.pem
install -m 644 "$(find /usr/lib/python3/dist-packages -name options-ssl-nginx.conf | head -1)" \
    /etc/letsencrypt/options-ssl-nginx.conf
```

## 9. Docker log rotation

Caps container logs (10 MB per file, 3 files max) without overwriting the
rest of `daemon.json` if it already exists:

```bash
sudo mkdir -p /etc/docker
```

Add/merge into `/etc/docker/daemon.json`:

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
sudo systemctl restart docker   # restarts ALL containers along with the daemon
```

## 10. fail2ban

Replace `22` with your server's actual SSH port if it's different:

```bash
sudo apt install -y fail2ban
```

`/etc/fail2ban/jail.local`:

```ini
[sshd]
enabled = true
port = 22
maxretry = 5
findtime = 10m
bantime = 1h
```

```bash
sudo systemctl enable --now fail2ban
```

## 11. unattended-upgrades

```bash
sudo apt install -y unattended-upgrades
```

`/etc/apt/apt.conf.d/20auto-upgrades`:

```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

```bash
sudo systemctl enable --now unattended-upgrades
```

## 12. ZRAM + swap + earlyoom

In the script, both zram's `PERCENT` and the backup swap file's size are
asked interactively. zram defaults to 75%; the swap file defaults to
`min(RAM, free/4)`, clamped to 512–4096 MB — the file is a backstop *under*
zram, so it scales with memory, while dividing by 4 keeps it from eating a
tight disk. By hand — just plug in your own numbers instead of the examples
below.

```bash
sudo apt install -y zram-tools
```

`/etc/default/zramswap` (example — 75%, use your own value):

```
ALGO=lz4
PERCENT=75
PRIORITY=100
```

```bash
sudo systemctl restart zramswap
```

A backup disk swapfile (example — 1 GB, priority 10, lower than zram so it
only gets used once zram fills up; swap in your own size instead of `1G`,
e.g. `2G` or `4G`):

```bash
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
echo "/swapfile none swap sw,pri=10 0 0" | sudo tee -a /etc/fstab
sudo swapon -a
```

Recommended sysctl values — `/etc/sysctl.d/99-zram.conf`:

```
vm.swappiness=80
vm.vfs_cache_pressure=50
```

```bash
sudo sysctl --system
sudo apt install -y earlyoom
sudo systemctl enable --now earlyoom
```

## 13. SSH hardening

**A separate, most important warning: doing this by hand means you lose the
self-test the script does** (a one-time key, an actual login via
`ssh user@127.0.0.1` before and after restarting `sshd`, automatic rollback
on failure — see [README](../README.en.md)). Nothing here is
verified automatically — only you, with the commands below. **Before
disabling the password, make sure key-based login actually works**, and
keep your current session open until you've confirmed a new one connects too.

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
echo "ssh-ed25519 AAAA...your-public-key..." >> ~/.ssh/authorized_keys
```

Test key-based login **in a separate, new terminal**, without closing the
current one:

```bash
ssh -i /path/to/private/key your_user@server_ip
```

Only once that works — `/etc/ssh/sshd_config.d/10-hardening.conf` (the name
isn't arbitrary: configs in `sshd_config.d/` are read alphabetically, and a
lot of cloud images already ship a `50-cloud-init.conf` with
`PasswordAuthentication yes` — `10` sorts before `50` and wins the merge):

```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers your_user
```

```bash
sudo sshd -t                     # syntax check only — applies nothing
sudo systemctl restart ssh
```

Again, **in a separate terminal**, confirm key-based login still works, and
additionally check the config actually took effect (relevant if
`/etc/ssh/sshd_config` is missing the line
`Include /etc/ssh/sshd_config.d/*.conf` — then the drop-in simply isn't read,
and key login can keep working even without the hardening applied):

```bash
sudo sshd -T | grep -i passwordauthentication   # should say "...: no"
```

If anything went wrong — roll back:

```bash
sudo rm -f /etc/ssh/sshd_config.d/10-hardening.conf
sudo systemctl restart ssh
```

Optional — passwordless sudo (also a deliberate step, not required):

```bash
echo "your_user ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/your_user
sudo chmod 440 /etc/sudoers.d/your_user
sudo visudo -c   # check syntax AFTER writing it — don't skip this
```

## 14. UFW firewall

Check what's actually listening first — otherwise you risk cutting off
something already running (a VPN, a proxy on a non-standard port):

```bash
ss -tln
```

```bash
sudo apt install -y ufw
sudo ufw allow 22/tcp        # your actual SSH port, if not 22
# and the same allow for every port you saw in the ss -tln output above
sudo ufw enable
sudo ufw status
```

---

If anything here doesn't match the script's actual behavior, open an issue —
this file should mirror `setup.sh` as-is, no surprises.
