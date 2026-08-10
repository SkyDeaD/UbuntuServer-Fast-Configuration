# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# STATUS-функции — только читают состояние, ничего не меняют
# ═══════════════════════════════════════════════════════════════
# не-root пользователи в группе sudo → REPLY_SUDOERS (через запятую)
REPLY_SUDOERS=''
list_sudo_users() {
    local members u
    members="$(getent group sudo 2>/dev/null | cut -d: -f4)"
    REPLY_SUDOERS=''
    IFS=',' read -ra members <<< "$members"
    for u in "${members[@]}"; do
        [ -z "$u" ] && continue
        [ "$u" = "root" ] && continue
        REPLY_SUDOERS="${REPLY_SUDOERS}${REPLY_SUDOERS:+, }${u}"
    done
}

status_newuser() {
    if [ "$TARGET_USER" != "root" ]; then
        echo -e "${GREEN}✓ работаем от ${TARGET_USER}${NC}"; return 0
    fi
    list_sudo_users
    if [ -n "$REPLY_SUDOERS" ]; then
        echo -e "${YELLOW}! есть: ${REPLY_SUDOERS}, но вы под root${NC}"; return 1
    fi
    echo -e "${DIM}○ только root${NC}"; return 1
}

status_cli() {
    local c missing=""
    # $CLI_PKGS объявляется ниже по файлу, но присваивание верхнего уровня
    # отрабатывает до первого вызова этой функции — читать безопасно
    for c in $CLI_PKGS; do
        pkg_installed "$c" || missing="${missing}${missing:+, }${c}"
    done
    command -v starship &>/dev/null || missing="${missing}${missing:+, }starship"
    if [ -n "$missing" ]; then
        echo -e "${DIM}○ не хватает: ${missing}${NC}"; return 1
    fi
    if ! grep -qF "# >>> vps-setup:cli >>>" "${TARGET_HOME}/.bashrc" 2>/dev/null; then
        echo -e "${YELLOW}! всё стоит, алиасов в .bashrc нет${NC}"; return 1
    fi
    echo -e "${GREEN}✓ установлено${NC}"; return 0
}

# dnsutils в Ubuntu 26.04 — виртуальный пакет (алиас), apt install его резолвит,
# но в списке установленных его нет; реальное имя пакета — bind9-dnsutils.
# certbot и python3-certbot-nginx отсюда сознательно убраны: TLS — это сервис со
# своими плагинами и секретами, ему выделен отдельный пункт меню (apply_certbot)
BASE_PKGS="micro curl wget git nano unzip htop bind9-dnsutils jq software-properties-common ca-certificates gnupg rsync"

# Пакеты CLI-набора вынесены в переменную: их перечисляли в трёх местах
# (status_cli, apply_cli, установка), и списки уже начинали расходиться
CLI_PKGS="eza bat fd-find ripgrep zoxide ncdu"

# Короткие описания — чтобы после установки было видно не только ЧТО приехало,
# но и зачем оно нужно. Пишем руками по-русски: apt-cache show даёт английский
# текст на несколько абзацев и вразнобой по стилю, в одну строку он не ложится.
declare -A PKG_DESC=(
    [micro]="текстовый редактор в терминале, понятнее vim"
    [curl]="скачивание по HTTP из командной строки"
    [wget]="скачивание файлов, умеет докачку и рекурсию"
    [git]="система контроля версий"
    [nano]="простой редактор, есть почти на любом сервере"
    [unzip]="распаковка zip-архивов"
    [htop]="интерактивный монитор процессов и нагрузки"
    [bind9-dnsutils]="dig и nslookup — диагностика DNS"
    [jq]="разбор и фильтрация JSON в шелл-скриптах"
    [software-properties-common]="даёт add-apt-repository для подключения PPA"
    [ca-certificates]="корневые сертификаты, без них не работает HTTPS"
    [gnupg]="проверка подписей пакетов и репозиториев"
    [rsync]="синхронизация файлов и папок, в том числе по SSH"
    [eza]="замена ls: иконки, цвета, дерево каталогов"
    [bat]="замена cat с подсветкой синтаксиса"
    [fd-find]="замена find — проще синтаксис и заметно быстрее"
    [ripgrep]="быстрый поиск по содержимому файлов"
    [zoxide]="«умный» cd, прыгает по часто используемым каталогам"
    [ncdu]="показывает, что именно занимает место на диске"
)

