<div align="center">

# USFC — ручная инструкция

---

</div>

<p align="center"><b>🇷🇺 Русский</b> · <a href="MANUAL.en.md">🇬🇧 English</a></p>

Если не хочется гонять чужой `curl | sudo bash` на своём сервере — вот те же
12 пунктов меню [usfc](../README.md), но руками, командами. Порядок такой же,
как в самом меню, и это не случайно: раздел «защита» — последним, чтобы UFW
увидел уже поднятые Docker/nginx (см. пункт 12).

## Содержание

- [1. Базовые пакеты](#1-базовые-пакеты)
- [2. CLI-утилиты + starship](#2-cli-утилиты--starship)
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

## 1. Базовые пакеты

```bash
sudo apt update
sudo apt install -y micro curl wget git nano certbot python3-certbot-nginx \
    unzip htop bind9-dnsutils jq software-properties-common ca-certificates \
    gnupg rsync
```

`software-properties-common` нужен ради `add-apt-repository` — без него не
встанет PPA для fastfetch (пункт 3). `bind9-dnsutils` — реальное имя пакета
за виртуальным `dnsutils` в Ubuntu 26.04.

## 2. CLI-утилиты + starship

```bash
sudo apt install -y eza bat fd-find ripgrep zoxide ncdu
curl -sS https://starship.rs/install.sh | sh -s -- -y
```

Дальше — в `~/.bashrc`:

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

`eza`/`bat` прекрасно работают и без алиасов: `eza --icons -la`, `batcat file.txt`.

## 3. fastfetch

```bash
sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
sudo apt update
sudo apt install -y fastfetch
```

Нужна версия ≥ 2.64.0 — более старые не умеют выравнивание в format-строках,
которое использует [`config.jsonc`](../src/config.jsonc) из этого репозитория:

```bash
mkdir -p ~/.config/fastfetch
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/src/config.jsonc \
    -o ~/.config/fastfetch/config.jsonc
```

И автозапуск при входе — в `~/.bashrc`:

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

Официальный репозиторий Docker, не `docker.io` из репов Ubuntu — тот старый:

```bash
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# codename — обычно noble (24.04) или ваш текущий; если для вашего кодового
# имени у Docker ещё нет пакетов, используйте noble — он совместим
CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${CODENAME} stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"   # перелогиньтесь, чтобы применилось без sudo
```

## 6. nginx-full

```bash
sudo apt install -y nginx-full
sudo systemctl enable --now nginx
```

## 7. Docker log rotation

Ограничивает логи контейнеров (10 МБ на файл, максимум 3 файла), не
перезаписывая остальной `daemon.json`, если он уже существует:

```bash
sudo mkdir -p /etc/docker
```

Добавьте/смёржите в `/etc/docker/daemon.json`:

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
sudo systemctl restart docker   # перезапустит ВСЕ контейнеры вместе с демоном
```

## 8. fail2ban

Замените `22` на реальный SSH-порт сервера, если он у вас другой:

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

В скрипте и `PERCENT` для zram, и размер резервного swap-файла теперь
спрашиваются интерактивно (zram — по умолчанию предлагает 75%, swap-файл —
предлагает размер по объёму свободного места на диске, а не жёстко 1 ГБ).
Руками — просто подставь свои значения вместо примеров ниже.

```bash
sudo apt install -y zram-tools
```

`/etc/default/zramswap` (пример — 75%, подставь своё значение):

```
ALGO=lz4
PERCENT=75
PRIORITY=100
```

```bash
sudo systemctl restart zramswap
```

Резервный swapfile на диске (пример — 1 GB, приоритет 10 ниже, чем у zram,
так что использоваться будет только когда zram заполнится; свой размер
подставь вместо `1G`, например `2G` или `4G`):

```bash
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
echo "/swapfile none swap sw,pri=10 0 0" | sudo tee -a /etc/fstab
sudo swapon -a
```

Рекомендованный sysctl — `/etc/sysctl.d/99-zram.conf`:

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

**Отдельное и самое важное предупреждение: делая это руками, вы теряете
самопроверку, которую делает скрипт** (одноразовый ключ, реальный логин
через `ssh user@127.0.0.1` до и после рестарта `sshd`, автоматический откат
при сбое — см. [README](../README.md#как-это-работает)). Здесь ничего не
проверяется автоматически — только вы сами, командами ниже. **Прежде чем
выключать пароль — убедитесь, что вход по ключу реально работает**, и
держите открытой текущую сессию, пока не убедитесь, что новая тоже
подключается.

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
echo "ssh-ed25519 AAAA...ваш-публичный-ключ..." >> ~/.ssh/authorized_keys
```

Проверьте вход по ключу **в отдельном, новом терминале**, не закрывая текущий:

```bash
ssh -i /путь/к/приватному/ключу ваш_пользователь@ip_сервера
```

Только если это сработало — `/etc/ssh/sshd_config.d/10-hardening.conf`
(имя не случайно: конфиги в `sshd_config.d/` читаются по алфавиту, и на
многих облачных образах уже лежит `50-cloud-init.conf` с
`PasswordAuthentication yes` — `10` идёт раньше `50` и побеждает при слиянии):

```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers ваш_пользователь
```

```bash
sudo sshd -t                     # проверка синтаксиса — ничего не применяет
sudo systemctl restart ssh
```

Снова, **в отдельном терминале**, убедитесь, что вход по ключу всё ещё
работает, и дополнительно сверьте, что конфиг реально подхватился (актуально,
если в `/etc/ssh/sshd_config` нет строки `Include /etc/ssh/sshd_config.d/*.conf` —
тогда дроп-ин просто не читается, а вход по ключу при этом может работать и без
хардненинга):

```bash
sudo sshd -T | grep -i passwordauthentication   # должно быть "yes: no"
```

Если что-то пошло не так — откат:

```bash
sudo rm -f /etc/ssh/sshd_config.d/10-hardening.conf
sudo systemctl restart ssh
```

Опционально — passwordless sudo (тоже осознанный шаг, не обязателен):

```bash
echo "ваш_пользователь ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ваш_пользователь
sudo chmod 440 /etc/sudoers.d/ваш_пользователь
sudo visudo -c   # проверить синтаксис ПОСЛЕ записи — важно не пропустить
```

## 12. UFW firewall

Сначала посмотрите, что реально слушает порты — иначе рискуете отрезать себе
что-то уже работающее (VPN, прокси на нестандартном порту):

```bash
ss -tln
```

```bash
sudo apt install -y ufw
sudo ufw allow 22/tcp        # ваш реальный SSH-порт, если он не 22
# и так же — allow для каждого порта, который увидели в выводе ss -tln выше
sudo ufw enable
sudo ufw status
```

---

Что-то не сходится с реальным поведением скрипта — открывайте issue, этот
файл должен отражать `setup.sh` как есть, без сюрпризов.
