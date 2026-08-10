<div align="center">

# USFC — ручная инструкция

> Инструкция описывает Ubuntu. На Debian отличия ровно два: у Docker свой
> путь репозитория (`/linux/debian` вместо `/linux/ubuntu`), а PPA fastfetch
> не существует — в Debian 13 пакет есть в обычных репозиториях, в Debian 12
> его нет вовсе.

---

</div>

<p align="center"><b>🇷🇺 Русский</b> · <a href="MANUAL.en.md">🇬🇧 English</a></p>

Если не хочется гонять чужой `curl | sudo bash` на своём сервере — вот те же
14 пунктов меню [usfc](../README.md), но руками, командами. Порядок такой же,
как в самом меню, и это не случайно: раздел «защита» — последним, чтобы UFW
увидел уже поднятые Docker/nginx (см. пункт 14).

## Содержание

- [1. Пользователь + sudo](#1-пользователь--sudo)
- [2. Базовые пакеты](#2-базовые-пакеты)
- [3. CLI-утилиты + starship](#3-cli-утилиты--starship)
- [4. fastfetch](#4-fastfetch)
- [5. tmux](#5-tmux)
- [6. Docker + Compose](#6-docker--compose)
- [7. nginx-full](#7-nginx-full)
- [8. Certbot + плагины](#8-certbot--плагины)
- [9. Docker log rotation](#9-docker-log-rotation)
- [10. fail2ban](#10-fail2ban)
- [11. unattended-upgrades](#11-unattended-upgrades)
- [12. ZRAM + swap + earlyoom](#12-zram--swap--earlyoom)
- [13. SSH hardening](#13-ssh-hardening)
- [14. UFW firewall](#14-ufw-firewall)

## 1. Пользователь + sudo

Нужен, только если сервер выдали с одним лишь `root` — типичная ситуация у VPS-хостеров.
Работать дальше из-под root не стоит: SSH hardening (пункт 13) без отдельного
пользователя не работает в принципе, а всё, что кладётся в домашний каталог
(алиасы, fastfetch, tmux, starship), осядет в `/root` и исчезнет из виду, как
только ты перезайдёшь под нормальным аккаунтом.

```bash
# создать пользователя с домашним каталогом и нормальным шеллом
useradd -m -s /bin/bash admin
passwd admin                      # или passwd -l admin — вход только по ключу

# дать sudo
usermod -aG sudo admin
```

Дальше — **самое важное и чаще всего забываемое**. Если ты заходишь на сервер по
SSH-ключу, то ключ лежит в `/root/.ssh/authorized_keys`, а у нового пользователя
его нет. Без копирования он не сможет войти вообще — и если после этого применить
SSH hardening, доступ к серверу будет потерян:

```bash
install -d -o admin -g admin -m 700 /home/admin/.ssh
install -o admin -g admin -m 600 /root/.ssh/authorized_keys /home/admin/.ssh/authorized_keys
```

Проверь, что вход работает, **не закрывая текущую сессию**:

```bash
ssh admin@<ip-сервера> 'id && sudo -n true && echo SUDO_OK'
```

Только после успешной проверки перезаходи под новым пользователем и продолжай
с пункта 2.

## 2. Базовые пакеты

```bash
sudo apt update
sudo apt install -y micro curl wget git nano unzip htop bind9-dnsutils jq \
    software-properties-common ca-certificates gnupg rsync
```

`software-properties-common` нужен ради `add-apt-repository` — без него не
встанет PPA для fastfetch (пункт 4). `bind9-dnsutils` — реальное имя пакета
за виртуальным `dnsutils` в Ubuntu 26.04. `certbot` сюда больше не входит —
он переехал в пункт 8.

## 3. CLI-утилиты + starship

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

## 4. fastfetch

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

# Выключить Docker насовсем нужно ОБОИМИ юнитами: пока жив docker.socket,
# демон поднимается сам при первом обращении к /var/run/docker.sock
sudo systemctl disable --now docker.socket docker.service
```

## 7. nginx-full

```bash
sudo apt install -y nginx-full
sudo systemctl enable --now nginx     # если нужно поднять прямо сейчас
```

Пакет поднимает сервис сам, из postinst. Если поднимать его пока не нужно —
не «ставь и гаси» (nginx успеет занять `:80`, а на занятом порту установка ещё
и ругнётся), а запрети старт на время установки штатным для Debian способом:

```bash
printf '#!/bin/sh\nexit 101\n' | sudo tee /usr/sbin/policy-rc.d >/dev/null
sudo chmod +x /usr/sbin/policy-rc.d
sudo apt install -y nginx-full
sudo rm -f /usr/sbin/policy-rc.d      # ОБЯЗАТЕЛЬНО: иначе сломается старт
                                      # сервисов при любой будущей установке
sudo systemctl disable nginx
```

## 8. Certbot + плагины

`certbot` вынесен из базовых пакетов в отдельный пункт: TLS — это сервис со
своими плагинами и секретами, и нужен он не на каждом сервере.

```bash
apt-get install -y certbot

# HTTP-01 — обычные сертификаты через уже поднятый nginx
apt-get install -y python3-certbot-nginx

# DNS-01 — без него не выпустить wildcard (*.example.com)
apt-get install -y python3-certbot-dns-cloudflare
```

> **Про WARNING от python-cloudflare 2.20.** Плагин объявляет
> `Depends: python3-cloudflare (<< 3.0)`, а в архиве Ubuntu 26.04 лежит ровно
> одна подходящая версия — `2.20.0`, и баннер из неё Ubuntu не вырезала
> (`/usr/lib/python3/dist-packages/CloudFlare/warning_2_20.py` на месте).
>
> Проверено на живой системе: баннер срабатывает в конструкторе клиента
> (`CloudFlare/cloudflare.py`), то есть **при реальном выпуске сертификата**.
> При `apt install`, `certbot --version` и `certbot plugins` его нет.
>
> Отключить его нельзя: `warn_warning_2_20()` сам вызывает
> `warnings.simplefilter('always', PendingDeprecationWarning)` и перебивает
> и `PYTHONWARNINGS=ignore`, и `python3 -W ignore` — проверял, не работает
> ни то, ни другое. Но он безвреден: к установке из apt претензия не относится
> (версия закреплена зависимостью пакета, а не выехала сама из `pip`), и на
> выпуск сертификатов он не влияет. Патчить файлы дистрибутива ради тишины
> не нужно.

Cloudflare-плагину нужен API-токен. Токен должен иметь права **Zone:DNS:Edit**:

```bash
install -d -m 700 /root/.secrets/certbot
umask 077
echo 'dns_cloudflare_api_token = ТВОЙ_ТОКЕН' > /root/.secrets/certbot/cloudflare.ini
chmod 600 /root/.secrets/certbot/cloudflare.ini
```

Права важны: при более открытых certbot сам откажется работать с файлом.
Выпуск wildcard-сертификата:

```bash
certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini \
  -d example.com -d "*.example.com"
```

### TLS-заготовки для nginx

`/etc/letsencrypt/ssl-dhparams.pem` и `/etc/letsencrypt/options-ssl-nginx.conf`
создаёт только nginx-*installer* certbot'а (то есть `certbot --nginx`). При
выпуске через `certbot certonly` — а это ровно то, ради чего ставят DNS-01, —
они не появятся, и типовой конфиг nginx, который на них ссылается, положит
сервер при старте.

Генерировать `dhparam` через `openssl` не нужно: там та же стандартная группа
ffdhe2048, что уже лежит внутри пакета certbot. Просто скопируй:

```bash
install -d -m 755 /etc/letsencrypt
install -m 644 "$(find /usr/lib/python3/dist-packages -name ssl-dhparams.pem | head -1)" \
    /etc/letsencrypt/ssl-dhparams.pem
install -m 644 "$(find /usr/lib/python3/dist-packages -name options-ssl-nginx.conf | head -1)" \
    /etc/letsencrypt/options-ssl-nginx.conf
```

## 9. Docker log rotation

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

## 10. fail2ban

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

В скрипте и `PERCENT` для zram, и размер резервного swap-файла
спрашиваются интерактивно. Для zram по умолчанию предлагается 75%, для
swap-файла — `min(RAM, свободно/4)`, зажатое в 512–4096 МБ: своп здесь резерв
*под* zram, поэтому считается от объёма памяти, а деление на 4 не даёт ему
съесть тесный диск. Руками — просто подставь свои значения вместо примеров ниже.

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

На btrfs `fallocate` даёт файл с дырами, непригодный для свопа — там вместо
первой строки нужен `sudo dd if=/dev/zero of=/swapfile bs=1M count=1024`.

### Поменять размер уже существующего swap-файла

Ubuntu в облачных образах кладёт свой `/swap.img`, и его размер редко совпадает
с тем, что нужно. Скрипт умеет пересоздавать такой файл сам (пункт 12), но
руками это делается так:

```bash
swapon --show                     # посмотреть путь, размер и сколько ЗАНЯТО
free -m                           # сколько свободной памяти
```

**Сначала убедись, что занятое в свопе влезет обратно в RAM**: `swapoff`
выгружает страницы в память, и если её не хватит — прилетит OOM с убитыми
процессами. Дальше:

```bash
sudo swapoff /swap.img
sudo rm -f /swap.img
sudo fallocate -l 2G /swap.img    # свой размер
sudo chmod 600 /swap.img
sudo mkswap /swap.img
sudo swapon -a                    # приоритет возьмётся из /etc/fstab
```

Путь сохраняй прежним. Если создать файл под новым именем и дописать вторую
строку в `/etc/fstab`, после перезагрузки поднимутся оба свопа сразу.

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

## 13. SSH hardening

**Отдельное и самое важное предупреждение: делая это руками, вы теряете
самопроверку, которую делает скрипт** (одноразовый ключ, реальный логин
через `ssh user@127.0.0.1` до и после рестарта `sshd`, автоматический откат
при сбое — см. [README](../README.md)). Здесь ничего не
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

## 14. UFW firewall

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