status_basepkgs() {
    local p missing=""
    for p in $BASE_PKGS; do
        pkg_installed "$p" || missing="${missing}${missing:+, }${p}"
    done
    if [ -n "$missing" ]; then
        echo -e "${DIM}○ не хватает: ${missing}${NC}"; return 1
    fi
    echo -e "${GREEN}✓ установлено${NC}"; return 0
}

# ПРО «автозапуск выкл.» ниже: сервис, который пользователь сознательно попросил не
# запускать (см. apply_service_autostart), — это законченное состояние, а не недоделка.
# Если бы он числился «не применён», режим A переспрашивал бы про него при каждом
# прогоне. Само состояние хранит systemd, отдельный файл-состояния не нужен.
status_nginx() {
    if ! pkg_installed nginx-full; then
        echo -e "${DIM}○ не установлен${NC}"; return 1
    fi
    if systemctl is-active nginx &>/dev/null; then
        echo -e "${GREEN}✓ установлен и запущен${NC}"; return 0
    fi
    if [ "$(systemctl is-enabled nginx 2>/dev/null)" = "disabled" ]; then
        echo -e "${GREEN}✓ установлен, автозапуск выкл.${NC}"; return 0
    fi
    echo -e "${YELLOW}! установлен, не запущен${NC}"; return 1
}

status_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${DIM}○ не установлен${NC}"; return 1
    fi
    local ver
    ver="$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)"
    if systemctl is-active docker.service &>/dev/null; then
        echo -e "${GREEN}✓ установлен (${ver})${NC}"; return 0
    fi
    # Демон стоит, но сокет жив — Docker поднимется по первому обращению.
    # Писать тут «автозапуск выкл.» нельзя: это ровно то состояние, в котором
    # оставлял систему прежний «systemctl disable --now docker» (см. service_units)
    if systemctl is-active docker.socket &>/dev/null \
       || [ "$(systemctl is-enabled docker.socket 2>/dev/null)" = "enabled" ]; then
        echo -e "${GREEN}✓ ${ver}, старт по запросу${NC}"; return 0
    fi
    if [ "$(systemctl is-enabled docker.service 2>/dev/null)" = "disabled" ]; then
        echo -e "${GREEN}✓ ${ver}, автозапуск выкл.${NC}"; return 0
    fi
    echo -e "${YELLOW}! ${ver}, не запущен${NC}"; return 1
}

# Cloudflare-плагин без credentials-файла нерабочий, поэтому «токен не задан» —
# отдельное видимое состояние в меню, а не тихая недоделка
CF_CREDENTIALS="/root/.secrets/certbot/cloudflare.ini"

status_certbot() {
    if ! pkg_installed certbot; then
        echo -e "${DIM}○ не установлен${NC}"; return 1
    fi
    local has_nginx=false has_cf=false
    pkg_installed python3-certbot-nginx && has_nginx=true
    pkg_installed python3-certbot-dns-cloudflare && has_cf=true

    if [ "$has_cf" = true ] && [ ! -s "$CF_CREDENTIALS" ]; then
        echo -e "${YELLOW}! токен CF не задан${NC}"; return 1
    fi
    # Файл на месте, но читается кем угодно — по сути тот же «не готово»:
    # certbot будет ругаться в лог, а токен от DNS-зоны лежит открытым.
    # Возврат 1 не косметика: пункт снова считается неприменённым, попадает
    # в режим A и в повторном прогоне права чинятся
    if [ "$has_cf" = true ] && cf_creds_world_readable; then
        echo -e "${YELLOW}! права токена CF: ${REPLY_CF_MODE}${NC}"; return 1
    fi
    if [ "$has_nginx" = false ] && [ "$has_cf" = false ]; then
        echo -e "${YELLOW}! без плагинов${NC}"; return 1
    fi
    # Отсутствие CF раньше было видно только по тому, чего в строке НЕТ, —
    # зелёная галочка при этом читалась как «всё стоит». Пишем прямо.
    # Цвет остаётся зелёным: wildcard нужен не всем, и делать пункт вечно
    # жёлтым (а значит и вечно «не применённым» для режима A) было бы враньём
    # в другую сторону.
    local plugins=""
    [ "$has_nginx" = true ] && plugins="nginx"
    if [ "$has_cf" = true ]; then
        plugins="${plugins}${plugins:+, }CF"
    else
        plugins="${plugins}${plugins:+, }без CF"
    fi
    echo -e "${GREEN}✓ certbot + ${plugins}${NC}"; return 0
}

