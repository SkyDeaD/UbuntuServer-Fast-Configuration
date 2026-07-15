<div align="center">

# USFC — manual guide

---

</div>

<p align="center"><a href="MANUAL.md">🇷🇺 Русский</a> · <b>🇬🇧 English</b></p>

If you'd rather not run someone else's `curl | sudo bash` on your server —
here are the same 12 menu items from [usfc](../README.en.md), but by hand,
as commands. The order matches the menu on purpose: the "hardening" section
comes last, so UFW sees Docker/nginx already listening (see item 12).

## Contents

- [1. Base packages](#1-base-packages)
- [2. CLI tools + starship](#2-cli-tools--starship)
- [3. fastfetch](#3-fastfetch)
- [4. tmux](#4-tmux)
- [5. Docker + Compose](#5-docker--compose)
- [6. nginx-full](#6-nginx-full)
- [7. Docker log rotation](#7-docker-log-rotation)
- [8. fail2ban](#8-fail2ban)
- [9. unattended-upgrades](#9-unattended-upgrades)
- [10. ZRAM + swap + earlyoom](#10-zram--swap--earlyoom)
- [11. SSH hardening](#11-ssh-hardening)
- [12. UFW firewall](#12-ufw-firewall)

## 1. Base packages

```bash
sudo apt update
sudo apt install -y micro curl wget git nano certbot python3-certbot-nginx \
    unzip htop bind9-dnsutils jq software-properties-common ca-certificates \
    gnupg rsync
```

`software-properties-common` is there for `add-apt-repository` — without it
the fastfetch PPA (item 3) won't install. `bind9-dnsutils` is the real
package name behind the virtual `dnsutils` on Ubuntu 26.04.

## 2. CLI tools + starship

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

## 3. fastfetch

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

## 4. tmux

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

## 5. Docker + Compose

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
```

## 6. nginx-full

```bash
sudo apt install -y nginx-full
sudo systemctl enable --now nginx
```

## 7. Docker log rotation

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

## 8. fail2ban

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

## 9. unattended-upgrades

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

## 10. ZRAM + swap + earlyoom

In the script, both zram's `PERCENT` and the backup swap file's size are now
asked interactively (zram defaults to suggesting 75%; the swap file suggests
a size based on free disk space, not a flat 1 GB every time). By hand — just
plug in your own numbers instead of the examples below.

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

## 11. SSH hardening

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

## 12. UFW firewall

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
