# USFC — ручная инструкция

<p align="center"><b>🇷🇺 Русский</b> · <a href="MANUAL.en.md">🇬🇧 English</a></p>

Если не хочется гонять чужой `curl | sudo bash` на своём сервере — вот те же
19 пунктов меню [usfc](../README.md), но руками, командами. Порядок такой же,
как в меню, и это не случайно: раздел «защита» — последним, чтобы UFW увидел
уже поднятые Docker и nginx (см. пункт 19).

Инструкция описывает Ubuntu. Отличия Debian:

- у Docker свой путь репозитория: `/linux/debian` вместо `/linux/ubuntu`;
- PPA fastfetch не существует: в Debian 13 пакет есть в обычных
  репозиториях, в Debian 12 его нет вовсе;
- приветствие при входе не показывает число обновлений: этот кэш есть только
  в Ubuntu.

Все команды ниже — от имени пользователя с `sudo`, кроме пункта 1.

## Содержание

- [1. Пользователь + sudo](#1-пользователь--sudo)
- [2. Имя, время, NTP](#2-имя-время-ntp)
- [3. TCP BBR](#3-tcp-bbr)
- [4. Базовые пакеты](#4-базовые-пакеты)
- [5. CLI-утилиты + starship](#5-cli-утилиты--starship)
- [6. fastfetch](#6-fastfetch)
- [7. Приветствие при входе](#7-приветствие-при-входе)
- [8. tmux](#8-tmux)
- [9. Docker + Compose](#9-docker--compose)
- [10. nginx-full](#10-nginx-full)
- [11. Certbot + плагины](#11-certbot--плагины)
- [12. Docker log rotation](#12-docker-log-rotation)
- [13. Лимит журнала systemd](#13-лимит-журнала-systemd)
- [14. fail2ban](#14-fail2ban)
- [15. Уведомления в Telegram](#15-уведомления-в-telegram)
- [16. unattended-upgrades](#16-unattended-upgrades)
- [17. ZRAM + swap + earlyoom](#17-zram--swap--earlyoom)
- [18. SSH hardening](#18-ssh-hardening)
- [19. UFW firewall](#19-ufw-firewall)
- [FAQ](#faq)

## 1. Пользователь + sudo

Нужен, только если сервер выдали с одним лишь `root` — типичная ситуация у
VPS-хостеров. Работать дальше из-под root не стоит: SSH hardening (пункт 18)
без отдельного пользователя не работает в принципе, а всё, что кладётся в
домашний каталог (алиасы, fastfetch, tmux, starship), осядет в `/root`.

```bash
# создать пользователя с домашним каталогом и нормальным шеллом
useradd -m -s /bin/bash admin
passwd admin                      # или passwd -l admin — вход только по ключу

# дать sudo
usermod -aG sudo admin
```

Дальше — **самое важное и чаще всего забываемое**. Если ты заходишь на сервер
по SSH-ключу, то ключ лежит в `/root/.ssh/authorized_keys`, а у нового
пользователя его нет. Без копирования он не сможет войти вообще — и если после
этого применить SSH hardening, доступ к серверу будет потерян:

```bash
install -d -o admin -g admin -m 700 /home/admin/.ssh
install -o admin -g admin -m 600 /root/.ssh/authorized_keys /home/admin/.ssh/authorized_keys
```

Проверь, что вход работает, **не закрывая текущую сессию**:

```bash
ssh admin@<ip-сервера> 'id && sudo -n true && echo SUDO_OK'
```

Замени `admin` на своё имя, а `<ip-сервера>` — на адрес сервера.

Пользователь, у которого нет пароля (`passwd -l`), не сможет выполнить
`sudo`: правило группы `sudo` требует пароль. Тогда нужен sudo без пароля.
usfc предлагает его сам и кладёт правило в отдельный файл, проверяя его
`visudo` до записи:

```bash
echo 'admin ALL=(ALL) NOPASSWD:ALL' > /tmp/90-usfc-admin
visudo -cf /tmp/90-usfc-admin && install -m 440 /tmp/90-usfc-admin /etc/sudoers.d/90-usfc-admin
```

Точку в имени файла sudo молча пропускает, поэтому для `john.doe` файл —
`90-usfc-john_doe`.

Только после успешной проверки перезаходи под новым пользователем и продолжай
с пункта 2.

## 2. Имя, время, NTP

Имя сервера:

```bash
sudo hostnamectl set-hostname web-1
```

Замени `web-1` на своё имя. Строку `127.0.1.1` в `/etc/hosts` приведи в
соответствие — иначе sudo и часть служб при каждом вызове ждут разрешения
имени:

```text
127.0.1.1 web-1
```

Если стоит cloud-init, он может сбросить имя при перезагрузке. Запрети это —
`/etc/cloud/cloud.cfg.d/99-usfc-hostname.cfg`:

```yaml
preserve_hostname: true
```

Часовой пояс и синхронизация времени:

```bash
timedatectl list-timezones | grep -i mosc
sudo timedatectl set-timezone Europe/Moscow
sudo apt install -y systemd-timesyncd
sudo timedatectl set-ntp true
```

Если уже стоит chrony или другой NTP-демон, `systemd-timesyncd` не ставь: они
конфликтуют.

## 3. TCP BBR

Алгоритм BBR вместе с очередью `fq`. Стандартный cubic принимает любую
потерю пакета за перегрузку и сбрасывает скорость; BBR опирается на
измеренную полосу и задержку. Полезнее всего для прокси, VPN и раздачи
файлов.

Сначала проверь, что ядро умеет BBR:

```bash
modinfo tcp_bbr >/dev/null && echo есть
```

`/etc/sysctl.d/60-usfc-bbr.conf`:

```text
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
```

`/etc/modules-load.d/usfc-bbr.conf` — чтобы модуль грузился при загрузке:

```text
tcp_bbr
```

```bash
sudo modprobe tcp_bbr
sudo sysctl -p /etc/sysctl.d/60-usfc-bbr.conf
sysctl net.ipv4.tcp_congestion_control   # должно быть bbr
```

В контейнере (LXC, OpenVZ) ядро хоста не твоё — там это не сработает. Пункт
usfc в контейнере ничего не пишет и говорит об этом.

## 4. Базовые пакеты

```bash
sudo apt update
sudo apt install -y micro curl wget git nano unzip htop bind9-dnsutils jq \
    software-properties-common ca-certificates gnupg rsync
```

`software-properties-common` нужен ради `add-apt-repository` — без него не
встанет PPA для fastfetch (пункт 6). `bind9-dnsutils` — реальное имя пакета за
виртуальным `dnsutils` в Ubuntu 26.04.

## 5. CLI-утилиты + starship

```bash
sudo apt install -y eza bat fd-find ripgrep zoxide ncdu btop
curl -fsSL https://starship.rs/install.sh | sh -s -- -y
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

usfc добавляет в тот же блок четыре функции. Две самые полезные:

```bash
# ports: слушающие TCP/UDP-порты с процессом
ports() { sudo ss -tulpn; }

# dps: компактный docker ps
dps() { docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' "$@"; }
```

Это упрощённые версии: в usfc `ports` форматирует вывод `ss`, а ещё есть
`extract` (распаковка архива по расширению) и `myip` (внешний и локальные
адреса).

Вид промпта задаёт `~/.config/starship.toml`. usfc пишет туда один из трёх
пресетов: `minimal` (пользователь@хост, каталог), `git` (плюс ветка, статус,
время, длительность команды) и `powerline` (цветные плашки). Чужой
`starship.toml` usfc не перезаписывает. Готовые пресеты starship — в его
документации: `starship preset --list`.

Каталог `~/.config` создавай от имени пользователя, а не через `sudo`:
если он станет root-овым, btop и другие программы не смогут хранить там
настройки. Уже сломанный чинится так:

```bash
sudo chown "$USER": ~/.config
```

## 6. fastfetch

```bash
sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
sudo apt update
sudo apt install -y fastfetch
```

Нужна версия ≥ 2.40.4 — на более старых [`config.jsonc`](../src/config.jsonc)
из этого репозитория выглядит не так:

```bash
mkdir -p ~/.config/fastfetch
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/src/config.jsonc \
    -o ~/.config/fastfetch/config.jsonc
```

Автозапуск — в `~/.bashrc`. Условия те же, что у usfc: только при входе по
SSH, только в login-оболочке (иначе каждый `bash` внутри сессии печатал бы
сводку), не внутри tmux и не когда стоит карточка из пункта 7:

```bash
if [ -n "${SSH_CONNECTION:-}" ] && [ -z "${TMUX:-}" ] \
   && shopt -q login_shell && [ ! -x /etc/update-motd.d/01-usfc ] \
   && command -v fastfetch >/dev/null 2>&1; then
    fastfetch
fi
```

## 7. Приветствие при входе

Текст при входе по SSH собирает `pam_motd`: он запускает все исполняемые
скрипты из `/etc/update-motd.d/` по порядку и следом показывает статичный
`/etc/motd`. Отсюда же берётся реклама провайдера.

Посмотри, что там лежит:

```bash
ls -l /etc/update-motd.d/
cat /etc/motd
```

Выключить скрипт, не удаляя, — снять право на запуск:

```bash
sudo chmod -x /etc/update-motd.d/10-help-text /etc/update-motd.d/50-motd-news
```

Вернуть — `sudo chmod +x` тем же файлам. Статичный текст:

```bash
sudo cp /etc/motd /etc/motd.orig
sudo truncate -s 0 /etc/motd
```

usfc вместо выключенного ставит свою карточку сервера —
`/etc/update-motd.d/01-usfc`: имя сервера крупными буквами, ОС, ядро,
виртуализация, IP, uptime, нагрузка, vCPU, полоски RAM и диска, swap, число
контейнеров и предупреждения:

```text

 ███╗   ██╗ ██████╗ ██████╗ ███████╗       ██████╗  ██╗
 ████╗  ██║██╔═══██╗██╔══██╗██╔════╝      ██╔═████╗███║
 ██╔██╗ ██║██║   ██║██║  ██║█████╗  █████╗██║██╔██║╚██║
 ██║╚██╗██║██║   ██║██║  ██║██╔══╝  ╚════╝████╔╝██║ ██║
 ██║ ╚████║╚██████╔╝██████╔╝███████╗      ╚██████╔╝ ██║
 ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝       ╚═════╝  ╚═╝

 Ubuntu 24.04.5 LTS · 6.8.0-147 · kvm · 2 vCPU
 203.0.113.10 · аптайм 3 ч · нагрузка 0.12 0.08 0.05

 RAM   ▰▰▱▱▱▱▱▱▱▱▱▱  20%  397M / 1.9G
 Диск  ▰▰▰▰▰▱▱▱▱▱▱▱  44%  4.7G / 10.6G
 Swap  zram 0M / 1.4G · диск 0M / 1.9G
```

Имя рисуется тем же шрифтом, что логотип usfc в меню, с тем же переливом
цвета. Если оно шире 76 колонок (примерно больше 9 символов), берётся
компактный шрифт в две строки; если не влезает и он или в имени есть символ,
которого нет в шрифте (разрешены латиница, цифры, `-`, `.`, `_`), имя
печатается обычным жирным текстом, в C-локали — тоже. Карточка из прежних
версий usfc в меню помечена «устарела»: повторный выбор пункта ставит новую. Скрипт не ходит в сеть: число обновлений берётся из кэша
`/var/lib/update-notifier/updates-available`. Что выключено, usfc записывает
в `/etc/usfc/motd-disabled`, чтобы вернуть всё повторным выбором пункта
(пункт спросит подтверждение). Скрипты-симлинки (на Ubuntu
`50-landscape-sysinfo` ведёт в `/usr/share`) usfc не выключает через
`chmod`, чтобы не трогать файл пакета: убирает саму ссылку и при возврате
создаёт её заново.
Руками такую карточку повторять не обязательно — вместо неё подойдёт
fastfetch (пункт 6).

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

Официальный репозиторий Docker, не `docker.io` из репозиториев Ubuntu — тот
старый:

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

Выключить Docker насовсем нужно **обоими** юнитами: пока жив `docker.socket`,
демон поднимается сам при первом обращении к `/var/run/docker.sock`:

```bash
sudo systemctl disable --now docker.socket docker.service
```

Optional: lazydocker — консольный интерфейс для контейнеров, логов и образов.
usfc берёт его из GitHub-релиза `jesseduffield/lazydocker` и сверяет sha256 с
файлом `checksums.txt` того же релиза. Руками — скачай архив под свою
архитектуру со страницы релизов, сверь `sha256sum` и положи бинарник в
`/usr/local/bin`.

## 10. nginx-full

```bash
sudo apt install -y nginx-full
sudo systemctl enable --now nginx     # если нужно поднять прямо сейчас
```

Пакет поднимает сервис сам, из postinst. Если поднимать его пока не нужно —
не «ставь и гаси» (nginx успеет занять `:80`, а на занятом порту установка
ещё и ругнётся), а запрети старт на время установки штатным для Debian
способом:

```bash
printf '#!/bin/sh\nexit 101\n' | sudo tee /usr/sbin/policy-rc.d >/dev/null
sudo chmod +x /usr/sbin/policy-rc.d
sudo apt install -y nginx-full
sudo rm -f /usr/sbin/policy-rc.d      # ОБЯЗАТЕЛЬНО: иначе сломается старт
                                      # сервисов при любой будущей установке
sudo systemctl disable nginx
```

## 11. Certbot + плагины

TLS — это сервис со своими плагинами и секретами, и нужен он не на каждом
сервере, поэтому это отдельный пункт.

```bash
sudo apt install -y certbot

# HTTP-01 — обычные сертификаты через уже поднятый nginx
sudo apt install -y python3-certbot-nginx

# DNS-01 — без него не выпустить wildcard (*.example.com)
sudo apt install -y python3-certbot-dns-cloudflare
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
> и `PYTHONWARNINGS=ignore`, и `python3 -W ignore`. Но он безвреден: версия
> закреплена зависимостью пакета, и на выпуск сертификатов баннер не влияет.
> Патчить файлы дистрибутива ради тишины не нужно.

Cloudflare-плагину нужен API-токен с правами **Zone:DNS:Edit**:

```bash
sudo install -d -m 700 /root/.secrets/certbot
sudo sh -c 'umask 077; echo "dns_cloudflare_api_token = ТВОЙ_ТОКЕН" > /root/.secrets/certbot/cloudflare.ini'
```

Замени `ТВОЙ_ТОКЕН` на токен. Права важны: при более открытых certbot сам
откажется работать с файлом. Выпуск wildcard-сертификата:

```bash
sudo certbot certonly --dns-cloudflare \
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
sudo install -d -m 755 /etc/letsencrypt
sudo install -m 644 "$(find /usr/lib/python3/dist-packages -name ssl-dhparams.pem | head -1)" \
    /etc/letsencrypt/ssl-dhparams.pem
sudo install -m 644 "$(find /usr/lib/python3/dist-packages -name options-ssl-nginx.conf | head -1)" \
    /etc/letsencrypt/options-ssl-nginx.conf
```

## 12. Docker log rotation

Ограничивает логи контейнеров: 10 МБ на файл, максимум 3 файла. Если
`/etc/docker/daemon.json` уже есть, добавь ключи в него, не затирая
остальное:

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
sudo systemctl restart docker   # перезапустит ВСЕ контейнеры вместе с демоном
```

Настройка действует только на контейнеры, созданные после перезапуска.

Если в `daemon.json` уже задан другой `log-driver` (`syslog`, `gelf`,
`journald` и т. п.), пункт его не меняет и пропускается: лимиты `max-size` и
`max-file` этим драйверам не подходят. Драйвер `local` сохраняется, лимиты
добавляются к нему. Для правки файла пункту нужен `python3`.

## 13. Лимит журнала systemd

По умолчанию journald может занять до 10% диска (но не больше 4 ГБ). usfc
ставит 5% диска, не меньше 100 и не больше 1000 МБ.

`/etc/systemd/journald.conf.d/usfc.conf` (пример — 500 МБ):

```ini
[Journal]
SystemMaxUse=500M
```

```bash
sudo systemctl restart systemd-journald
sudo journalctl --vacuum-size=500M   # сжать уже накопленное
journalctl --disk-usage
```

Меньше 50 МБ journald не удержит.

## 14. fail2ban

Узнай реальный SSH-порт:

```bash
sudo sshd -T | grep '^port '
```

```bash
sudo apt install -y fail2ban
```

Свой файл в `jail.d`, а не `jail.local`: тот остаётся для твоих правок.
`/etc/fail2ban/jail.d/usfc-sshd.local` (замени `22` на порт):

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

`backend = systemd` нужен на Debian 12: там нет `/var/log/auth.log`, и jail
без этого не находит лога.

```bash
sudo fail2ban-client -t                # проверить конфиг
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

## 15. Уведомления в Telegram

Нужен бот от @BotFather (это токен) и `chat_id` — куда писать. Узнать
`chat_id`: напиши боту `/start`, затем открой
`https://api.telegram.org/bot<токен>/getUpdates` и найди `"chat":{"id":…}`.

Токен держи в файле с правами `600` и не передавай в аргументах команды —
их видно в `ps`. usfc отдаёт адрес с токеном curl через stdin:

```bash
sudo install -d -m 700 /etc/usfc
sudo sh -c 'umask 077; printf "TG_TOKEN=%s\nTG_CHAT=%s\n" "ТОКЕН" "CHAT_ID" > /etc/usfc/notify.conf'
```

Замени `ТОКЕН` и `CHAT_ID`. Тестовое сообщение:

```bash
sudo bash -c '. /etc/usfc/notify.conf
  printf "url = \"https://api.telegram.org/bot%s/sendMessage\"\n" "$TG_TOKEN" \
  | curl -sS --connect-timeout 5 --max-time 10 --config - \
      --data-urlencode "chat_id=$TG_CHAT" --data-urlencode "text=проверка"'
```

Остальное usfc собирает из трёх событий, каждое по выбору:

- **вход по SSH** — строка в `/etc/pam.d/sshd`:
  `session optional pam_exec.so quiet /usr/local/sbin/usfc-notify-ssh`.
  `optional` важно: сбой отправки не мешает входу. Скрипт должен уходить в
  фон и сразу выходить с кодом `0`, иначе вход будет ждать сети;
- **бан fail2ban** — свой action в `/etc/fail2ban/action.d/usfc-telegram.conf`;
- **нужна перезагрузка** — ежедневный таймер `usfc-notify-reboot.timer`,
  который проверяет `/var/run/reboot-required`.

Руками это заметно больше работы, чем остальные пункты; полный набор
скриптов проще получить пунктом 15 в usfc. Если уведомления не приходят —
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#уведомления-в-telegram-не-приходят).

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

Optional: окно автоперезагрузки. Часть обновлений (ядро, libc) действует
только после перезагрузки. Свой файл, а не правка `50unattended-upgrades` —
его перепишет обновление пакета. `/etc/apt/apt.conf.d/52usfc-reboot`:

```text
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
```

`WithUsers "false"` — не перезагружать, пока кто-то вошёл по SSH. Проверь,
что другой файл позже по алфавиту не перебивает ключ:

```bash
apt-config dump | grep Automatic-Reboot
```

## 17. ZRAM + swap + earlyoom

В usfc и `PERCENT` для zram, и размер резервного swap-файла спрашиваются.
Для zram по умолчанию предлагается 75%, для swap-файла — `min(RAM,
свободно/4)`, зажатое в 512–4096 МБ: своп здесь резерв *под* zram, поэтому
считается от объёма памяти, а деление на 4 не даёт ему съесть тесный диск.

```bash
sudo apt install -y zram-tools
```

В `/etc/default/zramswap` поменяй три ключа (остальное не трогай; пример —
75%):

```text
ALGO=lz4
PERCENT=75
PRIORITY=100
```

```bash
sudo systemctl restart zramswap
```

Если на сервере уже работает `systemd-zram-generator`, zram-tools поверх
не ставь: будет два zram. Пункт usfc в этом случае настраивает генератор:
в `/etc/systemd/zram-generator.conf` меняет только `zram-size`,
`compression-algorithm` и `swap-priority` в секции `[zram0]`, остальные
секции и опции не трогает.

Если дисковых свопов несколько (например, `/swap.img` и раздел провайдера),
приоритет 10 нужен каждому: пункт исправляет все.

Резервный swap-файл на диске (пример — 1 ГБ). Приоритет 10 ниже, чем у zram,
так что использоваться он будет, только когда zram заполнится:

```bash
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
echo "/swapfile none swap sw,pri=10 0 0" | sudo tee -a /etc/fstab
sudo swapon -a
swapon --show                     # у /swapfile должно быть PRIO 10
```

На btrfs `fallocate` даёт файл с дырами, непригодный для свопа — там вместо
первой строки нужен `sudo dd if=/dev/zero of=/swapfile bs=1M count=1024`.

**Приоритет должен быть в `/etc/fstab`**, а не только в `swapon -p`: иначе
после перезагрузки своп поднимется с приоритетом по умолчанию и пойдёт в ход
раньше zram. Если строка свопа уже есть (`defaults`, `sw,nofail`, `UUID=…`),
допиши `,pri=10` в её четвёртое поле, а не добавляй вторую строку.

### Поменять размер уже существующего swap-файла

Ubuntu в облачных образах кладёт свой `/swap.img`, и его размер редко
совпадает с тем, что нужно:

```bash
swapon --show                     # путь, размер и сколько ЗАНЯТО
free -m                           # сколько свободной памяти
```

**Сначала убедись, что занятое в свопе влезет обратно в RAM**: `swapoff`
выгружает страницы в память, и если её не хватит — прилетит OOM с убитыми
процессами. usfc не выключает своп, если занятое не меньше, чем доступная
память минус 200 МБ. Дальше:

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

**Делая это руками, ты теряешь самопроверку, которую делает usfc**:
одноразовый ключ, реальный вход через `ssh user@127.0.0.1` до и после
рестарта `sshd`, автоматический откат при сбое. Здесь всё проверяешь ты сам.
**Прежде чем выключать пароль, убедись, что вход по ключу работает**, и держи
открытой текущую сессию, пока новая не подключится.

1. Положи свой публичный ключ:

   ```bash
   mkdir -p ~/.ssh && chmod 700 ~/.ssh
   touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
   echo "ssh-ed25519 AAAA...ваш-публичный-ключ..." >> ~/.ssh/authorized_keys
   ```

2. В отдельном, новом терминале проверь вход по ключу:

   ```bash
   ssh -i /путь/к/приватному/ключу ваш_пользователь@ip_сервера
   ```

3. Найди чужие настройки, которые перебьют твои. У sshd побеждает **первое**
   значение ключа: всё, что в `sshd_config` стоит до строки `Include`, и
   файлы `sshd_config.d/*.conf`, которые сортируются раньше твоего:

   ```bash
   sudo grep -rn -iE 'PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication|PubkeyAuthentication' \
       /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
   ```

   Строку провайдера с другим значением закомментируй (`#` в начале строки),
   сохранив копию файла.

4. Создай `/etc/ssh/sshd_config.d/00-usfc-hardening.conf`. Имя с `00`, чтобы
   сортироваться раньше файлов провайдера и `50-cloud-init.conf`:

   ```text
   PermitRootLogin no
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   PubkeyAuthentication yes
   ```

   `AllowUsers ваш_пользователь` добавляй, только если сознательно хочешь
   закрыть SSH всем остальным аккаунтам.

5. Проверь синтаксис и перезапусти:

   ```bash
   sudo sshd -t
   sudo systemctl restart ssh
   ```

6. Сверь, что sshd применяет на самом деле:

   ```bash
   sudo sshd -T | grep -E 'passwordauthentication|permitrootlogin|kbdinteractive|pubkeyauthentication'
   ```

   Ожидаемо: `passwordauthentication no`, `permitrootlogin no`,
   `kbdinteractiveauthentication no`, `pubkeyauthentication yes`. Если нет —
   какой-то файл всё ещё перебивает, вернись к шагу 3. Если в
   `/etc/ssh/sshd_config` нет строки `Include /etc/ssh/sshd_config.d/*.conf`,
   drop-in вообще не читается.

7. Снова в отдельном терминале убедись, что вход по ключу работает.

Откат:

```bash
sudo rm -f /etc/ssh/sshd_config.d/00-usfc-hardening.conf
sudo systemctl restart ssh
```

### Сменить порт SSH

Порт меняй в два шага, чтобы не потерять доступ. Директива `Port` у sshd
**складывается** по всем файлам: `Port 22` в `sshd_config` и `Port 2222` в
drop-in — это два порта.

1. Открой новый порт заранее — в UFW, в fail2ban (`port =` в
   `jail.d/usfc-sshd.local`) и в файрволе провайдера, если он есть:

   ```bash
   sudo ufw allow 2222/tcp
   ```

2. Добавь в `00-usfc-hardening.conf` оба порта и закомментируй `Port` в
   других файлах:

   ```text
   Port 22
   Port 2222
   ```

3. Перезапусти. На Ubuntu 22.10+ с сокетной активацией порт держит
   `ssh.socket`, ему нужен `daemon-reload`:

   ```bash
   sudo sshd -t
   sudo systemctl daemon-reload
   sudo systemctl restart ssh.socket   # если он есть: systemctl status ssh.socket
   sudo systemctl restart ssh
   ```

4. Со своей машины проверь вход на новом порту: `ssh -p 2222 user@server`.
5. Только после этого убери `Port 22`, повтори шаг 3 и закрой старый порт:
   `sudo ufw delete allow 22/tcp`.

Замени `2222` на свой порт. Строка `ListenAddress` с явным портом
(`ListenAddress 0.0.0.0:22`) сильнее `Port` — порт из неё убери.

## 19. UFW firewall

Сначала посмотри, что реально слушает порты — иначе рискуешь отрезать что-то
уже работающее (VPN на UDP, прокси на нестандартном порту):

```bash
sudo ss -tulpn
```

```bash
sudo apt install -y ufw
sudo ufw allow 22/tcp                 # твой SSH-порт — первым, до enable
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 443/tcp                # и так для каждого нужного порта
sudo ufw allow 51820/udp              # UDP — отдельно: WireGuard, Hysteria
sudo ufw enable
sudo ufw status verbose
```

Доступ к порту только с одного адреса:

```bash
sudo ufw allow from 203.0.113.10 to any port 5432 proto tcp
```

### Не отвечать на ping

В `/etc/ufw/before.rules` в блоках `# ok icmp codes for INPUT` и
`# ok icmp code for FORWARD` замени у строк `-p icmp` концовку `-j ACCEPT`
на `-j DROP` и добавь в конец блока INPUT:

```text
-A ufw-before-input -p icmp --icmp-type source-quench -j DROP
```

```bash
sudo ufw reload
```

Ответы на твои же соединения (в том числе «нужна фрагментация» для PMTU)
пропускает правило conntrack выше этих блоков, так что исходящие соединения
не ломаются. В `before6.rules` меняй только `echo-request`: на остальном
ICMPv6 держится обнаружение соседей, без него IPv6 перестаёт работать.

### Docker в обход UFW

Docker публикует порты (`-p 8080:80`) своими правилами iptables, мимо цепочек
UFW: с включённым файрволом порт всё равно открыт миру. usfc решает это по
схеме [ufw-docker](https://github.com/chaifeng/ufw-docker): блок в конце
`/etc/ufw/after.rules` заворачивает цепочку `DOCKER-USER` в правила
`ufw route`:

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

Правило маршрута пишется на порт **контейнера**: для `-p 8080:80` это `80`.
Схема работает только для IPv4 и iptables-бэкенда Docker; с
`"firewall-backend": "nftables"` в `daemon.json` цепочки `DOCKER-USER` нет.

## FAQ

### Почему CPU в VM виден как «Xeon (Skylake, IBRS)»

Модель процессора внутри виртуальной машины задаёт гипервизор провайдера, а
не железо. QEMU/KVM умеет показывать гостю именованную модель CPU — например
`Skylake-Server-IBRS`, и тогда в `/proc/cpuinfo` строка выглядит как
`Intel Xeon Processor (Skylake, IBRS)`. `IBRS` в названии — это вариант
модели с защитой от Spectre v2, а не отдельный процессор. Провайдеры выбирают
общую модель, чтобы VM могла переезжать между хостами с разными
процессорами, поэтому физически сервер может работать на более новом железе.

fastfetch и карточка usfc показывают то, что видит ядро. Изнутри VM это не
поменять. Сколько ядер и какие инструкции доступны на самом деле:

```bash
nproc
grep -o -w -E 'avx2|avx512f|aes' /proc/cpuinfo | sort -u
```

### Откуда берётся приветствие провайдера и как его убрать

Текст при входе собирается из скриптов `/etc/update-motd.d/` и статичного
`/etc/motd`. Провайдеры кладут туда свои скрипты и рекламу; cloud-init тоже
может писать в motd. Как выключить, не удаляя, — в
[пункте 7](#7-приветствие-при-входе).

### Что-то не сходится с поведением usfc

Открывай issue: этот файл должен отражать код как есть, без сюрпризов.