status_fastfetch() {
    if ! command -v fastfetch &>/dev/null; then
        echo -e "${DIM}○ не установлен${NC}"; return 1
    fi
    local v lowest
    v="$(fastfetch --version | grep -oP '\d+\.\d+\.\d+' | head -n1)"
    lowest="$(printf '%s\n%s\n' "$v" "2.64.0" | sort -V | head -n1)"
    if [ "$lowest" != "2.64.0" ]; then
        echo -e "${YELLOW}! ${v} (нужна >= 2.64.0)${NC}"; return 1
    fi
    if [ ! -f "${TARGET_HOME}/.config/fastfetch/config.jsonc" ]; then
        echo -e "${YELLOW}! ${v}, конфига нет${NC}"; return 1
    fi
    echo -e "${GREEN}✓ ${v}${NC}"; return 0
}

status_tmux() {
    if command -v tmux &>/dev/null; then
        if [ -f "${TARGET_HOME}/.tmux.conf" ]; then
            echo -e "${GREEN}✓ установлен + конфиг${NC}"; return 0
        else
            echo -e "${YELLOW}! установлен, конфига нет${NC}"; return 1
        fi
    else
        echo -e "${DIM}○ не установлен${NC}"; return 1
    fi
}

status_dockerlog() {
    if ! command -v docker &>/dev/null; then
        echo -e "${DIM}— (нужен Docker)${NC}"; return 1
    fi
    if [ -f /etc/docker/daemon.json ] && python3 -c "
import json,sys
try:
    d=json.load(open('/etc/docker/daemon.json'))
    sys.exit(0 if d.get('log-opts',{}).get('max-size')=='10m' else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
        echo -e "${GREEN}✓ настроено (max-size=10m)${NC}"; return 0
    else
        echo -e "${DIM}○ не настроено${NC}"; return 1
    fi
}

status_fail2ban() {
    systemctl is-active fail2ban &>/dev/null \
        && { echo -e "${GREEN}✓ запущен${NC}"; return 0; } \
        || { echo -e "${DIM}○ не запущен${NC}"; return 1; }
}

status_unattended() {
    if [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
        echo -e "${GREEN}✓ включено${NC}"; return 0
    else
        echo -e "${DIM}○ выключено${NC}"; return 1
    fi
}

status_zram() {
    local zram_ok=false swap_ok=false
    local n t s u p
    while read -r n t s u p; do
        case "$n" in
            /dev/zram*) [ "$p" = "100" ] && zram_ok=true ;;
            *)          [ "$p" = "10" ] && swap_ok=true ;;
        esac
    done < <(swapon --show --noheadings --raw 2>/dev/null)
    if [ "$zram_ok" = true ] && [ "$swap_ok" = true ]; then
        echo -e "${GREEN}✓ настроено${NC}"; return 0
    elif [ "$zram_ok" = true ] || [ "$swap_ok" = true ]; then
        echo -e "${YELLOW}! настроено частично${NC}"; return 1
    else
        echo -e "${DIM}○ не настроено${NC}"; return 1
    fi
}

status_sshhardening() {
    if [ ! -f /etc/ssh/sshd_config.d/10-hardening.conf ]; then
        # под прямым root пункт неприменим в принципе (нужен отдельный пользователь) —
        # честнее сказать это сразу, чем показывать «не применено» и молчать о причине
        if [ "$TARGET_USER" = "root" ]; then
            echo -e "${DIM}— нужен обычный пользователь${NC}"; return 1
        fi
        echo -e "${DIM}○ не применено${NC}"; return 1
    fi
    if [ "$SSHD_PASSWORDAUTH" = "no" ]; then
        echo -e "${GREEN}✓ применено (пароль выключен)${NC}"; return 0
    fi
    echo -e "${YELLOW}! конфиг есть, но passwordauthentication=${SSHD_PASSWORDAUTH:-?}${NC}"; return 1
}

status_ufw() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep "Status: active" >/dev/null; then
        echo -e "${GREEN}✓ включён${NC}"; return 0
    else
        echo -e "${DIM}○ выключен${NC}"; return 1
    fi
}
