#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  vps-setup — команда: usfc
#  Menu-driven: CLI tools + Docker + zram/swap + fastfetch + starship
#  + hardening (fail2ban, unattended-upgrades, docker log rotation,
#    tmux, SSH key-only hardening (self-testing), UFW)
#  + self-update on every run
#  https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration
# ═══════════════════════════════════════════════════════════════
set -uo pipefail
# ПРИМЕЧАНИЕ: сознательно без -e — это интерактивное меню, которое
# живёт много действий подряд; одна упавшая подкоманда не должна
# убивать всю сессию, только то конкретное действие.

# Ассоциативные массивы (кэши пакетов/статусов/рамок) — bash 4+.
# Ubuntu везде даёт bash 5, но если скрипт запустили через `sh setup.sh`
# или на экзотике, лучше сказать это прямо, чем сыпать «declare -A: invalid option»
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "Нужен bash 4 или новее. Запуск: bash $0" >&2
    exit 1
fi

# C.UTF-8 встроена в glibc и не требует locale-gen — в отличие от ru_RU.UTF-8/en_US.UTF-8,
# которые на свежих VPS-образах часто объявлены, но не собраны. Именно из-за такого
# полусломанного locale раньше приходилось считать длину строк через python3: ${#s} мерил
# байты вместо символов, а tr резал многобайтовый "─" на мусор. Фиксируем окружение один
# раз здесь — и вся отрисовка живёт на чистом bash.
if [ -z "${USFC_KEEP_LOCALE:-}" ] && locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8
fi

# Считает ли ${#s} символы (а не байты) — определяем один раз, дальше это
# горячий путь отрисовки меню, там не до проверок
_probe='─'
if [ "${#_probe}" -eq 1 ]; then CHARLEN_NATIVE=true; else CHARLEN_NATIVE=false; fi
unset _probe

REPO_RAW_BASE="https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/src"

# ── Цвета ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Цвет выключается, если пользователь об этом попросил или если его некому
# увидеть. Три общепринятых условия (no-color.org и clig.dev: «Disable color if
# your program is not in a terminal or the user requested it»):
#   * NO_COLOR непустая — значение неважно, важен сам факт;
#   * TERM=dumb — терминал не умеет управляющие последовательности;
#   * stdout не терминал — вывод уехал в файл или в пайп, escape-коды там мусор.
# Разметка от этого не ломается: visible_len/pad_title корректно считают длину
# при пустых цветовых переменных, это покрыто тестами.
if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ] || [ ! -t 1 ]; then
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BLUE=''; MAGENTA=''
    BOLD=''; DIM=''; NC=''
    USFC_NO_COLOR=true
else
    USFC_NO_COLOR=false
fi

log_info()    { echo -e "  ${CYAN}[i]${NC} ${1:-}"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} ${1:-}"; }
log_warn()    { echo -e "  ${YELLOW}[!]${NC} ${1:-}" >&2; }
log_error()   { echo -e "  ${RED}[✗]${NC} ${1:-}" >&2; }

# на Ubuntu 24.04+ needrestart может всплыть интерактивным диалогом посреди
# apt-get install и подвесить безголовый скрипт — глушим заранее
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

BULK_MODE=false
ZRAM_BULK_PERCENT=""
SWAP_BULK_MB=""

# Состояние свопа — заполняется read_swap_state(). Объявлены здесь, чтобы
# обращение к ним до первого вызова не роняло скрипт из-за `set -u`
ZRAM_ACTIVE=false; ZRAM_PRIO=""
SWAP_ACTIVE=false; SWAP_PRIO=""; SWAP_PATH=""
SWAP_TYPE=""; SWAP_SIZE_MB=0; SWAP_USED_MB=0

# ═══════════════════════════════════════════════════════════════
# Лог и запуск длинных команд
# ═══════════════════════════════════════════════════════════════
# Сырой вывод apt/curl/systemctl всегда уезжает в файл, а на экране остаётся одна
# живая строка со спиннером. Лог обязателен: без него сворачивание вывода
# превратило бы любую неудачную установку в неотлаживаемую.
USFC_LOG="/var/log/usfc.log"
USFC_LOG_MAX=5242880   # 5 МБ, дальше — ротация в .1
USFC_VERBOSE="${USFC_VERBOSE:-}"

log_init() {
    local size
    size="$(stat -c %s "$USFC_LOG" 2>/dev/null)" || size=0
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    [ "$size" -gt "$USFC_LOG_MAX" ] && mv -f "$USFC_LOG" "${USFC_LOG}.1" 2>/dev/null
    if ! touch "$USFC_LOG" 2>/dev/null; then
        # некуда писать (только чтение / нет прав) — не падаем, просто теряем лог
        USFC_LOG="/dev/null"
        return
    fi
    chmod 640 "$USFC_LOG" 2>/dev/null
    chgrp adm "$USFC_LOG" 2>/dev/null
    printf '\n===== %s  usfc %s  пользователь=%s =====\n' \
        "$(date '+%F %T')" "${VERSION:-?}" "${TARGET_USER:-?}" >> "$USFC_LOG"
}

# брайлевские кадры красивее, но при несобранном locale порежутся на мусорные
# байты — там честнее обычная ASCII-вертушка
if [ "$CHARLEN_NATIVE" = true ]; then
    SPINNER_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; SPINNER_N=10
else
    SPINNER_FRAMES='|/-\'; SPINNER_N=4
fi

# Текущее время в секундах → REPLY_NOW.
# Специально НЕ через магическую переменную SECONDS: её присваивание глобально
# сбрасывает счётчик, и вложенный замер (run_logged внутри пункта) обнулял бы
# внешний замер этого пункта — в сводке получались отрицательные секунды.
# EPOCHSECONDS есть в bash 5 и не стоит ни одного форка; date — запасной путь.
REPLY_NOW=0
now_s() {
    if [ -n "${EPOCHSECONDS:-}" ]; then
        REPLY_NOW="$EPOCHSECONDS"
    else
        REPLY_NOW="$(date +%s)"
    fi
}

RUN_LOGGED_PID=''
CURSOR_HIDDEN=false
# курсор возвращаем в любом случае — иначе Ctrl-C посреди установки оставит
# пользователя в терминале без курсора. Но только если мы его реально прятали:
# безусловный tput cnorm подмешивал управляющие последовательности в вывод
# даже при обычном выходе из меню, в том числе при перенаправлении в файл
cleanup_spinner() {
    [ -n "$RUN_LOGGED_PID" ] && kill "$RUN_LOGGED_PID" 2>/dev/null
    RUN_LOGGED_PID=''
    if [ "$CURSOR_HIDDEN" = true ]; then
        tput cnorm 2>/dev/null
        CURSOR_HIDDEN=false
    fi
}

_spin_wait() {
    local pid="$1" desc="$2" started="$3" i=0 frame
    tput civis 2>/dev/null && CURSOR_HIDDEN=true
    while kill -0 "$pid" 2>/dev/null; do
        frame="${SPINNER_FRAMES:$((i % SPINNER_N)):1}"
        now_s
        printf '\r  %b %s...  %ss ' "${CYAN}${frame}${NC}" "$desc" "$((REPLY_NOW - started))"
        i=$((i + 1))
        sleep 0.15
    done
    if [ "$CURSOR_HIDDEN" = true ]; then
        tput cnorm 2>/dev/null
        CURSOR_HIDDEN=false
    fi
    printf '\r%*s\r' "$((TERM_W + 6))" ''
}

# best-effort статистика из вывода apt → REPLY_STATS. Локаль форсирована в C.UTF-8,
# так что строки apt английские и предсказуемые; не распарсилось — молча опускаем
REPLY_STATS=''
_apt_stats_since() {
    REPLY_STATS=''
    local offset="$1" line pkgs='' size=''
    while IFS= read -r line; do
        if [[ "$line" =~ ([0-9]+)\ upgraded,\ ([0-9]+)\ newly\ installed ]]; then
            pkgs=$(( BASH_REMATCH[1] + BASH_REMATCH[2] ))
        elif [[ "$line" =~ ^Need\ to\ get\ ([0-9.,]+\ [kMG]?B) ]]; then
            size="${BASH_REMATCH[1]}"
        fi
    done < <(tail -c "+$((offset + 1))" "$USFC_LOG" 2>/dev/null)
    [ -n "$pkgs" ] && [ "$pkgs" -gt 0 ] && REPLY_STATS="${pkgs} пакет(ов)"
    [ -n "$size" ] && REPLY_STATS="${REPLY_STATS}${REPLY_STATS:+, }${size}"
}

# run_logged "<описание>" команда аргументы... — выполняет команду, пряча её вывод
# в лог и показывая одну строку со спиннером. Возвращает код возврата команды.
# ВАЖНО: только для НЕинтерактивных команд — спиннер затрёт любой вопрос.
run_logged() {
    local desc="${1:-Выполнение}"; shift
    [ "$#" -eq 0 ] && return 0

    local offset
    offset="$(stat -c %s "$USFC_LOG" 2>/dev/null)" || offset=0
    [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
    printf '\n--- %s $ %s\n' "$(date '+%F %T')" "$*" >> "$USFC_LOG"

    local rc elapsed started
    now_s; started="$REPLY_NOW"
    # stdin у команды всегда /dev/null: это заведомо неинтерактивные вызовы, а без
    # закрытого stdin фоновый apt способен вычитать ввод, предназначенный
    # следующему вопросу скрипта, и вопрос молча «проскочит»
    if [ -n "$USFC_VERBOSE" ] || [ ! -t 1 ]; then
        # verbose или вывод не в терминал (перенаправление в файл, CI) — спиннер
        # там бесполезен и только насорит управляющими последовательностями
        "$@" </dev/null 2>&1 | tee -a "$USFC_LOG"
        rc="${PIPESTATUS[0]}"
    else
        "$@" </dev/null >> "$USFC_LOG" 2>&1 &
        RUN_LOGGED_PID=$!
        _spin_wait "$RUN_LOGGED_PID" "$desc" "$started"
        wait "$RUN_LOGGED_PID"; rc=$?
        RUN_LOGGED_PID=''
    fi
    now_s; elapsed=$((REPLY_NOW - started))

    if [ "$rc" -eq 0 ]; then
        _apt_stats_since "$offset"
        local extra="${elapsed}s"
        [ -n "$REPLY_STATS" ] && extra="${REPLY_STATS}, ${elapsed}s"
        log_success "${desc} ${DIM}(${extra})${NC}"
    else
        log_error "${desc} — не удалось (код ${rc}, ${elapsed}s)"
        echo -e "  ${DIM}последние строки вывода:${NC}"
        tail -c "+$((offset + 1))" "$USFC_LOG" 2>/dev/null | tail -n 20 | sed 's/^/      /'
        log_info "полный лог: ${USFC_LOG}"
    fi
    return "$rc"
}

ask_yn() {
    local question="${1:-}" default="${2:-Y}" reply prompt
    if [ "$BULK_MODE" = true ]; then
        [ "$default" = "Y" ] && return 0 || return 1
    fi
    if [ "$default" = "Y" ]; then prompt="[Y/n]"; else prompt="[y/N]"; fi
    echo -en "  ${BOLD}${question}${NC} ${DIM}${prompt}:${NC} "
    read -r reply </dev/tty
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

# ask_value question default — как ask_yn, но для чисел; печатает результат
# в stdout (нужно вызывать через командную подстановку), весь интерактив — в stderr
ask_value() {
    local question="${1:-}" default="${2:-}" reply
    if [ "$BULK_MODE" = true ]; then
        echo "$default"
        return
    fi
    echo -en "  ${BOLD}${question}${NC} ${DIM}[${default}]:${NC} " >&2
    read -r reply </dev/tty
    reply="${reply:-$default}"
    if ! [[ "$reply" =~ ^[0-9]+$ ]]; then
        log_warn "Не похоже на число — использую значение по умолчанию (${default})"
        reply="$default"
    fi
    echo "$reply"
}

# ── Шапка ─────────────────────────────────────────────────────────────────────
# Шрифт ANSI Shadow с разрядкой в 4 пробела между буквами. Разрядка — самый
# дешёвый способ сделать логотип крупнее: 45 колонок вместо 33 при той же
# высоте в 6 строк. Шрифты вроде bigmono12 дали бы 12 строк, и экран меню
# (сейчас ~43 строки) перестал бы влезать в стандартный терминал 40x120.
LOGO_LINES=(
'██╗   ██╗    ███████╗    ███████╗     ██████╗'
'██║   ██║    ██╔════╝    ██╔════╝    ██╔════╝'
'██║   ██║    ███████╗    █████╗      ██║     '
'██║   ██║    ╚════██║    ██╔══╝      ██║     '
'╚██████╔╝    ███████║    ██║         ╚██████╗'
' ╚═════╝     ╚══════╝    ╚═╝          ╚═════╝'
)
LOGO_W=45

# Перелив голубой → синий по строкам логотипа. 256-цветные коды поддерживают
# практически все современные терминалы, но если TERM не задан (cron, пайп) или
# палитра беднее — молча откатываемся на ровный CYAN, а не сыпем мусором.
LOGO_COLORS=()
init_logo_colors() {
    local ncolors i ramp=(51 45 39 33 27 21)
    LOGO_COLORS=()
    # цвет выключен целиком (NO_COLOR / не терминал) — никакого градиента,
    # иначе escape-коды полезли бы в файл вопреки просьбе пользователя
    if [ "$USFC_NO_COLOR" = true ]; then
        for i in "${!LOGO_LINES[@]}"; do LOGO_COLORS+=(''); done
        return
    fi
    ncolors="$(tput colors 2>/dev/null)"
    [[ "$ncolors" =~ ^[0-9]+$ ]] || ncolors=8
    for i in "${!LOGO_LINES[@]}"; do
        if [ "$ncolors" -ge 256 ]; then
            LOGO_COLORS+=("\033[38;5;${ramp[$i]}m")
        else
            LOGO_COLORS+=("$CYAN")
        fi
    done
}

# МБ → «1.6 ГБ» / «512 МБ» без внешних процессов
fmt_size_mb() {
    local mb="${1:-0}"
    if [ "$mb" -ge 1024 ]; then
        printf '%d.%d ГБ' "$((mb / 1024))" "$(( (mb % 1024) * 10 / 1024 ))"
    else
        printf '%d МБ' "$mb"
    fi
}

# сводка о машине справа от логотипа → массив HEADER_INFO.
# Всё читается из /proc и /etc — шапка рисуется раз на экран, это дёшево.
# ВАЖНО: /etc/os-release нельзя просто `source` — там есть переменная VERSION,
# которая затрёт версию самого скрипта. Поэтому разбираем построчно.
HEADER_INFO=()
build_header_info() {
    local host os ram_mb free_mb up_s up_txt k v
    host="$(< /proc/sys/kernel/hostname)"
    while IFS='=' read -r k v; do
        [ "$k" = "PRETTY_NAME" ] || continue
        v="${v%\"}"; v="${v#\"}"; os="$v"; break
    done < /etc/os-release 2>/dev/null
    ram_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    [[ "$ram_mb" =~ ^[0-9]+$ ]] || ram_mb=0
    free_mb="$(df -m / 2>/dev/null | awk 'NR==2{print $4}')"
    [[ "$free_mb" =~ ^[0-9]+$ ]] || free_mb=0
    up_s="$(< /proc/uptime)"; up_s="${up_s%%.*}"
    [[ "$up_s" =~ ^[0-9]+$ ]] || up_s=0
    if   [ "$up_s" -ge 86400 ]; then up_txt="$((up_s / 86400)) дн $(( (up_s % 86400) / 3600 )) ч"
    elif [ "$up_s" -ge 3600 ];  then up_txt="$((up_s / 3600)) ч $(( (up_s % 3600) / 60 )) мин"
    else                             up_txt="$((up_s / 60)) мин"
    fi

    HEADER_INFO=(
        "${BOLD}${host}${NC}"
        "${DIM}${os:-Linux}${NC}"
        "${DIM}RAM${NC}    $(fmt_size_mb "$ram_mb")"
        "${DIM}Диск${NC}   $(fmt_size_mb "$free_mb") свободно"
        "${DIM}Uptime${NC} ${up_txt}"
    )
}

# «применено 9 из 14 ██████░░░░» из уже посчитанного кэша статусов — бесплатно.
# Пока кэш не построен (самый первый показ шапки), просто ничего не печатаем.
REPLY_PROGRESS=''
build_progress() {
    REPLY_PROGRESS=''
    [ "${#STATUS_RC[@]}" -eq 0 ] && return 0
    local id done=0 total="${#ITEM_IDS[@]}" cells filled i bar='' ch_full ch_empty
    for id in "${ITEM_IDS[@]}"; do
        [ "${STATUS_RC[$id]:-1}" -eq 0 ] && done=$((done + 1))
    done
    [ "$total" -le 0 ] && return 0
    # ровно 2 ячейки на пункт: деление точное, ошибок округления нет по построению
    cells=$(( total * 2 ))
    filled=$(( done * 2 ))
    # ASCII-фолбэк при небитом locale — "#" и ".", но НЕ "=" и "-": шрифты
    # с лигатурами (FiraCode, JetBrains Mono) склеивают их в стрелки и полосы
    if [ "$CHARLEN_NATIVE" = true ]; then ch_full='█'; ch_empty='░'
    else                                  ch_full='#'; ch_empty='.'
    fi
    for ((i = 0; i < cells; i++)); do
        if [ "$i" -lt "$filled" ]; then bar+="$ch_full"; else bar+="$ch_empty"; fi
    done
    REPLY_PROGRESS="${DIM}применено${NC} ${BOLD}${done}${NC}${DIM} из ${total}${NC}  ${GREEN}${bar:0:filled}${NC}${DIM}${bar:filled}${NC}"
}

show_header() {
    # Очистка экрана осмысленна только в терминале: при перенаправлении в файл
    # или в пайп это просто мусорные управляющие байты в начале вывода
    if [ -t 1 ]; then
        clear 2>/dev/null || printf '\033[2J\033[H'
    fi
    [ "${#LOGO_COLORS[@]}" -eq 0 ] && init_logo_colors

    # сводку показываем, только если она реально помещается рядом с логотипом:
    # 45 колонок логотипа + 3 отступа + ~34 на самую длинную строку сводки
    local with_info=false
    if [ "$TERM_W" -ge 82 ]; then
        with_info=true
        build_header_info
    fi

    echo ""
    local i line info
    for i in "${!LOGO_LINES[@]}"; do
        line="${LOGO_COLORS[$i]}${LOGO_LINES[$i]}${NC}"
        info=""
        [ "$with_info" = true ] && info="${HEADER_INFO[$i]:-}"
        if [ -n "$info" ]; then
            pad_title "${LOGO_LINES[$i]}" "$LOGO_W"
            printf "  %b%s%b   %b\n" "${LOGO_COLORS[$i]}" "$REPLY_PAD" "$NC" "$info"
        else
            echo -e "  ${line}"
        fi
    done

    build_progress
    if [ -n "$REPLY_PROGRESS" ] && [ "$with_info" = true ]; then
        pad_title "USFC v${VERSION} by SkyDeaD" 44
        printf "  ${BOLD}%s${NC}  %b\n" "$REPLY_PAD" "$REPLY_PROGRESS"
    else
        echo -e "  ${BOLD}USFC${NC} ${DIM}v${VERSION} by SkyDeaD${NC}   ${DIM}UbuntuServer Fast Configuration${NC}"
    fi
    hr_heavy "$CYAN"
}

pause() {
    echo ""
    echo -en "  ${DIM}Enter — продолжить...${NC}"
    read -r _ </dev/tty
}

# ── root / целевой пользователь ────────────────────────────────
# root нужен, чтобы что-то ДЕЛАТЬ. Просто загрузить функции (тесты, CI) можно и
# без него — иначе линтер пришлось бы гонять от root на ровном месте
if [ "$(id -u)" -ne 0 ] && [ -z "${USFC_SOURCE_ONLY:-}" ]; then
    echo "Нужны права root: curl -fsSL .../install.sh | sudo bash && source ~/.bashrc" >&2
    exit 1
fi

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
else
    # ОСТОРОЖНО с logname: когда login-сессии нет (консоль хостера на свежей VPS,
    # cloud-init, запуск из systemd-юнита), он печатает "no login name" в stderr
    # и выходит с кодом НОЛЬ. То есть "logname || echo root" не спасает: подстановка
    # молча даёт пустую строку, и дальше скрипт падал на getent с пустым именем —
    # ровно на том сценарии голого root, ради которого всё и затевалось.
    TARGET_USER="$(logname 2>/dev/null)"
fi
# нет имени или такого пользователя не существует — значит login-сессии нет,
# работаем от root: это нормальное состояние свежей виртуалки, а не ошибка
if [ -z "$TARGET_USER" ] || ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    TARGET_USER=root
fi
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    if [ -n "${USFC_SOURCE_ONLY:-}" ]; then
        TARGET_HOME="${HOME:-/root}"
    else
        echo "Не удалось определить домашнюю директорию пользователя $TARGET_USER" >&2
        exit 1
    fi
fi

# sshd -T — не самый быстрый вызов, а нужен он в двух местах (порт при старте и
# passwordauthentication в status_sshhardening, который считается на каждой
# перерисовке меню). Разбираем один раз в глобальные, обновляем только после
# реальной правки конфига в apply_sshhardening()
SSH_PORT=22
SSHD_PASSWORDAUTH=''
refresh_sshd_config() {
    local out key val
    out="$(sshd -T 2>/dev/null)"
    SSH_PORT=''; SSHD_PASSWORDAUTH=''
    while read -r key val _; do
        case "$key" in
            port)                   [ -z "$SSH_PORT" ] && SSH_PORT="$val" ;;
            passwordauthentication) SSHD_PASSWORDAUTH="$val" ;;
        esac
    done <<< "$out"
    [ -z "$SSH_PORT" ] && SSH_PORT=22
}
refresh_sshd_config

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

VERSION="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]')"
[ -z "$VERSION" ] && VERSION="0.0.0"

# ═══════════════════════════════════════════════════════════════
# Автозапуск сервисов
# ═══════════════════════════════════════════════════════════════
# deb-пакеты nginx и docker поднимают сервис сами, из postinst — раньше, чем
# скрипт вообще получит управление. Чтобы «не запускать» означало именно это, а не
# «поднять и тут же погасить» (nginx успел бы занять :80 — а если порт уже занят,
# то и сама установка ругнётся), установка оборачивается в policy-rc.d: штатный
# для Debian способ сказать пакетам «сервисы не трогать».
POLICY_RC_D=/usr/sbin/policy-rc.d
POLICY_RC_D_OURS=false

drop_policy_rc_d() {
    [ "$POLICY_RC_D_OURS" = true ] || return 0
    rm -f "$POLICY_RC_D"
    POLICY_RC_D_OURS=false
}

with_no_service_start() {
    # чужой policy-rc.d не трогаем вообще: он не наш и, возможно, кому-то нужен
    if [ ! -e "$POLICY_RC_D" ]; then
        printf '#!/bin/sh\nexit 101\n' > "$POLICY_RC_D"
        chmod +x "$POLICY_RC_D"
        POLICY_RC_D_OURS=true
    fi
    "$@"
    local rc=$?
    drop_policy_rc_d
    return "$rc"
}

# Забытый policy-rc.d тихо ломает старт сервисов при ЛЮБОЙ будущей apt install
# в системе — поэтому убираем его и при аварийном выходе, не только при штатном
trap 'cleanup_spinner; drop_policy_rc_d' EXIT INT TERM

# Предзаданные ответы для пакетного режима (см. main): пусто — спрашиваем.
# Читаются косвенно, через ${!1} в resolve_autostart — shellcheck этого не видит.
# shellcheck disable=SC2034
NGINX_AUTOSTART=""
# shellcheck disable=SC2034
DOCKER_AUTOSTART=""

# resolve_autostart <имя_переменной> <вопрос> — 0 если запускать, 1 если нет
resolve_autostart() {
    local preset="${!1:-}"
    case "$preset" in
        Y) return 0 ;;
        N) return 1 ;;
    esac
    ask_yn "$2" N
}

apply_service_autostart() {
    local svc="$1" want="$2"
    if [ "$want" = true ]; then
        if systemctl enable --now "$svc" >/dev/null 2>&1; then
            log_success "${svc}: запущен, автозапуск включён"
        else
            log_error "Не удалось запустить ${svc} — подробности: journalctl -u ${svc}"
        fi
    else
        systemctl disable --now "$svc" >/dev/null 2>&1
        log_success "${svc}: установлен, но НЕ запущен (автозапуск выключен)"
        log_info "Запустить позже: ${BOLD}sudo systemctl enable --now ${svc}${NC}"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Кэш установленных пакетов и ленивый apt update
# ═══════════════════════════════════════════════════════════════
# Раньше каждая status_*-функция дёргала `dpkg -s` отдельно на каждый пакет —
# около 25 запусков за одну перерисовку меню, и каждый из них перечитывает
# /var/lib/dpkg/status целиком. Один снимок вместо этого.
# Присваивание =() здесь обязательно, а не косметика: `declare -A x` БЕЗ него
# оставляет переменную «необъявленной» с точки зрения set -u, и первое же
# обращение ${#x[@]} роняет скрипт с «unbound variable». Проверено на bash 5.3.
declare -A PKG_INSTALLED=()
PKG_CACHE_READY=false
refresh_pkg_cache() {
    local pkg state
    PKG_INSTALLED=()
    while read -r pkg state; do
        [ "$state" = "installed" ] && PKG_INSTALLED[$pkg]=1
    done < <(dpkg-query -W -f='${Package} ${db:Status-Status}\n' 2>/dev/null)
    PKG_CACHE_READY=true
}
# сам наполняет кэш, если его ещё не строили: иначе любой вызов до
# refresh_pkg_cache молча отвечал бы «пакет не установлен» на всё подряд
pkg_installed() {
    [ "$PKG_CACHE_READY" = true ] || refresh_pkg_cache
    [ -n "${PKG_INSTALLED[${1}]:-}" ]
}

# ── Отчёт по набору пакетов ───────────────────────────────────────────────────
# Один apt-вызов на десяток пакетов схлопывается в одну строку итога, и из неё
# не видно ни что приехало, ни зачем оно нужно. Снимаем состояние ДО установки,
# после — печатаем по строке на пакет.
declare -A PKG_WAS=()
snapshot_pkgs() {
    PKG_WAS=()
    local p
    for p in "$@"; do
        pkg_installed "$p" && PKG_WAS[$p]=1
    done
}

show_pkg_report() {
    local p name_w=27 desc_w mark color desc
    # 5 — отступ слева и маркер с пробелом; остальное отдаём описанию
    desc_w=$(( TERM_W - 5 - name_w - 1 ))
    [ "$desc_w" -lt 10 ] && desc_w=10
    echo ""
    for p in "$@"; do
        if [ -n "${PKG_WAS[$p]:-}" ]; then
            mark='·'; color="$DIM"
        elif pkg_installed "$p"; then
            mark='+'; color="$GREEN"
        else
            # apt отчитался успехом, но пакета нет — например, имя оказалось
            # виртуальным. Молчать об этом нельзя
            mark='✗'; color="$RED"
        fi
        desc="${PKG_DESC[$p]:-}"
        truncate_colored "$desc" "$desc_w"; desc="$REPLY_TRUNC"
        pad_title "$p" "$name_w"
        printf "     %b%s%b %s${DIM}%s${NC}\n" "$color" "$mark" "$NC" "$REPLY_PAD" "$desc"
    done
    echo -e "     ${GREEN}+${NC}${DIM} — установлен сейчас    ${NC}${DIM}·${NC}${DIM} — уже был в системе${NC}"
}

# ── apt и блокировка dpkg ─────────────────────────────────────────────────────
# На свежезагруженной VPS apt-daily.timer поднимает unattended-upgrades, и тот
# держит /var/lib/dpkg/lock-frontend минутами. По умолчанию apt НЕ ждёт вовсе
# (DPkg::Lock::Timeout пуст, то есть 0) и падает мгновенно с кодом 100 —
# «E: Could not get lock ... It is held by process N (unattended-upgr)».
# Ирония в том, что unattended-upgrades включает сам usfc.
#
# Лечится нативно: apt умеет ждать сам, и оба вида блокировок (frontend и
# archive) — ему, в отличие от нас, не нужно гадать про fuser/flock, которых
# на минимальном образе может не оказаться.
APT_LOCK_TIMEOUT="${USFC_APT_LOCK_TIMEOUT:-300}"
apt_get() { apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" "$@"; }

# Спиннер покажет растущий таймер, но не объяснит, ПОЧЕМУ установка «висит».
# pgrep берём вместо fuser/lsof: procps есть всегда, psmisc и lsof — нет.
APT_BUSY_WARNED=false
warn_if_apt_busy() {
    [ "$APT_BUSY_WARNED" = true ] && return 0
    local holder=""
    if pgrep -x unattended-upgr >/dev/null 2>&1; then
        holder="unattended-upgrades"
    elif pgrep -x apt-get >/dev/null 2>&1 || pgrep -x apt >/dev/null 2>&1; then
        holder="другой apt"
    elif pgrep -x dpkg >/dev/null 2>&1; then
        holder="dpkg"
    fi
    [ -z "$holder" ] && return 0
    APT_BUSY_WARNED=true
    # Формулировка намеренно осторожная: мы видим лишь ЗАПУЩЕННЫЙ процесс, а не
    # то, кто именно держит блокировку. Настоящего держателя назовёт сам apt в
    # логе («Waiting for cache lock: ...»), гадать за него не будем
    log_info "Сейчас работает ${BOLD}${holder}${NC} — он может держать блокировку dpkg"
    log_info "Если так, подожду её освобождения до $((APT_LOCK_TIMEOUT / 60)) мин: для только что загруженного сервера это нормально"
}

# apt-get update больше не висит на старте каждого запуска: списки нужны только
# перед реальной установкой, и только если они успели протухнуть. Открыть меню
# и посмотреть статусы теперь не стоит ни одного сетевого запроса.
APT_UPDATED=false
APT_MAX_AGE=3600
ensure_apt_updated() {
    [ "$APT_UPDATED" = true ] && return 0
    local now mtime age src
    now="$(date +%s)"
    # update-success-stamp честнее mtime каталога: он отражает именно успешный
    # update, а не любое касание /var/lib/apt/lists
    if [ -f /var/lib/apt/periodic/update-success-stamp ]; then
        src=/var/lib/apt/periodic/update-success-stamp
    else
        src=/var/lib/apt/lists
    fi
    mtime="$(stat -c %Y "$src" 2>/dev/null)" || mtime=0
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    age=$(( now - mtime ))
    if [ "$mtime" -gt 0 ] && [ "$age" -lt "$APT_MAX_AGE" ]; then
        APT_UPDATED=true
        return 0
    fi
    warn_if_apt_busy
    run_logged "Обновление списков пакетов apt" apt_get update -qq
    APT_UPDATED=true
    refresh_pkg_cache
}

# ═══════════════════════════════════════════════════════════════
# Самообновление — сверяется при каждом запуске
# ═══════════════════════════════════════════════════════════════
# Проверка обязательна на КАЖДОМ запуске, кэша по времени тут нет специально.
# Ускорение достигается иначе: curl уходит в фон первой же строкой main(), пока
# считается кэш пакетов и статусы. Итоговая цена — max(сеть, локальная работа),
# а не их сумма, как было раньше.
UPDATE_CHECK_FILE=""
UPDATE_CHECK_PID=""

start_update_check() {
    [ -n "${USFC_NO_UPDATE:-}" ] && return 0
    UPDATE_CHECK_FILE="$(mktemp)"
    curl -fsSL --max-time 5 "${REPO_RAW_BASE}/VERSION" -o "$UPDATE_CHECK_FILE" 2>/dev/null &
    UPDATE_CHECK_PID=$!
}

check_for_update() {
    if [ -n "${USFC_NO_UPDATE:-}" ]; then
        log_info "Проверка обновлений отключена (--no-update)"
        return 1
    fi

    local remote_version=""
    if [ -n "$UPDATE_CHECK_PID" ]; then
        wait "$UPDATE_CHECK_PID" 2>/dev/null
        UPDATE_CHECK_PID=""
        remote_version="$(tr -d '[:space:]' < "$UPDATE_CHECK_FILE" 2>/dev/null)"
        rm -f "$UPDATE_CHECK_FILE"
    fi

    if [ -z "$remote_version" ]; then
        log_warn "Не удалось проверить обновления (нет сети или файла VERSION в репо)"
        return 0
    fi

    if [ "$remote_version" = "$VERSION" ]; then
        return 1
    fi

    # sort -V — версии сравниваются по-настоящему (4.2.0 > 4.1.1), а не строковым "!="
    local newest
    newest="$(printf '%s\n%s\n' "$VERSION" "$remote_version" | sort -V | tail -n1)"
    if [ "$newest" = "$VERSION" ]; then
        # локальная версия уже новее (или равна) той, что в репозитории — предлагать
        # "обновиться" на более старую значило бы откатывать себя назад молча
        return 1
    fi

    log_info "Доступна новая версия: ${BOLD}${remote_version}${NC} ${DIM}(у вас ${VERSION})${NC}"
    if ask_yn "Обновить usfc до ${remote_version} сейчас?"; then
        local tmp
        tmp="$(mktemp)"
        if curl -fsSL "${REPO_RAW_BASE}/setup.sh" -o "$tmp"; then
            if bash -n "$tmp" 2>/dev/null; then
                cp "$tmp" "$SCRIPT_PATH"
                chmod +x "$SCRIPT_PATH"
                rm -f "$tmp"
                printf '%s' "$remote_version" > "${SCRIPT_DIR}/VERSION"
                log_success "Обновлено до ${remote_version}, перезапускаю..."
                exec "$SCRIPT_PATH"
            else
                log_error "Новая версия не прошла проверку синтаксиса (bash -n) — не обновляю, остаюсь на ${VERSION}"
                rm -f "$tmp"
            fi
        else
            log_error "Не удалось скачать новую версию — остаюсь на ${VERSION}"
            rm -f "$tmp"
        fi
    fi
    return 0
}

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
    if systemctl is-active docker &>/dev/null; then
        echo -e "${GREEN}✓ установлен (${ver})${NC}"; return 0
    fi
    if [ "$(systemctl is-enabled docker 2>/dev/null)" = "disabled" ]; then
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
    if [ "$has_nginx" = false ] && [ "$has_cf" = false ]; then
        echo -e "${YELLOW}! без плагинов${NC}"; return 1
    fi
    local plugins=""
    [ "$has_nginx" = true ] && plugins="nginx"
    [ "$has_cf" = true ] && plugins="${plugins}${plugins:+,}CF"
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
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "${GREEN}✓ включён${NC}"; return 0
    else
        echo -e "${DIM}○ выключен${NC}"; return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# APPLY-функции
# ═══════════════════════════════════════════════════════════════
# usfc-обёртка — не отдельный пункт меню, ставится сама при первом запуске,
# свой маркер, идемпотентно. Пропускаем для прямого root — sudo тут бесполезен
# (и может быть даже не установлен на такой машине); зато сразу после создания
# пользователя (switch_target_user) она ставится уже ему.
# Это bash-ФУНКЦИЯ, а не alias: после того как дочерний sudo-процесс меню
# завершится, функция сама делает "source ~/.bashrc" — но уже в ТЕКУЩЕЙ
# интерактивной оболочке (функции выполняются в вызывающем шелле, не в
# подпроцессе), так что новые алиасы/промпт подхватываются без ручного
# source и без переподключения. USFC_RESOURCE гейтит fastfetch-автозапуск
# (см. apply_fastfetch) — иначе баннер печатался бы второй раз при каждом
# выходе из меню.
install_usfc_wrapper() {
    [ "$TARGET_USER" = "root" ] && return 0
    local bashrc="${TARGET_HOME}/.bashrc" need_block=false
    if grep -qF "# >>> vps-setup:self >>>" "$bashrc" 2>/dev/null; then
        if grep -qF "alias usfc='sudo usfc'" "$bashrc" 2>/dev/null; then
            sed -i '/# >>> vps-setup:self >>>/,/# <<< vps-setup:self <<</d' "$bashrc"
            need_block=true
        fi
    else
        need_block=true
    fi
    [ "$need_block" = false ] && return 0
    cat >> "$bashrc" <<'EOF'

# >>> vps-setup:self >>>
usfc() {
    sudo /usr/local/bin/usfc "$@"
    USFC_RESOURCE=1 source ~/.bashrc 2>/dev/null
    unset USFC_RESOURCE
}
# <<< vps-setup:self <<<
EOF
    chown "${TARGET_USER}:$(id -g "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$bashrc" 2>/dev/null
}

# Совет перезайти под новым пользователем — печатается и сразу, и ещё раз при
# выходе из меню, чтобы не потерялся за выводом последующих установок
RELOGIN_HINT_USER=""
ROOT_PROMPT_SHOWN=false

# переключает весь дальнейший контекст скрипта на нового пользователя: всё, что
# ставится дальше (алиасы, fastfetch, tmux, starship), должно лечь ЕМУ, а не в
# /root, откуда оно исчезнет из виду сразу после перелогина
switch_target_user() {
    local user="$1" home
    home="$(getent passwd "$user" | cut -d: -f6)"
    if [ -z "$home" ] || [ ! -d "$home" ]; then
        log_error "Не удалось определить домашний каталог ${user} — контекст не переключаю"
        return 1
    fi
    TARGET_USER="$user"
    TARGET_HOME="$home"
    install_usfc_wrapper
    invalidate_statuses
    RELOGIN_HINT_USER="$user"
    log_info "Дальнейшие настройки применяются к ${BOLD}${user}${NC} ${DIM}(${home})${NC}"
}

print_relogin_hint() {
    [ -z "$RELOGIN_HINT_USER" ] && return 0
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo ""
    log_warn "Разлогинься и подключись уже под новым пользователем:"
    echo -e "      ${BOLD}ssh ${RELOGIN_HINT_USER}@${ip:-<ip-сервера>}${NC}"
    log_info "Дальше просто ${BOLD}usfc${NC} — sudo писать не нужно"
}

apply_newuser() {
    if [ "$BULK_MODE" = true ]; then
        log_warn "Создание пользователя требует ввода имени и пароля — пропущено в пакетном режиме."
        log_warn "Настройте отдельно пунктом $(item_number newuser)."
        return
    fi
    if [ "$TARGET_USER" != "root" ]; then
        log_info "Скрипт уже работает от имени ${TARGET_USER} — отдельный пользователь не нужен"
        if ! ask_yn "Всё равно создать ещё одного пользователя с sudo?" N; then return; fi
    fi

    # на совсем минимальных образах sudo может отсутствовать — без него
    # «добавить в группу sudo» превратилось бы в бессмысленный жест
    if ! command -v sudo &>/dev/null || ! getent group sudo &>/dev/null; then
        log_info "sudo не установлен — ставлю (без него группа sudo ничего не даёт)"
        ensure_apt_updated
        run_logged "sudo" apt_get install -y sudo || return 1
        refresh_pkg_cache
    fi

    # ── имя ───────────────────────────────────────────────────────────────────
    local name="" attempt=0 existing=false
    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        echo -en "  ${BOLD}Имя нового пользователя${NC} ${DIM}(латиница, начиная с буквы):${NC} "
        read -r name </dev/tty
        if [ -z "$name" ]; then
            log_error "Пустое имя"; name=""; continue
        fi
        if [[ ! "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            log_error "Недопустимое имя «${name}» — только строчные латинские буквы, цифры, _ и -, начиная с буквы"
            name=""; continue
        fi
        if id -u "$name" &>/dev/null; then
            log_warn "Пользователь ${name} уже существует"
            if ask_yn "Использовать его и просто добавить в группу sudo?" N; then
                existing=true
                break
            fi
            name=""; continue
        fi
        break
    done
    if [ -z "$name" ]; then
        log_error "Имя так и не задано — пользователь не создан"
        return 1
    fi

    # ── ключи из /root: без них новый пользователь просто не сможет зайти ─────
    # решаем это ДО пароля: пустой пароль допустим, только если ключ реально есть
    local key_ok=false
    if [ "$existing" = false ]; then
        useradd -m -s /bin/bash "$name" || { log_error "Не удалось создать пользователя"; return 1; }
        log_success "Пользователь ${name} создан"
    fi

    ensure_ssh_dir "$name" "$(getent passwd "$name" | cut -d: -f6)" || {
        log_error "Не удалось подготовить ~/.ssh для ${name}"; return 1; }
    local auth_keys="$REPLY_AUTHKEYS"
    [ -s "$auth_keys" ] && key_ok=true

    local root_keys="/root/.ssh/authorized_keys" n_keys=0
    if [ -s "$root_keys" ]; then
        n_keys="$(grep -c '^ssh-\|^ecdsa-\|^sk-' "$root_keys" 2>/dev/null || echo 0)"
        log_info "В /root/.ssh/authorized_keys найдено ключей: ${n_keys}"
        log_warn "Если ты заходишь на сервер по ключу — без копирования ${name} не сможет войти вообще"
        if ask_yn "Скопировать эти ключи для ${name}?" Y; then
            local line copied=0
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                grep -qxF "$line" "$auth_keys" 2>/dev/null && continue
                echo "$line" >> "$auth_keys"
                copied=$((copied + 1))
            done < "$root_keys"
            log_success "Скопировано ключей: ${copied}"
            [ -s "$auth_keys" ] && key_ok=true
        fi
    fi
    if ask_yn "Добавить ещё один публичный ключ вручную?" N; then
        add_pubkey_interactive "$auth_keys" && key_ok=true
    fi
    # права могли уехать после дозаписи от root
    local gid; gid="$(id -g "$name" 2>/dev/null || echo "$name")"
    chown "${name}:${gid}" "$auth_keys" 2>/dev/null
    chmod 600 "$auth_keys" 2>/dev/null

    # ── пароль ────────────────────────────────────────────────────────────────
    local pw1 pw2 pw_set=false
    attempt=0
    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        echo -en "  ${BOLD}Пароль для ${name}${NC} ${DIM}(Enter — без пароля, вход только по ключу):${NC} "
        read -rs pw1 </dev/tty; echo ""
        if [ -z "$pw1" ]; then
            if [ "$key_ok" = true ]; then
                passwd -l "$name" >/dev/null 2>&1
                log_success "Пароль не задан и заблокирован — вход только по SSH-ключу"
                pw_set=true
                break
            fi
            log_error "Ни пароля, ни ключей — так пользователь не сможет войти вообще. Задай пароль."
            continue
        fi
        echo -en "  ${BOLD}Повтори пароль:${NC} "
        read -rs pw2 </dev/tty; echo ""
        if [ "$pw1" != "$pw2" ]; then
            log_error "Пароли не совпали"
            continue
        fi
        [ "${#pw1}" -lt 8 ] && log_warn "Пароль короче 8 символов — на сервере, смотрящем в интернет, это слабо"
        if printf '%s:%s\n' "$name" "$pw1" | chpasswd; then
            log_success "Пароль установлен"
            pw_set=true
        else
            log_error "Не удалось установить пароль"
        fi
        break
    done
    unset pw1 pw2
    if [ "$pw_set" = false ] && [ "$key_ok" = false ]; then
        log_error "У ${name} нет ни пароля, ни ключа — зайти под ним будет невозможно"
        log_warn "Задай пароль вручную: sudo passwd ${name}"
    fi

    # ── sudo ──────────────────────────────────────────────────────────────────
    if usermod -aG sudo "$name"; then
        log_success "Пользователь ${name} добавлен в группу sudo"
    else
        log_error "Не удалось добавить ${name} в группу sudo"
        return 1
    fi

    invalidate_statuses
    switch_target_user "$name"
    print_relogin_hint
}

apply_cli() {
    local need_install=false p
    for p in $CLI_PKGS; do
        pkg_installed "$p" || need_install=true
    done
    command -v starship &>/dev/null || need_install=true

    if [ "$need_install" = true ]; then
        if ask_yn "Установить ${CLI_PKGS// /, }, starship?"; then
            ensure_apt_updated
            # shellcheck disable=SC2086
            snapshot_pkgs $CLI_PKGS
            # shellcheck disable=SC2086
            run_logged "CLI-утилиты (${CLI_PKGS// /, })" apt_get install -y $CLI_PKGS
            refresh_pkg_cache
            if ! command -v starship &>/dev/null; then
                run_logged "starship" bash -c 'curl -sS https://starship.rs/install.sh | sh -s -- -y'
            fi
            # shellcheck disable=SC2086
            show_pkg_report $CLI_PKGS
        fi
    else
        log_success "eza/bat/fd/ripgrep/zoxide/ncdu/starship уже установлены"
    fi

    # алиасы и промпт пишем сразу следом — не отдельным пунктом меню, но только если
    # утилиты реально стоят: если пользователь отказался ставить или apt не смог,
    # алиасы на несуществующие eza/batcat сломают ls/cat в следующей сессии
    if ! command -v eza &>/dev/null && ! command -v batcat &>/dev/null; then
        log_warn "eza/batcat не установлены — алиасы в .bashrc не пишу"
        return
    fi
    local BASHRC="${TARGET_HOME}/.bashrc"
    if grep -qF "# >>> vps-setup:cli >>>" "$BASHRC" 2>/dev/null; then
        log_info "Алиасы CLI-утилит в .bashrc уже есть"
    else
        cat >> "$BASHRC" <<EOF

# >>> vps-setup:cli >>>
alias ls='eza --icons --group-directories-first -1 --long --no-permissions --no-user --no-time'
alias ll='eza -lah --icons --group-directories-first'
alias la='eza -a --icons --group-directories-first -1 --long --no-permissions --no-user --no-time'
alias lt='eza --tree --icons --level=2 --group-directories-first'
alias cat='batcat --paging=never'
alias catp='batcat'
alias scat='sudo batcat --paging=never'
alias fd='fdfind'
command -v zoxide &>/dev/null && eval "\$(zoxide init bash)"
command -v starship &>/dev/null && eval "\$(starship init bash)"
# <<< vps-setup:cli <<<
EOF
        chown "${TARGET_USER}:${TARGET_USER}" "$BASHRC"
        log_success "Алиасы добавлены в .bashrc"
    fi
}

apply_basepkgs() {
    if ask_yn "Установить базовый набор пакетов (${BASE_PKGS})?"; then
        ensure_apt_updated
        # shellcheck disable=SC2086
        snapshot_pkgs $BASE_PKGS
        # shellcheck disable=SC2086
        run_logged "Базовый набор пакетов" apt_get install -y $BASE_PKGS
        refresh_pkg_cache
        # shellcheck disable=SC2086
        show_pkg_report $BASE_PKGS
    fi
}

apply_nginx() {
    if ! pkg_installed nginx-full; then
        if ! ask_yn "Установить nginx-full?"; then return; fi
        # спрашиваем ДО установки: ответ решает, дать ли postinst поднять сервис
        local autostart=false
        resolve_autostart NGINX_AUTOSTART "Запустить nginx и включить автозапуск?" && autostart=true
        ensure_apt_updated
        with_no_service_start run_logged "nginx-full" apt_get install -y nginx-full || return 1
        refresh_pkg_cache
        apply_service_autostart nginx "$autostart"
        return
    fi

    log_info "nginx-full уже установлен"
    local enabled active
    enabled="$(systemctl is-enabled nginx 2>/dev/null)"
    active="$(systemctl is-active nginx 2>/dev/null)"
    if [ "$active" = "active" ]; then
        log_success "nginx запущен ${DIM}(автозапуск: ${enabled:-?})${NC}"
        if [ "$enabled" != "enabled" ] && ask_yn "Включить автозапуск nginx при загрузке?" N; then
            systemctl enable nginx >/dev/null 2>&1 && log_success "Автозапуск включён"
        fi
    elif ask_yn "nginx не запущен. Запустить и включить автозапуск?" N; then
        apply_service_autostart nginx true
    else
        log_info "Оставляю nginx выключенным"
    fi
}

apply_certbot() {
    ensure_apt_updated
    if ! pkg_installed certbot; then
        if ! ask_yn "Установить certbot (Let's Encrypt)?"; then return; fi
        run_logged "certbot" apt_get install -y certbot || return 1
        refresh_pkg_cache
    else
        log_info "certbot уже установлен: $(certbot --version 2>&1 | head -n1)"
    fi

    # ── плагин nginx (HTTP-01) ────────────────────────────────────────────────
    if pkg_installed python3-certbot-nginx; then
        log_success "Плагин nginx уже установлен"
    elif ! pkg_installed nginx-full; then
        log_info "nginx не установлен — плагин nginx пропускаю (поставь nginx и вернись сюда)"
    elif ask_yn "Установить плагин nginx (HTTP-01, обычные сертификаты)?"; then
        run_logged "python3-certbot-nginx" apt_get install -y python3-certbot-nginx && refresh_pkg_cache
    fi

    # ── плагин Cloudflare (DNS-01) ────────────────────────────────────────────
    local want_cf=false
    if pkg_installed python3-certbot-dns-cloudflare; then
        want_cf=true
        log_success "Плагин Cloudflare уже установлен"
    elif ask_yn "Установить плагин Cloudflare (DNS-01, нужен для wildcard-сертификатов)?" N; then
        if run_logged "python3-certbot-dns-cloudflare" apt_get install -y python3-certbot-dns-cloudflare; then
            refresh_pkg_cache
            want_cf=true
            # apt тянет python3-cloudflare 2.20.x — единственную версию в архиве.
            # Она печатает большой WARNING про «апгрейд без пиннинга»: срабатывает
            # в конструкторе клиента (CloudFlare/cloudflare.py), то есть при
            # РЕАЛЬНОМ выпуске сертификата, а не при установке. Заглушить нельзя —
            # warn_warning_2_20() сам делает simplefilter('always'), перебивая
            # PYTHONWARNINGS и -W ignore. К apt-установке претензия не относится:
            # версия закреплена зависимостью пакета (<< 3.0), это не pip-апгрейд.
            # Предупреждаем заранее, чтобы баннер не выглядел поломкой.
            if dpkg-query -W -f='${Version}' python3-cloudflare 2>/dev/null | grep -q '^2\.20'; then
                log_warn "При выпуске сертификата certbot напечатает большой WARNING про"
                log_warn "python-cloudflare 2.20. Это безвредно и не отключается: версия"
                log_warn "закреплена пакетом (<< 3.0), на выпуск сертификатов не влияет."
            fi
        fi
    fi

    [ "$want_cf" = true ] && apply_cloudflare_credentials
    apply_certbot_tls_assets
}

# Токен Cloudflare. Кладём в /root: certbot всегда запускается от root, а при более
# открытых правах он сам ругается на небезопасный credentials-файл
apply_cloudflare_credentials() {
    if [ -s "$CF_CREDENTIALS" ]; then
        log_success "Credentials-файл уже есть: ${CF_CREDENTIALS}"
        if ! ask_yn "Перезаписать его новым токеном?" N; then return; fi
    elif ! ask_yn "Создать ${CF_CREDENTIALS} с API-токеном Cloudflare?" N; then
        log_warn "Без токена плагин Cloudflare работать НЕ будет — выпуск сертификатов упадёт"
        log_warn "В меню этот пункт так и будет показывать «токен CF не задан»"
        log_info "Создать вручную (права Zone:DNS:Edit):"
        echo -e "      ${DIM}mkdir -p $(dirname "$CF_CREDENTIALS") && chmod 700 $(dirname "$CF_CREDENTIALS")${NC}"
        echo -e "      ${DIM}echo 'dns_cloudflare_api_token = ТОКЕН' > ${CF_CREDENTIALS}${NC}"
        echo -e "      ${DIM}chmod 600 ${CF_CREDENTIALS}${NC}"
        cf_wildcard_hint
        return
    fi

    echo -en "  ${BOLD}API-токен Cloudflare${NC} ${DIM}(права Zone:DNS:Edit, ввод скрыт):${NC} "
    local token
    read -rs token </dev/tty; echo ""
    if [ -z "$token" ]; then
        log_error "Пустой токен — файл не создан"
        return 1
    fi

    install -d -m 700 "$(dirname "$CF_CREDENTIALS")" || { log_error "Не удалось создать каталог"; return 1; }
    umask 077
    printf 'dns_cloudflare_api_token = %s\n' "$token" > "$CF_CREDENTIALS" || {
        log_error "Не удалось записать ${CF_CREDENTIALS}"; return 1; }
    chmod 600 "$CF_CREDENTIALS"
    chown root:root "$CF_CREDENTIALS"
    log_success "Credentials-файл создан: ${CF_CREDENTIALS} (600, root:root)"
    cf_wildcard_hint
}

cf_wildcard_hint() {
    log_info "Выпуск wildcard-сертификата:"
    echo -e "      ${DIM}certbot certonly --dns-cloudflare \\\\${NC}"
    echo -e "      ${DIM}  --dns-cloudflare-credentials ${CF_CREDENTIALS} \\\\${NC}"
    echo -e "      ${DIM}  -d example.com -d \"*.example.com\"${NC}"
}

# ssl-dhparams.pem и options-ssl-nginx.conf создаёт только nginx-*installer* certbot'а.
# При выпуске wildcard через `certbot certonly` (а это ровно то, ради чего ставят
# DNS-01) их не появится — и типовой конфиг nginx, который на них ссылается, положит
# сервер при старте. Оба файла уже лежат внутри пакета certbot: генерировать
# dhparam через openssl не нужно, там та же стандартная группа ffdhe2048.
apply_certbot_tls_assets() {
    if ! pkg_installed nginx-full; then
        return
    fi
    local want=false name src dst
    for name in ssl-dhparams.pem options-ssl-nginx.conf; do
        [ -f "/etc/letsencrypt/${name}" ] || want=true
    done
    if [ "$want" = false ]; then
        log_success "TLS-заготовки в /etc/letsencrypt уже на месте"
        return
    fi
    if ! ask_yn "Положить TLS-заготовки certbot (ssl-dhparams.pem, options-ssl-nginx.conf) в /etc/letsencrypt?" N; then
        return
    fi

    install -d -m 755 /etc/letsencrypt
    for name in ssl-dhparams.pem options-ssl-nginx.conf; do
        dst="/etc/letsencrypt/${name}"
        if [ -f "$dst" ]; then
            log_info "${name} уже есть — не трогаю"
            continue
        fi
        # путь внутри пакета ищем в рантайме: он менялся между версиями certbot,
        # хардкодить его — напрашиваться на молчаливую поломку
        src="$(find /usr/lib/python3/dist-packages /usr/lib/python3*/site-packages \
                -name "$name" -type f 2>/dev/null | head -n1)"
        if [ -z "$src" ]; then
            log_warn "${name} не найден внутри пакетов certbot — пропускаю (не выдумываю содержимое)"
            continue
        fi
        if install -m 644 "$src" "$dst"; then
            log_success "${name} → ${dst}"
        else
            log_error "Не удалось скопировать ${name}"
        fi
    done
}

apply_docker() {
    if ! ask_yn "Установить Docker + Docker Compose (официальный репозиторий)?"; then return; fi
    # спрашиваем ДО установки — ответ решает, дать ли postinst поднять демон
    local autostart=false
    resolve_autostart DOCKER_AUTOSTART "Запустить Docker и включить автозапуск?" && autostart=true

    ensure_apt_updated
    run_logged "Зависимости Docker" apt_get install -y ca-certificates curl || return 1
    install -m 0755 -d /etc/apt/keyrings
    run_logged "GPG-ключ Docker" \
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || return 1
    chmod a+r /etc/apt/keyrings/docker.asc
    local codename
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list
    run_logged "Списки пакетов Docker" apt_get update -qq
    if ! apt-cache policy docker-ce-cli 2>/dev/null | grep -q 'Candidate:.*[0-9]'; then
        log_warn "У Docker пока нет пакетов под '${codename}' — переключаюсь на noble (24.04, совместимо)"
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
            > /etc/apt/sources.list.d/docker.list
        run_logged "Списки пакетов Docker (noble)" apt_get update -qq
    fi
    with_no_service_start run_logged "Docker CE + Compose" \
        apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    refresh_pkg_cache

    apply_service_autostart docker "$autostart"

    # под прямым root группа docker бессмысленна: root и так может всё,
    # а usermod -aG docker root только путает вывод
    if [ "$TARGET_USER" != "root" ]; then
        usermod -aG docker "$TARGET_USER"
        log_info "Пользователь ${TARGET_USER} добавлен в группу docker — перелогинься для работы без sudo"
    else
        log_info "Работаем от root — в группу docker никого не добавляю"
    fi
    log_success "Docker установлен: $(docker --version 2>/dev/null)"
}

apply_fastfetch() {
    local need_ppa=true
    if command -v fastfetch &>/dev/null; then
        local v lowest
        v="$(fastfetch --version | grep -oP '\d+\.\d+\.\d+' | head -n1)"
        lowest="$(printf '%s\n%s\n' "$v" "2.64.0" | sort -V | head -n1)"
        [ "$lowest" = "2.64.0" ] && need_ppa=false
    fi
    if [ "$need_ppa" = true ]; then
        if ask_yn "Установить/обновить fastfetch (через PPA)?"; then
            ensure_apt_updated
            # -n (--no-update): add-apt-repository в конце сам дёргает apt update,
            # но опцию DPkg::Lock::Timeout ему не передать — значит он споткнётся
            # о ту же блокировку dpkg. Добавляем только репозиторий, а списки
            # обновляем своим apt_get, у которого таймаут уже есть.
            run_logged "PPA fastfetch" add-apt-repository -y -n ppa:zhangsongcui3371/fastfetch
            run_logged "Списки пакетов PPA" apt_get update -qq
            if run_logged "fastfetch" apt_get install -y fastfetch; then
                refresh_pkg_cache
                log_info "Версия: $(fastfetch --version 2>/dev/null)"
            fi
        fi
    else
        log_success "fastfetch уже подходящей версии"
    fi

    # конфиг и автозапуск в .bashrc пишем сразу следом — не отдельным пунктом меню
    if ! command -v fastfetch &>/dev/null; then return; fi

    install -d -o "$TARGET_USER" -g "$(id -g "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" \
        -m 755 "${TARGET_HOME}/.config/fastfetch"
    if [ -f "${TARGET_HOME}/.config/fastfetch/config.jsonc" ]; then
        log_info "config.jsonc уже есть"
    elif curl -fsSL "${REPO_RAW_BASE}/config.jsonc" -o "${TARGET_HOME}/.config/fastfetch/config.jsonc" 2>/dev/null; then
        chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.config/fastfetch/config.jsonc"
        log_success "config.jsonc установлен"
    else
        log_warn "Не удалось скачать config.jsonc из ${REPO_RAW_BASE}"
    fi

    local BASHRC="${TARGET_HOME}/.bashrc" need_fastfetch_block=false
    if grep -qF "# >>> vps-setup:fastfetch >>>" "$BASHRC" 2>/dev/null; then
        # старый блок (без гейта USFC_RESOURCE) печатал бы fastfetch второй раз
        # при каждом auto-source из usfc-обёртки (см. main()) — апгрейдим его
        if grep -qF "USFC_RESOURCE:-" "$BASHRC" 2>/dev/null; then
            log_info "Автозапуск fastfetch в .bashrc уже есть"
        else
            sed -i '/# >>> vps-setup:fastfetch >>>/,/# <<< vps-setup:fastfetch <<</d' "$BASHRC"
            need_fastfetch_block=true
        fi
    else
        need_fastfetch_block=true
    fi
    if [ "$need_fastfetch_block" = true ]; then
        cat >> "$BASHRC" <<'EOF'

# >>> vps-setup:fastfetch >>>
if [ -z "${USFC_RESOURCE:-}" ] && [ -x "$(command -v fastfetch)" ]; then
    fastfetch
fi
# <<< vps-setup:fastfetch <<<
EOF
        chown "${TARGET_USER}:${TARGET_USER}" "$BASHRC"
        log_success "Автозапуск добавлен в .bashrc"
    fi
}

apply_tmux() {
    if ! command -v tmux &>/dev/null; then
        if ask_yn "Установить tmux?"; then
            ensure_apt_updated
            run_logged "tmux" apt_get install -y tmux || return 1
            refresh_pkg_cache
        else
            return
        fi
    fi
    local TMUX_CONF="${TARGET_HOME}/.tmux.conf"
    if [ -f "$TMUX_CONF" ]; then
        log_info ".tmux.conf уже существует — не трогаю"
    elif ask_yn "Положить базовый .tmux.conf (мышь, история 10000, статус-бар)?"; then
        cat > "$TMUX_CONF" <<'EOF'
set -g mouse on
set -g history-limit 10000
set -g status-bg colour234
set -g status-fg colour250
set -g status-left '#[fg=colour39,bold]#S '
set -g status-right '%H:%M %d-%b-%y'
setw -g automatic-rename on
EOF
        chown "${TARGET_USER}:${TARGET_USER}" "$TMUX_CONF"
        log_success ".tmux.conf установлен"
    fi
}

apply_dockerlog() {
    if ! command -v docker &>/dev/null; then
        log_info "Docker не установлен — сначала установи Docker (пункт $(item_number docker))"
        return
    fi
    [ -f /etc/docker/daemon.json ] && log_warn "daemon.json уже существует, будет дополнен (не перезаписан целиком)"
    if ! ask_yn "Ограничить логи контейнеров (max-size=10m, max-file=3)?"; then return; fi
    mkdir -p /etc/docker
    python3 - /etc/docker/daemon.json <<'PYEOF'
import json, sys, os
path = sys.argv[1]
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
data["log-driver"] = "json-file"
data.setdefault("log-opts", {})
data["log-opts"]["max-size"] = "10m"
data["log-opts"]["max-file"] = "3"
json.dump(data, open(path, "w"), indent=2)
PYEOF
    log_success "daemon.json обновлён"
    if ask_yn "Перезапустить Docker сейчас? ВСЕ контейнеры перезапустятся вместе с демоном" N; then
        systemctl restart docker && log_success "Docker перезапущен"
    else
        log_info "Применится при следующем перезапуске Docker/сервера"
    fi
}

apply_fail2ban() {
    if ! ask_yn "Установить fail2ban?"; then return; fi
    ensure_apt_updated
    run_logged "fail2ban" apt_get install -y fail2ban || return 1
    refresh_pkg_cache
    cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    systemctl enable --now fail2ban >/dev/null
    log_success "fail2ban установлен и настроен на порт ${SSH_PORT}"
}

apply_unattended() {
    if ! ask_yn "Включить автообновление security-патчей?"; then return; fi
    ensure_apt_updated
    run_logged "unattended-upgrades" apt_get install -y unattended-upgrades || return 1
    refresh_pkg_cache
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    systemctl enable --now unattended-upgrades >/dev/null
    log_success "unattended-upgrades включён"
}

# suggest_swap_mb [место_которое_освободится_МБ] — рекомендуемый размер
# резервного swap-файла: min(RAM, свободно/4), зажатое в 512-4096 МБ.
#
# Почему так, а не «10% диска», как было раньше: своп здесь — резерв ПОД zram
# (приоритет 10 против 100), то есть его роль определяется объёмом памяти,
# а старая формула про RAM не знала вообще. Деление на 4 не даёт свопу съесть
# тесный диск, кламп снизу спасает совсем маленькие машины.
#
# Аргумент нужен при ПЕРЕсоздании: место под текущим swap-файлом освободится,
# и без этого слагаемого своп нельзя было бы увеличить даже когда диск позволяет.
suggest_swap_mb() {
    local extra_mb="${1:-0}" free_mb ram_mb suggested
    free_mb="$(df -m / 2>/dev/null | awk 'NR==2{print $4}')"
    [[ "$free_mb" =~ ^[0-9]+$ ]] || free_mb=0
    [[ "$extra_mb" =~ ^[0-9]+$ ]] || extra_mb=0
    free_mb=$(( free_mb + extra_mb ))

    ram_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    [[ "$ram_mb" =~ ^[0-9]+$ ]] || ram_mb=1024

    suggested=$(( free_mb / 4 ))
    [ "$ram_mb" -lt "$suggested" ] && suggested="$ram_mb"
    [ "$suggested" -lt 512 ] && suggested=512
    [ "$suggested" -gt 4096 ] && suggested=4096
    echo "$suggested"
}

# swap_needs_resize <текущий_МБ> <рекомендуемый_МБ> — расходятся ли больше
# чем на 10%. Ниже порога не пристаём: своп «примерно правильного» размера
# трогать незачем, а лишний вопрос на каждом заходе в пункт раздражает
swap_needs_resize() {
    local cur="${1:-0}" want="${2:-0}" diff
    [ "$want" -le 0 ] && return 1
    diff=$(( cur > want ? cur - want : want - cur ))
    [ $(( diff * 100 )) -gt $(( want * 10 )) ]
}

# читает текущее состояние zram/swap в глобальные переменные — общий
# парсинг для apply_zram() и предзапроса значений перед bulk-режимом в main()
# SWAP_TYPE/SWAP_SIZE_MB/SWAP_USED_MB нужны, чтобы решить, можно ли безопасно
# пересоздать своп: раздел трогать нельзя, а занятое должно влезть обратно в RAM
read_swap_state() {
    ZRAM_ACTIVE=false; ZRAM_PRIO=""
    SWAP_ACTIVE=false; SWAP_PRIO=""; SWAP_PATH=""
    SWAP_TYPE=""; SWAP_SIZE_MB=0; SWAP_USED_MB=0
    local n t s u p
    while read -r n t s u p; do
        case "$n" in
            /dev/zram*) ZRAM_ACTIVE=true; ZRAM_PRIO="$p" ;;
            *)
                SWAP_ACTIVE=true; SWAP_PRIO="$p"; SWAP_PATH="$n"; SWAP_TYPE="$t"
                SWAP_SIZE_MB="$(human_to_mb "$s")"
                SWAP_USED_MB="$(human_to_mb "$u")"
                ;;
        esac
    done < <(swapon --show --noheadings --raw 2>/dev/null)
}

# "1.9G" / "12.1M" / "512K" / "0B" → целые МБ. swapon --raw печатает именно так
human_to_mb() {
    local v="${1:-0}" num unit
    num="${v%[BKMGTbkmgt]}"
    unit="${v#"$num"}"
    [[ "$num" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo 0; return; }
    case "${unit^^}" in
        G) awk -v n="$num" 'BEGIN{printf "%d", n*1024}' ;;
        T) awk -v n="$num" 'BEGIN{printf "%d", n*1024*1024}' ;;
        M) awk -v n="$num" 'BEGIN{printf "%d", n}' ;;
        K) awk -v n="$num" 'BEGIN{printf "%d", n/1024}' ;;
        *) awk -v n="$num" 'BEGIN{printf "%d", n/1048576}' ;;
    esac
}

# create_swapfile <путь> <МБ> — выделяет файл и делает из него своп.
# fallocate быстрее, но на btrfs даёт файл с дырами, непригодный для свопа —
# тогда честно переписываем нулями через dd. Возвращает 0 только если своп
# реально поднялся.
create_swapfile() {
    local path="$1" mb="$2"
    rm -f "$path"
    if ! fallocate -l "${mb}M" "$path" 2>/dev/null; then
        log_info "fallocate не сработал — выделяю файл через dd (дольше)"
        dd if=/dev/zero of="$path" bs=1M count="$mb" status=none 2>/dev/null || return 1
    fi
    chmod 600 "$path"
    if ! mkswap "$path" >/dev/null 2>&1; then
        log_info "mkswap не принял файл — переделываю через dd"
        rm -f "$path"
        dd if=/dev/zero of="$path" bs=1M count="$mb" status=none 2>/dev/null || return 1
        chmod 600 "$path"
        mkswap "$path" >/dev/null 2>&1 || return 1
    fi
    swapon "$path" 2>/dev/null || return 1
    return 0
}

# ensure_fstab_swap <путь> — ровно одна запись с pri=10, без дублей.
# Дубль опаснее, чем кажется: после ребута своп смонтируется дважды
ensure_fstab_swap() {
    local path="$1" esc
    esc="$(printf '%s' "$path" | sed 's/[.[\*^$/]/\\&/g')"
    if grep -qE "^${esc}\s" /etc/fstab 2>/dev/null; then
        sed -i -E "s#^(${esc}\s+none\s+swap\s+)sw([^,].*)?\$#\1sw,pri=10\2#" /etc/fstab
    else
        echo "${path} none swap sw,pri=10 0 0" >> /etc/fstab
    fi
}

# resize_swapfile <путь> <новый_МБ> — пересоздание уже работающего свопа.
# Самая опасная операция в скрипте: между swapoff и swapon машина живёт без
# резервной памяти, поэтому все проверки — ДО того, как что-то трогать.
resize_swapfile() {
    local path="$1" new_mb="$2" old_mb="$3" used_mb="$4"

    if [ ! -f "$path" ]; then
        log_error "${path} — не обычный файл, пересоздавать не буду"
        return 1
    fi

    # swapoff выгружает занятые страницы обратно в RAM. Если они туда не
    # влезают — получим OOM и убитые процессы, поэтому просто отказываемся
    local avail_mb
    avail_mb="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    [[ "$avail_mb" =~ ^[0-9]+$ ]] || avail_mb=0
    if [ "$used_mb" -gt 0 ] && [ "$used_mb" -ge $(( avail_mb - 200 )) ]; then
        log_error "В свопе занято ${used_mb} МБ, а свободной памяти всего ${avail_mb} МБ"
        log_error "Отключение свопа сейчас рискует уронить процессы — размер не меняю"
        log_info "Освободи память (или перезагрузись) и вернись в этот пункт"
        return 1
    fi

    # места должно хватить с учётом того, что старый файл освободится
    local free_mb
    free_mb="$(df -m / 2>/dev/null | awk 'NR==2{print $4}')"
    [[ "$free_mb" =~ ^[0-9]+$ ]] || free_mb=0
    if [ "$new_mb" -gt $(( free_mb + old_mb - 256 )) ]; then
        log_error "Не хватит места: нужно ${new_mb} МБ, доступно ~$(( free_mb + old_mb )) МБ"
        return 1
    fi

    log_info "Отключаю ${path} ${DIM}(занято ${used_mb} МБ, свободной памяти ${avail_mb} МБ)${NC}"
    if ! swapoff "$path" 2>/dev/null; then
        log_error "swapoff ${path} не удался — ничего не менял"
        return 1
    fi

    if create_swapfile "$path" "$new_mb"; then
        ensure_fstab_swap "$path"
        swapoff "$path" 2>/dev/null
        swapon -a 2>/dev/null           # поднимаем уже с приоритетом из fstab
        log_success "swap пересоздан: ${new_mb} МБ, приоритет 10"
        return 0
    fi

    # не получилось — машина сейчас без свопа, это надо исправить или хотя бы
    # сказать вслух, а не оставить молча
    log_error "Не удалось создать своп размером ${new_mb} МБ"
    if create_swapfile "$path" "$old_mb"; then
        ensure_fstab_swap "$path"
        swapoff "$path" 2>/dev/null
        swapon -a 2>/dev/null
        log_warn "Вернул прежний размер ${old_mb} МБ — система со свопом"
    else
        log_error "ВНИМАНИЕ: своп сейчас ВЫКЛЮЧЕН. Подними вручную:"
        echo -e "      ${BOLD}sudo fallocate -l ${old_mb}M ${path} && sudo chmod 600 ${path}${NC}"
        echo -e "      ${BOLD}sudo mkswap ${path} && sudo swapon -a${NC}"
    fi
    return 1
}

apply_zram() {
    read_swap_state
    local zram_active="$ZRAM_ACTIVE" zram_prio="$ZRAM_PRIO" \
          swap_active="$SWAP_ACTIVE" swap_prio="$SWAP_PRIO" swap_path="$SWAP_PATH"

    if [ "$zram_active" = true ]; then
        if [ "$zram_prio" = "100" ]; then
            log_success "zram уже настроен (приоритет 100) — пропускаю"
        else
            log_warn "zram активен, но приоритет ${zram_prio} (рекомендуется 100), похоже настраивали вручную"
            if ask_yn "Перенастроить под рекомендованные значения?" N; then
                local cur_percent zram_percent
                cur_percent="$(grep -oP '^PERCENT=\K[0-9]+' /etc/default/zramswap 2>/dev/null)"
                [ -z "$cur_percent" ] && cur_percent=75
                zram_percent="$(ask_value "Размер zram в % от RAM?" "$cur_percent")"
                ensure_apt_updated
                if run_logged "zram-tools" apt_get install -y zram-tools; then
                    systemctl stop zramswap 2>/dev/null
                    swapoff /dev/zram0 2>/dev/null || true
                    printf 'ALGO=lz4\nPERCENT=%s\nPRIORITY=100\n' "$zram_percent" > /etc/default/zramswap
                    if ! systemctl start zramswap; then
                        sleep 2
                        systemctl start zramswap
                    fi
                    if swapon --show --noheadings --raw 2>/dev/null | awk '{print $1}' | grep -q '^/dev/zram'; then
                        log_success "zram перенастроен (${zram_percent}% RAM)"
                    else
                        log_error "Не удалось поднять zram — попробуйте вручную: systemctl restart zramswap"
                    fi
                else
                    log_error "Установка zram-tools не удалась"
                fi
            fi
        fi
    elif ask_yn "Установить и настроить zram (lz4, приоритет 100)?"; then
        local zram_percent
        zram_percent="$(ask_value "Размер zram в % от RAM?" "${ZRAM_BULK_PERCENT:-75}")"
        ensure_apt_updated
        if run_logged "zram-tools" apt_get install -y zram-tools; then
            systemctl stop zramswap 2>/dev/null
            swapoff /dev/zram0 2>/dev/null || true
            printf 'ALGO=lz4\nPERCENT=%s\nPRIORITY=100\n' "$zram_percent" > /etc/default/zramswap
            if ! systemctl start zramswap; then
                sleep 2
                systemctl start zramswap
            fi
            if swapon --show --noheadings --raw 2>/dev/null | awk '{print $1}' | grep -q '^/dev/zram'; then
                log_success "zram-tools установлен и настроен (${zram_percent}% RAM)"
            else
                log_error "Не удалось поднять zram — попробуйте вручную: systemctl restart zramswap"
            fi
        else
            log_error "Установка zram-tools не удалась"
        fi
    fi

    if [ "$swap_active" = true ]; then
        if [ "$swap_prio" = "10" ]; then
            local sw_suggest
            sw_suggest="$(suggest_swap_mb "$SWAP_SIZE_MB")"
            log_success "Резервный своп: ${swap_path}, ${SWAP_SIZE_MB} МБ, приоритет 10 ${DIM}(занято ${SWAP_USED_MB} МБ)${NC}"

            if [ "$SWAP_TYPE" != "file" ]; then
                # раздел или LVM: менять его размер — это про parted/lvresize и
                # риск для данных, такое не место в меню быстрой настройки
                log_info "Тип свопа — ${SWAP_TYPE:-?}, размер разделов этот скрипт не меняет"
            elif swap_needs_resize "$SWAP_SIZE_MB" "$sw_suggest"; then
                log_info "Рекомендуемый размер для этой машины: ${BOLD}${sw_suggest} МБ${NC} ${DIM}(min(RAM, свободно/4))${NC}"
                # В пакетном режиме ask_yn всегда вернёт дефолт N, поэтому
                # согласием считаем сам факт того, что размер уже спросили
                # заранее в main() — иначе предзаданное значение пропало бы зря
                local want_resize=false
                if [ "$BULK_MODE" = true ]; then
                    [ -n "$SWAP_BULK_MB" ] && want_resize=true
                elif ask_yn "Изменить размер swap-файла?" N; then
                    want_resize=true
                fi
                if [ "$want_resize" = true ]; then
                    local new_mb
                    new_mb="$(ask_value "Размер swap-файла, МБ?" "${SWAP_BULK_MB:-$sw_suggest}")"
                    if [ "$new_mb" -lt 64 ]; then
                        log_error "Слишком мало (${new_mb} МБ) — размер не меняю"
                    else
                        resize_swapfile "$swap_path" "$new_mb" "$SWAP_SIZE_MB" "$SWAP_USED_MB"
                    fi
                fi
            else
                log_success "Размер близок к рекомендуемому (${sw_suggest} МБ) — оставляю как есть"
            fi
        else
            log_warn "Своп на диске (${swap_path}) активен, но приоритет ${swap_prio} (рекомендуется 10)"
            if ask_yn "Исправить приоритет ${swap_path} в /etc/fstab на 10?"; then
                local esc_path
                esc_path="$(printf '%s' "$swap_path" | sed 's/[.[\*^$/]/\\&/g')"
                sed -i -E "s#^(${esc_path}\s+none\s+swap\s+)sw([^,].*)?\$#\1sw,pri=10\2#" /etc/fstab
                swapoff "$swap_path" 2>/dev/null || true
                swapon -a
                # sed молча не найдёт строку, если своп в fstab указан через
                # UUID=/LABEL=, а не путём (типично для разделов) — тогда без
                # этой проверки log_success был бы враньём
                if swapon --show --noheadings --raw 2>/dev/null | awk -v p="$swap_path" '$1==p {print $5}' | grep -q '^10$'; then
                    log_success "Приоритет исправлен"
                else
                    log_error "Не удалось исправить приоритет ${swap_path} — возможно, в /etc/fstab он указан через UUID=/LABEL=, а не путём. Поправьте вручную: pri=10 в опциях монтирования"
                fi
            fi
        fi
    else
        local suggested_mb
        suggested_mb="$(suggest_swap_mb)"
        if ask_yn "Создать резервный swap-файл (по умолчанию ${suggested_mb} МБ, приоритет 10)?"; then
            local swap_mb
            swap_mb="$(ask_value "Размер swap-файла, МБ?" "${SWAP_BULK_MB:-$suggested_mb}")"
            if create_swapfile /swapfile "$swap_mb"; then
                ensure_fstab_swap /swapfile
                swapoff /swapfile 2>/dev/null
                swapon -a 2>/dev/null       # поднимаем уже с приоритетом из fstab
                log_success "swapfile создан (${swap_mb} МБ, приоритет 10)"
            else
                log_error "Не удалось создать /swapfile на ${swap_mb} МБ — подробности выше"
            fi
        fi
    fi

    local cur_sw cur_vfs
    cur_sw="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo '?')"
    cur_vfs="$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo '?')"
    if [ "$cur_sw" = "80" ] && [ "$cur_vfs" = "50" ]; then
        log_success "sysctl уже настроен как рекомендуется"
    else
        log_info "Сейчас: swappiness=${cur_sw}, vfs_cache_pressure=${cur_vfs} ${DIM}(рекомендуется 80/50)${NC}"
        local sysctl_default=Y
        [ "$cur_sw" != "60" ] || [ "$cur_vfs" != "100" ] && sysctl_default=N
        if ask_yn "Применить рекомендованные значения sysctl?" "$sysctl_default"; then
            printf 'vm.swappiness=80\nvm.vfs_cache_pressure=50\n' > /etc/sysctl.d/99-zram.conf
            sysctl --system >/dev/null
            log_success "sysctl применён"
        fi
    fi

    if systemctl is-enabled earlyoom &>/dev/null 2>&1; then
        log_success "earlyoom уже включён"
    elif ask_yn "Установить earlyoom (защита от полного падения при нехватке памяти)?"; then
        ensure_apt_updated
        if run_logged "earlyoom" apt_get install -y earlyoom; then
            systemctl enable --now earlyoom >/dev/null
            log_success "earlyoom включён"
        fi
        refresh_pkg_cache
    fi

    echo ""
    log_info "Текущее состояние свопа:"
    swapon --show 2>/dev/null | sed 's/^/      /'
}

# ── Общая работа с ~/.ssh ─────────────────────────────────────────────────────
# Специально без `sudo -u`: на голом root-образе (а это ровно наш сценарий, когда
# пользователя ещё не создали) sudo может быть не установлен вообще, и такие
# строки падали бы молча. install(1) умеет владельца и права сам, без подмены uid.
REPLY_AUTHKEYS=''
ensure_ssh_dir() {
    local user="$1" home="$2" dir="${2}/.ssh" gid
    gid="$(id -g "$user" 2>/dev/null)" || gid="$user"
    install -d -o "$user" -g "$gid" -m 700 "$dir" || return 1
    REPLY_AUTHKEYS="${dir}/authorized_keys"
    if [ -f "$REPLY_AUTHKEYS" ]; then
        chown "${user}:${gid}" "$REPLY_AUTHKEYS"
        chmod 600 "$REPLY_AUTHKEYS"
    else
        install -o "$user" -g "$gid" -m 600 /dev/null "$REPLY_AUTHKEYS" || return 1
    fi
}

# просит вставить публичный ключ и дописывает его в authorized_keys.
# Возвращает 0, только если ключ реально добавлен (или уже был) — на это
# опирается apply_newuser, решая, можно ли оставить пользователя без пароля
add_pubkey_interactive() {
    local auth_keys="$1" pubkey_line
    echo -en "  ${BOLD}Вставь публичный ключ одной строкой:${NC} "
    read -r pubkey_line </dev/tty
    if [ -z "$pubkey_line" ]; then
        log_info "Пусто — ключ не добавлен"
        return 1
    fi
    if [[ ! "$pubkey_line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-|sk-ecdsa-) ]]; then
        log_error "Не похоже на публичный SSH-ключ — не добавляю"
        return 1
    fi
    if grep -qF "$pubkey_line" "$auth_keys" 2>/dev/null; then
        log_info "Такой ключ уже есть"
        return 0
    fi
    echo "$pubkey_line" >> "$auth_keys"
    log_success "Ключ добавлен"
    return 0
}

apply_sshhardening() {
    if [ "$TARGET_USER" = "root" ]; then
        log_warn "Скрипт запущен напрямую под root — hardening требует отдельного пользователя"
        log_warn "Создай его (adduser <имя> && usermod -aG sudo <имя>) и перезайди под ним"
        return
    fi
    if [ "$BULK_MODE" = true ]; then
        log_warn "SSH hardening требует явного подтверждения — пропущено в пакетном режиме. Настройте отдельно пунктом $(item_number sshhardening)."
        return
    fi
    if ! ask_yn "Настроить SSH hardening для ${TARGET_USER} (ключи вместо пароля, запрет root-логина)?" N; then return; fi

    ensure_ssh_dir "$TARGET_USER" "$TARGET_HOME" || { log_error "Не удалось подготовить ~/.ssh"; return 1; }
    local AUTH_KEYS="$REPLY_AUTHKEYS"

    if [ -s "$AUTH_KEYS" ]; then
        log_info "В authorized_keys уже есть $(grep -c '^ssh-\|^ecdsa-\|^sk-' "$AUTH_KEYS" 2>/dev/null || echo 0) ключ(ей)"
    else
        log_info "authorized_keys пока пуст"
    fi

    if ask_yn "Добавить новый публичный ключ (вставить содержимое .pub со своей машины)?"; then
        add_pubkey_interactive "$AUTH_KEYS"
    fi

    if [ ! -s "$AUTH_KEYS" ]; then
        log_error "authorized_keys пуст — отключать пароль нельзя. Hardening прерван."
        return 1
    fi

    if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
        log_info "Найден 50-cloud-init.conf — наш 10-hardening.conf побеждает при слиянии (10 < 50)"
    fi

    local TEST_KEY="/tmp/vps-setup-selftest-$$"
    ssh-keygen -t ed25519 -N '' -f "$TEST_KEY" -C "vps-setup-selftest" -q
    local TEST_PUB
    TEST_PUB="$(cat "${TEST_KEY}.pub")"
    echo "$TEST_PUB" >> "$AUTH_KEYS"

    ssh_selftest() {
        ssh -i "$TEST_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "$SSH_PORT" \
            "${TARGET_USER}@127.0.0.1" 'echo VPS_SETUP_KEY_OK' 2>/dev/null | grep -q VPS_SETUP_KEY_OK
    }
    cleanup_test_key() {
        grep -vF "$TEST_PUB" "$AUTH_KEYS" > "${AUTH_KEYS}.tmp" 2>/dev/null && mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
        chown "${TARGET_USER}:${TARGET_USER}" "$AUTH_KEYS"
        chmod 600 "$AUTH_KEYS"
        rm -f "$TEST_KEY" "${TEST_KEY}.pub"
    }

    log_info "Проверяю базовый вход по ключу (до изменений конфига)..."
    if ! ssh_selftest; then
        log_error "Вход по ключу не проходит даже сейчас — hardening не запускаю"
        cleanup_test_key
        return 1
    fi
    log_success "Базовый вход по ключу подтверждён"
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
    cat > /etc/ssh/sshd_config.d/10-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers ${TARGET_USER}
EOF

    if ! sshd -t 2>/dev/null; then
        log_error "sshd -t не прошёл — откатываю"
        rm -f /etc/ssh/sshd_config.d/10-hardening.conf
        cleanup_test_key
        return 1
    fi

    systemctl restart ssh
    sleep 1
    log_info "Проверяю вход по ключу ПОСЛЕ применения hardening..."
    if ssh_selftest; then
        # вход по ключу подтверждает только то, что ключевая аутентификация жива —
        # отдельно сверяем через sshd -T, что PasswordAuthentication реально no
        # (например, без "Include .../sshd_config.d/*.conf" в базовом sshd_config
        # наш дроп-ин просто не подхватился бы, а ключевой вход при этом всё равно работал)
        refresh_sshd_config
        local pa="$SSHD_PASSWORDAUTH"
        if [ "$pa" != "no" ]; then
            log_error "Вход по ключу работает, но sshd -T показывает passwordauthentication=${pa:-?} — конфиг не применился"
            log_error "Вероятная причина: в /etc/ssh/sshd_config нет 'Include /etc/ssh/sshd_config.d/*.conf'"
            log_warn "Дроп-ин не откатываю — он и так не действует, откат ничего не изменит"
            cleanup_test_key
            return 1
        fi
        log_success "SSH hardening применён: root-логин выключен, пароль выключен"
        log_info "Текущая сессия не разрывалась — рестарт sshd не убивает открытые соединения"
        cleanup_test_key
        if ask_yn "Настроить passwordless sudo для ${TARGET_USER}?"; then
            local SUDOERS_FILE="/etc/sudoers.d/${TARGET_USER}"
            echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > "${SUDOERS_FILE}.tmp"
            if visudo -c -f "${SUDOERS_FILE}.tmp" >/dev/null 2>&1; then
                mv "${SUDOERS_FILE}.tmp" "$SUDOERS_FILE"
                chmod 440 "$SUDOERS_FILE"
                log_success "Passwordless sudo настроен"
            else
                log_error "Синтаксическая ошибка в sudoers — не применяю"
                rm -f "${SUDOERS_FILE}.tmp"
            fi
        fi
    else
        log_error "После рестарта sshd вход по ключу НЕ проходит — АВАРИЙНЫЙ ОТКАТ"
        rm -f /etc/ssh/sshd_config.d/10-hardening.conf
        systemctl restart ssh
        refresh_sshd_config
        cleanup_test_key
        log_error "Конфиг откачен. Текущая сессия жива — ничего не сломано."
        return 1
    fi
}

apply_ufw() {
    log_info "Обнаруженные слушающие TCP-порты:"
    local listening
    listening="$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\])' | grep -oE '[0-9]+$' | sort -un)"
    echo "$listening" | sed 's/^/      /'
    echo ""
    log_warn "Если на сервере уже крутится VPN/прокси — включение без разрешения ЕГО портов оборвёт его"
    if [ "$BULK_MODE" = true ]; then
        log_warn "UFW требует явного подтверждения — пропущено в пакетном режиме. Настройте отдельно пунктом $(item_number ufw)."
        return
    fi
    if ! ask_yn "Включить UFW, разрешив SSH-порт (${SSH_PORT}) и все порты выше?" N; then return; fi
    ensure_apt_updated
    run_logged "UFW" apt_get install -y ufw || return 1
    refresh_pkg_cache
    ufw allow "${SSH_PORT}"/tcp >/dev/null
    while read -r p; do
        [ -n "$p" ] && ufw allow "${p}"/tcp >/dev/null
    done <<< "$listening"
    ufw --force enable >/dev/null
    log_success "UFW включён"
    ufw status | sed 's/^/      /'
}

# ═══════════════════════════════════════════════════════════════
# DISABLE-функции — только для безопасно обратимых пунктов
# ═══════════════════════════════════════════════════════════════
disable_dockerlog() {
    if [ ! -f /etc/docker/daemon.json ]; then log_info "daemon.json нет — нечего отключать"; return; fi
    if ask_yn "Убрать лимиты логов из daemon.json?" N; then
        python3 - /etc/docker/daemon.json <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception:
    data = {}
data.pop("log-opts", None)
if data.get("log-driver") == "json-file":
    data.pop("log-driver", None)
json.dump(data, open(path, "w"), indent=2)
PYEOF
        log_success "Лимиты убраны из daemon.json"
        ask_yn "Перезапустить Docker сейчас?" N && { systemctl restart docker && log_success "Docker перезапущен"; }
    fi
}
disable_fail2ban() {
    ask_yn "Остановить и выключить fail2ban?" N && { systemctl disable --now fail2ban &>/dev/null; log_success "fail2ban выключен"; }
}
disable_unattended() {
    if ask_yn "Выключить unattended-upgrades?" N; then
        printf 'APT::Periodic::Update-Package-Lists "0";\nAPT::Periodic::Unattended-Upgrade "0";\n' > /etc/apt/apt.conf.d/20auto-upgrades
        systemctl disable unattended-upgrades &>/dev/null || true
        log_success "unattended-upgrades выключен"
    fi
}
disable_zram() {
    if ask_yn "Выключить zram-устройство (swapfile на диске НЕ трогается)?" N; then
        systemctl disable --now zramswap &>/dev/null || true
        log_success "zram выключен. swapfile (если есть) продолжает работать"
    fi
}
disable_ufw() {
    ask_yn "Выключить UFW?" N && { ufw disable &>/dev/null; log_success "UFW выключен"; }
}

# ═══════════════════════════════════════════════════════════════
# Меню
# ═══════════════════════════════════════════════════════════════
ITEM_IDS=(newuser basepkgs cli fastfetch tmux docker nginx certbot dockerlog fail2ban unattended zram sshhardening ufw)
ITEM_TITLES=(
    "Пользователь + sudo"
    "Базовые пакеты"
    "CLI-утилиты + starship"
    "fastfetch"
    "tmux"
    "Docker + Compose"
    "nginx-full"
    "Certbot + плагины"
    "Docker log rotation"
    "fail2ban"
    "unattended-upgrades"
    "ZRAM + swap + earlyoom"
    "SSH hardening"
    "UFW firewall"
)
ITEM_SECTIONS=(система база база база база сервисы сервисы сервисы защита защита защита защита защита защита)
DISABLE_SUPPORTED=(dockerlog fail2ban unattended zram ufw)

# Буквы разделов. Раньше раскрытие B/S/P было зашито числами прямо в main()
# ("B) valid+=(1 2 3 4)"), и любой новый пункт молча ломал его. Теперь это
# единственный источник истины, а номера выводятся из ITEM_SECTIONS.
SECTION_NAMES=(система база сервисы защита)
SECTION_LETTERS=(C B S P)

# item_number <id> → номер пункта в меню. Нужен сообщениям вида «настройте
# отдельно пунктом N»: захардкоженные там числа разъезжались с меню при каждом
# добавлении пункта, причём молча
item_number() {
    local id="${1:-}" i
    for i in "${!ITEM_IDS[@]}"; do
        [ "${ITEM_IDS[$i]}" = "$id" ] && { printf '%s' "$((i + 1))"; return 0; }
    done
    printf '?'
    return 1
}

# expand_section_letter <буква> → номера пунктов этого раздела (через пробел)
REPLY_SECTION_ITEMS=''
expand_section_letter() {
    local letter="${1:-}" i sec want=''
    for i in "${!SECTION_LETTERS[@]}"; do
        [ "${SECTION_LETTERS[$i]}" = "$letter" ] && { want="${SECTION_NAMES[$i]}"; break; }
    done
    REPLY_SECTION_ITEMS=''
    [ -z "$want" ] && return 1
    for i in "${!ITEM_SECTIONS[@]}"; do
        sec="${ITEM_SECTIONS[$i]}"
        [ "$sec" = "$want" ] && REPLY_SECTION_ITEMS="${REPLY_SECTION_ITEMS}${REPLY_SECTION_ITEMS:+ }$((i + 1))"
    done
    return 0
}

# ── Справка по пунктам (клавиша I) ────────────────────────────────────────────
# Параллельно ITEM_IDS. Тексты — те же, что в разделе «Что делает каждый пункт»
# в README: там ровно 14 описаний, один в один с меню. При правке одного места
# правь и второе — расхождение заметить будет некому.
ITEM_SHORT=(
    "создаёт обычного юзера с sudo на голой VPS"
    "micro, curl, git, htop, jq и прочая база"
    "современные замены ls/cat/find + промпт"
    "сводка о сервере при каждом заходе по SSH"
    "мультиплексор: сессия переживает обрыв связи"
    "Docker CE + Compose из официального репозитория"
    "веб-сервер и реверс-прокси"
    "TLS-сертификаты, в том числе wildcard через DNS"
    "ограничивает логи контейнеров, чтобы не съели диск"
    "банит перебор паролей по SSH"
    "сам ставит security-обновления системы"
    "сжатая память + резервный своп + защита от OOM"
    "вход только по ключу, root-логин закрыт"
    "файрвол: закрывает всё, кроме нужного"
)

ITEM_FULL=(
"Нужен, когда хостер выдал сервер с одним лишь root. Работать из-под root
не стоит: SSH hardening без отдельного пользователя не работает в принципе,
а всё, что кладётся в домашний каталог (алиасы, fastfetch, tmux, starship),
осядет в /root и исчезнет, как только ты перезайдёшь под нормальным аккаунтом.

Спрашивает имя и пароль (скрытым вводом, с повтором), добавляет в группу sudo
и — самое важное — копирует ключи из /root/.ssh/authorized_keys. Без этого
новый пользователь не сможет войти вообще, а после SSH hardening доступ
к серверу будет потерян. Дальше вся настройка переключается на него прямо
в работающей сессии."

"micro, curl, wget, git, nano, unzip, htop, jq, rsync и ещё несколько вещей,
которые обычно ставишь в первую же минуту на любом сервере. В том числе
software-properties-common, без которого не заработает add-apt-repository,
нужный дальше для PPA fastfetch.

После установки выводится список: что приехало сейчас, что уже стояло,
и коротко — зачем каждый пакет нужен."

"Современные замены классических утилит: eza вместо ls с иконками, bat вместо
cat с подсветкой, fd вместо find, ripgrep для поиска по содержимому, zoxide —
«умный» cd, ncdu для разбора места на диске. Плюс промпт starship.

Всё вместе, потому что это один и тот же слой «как выглядит и ощущается
терминал». Алиасы в .bashrc и eval-строки для zoxide/starship пишутся сразу
этим же пунктом. Список алиасов — на экране H."

"Показывает информацию о сервере (ОС, ядро, память, диск, IP) при каждом заходе
по SSH. Версия не ниже 2.64.0: более старые не умеют выравнивание в format-
строках, которое использует прилагаемый config.jsonc.

Конфиг и автозапуск пишутся в .bashrc сразу этим же пунктом."

"Мультиплексор терминала: держит сессию живой при обрыве связи. Переподключаешься
по SSH — и всё, что запускал, на месте, включая несколько окон и панелей.
Незаменим, когда запускаешь что-то долгое на сервере через нестабильный канал.

Ставится с минимальным конфигом: мышь, история на 10000 строк, статус-бар."

"Docker CE + Compose plugin из официального репозитория Docker, а не пакет
docker.io из репозиториев Ubuntu — тот заметно старее.

Автозапуск спрашивается ДО установки и по умолчанию выключен: сервер не всегда
нужно поднимать прямо сейчас. Пользователь добавляется в группу docker, чтобы
работать без sudo (нужен перелогин)."

"Веб-сервер и реверс-прокси, пакет nginx-full.

Автозапуск спрашивается ДО установки, по умолчанию выключен. Чтобы «не
запускать» означало именно это, а не «поднять и тут же погасить» (nginx успел
бы занять :80), установка оборачивается в policy-rc.d. Намеренно выключенный
сервис считается законченным состоянием и больше не переспрашивается."

"Сам certbot плюс, по выбору, плагин nginx (HTTP-01, обычные сертификаты)
и плагин dns-cloudflare (DNS-01 — без него не выпустить wildcard).

Для Cloudflare предлагается создать /root/.secrets/certbot/cloudflare.ini
с API-токеном (права 600, токену нужны права Zone:DNS:Edit). Без файла плагин
нерабочий, поэтому его отсутствие видно в меню отдельным статусом.

Отдельно предлагается положить в /etc/letsencrypt заготовки ssl-dhparams.pem
и options-ssl-nginx.conf: при выпуске wildcard через certonly они не создаются,
а типовой конфиг nginx на них ссылается и роняет сервер при старте."

"Ограничивает логи контейнеров: 10 МБ на файл, 3 файла.

Без этого логи Docker ничем не ограничены и со временем способны забить весь
диск — на маленькой VPS это вопрос недель. Настройка пишется в
/etc/docker/daemon.json, существующий файл дополняется, а не перезаписывается."

"Банит IP после нескольких неудачных попыток входа по SSH — защита от перебора
паролей.

Настраивается на реальный SSH-порт сервера, а не на захардкоженный 22."

"Сам ставит security-обновления системы, без твоего участия.

Полезно и одновременно коварно: именно unattended-upgrades держит блокировку
dpkg на только что загруженном сервере, из-за чего установка пакетов может
подождать несколько минут. Скрипт это учитывает и ждёт освобождения."

"zram — сжатая память прямо в оперативке (по умолчанию 75% RAM, приоритет 100),
плюс резервный swap-файл на диске с приоритетом 10, чтобы использовался только
когда zram закончился.

Размер свопа считается как min(RAM, свободно/4), зажатое в 512–4096 МБ. Если
swap-файл уже есть и его размер расходится с рекомендацией больше чем на 10%,
пункт предложит пересоздать. Разделы и LVM не трогаются.

Плюс vm.swappiness=80 / vm.vfs_cache_pressure=50 и опционально earlyoom —
защита от полного зависания сервера при нехватке памяти."

"Переводит вход только на ключ: выключает пароль и запрещает root-логин.

Самый рискованный пункт меню, поэтому единственный с самопроверкой. Перед тем
как выключить пароль, скрипт заводит одноразовый ключ и реально проверяет вход
по нему. Если проверка не прошла — автоматически откатывает конфиг и оставляет
пароль включённым. Текущая сессия при этом не разрывается.

Требует отдельного пользователя (пункт 1) — из-под root не работает."

"Файрвол: закрывает все порты, кроме нужных — SSH-порта и того, что сервер уже
реально слушает на момент включения.

Автоопределение занятых портов сделано именно для того, чтобы включение UFW
не отрезало уже поднятые Docker и nginx. Но если на сервере крутится VPN или
прокси, его порт всё равно стоит проверить глазами перед включением."
)

# Параллельно ITEM_IDS — команды отката для справочного экрана (R). Пусто там,
# где пункт входит в DISABLE_SUPPORTED: для них show_rollback_reference() сама
# генерирует единую строку вместо ручных команд, так что нумерация/маркеры
# никогда не расходятся с реальным меню.
ROLLBACK_NOTES=(
"sudo deluser --remove-home <имя>          # удалить пользователя вместе с /home
     sudo gpasswd -d <имя> sudo               # или просто отобрать sudo, оставив аккаунт
     # СНАЧАЛА убедись, что остаётся хоть один способ попасть на сервер (root по ключу
     # или другой sudo-пользователь) — иначе закроешь себе доступ насовсем"
"sudo apt purge micro unzip htop bind9-dnsutils jq rsync
     (осторожно: curl/git/ca-certificates часто нужны другим программам — не удаляй не глядя)"
"sudo apt purge eza bat fd-find ripgrep zoxide ncdu
     sudo rm -f \"\$(command -v starship)\"   # если ставился этим же пунктом"
"sudo apt purge fastfetch
     sudo add-apt-repository --remove ppa:zhangsongcui3371/fastfetch
     rm -f ~/.config/fastfetch/config.jsonc
     sed -i '/# >>> vps-setup:fastfetch >>>/,/# <<< vps-setup:fastfetch <<</d' ~/.bashrc"
"sudo apt purge tmux
     rm -f ~/.tmux.conf"
"sudo systemctl stop docker
     sudo apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
     sudo rm -rf /var/lib/docker /var/lib/containerd
     # УДАЛЯЕТ все контейнеры/образы/volume без возврата — сначала забэкапь данные"
"sudo systemctl stop nginx
     sudo apt purge nginx-full
     sudo rm -rf /etc/nginx
     # УДАЛЯЕТ конфиги сайтов в /etc/nginx — если уже настраивал поверх, забэкапь"
"sudo apt purge certbot python3-certbot-nginx python3-certbot-dns-cloudflare
     sudo rm -f ${CF_CREDENTIALS}
     sudo rm -f /etc/letsencrypt/ssl-dhparams.pem /etc/letsencrypt/options-ssl-nginx.conf
     # /etc/letsencrypt/live и archive НЕ трогай, если сертификаты ещё используются"
""
""
""
""
"sudo rm -f /etc/ssh/sshd_config.d/10-hardening.conf
     sudo systemctl restart ssh
     sudo rm -f /etc/sudoers.d/${TARGET_USER}
     # возвращает вход по паролю — убедись, что есть другой способ попасть на сервер"
""
)

item_supports_disable() {
    local id="${1:-}" d
    for d in "${DISABLE_SUPPORTED[@]}"; do [ "$d" = "$id" ] && return 0; done
    return 1
}

# ── Адаптивная раскладка — один источник истины для ширины разделителей/рамок ──
# ВАЖНО про соглашение в этом блоке: функции ниже пишут результат в глобальные
# REPLY_*, а не в stdout. Это некрасиво, но принципиально: вызов через $(...) —
# это fork, а на ОДНУ перерисовку меню их приходится под сотню. Раньше здесь ещё и
# запускался python3 на каждую ячейку таблицы, что превращало отрисовку экрана
# в 3-6 секунд на слабой VPS. Теперь весь layout считается в самом bash, без единого
# внешнего процесса.
#
# TERM_W — не сырая ширина терминала, а уже за вычетом 2-пробельного отступа,
# который hr()/box_line()/строки меню всегда добавляют слева: иначе рамка
# оказывается на 2 колонки шире реального терминала, и на настоящем pty это
# рвёт многобайтовые "─" переносом строки посреди символа.
TERM_W=78
refresh_term_width() {
    local w
    w="$(tput cols 2>/dev/null)"
    [[ "$w" =~ ^[0-9]+$ ]] || w=80
    [ "$w" -lt 60 ] && w=60
    # 120x40 — целевой размер холста по TUI-стандартам (80x24 — минимум, который
    # обязан работать). Прежний потолок 100 резал широкие терминалы: статусная
    # колонка не дорастала до длинных списков недостающих пакетов
    [ "$w" -gt 120 ] && w=120
    TERM_W=$((w - 2))
}

# N штук "─" одной строкой → REPLY_DASH, с мемоизацией: за один экран одни и те же
# ширины запрашиваются десятки раз. Набирается посимвольным циклом в самом bash —
# ни seq, ни tr, ни printf-с-подстановкой. Ноль форков и полная независимость от
# locale: раньше tr на боксах с необобранным locale (LANG объявлен, но сам locale
# не собран — нередкая история на свежих VPS-образах) работал побайтово и резал
# 3-байтовый "─" на мусор.
declare -A _DASH_CACHE=()
REPLY_DASH=''
# repeat_char <символ> <N> → REPLY_DASH. Кэш общий, ключ включает символ:
# лёгкая линия "─" идёт на рамки и разделители внутри пунктов, тяжёлая "━" —
# только под шапкой (канонический разделитель заголовка в TUI-стандартах)
repeat_char() {
    local ch="${1:-─}" n="${2:-0}" key
    [ "$n" -lt 0 ] && n=0
    key="${ch}:${n}"
    if [ -z "${_DASH_CACHE[$key]:-}" ]; then
        local s='' i=0
        while [ "$i" -lt "$n" ]; do s+="$ch"; i=$((i + 1)); done
        _DASH_CACHE[$key]="$s"
    fi
    REPLY_DASH="${_DASH_CACHE[$key]}"
}
repeat_dash() { repeat_char '─' "${1:-0}"; }

hr() {
    local color="${1:-$DIM}"
    repeat_dash "$TERM_W"
    echo -e "  ${color}${REPLY_DASH}${NC}"
}

# разделитель под шапкой — тяжёлой линией, чтобы отделять «обложку» от работы
hr_heavy() {
    local color="${1:-$CYAN}"
    repeat_char '━' "$TERM_W"
    echo -e "  ${color}${REPLY_DASH}${NC}"
}

# box_line color left mid right w1 w2 ... — одна строка рамки (┌─┬─┐ / ├─┼─┤ / └─┴─┘)
box_line() {
    local color="$1" left="$2" mid="$3" right="$4"; shift 4
    local out="$left" first=true w
    for w in "$@"; do
        repeat_dash "$((w + 2))"
        if [ "$first" = true ]; then
            out="${out}${REPLY_DASH}"; first=false
        else
            out="${out}${mid}${REPLY_DASH}"
        fi
    done
    echo -e "  ${color}${out}${right}${NC}"
}

# снимает цветовые коды → REPLY_PLAIN.
# два разных вида "цветового кода" встречаются в этом файле: настоящий ESC-байт
# (\x1b) — так выглядит вывод, прошедший через echo -e/printf %b (например,
# результат status_* функций) — и буквальный 4-символьный текст "\033" — так
# выглядит цвет, если переменную типа $BOLD (объявлена в '...', без раскрытия
# escape-последовательностей) подставили в строку напрямую, минуя echo -e.
# Оба варианта не несут видимой ширины и должны вырезаться одинаково.
REPLY_PLAIN=''
strip_ansi() {
    local s="${1-}" out=''
    while [[ "$s" == *$'\e['* ]]; do
        out+="${s%%$'\e['*}"
        s="${s#*$'\e['}"
        # обрыв без завершающего "m" не должен зациклить нас на той же строке
        if [[ "$s" == *m* ]]; then s="${s#*m}"; else s=''; fi
    done
    s="${out}${s}"; out=''
    while [[ "$s" == *'\033['* ]]; do
        out+="${s%%'\033['*}"
        s="${s#*'\033['}"
        if [[ "$s" == *m* ]]; then s="${s#*m}"; else s=''; fi
    done
    REPLY_PLAIN="${out}${s}"
}

# видимая (без ANSI-кодов) длина строки в СИМВОЛАХ → REPLY_LEN. Cyrillic-safe:
# общий счётчик для паддинга/обрезки цветного текста (статусная колонка, легенда)
REPLY_LEN=0
visible_len() {
    strip_ansi "${1-}"
    if [ "$CHARLEN_NATIVE" = true ]; then
        REPLY_LEN="${#REPLY_PLAIN}"
    else
        # locale не собран — ${#s} мерит байты. Континуационные байты UTF-8
        # (10xxxxxx) собственной ширины не несут: выкидываем их, и на каждый
        # символ остаётся ровно один ведущий байт — это и есть длина в символах
        local lead="${REPLY_PLAIN//[$'\x80'-$'\xbf']/}"
        REPLY_LEN="${#lead}"
    fi
}

# дополняет строку пробелами до width → REPLY_PAD
REPLY_PAD=''
pad_title() {
    local s="${1-}" width="${2:-0}" pad
    visible_len "$s"
    pad=$((width - REPLY_LEN))
    # минимум 1 пробел паддинга — на этом держится расчёт idx_w в show_menu()
    [ "$pad" -lt 1 ] && pad=1
    printf -v REPLY_PAD '%s%*s' "$s" "$pad" ''
}

# ячейка сетки фиксированной ширины (цветной текст + добивка пробелами) → REPLY_CELL.
# В отличие от pad_title() не форсирует минимум 1 пробел: ячейки стоят вплотную
REPLY_CELL=''
grid_cell() {
    local content="${1-}" width="${2:-0}" cpad
    visible_len "$content"
    cpad=$((width - REPLY_LEN))
    [ "$cpad" -lt 0 ] && cpad=0
    printf -v REPLY_CELL '%s%*s' "$content" "$cpad" ''
}

# обрезает цветную строку до width видимых символов, добавляя "..." если длиннее,
# → REPLY_TRUNC. Предполагает, что вся строка обёрнута РОВНО в один цветовой код
# (так и есть у всех status_* — один ${COLOR}...${NC} на всю строку)
REPLY_TRUNC=''
truncate_colored() {
    local text="${1-}" width="${2:-0}"
    visible_len "$text"
    if [ "$REPLY_LEN" -le "$width" ]; then
        REPLY_TRUNC="$text"
        return
    fi
    local plain="$REPLY_PLAIN" color='' body keep=$((width - 3))
    [ "$keep" -lt 0 ] && keep=0
    # цветовой код в начале строки — в любом из двух видов (см. strip_ansi)
    if [[ "$text" == $'\e['* || "$text" == '\033['* ]] && [[ "$text" == *m* ]]; then
        color="${text%%m*}m"
    fi
    if [ "$CHARLEN_NATIVE" = true ]; then
        body="${plain:0:keep}"
    else
        # ${plain:i:1} здесь режет БАЙТЫ, а не символы. Идём вперёд и считаем
        # только ведущие байты: континуационные (10xxxxxx) дописываем к текущему
        # символу, не увеличивая счётчик. Останавливаемся ровно на начале
        # символа номер keep+1 — то есть режем по символам, а не пополам
        local i=0 n=0 ch
        body=''
        while [ "$i" -lt "${#plain}" ]; do
            ch="${plain:i:1}"
            case "$ch" in
                [$'\x80'-$'\xbf']) ;;
                *) [ "$n" -ge "$keep" ] && break; n=$((n + 1)) ;;
            esac
            body+="$ch"
            i=$((i + 1))
        done
    fi
    # Сброс дописываем, только если в строке реально был цветовой код — иначе
    # для обычного текста это добавило бы буквальный "\033[0m" как текст,
    # который потом портит и вид, и подсчёт длины в pad_title.
    #
    # Сброс берём НЕ из $NC, а того же вида, что и найденный префикс: цвет сюда
    # пришёл внутри самой строки, и закрыть его надо независимо от того, включён
    # ли цвет глобально. При NO_COLOR переменная $NC пуста, и опора на неё
    # оставила бы незакрытую последовательность, текущую на всю рамку.
    if [ -n "$color" ]; then
        local reset
        if [[ "$color" == $'\e['* ]]; then reset=$'\e[0m'; else reset='\033[0m'; fi
        REPLY_TRUNC="${color}${body}...${reset}"
    else
        REPLY_TRUNC="${body}..."
    fi
}

# ── Кэш статусов ──────────────────────────────────────────────────────────────
# status_* — самые дорогие функции в скрипте (dpkg, systemctl, sshd -T), а зовут их
# и ради текста для меню, и ради кода возврата (process_item, фильтр pending в main).
# Считаем всё разом и держим до ближайшего действия, которое реально что-то меняет.
declare -A STATUS_TEXT=() STATUS_RC=()
STATUS_DIRTY=true

invalidate_statuses() { STATUS_DIRTY=true; }

refresh_statuses() {
    [ "$STATUS_DIRTY" = false ] && return 0
    local id out rc
    for id in "${ITEM_IDS[@]}"; do
        out="$("status_${id}")"; rc=$?
        STATUS_TEXT[$id]="$out"
        STATUS_RC[$id]="$rc"
    done
    STATUS_DIRTY=false
}

# код возврата status_<id> из кэша — замена россыпи `status_"$id" >/dev/null; [ $? ... ]`
item_applied() {
    refresh_statuses
    [ "${STATUS_RC[${1}]:-1}" -eq 0 ]
}

REPLY_COLOR=''
section_color_for() {
    case "${1:-}" in
        система)  REPLY_COLOR="$YELLOW" ;;
        база)     REPLY_COLOR="$CYAN" ;;
        сервисы)  REPLY_COLOR="$BLUE" ;;
        защита)   REPLY_COLOR="$MAGENTA" ;;
        *)        REPLY_COLOR="$NC" ;;
    esac
}

show_menu() {
    refresh_term_width
    refresh_statuses
    show_header
    echo -e "  ${DIM}Пользователь:${NC} ${BOLD}${TARGET_USER}${NC}   ${DIM}SSH-порт:${NC} ${BOLD}${SSH_PORT}${NC}"
    if [ "$TARGET_USER" = "root" ]; then
        echo -e "  ${YELLOW}${BOLD}!${NC} ${YELLOW}Работа из-под root: часть настроек ляжет в /root и пропадёт после перелогина${NC}"
    fi
    echo ""

    # Колонки: # / Пункт / Статус. Отдельной колонки «Раздел» больше нет —
    # название раздела печатается один раз строкой-подзаголовком, а не
    # повторяется в каждой строке. Освободившиеся ~13 колонок уходят статусу:
    # раньше списки недостающих пакетов обрезались на «eza, bat, fd-find, z...».
    #
    # idx_w=3, не 2: pad_title всегда добавляет минимум 1 пробел-паддинга (см. её
    # реализацию), поэтому при ширине ровно "12" (2 символа) паддинг обнулялся бы
    # и принудительно поднимался до 1, ломая выравнивание рамки именно на пунктах 10-14
    local idx_w=3 title_w=26 status_w inner_w=$TERM_W
    # -10: 4 символа рамки (╭/│×2/╮ и аналоги) + по 2 паддинга на три колонки,
    # минус собственные "+2" статусной колонки, которую эта формула и вычисляет
    status_w=$(( inner_w - idx_w - title_w - 10 ))
    # 6 — минимум, при котором рамка ещё влезает в нижнюю границу TERM_W
    [ "$status_w" -lt 6 ] && status_w=6

    local c_idx c_title c_status
    box_line "$DIM" '╭' '┬' '╮' "$idx_w" "$title_w" "$status_w"
    pad_title "#"      "$idx_w";    c_idx="$REPLY_PAD"
    pad_title "Пункт"  "$title_w";  c_title="$REPLY_PAD"
    pad_title "Статус" "$status_w"; c_status="$REPLY_PAD"
    printf "  ${DIM}│${NC} ${BOLD}%s${NC} ${DIM}│${NC} ${BOLD}%s${NC} ${DIM}│${NC} ${BOLD}%s${NC} ${DIM}│${NC}\n" \
        "$c_idx" "$c_title" "$c_status"
    box_line "$DIM" '├' '┼' '┤' "$idx_w" "$title_w" "$status_w"

    local i=1 id section section_color prev_section=""
    for id in "${ITEM_IDS[@]}"; do
        local status_line status_pad
        section="${ITEM_SECTIONS[$((i-1))]}"
        section_color_for "$section"; section_color="$REPLY_COLOR"

        # сменился раздел — печатаем подзаголовок группы. Это обычная строка
        # таблицы с пустыми "#" и "Статус", поэтому разделители колонок
        # остаются на своих местах и рамка не едет
        if [ "$section" != "$prev_section" ]; then
            prev_section="$section"
            pad_title "" "$idx_w";                        c_idx="$REPLY_PAD"
            pad_title "● ${section^^}" "$title_w";        c_title="$REPLY_PAD"
            pad_title "" "$status_w";                     c_status="$REPLY_PAD"
            printf "  ${DIM}│${NC} %s ${DIM}│${NC} ${section_color}${BOLD}%s${NC} ${DIM}│${NC} %s ${DIM}│${NC}\n" \
                "$c_idx" "$c_title" "$c_status"
        fi

        # длинный статус (например, большой список недостающих пакетов) обрезаем
        # с "..." вместо того, чтобы дать ему вылезти за правую рамку — рамка должна
        # оставаться ровной на любой строке
        truncate_colored "${STATUS_TEXT[$id]:-}" "$status_w"; status_line="$REPLY_TRUNC"
        visible_len "$status_line"
        status_pad=$((status_w - REPLY_LEN))
        [ "$status_pad" -lt 0 ] && status_pad=0
        pad_title "$i" "$idx_w";                              c_idx="$REPLY_PAD"
        pad_title "  ${ITEM_TITLES[$((i-1))]}" "$title_w";    c_title="$REPLY_PAD"
        printf "  ${DIM}│${NC} %s ${DIM}│${NC} %s ${DIM}│${NC} %b%*s ${DIM}│${NC}\n" \
            "$c_idx" "$c_title" "$status_line" "$status_pad" ""
        i=$((i+1))
    done
    box_line "$DIM" '╰' '┴' '╯' "$idx_w" "$title_w" "$status_w"

    echo ""
    # legend_w = inner_w - 4: box_line/рамка сама добавляет 2 бордюрных символа
    # (┌/┐ или │/│) + 2 паддинга вокруг содержимого одной колонки — если отдать
    # ей inner_w напрямую, итоговая рамка окажется на 4 символа шире терминала
    local legend_w=$((inner_w - 4)) line
    local lbl_choice lbl_sections lbl_commands lbl_blank legend1 legend2 legend3 legend4
    pad_title "Выбор:"   10; lbl_choice="$REPLY_PAD"
    pad_title "Разделы:" 10; lbl_sections="$REPLY_PAD"
    pad_title "Команды:" 10; lbl_commands="$REPLY_PAD"
    pad_title ""         10; lbl_blank="$REPLY_PAD"
    legend1="${BOLD}${lbl_choice}${NC}${CYAN}${BOLD}5${NC} / ${CYAN}${BOLD}1 3 5${NC} / ${CYAN}${BOLD}1,3,5${NC} — один или несколько пунктов сразу"
    legend2="${lbl_blank}${DIM}буквы разделов тоже можно сочетать (B,S); применённый пункт «защиты» — повторный выбор предложит отключить${NC}"

    # Разделы:/Команды: — сеткой в равные колонки вместо инлайн-списка через
    # три пробела, чтобы пункты стояли ровно друг под другом, а не вразнобой.
    # Делим на 5, а не на 4: разделов теперь четыре (C/B/S/P) плюс хвостовое «A всё»
    # Делим на 6: четыре раздела (C/B/S/P) плюс хвостовое «A всё», а в строке
    # команд теперь пять пунктов вместо четырёх — добавилась справка I
    local item_w=$(( (legend_w - 10) / 6 )) g1 g2 g3 g4
    [ "$item_w" -lt 10 ] && item_w=10
    grid_cell "${YELLOW}${BOLD}C${NC} ${YELLOW}система${NC}"  "$item_w"; g1="$REPLY_CELL"
    grid_cell "${CYAN}${BOLD}B${NC} ${CYAN}база${NC}"         "$item_w"; g2="$REPLY_CELL"
    grid_cell "${BLUE}${BOLD}S${NC} ${BLUE}сервисы${NC}"      "$item_w"; g3="$REPLY_CELL"
    grid_cell "${MAGENTA}${BOLD}P${NC} ${MAGENTA}защита${NC}" "$item_w"; g4="$REPLY_CELL"
    legend3="${BOLD}${lbl_sections}${NC}${g1}${g2}${g3}${g4}${BOLD}A${NC} всё"
    grid_cell "${CYAN}${BOLD}I${NC} справка" "$item_w"; g1="$REPLY_CELL"
    grid_cell "${CYAN}${BOLD}H${NC} алиасы"  "$item_w"; g2="$REPLY_CELL"
    grid_cell "${CYAN}${BOLD}R${NC} откат"   "$item_w"; g3="$REPLY_CELL"
    grid_cell "${CYAN}${BOLD}U${NC} удалить" "$item_w"; g4="$REPLY_CELL"
    legend4="${BOLD}${lbl_commands}${NC}${g1}${g2}${g3}${g4}${CYAN}${BOLD}Q${NC} выход"
    box_line "$DIM" '╭' '┬' '╮' "$legend_w"
    for line in "$legend1" "$legend2" "$legend3" "$legend4"; do
        local ltrunc lpad
        truncate_colored "$line" "$legend_w"; ltrunc="$REPLY_TRUNC"
        visible_len "$ltrunc"
        lpad=$((legend_w - REPLY_LEN))
        [ "$lpad" -lt 0 ] && lpad=0
        printf "  ${DIM}│${NC} %b%*s ${DIM}│${NC}\n" "$ltrunc" "$lpad" ""
    done
    box_line "$DIM" '╰' '┴' '╯' "$legend_w"
    echo ""
}

# process_item <номер> [позиция-в-пачке] [всего-в-пачке]
# Два последних аргумента нужны только для шапки "[3/7]" в пакетном режиме.
# Возвращает код возврата apply_*/disable_* — на нём строится итоговая сводка.
process_item() {
    local idx="$1" pos="${2:-}" total="${3:-}"
    local id="${ITEM_IDS[$((idx-1))]}" title="${ITEM_TITLES[$((idx-1))]}" prefix=""
    [ -n "$pos" ] && [ -n "$total" ] && prefix="${DIM}[${pos}/${total}]${NC} "
    echo ""
    local rc=0
    if item_supports_disable "$id" && item_applied "$id"; then
        echo -e "  ${prefix}${CYAN}${BOLD}▸ Отключить: ${title}${NC}"
        hr
        "disable_${id}"; rc=$?
    else
        echo -e "  ${prefix}${CYAN}${BOLD}▸ ${title}${NC}"
        hr
        "apply_${id}"; rc=$?
    fi
    # что-то могло измениться — статусы в кэше больше не заслуживают доверия
    invalidate_statuses
    return "$rc"
}

# ── Итоговая сводка пакетного прогона ─────────────────────────────────────────
# Результат берём из РЕАЛЬНОГО состояния системы, а не из самоотчёта функций:
# многие apply_* возвращают 0 и когда пользователь просто отказался.
SUMMARY_TITLES=()
SUMMARY_RESULTS=()
SUMMARY_TIMES=()
SUMMARY_FAILED=()

summary_reset() { SUMMARY_TITLES=(); SUMMARY_RESULTS=(); SUMMARY_TIMES=(); SUMMARY_FAILED=(); }

summary_record() {
    local idx="$1" rc="$2" secs="$3"
    local id="${ITEM_IDS[$((idx-1))]}" title="${ITEM_TITLES[$((idx-1))]}" result
    if [ "$rc" -ne 0 ]; then
        result="${RED}✗ ошибка${NC}"
        SUMMARY_FAILED+=("$title")
    elif "status_${id}" >/dev/null 2>&1; then
        result="${GREEN}✓ готово${NC}"
    else
        result="${DIM}— пропущено${NC}"
    fi
    SUMMARY_TITLES+=("$title")
    SUMMARY_RESULTS+=("$result")
    SUMMARY_TIMES+=("${secs}s")
}

show_summary() {
    [ "${#SUMMARY_TITLES[@]}" -eq 0 ] && return 0
    refresh_term_width
    echo ""
    echo -e "  ${BOLD}Итоги прогона${NC}"
    local name_w=26 res_w=14 time_w=6 i t r pad
    box_line "$DIM" '╭' '┬' '╮' "$name_w" "$res_w" "$time_w"
    for i in "${!SUMMARY_TITLES[@]}"; do
        truncate_colored "${SUMMARY_TITLES[$i]}" "$name_w"; t="$REPLY_TRUNC"
        pad_title "$t" "$name_w"; t="$REPLY_PAD"
        truncate_colored "${SUMMARY_RESULTS[$i]}" "$res_w"; r="$REPLY_TRUNC"
        visible_len "$r"; pad=$((res_w - REPLY_LEN)); [ "$pad" -lt 0 ] && pad=0
        printf "  ${DIM}│${NC} %s ${DIM}│${NC} %b%*s ${DIM}│${NC} %${time_w}s ${DIM}│${NC}\n" \
            "$t" "$r" "$pad" "" "${SUMMARY_TIMES[$i]}"
    done
    box_line "$DIM" '╰' '┴' '╯' "$name_w" "$res_w" "$time_w"
    if [ "${#SUMMARY_FAILED[@]}" -gt 0 ]; then
        echo ""
        for t in "${SUMMARY_FAILED[@]}"; do
            log_warn "${t}: подробности в ${USFC_LOG}"
        done
    fi
}

show_aliases_help() {
    refresh_term_width
    show_header
    echo -e "  ${BOLD}Алиасы${NC} ${DIM}(usfc — сам при первом запуске; ls/ll/la/lt/cat/catp/scat/fd — пункт «CLI-утилиты»)${NC}"
    echo ""

    local col1=8 col2=30 col3 inner_w=$TERM_W
    # 6 = 4 бордюрных символа (│×3 + внешние) + 2 паддинга третьей колонки,
    # которую эта формула вычисляет (её собственные "+2" не должны
    # компенсироваться дважды) — тот же приём, что и в show_menu()
    col3=$(( inner_w - (col1 + 2) - (col2 + 2) - 6 ))
    [ "$col3" -lt 10 ] && col3=10

    local rows=(
        "ls|eza --icons --group-directories-first|список файлов с иконками (замена ls)"
        "ll|eza -lah --icons --group-directories-first|подробный список, аналог ls -la"
        "la|eza -a --icons --group-directories-first|список вместе со скрытыми файлами"
        "lt|eza --tree --icons --level=2 ...|дерево каталогов, 2 уровня вглубь"
        "cat|batcat --paging=never|вывод файла с подсветкой, без пейджера"
        "catp|batcat|то же, с пейджером (для длинных файлов)"
        "scat|sudo batcat --paging=never|cat для файлов, читаемых только под root"
        "fd|fdfind|быстрый поиск файлов, замена find"
        "usfc|sudo usfc + auto-source ~/.bashrc|запуск меню, .bashrc подхватится само"
    )

    box_line "$DIM" '╭' '┬' '╮' "$col1" "$col2" "$col3"
    local hdr3="Что делает" hdr3_pad h1 h2
    # col3 динамический (зависит от TERM_W) и на узких терминалах может
    # совпасть по длине с заголовком — та же ловушка pad_title(), что и у cmd_t/desc_t
    visible_len "$hdr3"; hdr3_pad=$((col3 - REPLY_LEN)); [ "$hdr3_pad" -lt 0 ] && hdr3_pad=0
    pad_title "Алиас" "$col1";            h1="$REPLY_PAD"
    pad_title "Реальная команда" "$col2"; h2="$REPLY_PAD"
    printf "  ${DIM}│${NC} ${BOLD}%s${NC} ${DIM}│${NC} ${BOLD}%s${NC} ${DIM}│${NC} ${BOLD}%s%*s${NC} ${DIM}│${NC}\n" \
        "$h1" "$h2" "$hdr3" "$hdr3_pad" ""
    box_line "$DIM" '├' '┼' '┤' "$col1" "$col2" "$col3"
    local row alias cmd desc cmd_t desc_t cmd_pad desc_pad a_t
    for row in "${rows[@]}"; do
        IFS='|' read -r alias cmd desc <<< "$row"
        truncate_colored "$cmd" "$col2";  cmd_t="$REPLY_TRUNC"
        truncate_colored "$desc" "$col3"; desc_t="$REPLY_TRUNC"
        # руками, не через pad_title(): та форсирует минимум 1 пробел паддинга,
        # а truncate_colored() при обрезке всегда возвращает СТРОКУ РОВНО В width
        # символов — pad был бы 0, форс поднял бы его до 1, и рамка бы поехала
        # (та же схема, что уже используется для status_line/легенды в show_menu())
        visible_len "$cmd_t";  cmd_pad=$((col2 - REPLY_LEN));  [ "$cmd_pad" -lt 0 ] && cmd_pad=0
        visible_len "$desc_t"; desc_pad=$((col3 - REPLY_LEN)); [ "$desc_pad" -lt 0 ] && desc_pad=0
        pad_title "$alias" "$col1"; a_t="$REPLY_PAD"
        printf "  ${DIM}│${NC} ${CYAN}%s${NC} ${DIM}│${NC} %s%*s ${DIM}│${NC} %s%*s ${DIM}│${NC}\n" \
            "$a_t" \
            "$cmd_t" "$cmd_pad" "" \
            "$desc_t" "$desc_pad" ""
    done
    box_line "$DIM" '╰' '┴' '╯' "$col1" "$col2" "$col3"

    echo ""
    log_info "eza/bat умеют работать и без алиасов: eza --icons -la, batcat file.txt и т.д."
    log_info "Почему у cat/ls вообще другое поведение под sudo — см. README, раздел FAQ"
    echo ""
    pause
}

# ── Экраны справки по пунктам ─────────────────────────────────────────────────
# Список всех пунктов с однострочным описанием и выбором номера для подробностей.
# Двухуровнево, потому что все 14 описаний целиком — это под сотню строк,
# в один экран они не влезают ни при какой ширине.
show_item_help() {
    while true; do
        refresh_term_width
        refresh_statuses
        show_header
        echo -e "  ${BOLD}Справка по пунктам${NC} ${DIM}— что делает каждый пункт меню${NC}"
        echo ""

        local i=1 id section section_color prev_section="" num_w=4 title_w=26 desc_w
        desc_w=$(( TERM_W - num_w - title_w - 4 ))
        [ "$desc_w" -lt 10 ] && desc_w=10

        for id in "${ITEM_IDS[@]}"; do
            section="${ITEM_SECTIONS[$((i-1))]}"
            section_color_for "$section"; section_color="$REPLY_COLOR"
            if [ "$section" != "$prev_section" ]; then
                prev_section="$section"
                echo -e "  ${section_color}${BOLD}● ${section^^}${NC}"
            fi
            local short
            truncate_colored "${ITEM_SHORT[$((i-1))]}" "$desc_w"; short="$REPLY_TRUNC"
            pad_title "$i" "$num_w"
            local c_num="$REPLY_PAD"
            pad_title "${ITEM_TITLES[$((i-1))]}" "$title_w"
            printf "  ${DIM}%s${NC}%s ${DIM}%s${NC}\n" "$c_num" "$REPLY_PAD" "$short"
            i=$((i+1))
        done

        echo ""
        echo -en "  ${BOLD}Номер пункта — подробности, Enter — назад:${NC} "
        local choice
        read -r choice </dev/tty
        [ -z "$choice" ] && return 0
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#ITEM_IDS[@]}" ]; then
            show_item_detail "$choice"
        else
            log_error "Нет пункта «${choice}» — введи число от 1 до ${#ITEM_IDS[@]} или Enter для выхода"
            sleep 1
        fi
    done
}

# Подробности по одному пункту. Ничего не дублирует: описание берётся из
# ITEM_FULL, текущее состояние — из кэша статусов, откат — из ROLLBACK_NOTES
# (или из того же правила про повторный выбор, что показывает экран R).
show_item_detail() {
    local idx="$1"
    local i=$((idx - 1))
    local id="${ITEM_IDS[$i]}" section="${ITEM_SECTIONS[$i]}"
    refresh_term_width
    show_header
    section_color_for "$section"
    echo -e "  ${REPLY_COLOR}${BOLD}${idx}. ${ITEM_TITLES[$i]}${NC}   ${DIM}раздел: ${section}${NC}"
    hr
    echo ""
    # описание печатаем как есть: переносы строк расставлены в тексте руками,
    # чтобы не заниматься переносом слов в шелле
    while IFS= read -r line; do
        echo -e "  ${line}"
    done <<< "${ITEM_FULL[$i]}"
    echo ""
    hr
    echo -e "  ${BOLD}Статус сейчас:${NC} ${STATUS_TEXT[$id]:-—}"
    if item_supports_disable "$id"; then
        echo -e "  ${BOLD}Откат:${NC} ${DIM}выбери пункт ${idx} в меню ещё раз — скрипт увидит, что применено, и предложит отключить${NC}"
    elif [ -n "${ROLLBACK_NOTES[$i]}" ]; then
        echo -e "  ${BOLD}Откат:${NC}"
        echo -e "     ${DIM}${ROLLBACK_NOTES[$i]}${NC}"
    fi
    pause
}

show_rollback_reference() {
    refresh_term_width
    show_header
    echo -e "  ${BOLD}Откат по пунктам${NC} ${DIM}— только справка, ни одна из этих команд не выполняется скриптом сама${NC}"
    echo ""
    local i=1 id section section_color note
    for id in "${ITEM_IDS[@]}"; do
        section="${ITEM_SECTIONS[$((i-1))]}"
        section_color_for "$section"; section_color="$REPLY_COLOR"
        echo -e "  ${section_color}${BOLD}[$i] ${ITEM_TITLES[$((i-1))]}${NC}"
        if item_supports_disable "$id"; then
            echo -e "     ${DIM}уже откатывается прямо в меню — выбери пункт [$i] ещё раз, скрипт сам увидит, что применено, и предложит отключить${NC}"
        else
            note="${ROLLBACK_NOTES[$((i-1))]}"
            echo -e "     ${DIM}${note}${NC}"
        fi
        echo ""
        i=$((i+1))
    done
    pause
}

uninstall_self() {
    echo ""
    log_warn "Это удаляет СЕБЯ (сам скрипт usfc) — /opt/vps-setup и команду usfc"
    log_info "Всё, что скрипт установил на систему (пакеты, Docker, nginx, SSH hardening и т.д.) —"
    log_info "этим не трогается. Для этого есть пункт R (справка по откату)"
    if ask_yn "Точно удалить usfc из системы?" N; then
        rm -f /usr/local/bin/usfc
        rm -rf /opt/vps-setup
        echo ""
        log_success "usfc удалён. Пока."
        exit 0
    fi
}

show_usage() {
    cat <<EOF
usfc ${VERSION} — UbuntuServer Fast Configuration
  https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration

Использование: sudo usfc [опции]

Без опций открывается интерактивное меню.

Опции:
  -h, --help       эта справка
  -V, --version    версия и выход
      --no-update  не проверять и не ставить обновления самого usfc
      --verbose    показывать сырой вывод команд вместо спиннера

Переменные окружения:
  USFC_NO_UPDATE=1          то же, что --no-update
  USFC_VERBOSE=1            то же, что --verbose
  USFC_KEEP_LOCALE=1        не форсировать LC_ALL=C.UTF-8
  NO_COLOR=1                вывод без цвета (цвет отключается сам, если
                            TERM=dumb или вывод идёт не в терминал)
  USFC_APT_LOCK_TIMEOUT=N   сколько секунд ждать освобождения блокировки dpkg
                            (по умолчанию ${APT_LOCK_TIMEOUT}; на свежем сервере её
                            держит unattended-upgrades)

Лог всех выполненных команд: ${USFC_LOG}
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)    show_usage; exit 0 ;;
            -V|--version) echo "$VERSION"; exit 0 ;;
            --no-update)  USFC_NO_UPDATE=1 ;;
            --verbose)    USFC_VERBOSE=1 ;;
            *)
                echo "Неизвестная опция: $1" >&2
                echo "" >&2
                show_usage >&2
                exit 2
                ;;
        esac
        shift
    done
}

main() {
    # curl за VERSION стартует ПЕРВЫМ и крутится в фоне, пока идёт вся локальная
    # работа ниже — так проверка обновлений остаётся на каждом запуске, но
    # перестаёт быть последовательной задержкой перед первым экраном
    start_update_check
    log_init

    show_header
    log_info "Пользователь: ${BOLD}${TARGET_USER}${NC} ${DIM}(${TARGET_HOME})${NC}"
    log_info "SSH-порт: ${SSH_PORT}"

    # usfc-обёртка — не отдельный пункт меню, ставится сама при первом запуске,
    # свой маркер, идемпотентно. Пропускаем для прямого root — sudo тут бесполезен
    # (и может быть даже не установлен на такой машине).
    # Это bash-ФУНКЦИЯ, а не alias: после того как дочерний sudo-процесс меню
    # завершится, функция сама делает "source ~/.bashrc" — но уже в ТЕКУЩЕЙ
    # интерактивной оболочке (функции выполняются в вызывающем шелле, не в
    # подпроцессе), так что новые алиасы/промпт подхватываются без ручного
    # source и без переподключения. USFC_RESOURCE гейтит fastfetch-автозапуск
    # (см. apply_fastfetch) — иначе баннер печатался бы второй раз при каждом
    # выходе из меню.
    install_usfc_wrapper

    # apt-get update со старта убран: списки нужны только перед реальной установкой,
    # и ensure_apt_updated возьмёт их сам, если они успели протухнуть. Просто открыть
    # меню и посмотреть статусы теперь не стоит ни одного сетевого запроса.
    refresh_pkg_cache

    # Версию сверяем при КАЖДОМ запуске — но curl уже крутится в фоне (см. main),
    # пока считался кэш пакетов, так что ждать почти нечего.
    if check_for_update; then
        pause
    fi

    # Голый root — самый частый способ получить VPS. Предлагаем завести нормального
    # пользователя ДО того, как что-то поставится в /root и потеряется при перелогине.
    if [ "$TARGET_USER" = "root" ] && [ "$ROOT_PROMPT_SHOWN" = false ]; then
        ROOT_PROMPT_SHOWN=true
        echo ""
        log_warn "Скрипт запущен от имени root."
        log_info "РЕКОМЕНДУЮ создать обычного пользователя с sudo: работать из-под root"
        log_info "небезопасно, SSH hardening без отдельного пользователя не работает вообще,"
        log_info "а алиасы/fastfetch/tmux сейчас лягут в /root и пропадут после перелогина."
        echo ""
        if ask_yn "Создать пользователя сейчас?" Y; then
            apply_newuser
            invalidate_statuses
        else
            log_info "Ок. Пункт 1 в меню доступен в любой момент."
        fi
        pause
    fi

    while true; do
        show_menu
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        read -r choice </dev/tty
        case "$choice" in
            [Qq]) echo ""; log_info "Пока. Повторный запуск: usfc"; break ;;
            [Hh]) show_aliases_help ;;
            # "?" как синоним I: привычнее для тех, кто ищет справку вслепую
            [Ii]|'?') show_item_help ;;
            [Rr]) show_rollback_reference ;;
            [Uu]) uninstall_self; pause ;;
            *)
                # номера и буквы разделов вперемешку через пробел/запятую:
                # "5", "1 3 5", "1,3,5", "B", "B,S", "B,14" — всё разбирается одинаково
                local -a nums valid=()
                IFS=', ' read -ra nums <<< "$choice"
                local tok upper i
                for tok in "${nums[@]}"; do
                    [ -z "$tok" ] && continue
                    upper="${tok^^}"
                    if [ "$upper" = "A" ]; then
                        for ((i = 1; i <= ${#ITEM_IDS[@]}; i++)); do valid+=("$i"); done
                    elif expand_section_letter "$upper"; then
                        # номера раздела выводятся из ITEM_SECTIONS, а не зашиты числами —
                        # добавление пункта больше не может разойтись с буквами
                        # shellcheck disable=SC2206
                        valid+=($REPLY_SECTION_ITEMS)
                    elif [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "${#ITEM_IDS[@]}" ]; then
                        valid+=("$tok")
                    else
                        log_error "Нет пункта «${tok}»"
                    fi
                done

                # убрать дубликаты, сохраняя порядок (могут возникнуть при пересечении, например "3,B")
                local -a dedup=()
                local n already
                for n in "${valid[@]}"; do
                    already=false
                    for i in "${dedup[@]}"; do [ "$i" = "$n" ] && already=true && break; done
                    [ "$already" = false ] && dedup+=("$n")
                done
                valid=("${dedup[@]}")

                if [ "${#valid[@]}" -eq 0 ]; then
                    log_error "Не понял ввод — номер пункта, буква раздела (C/B/S/P/A), можно сочетать через пробел/запятую, либо I, H, R, U, Q"
                    sleep 1
                elif [ "${#valid[@]}" -eq 1 ]; then
                    # один пункт — как обычно, интерактивно, со всеми вопросами внутри
                    process_item "${valid[0]}"
                    pause
                else
                    # несколько пунктов разом — сначала убираем то, что уже применено
                    # (иначе "B,S" при частично готовой системе будет зря переспрашивать про то, что и так стоит)
                    local -a pending=() pending_ids=()
                    local id
                    for n in "${valid[@]}"; do
                        id="${ITEM_IDS[$((n-1))]}"
                        if ! item_applied "$id"; then
                            pending+=("$n")
                            pending_ids+=("$id")
                        fi
                    done

                    echo ""
                    if [ "${#pending[@]}" -eq 0 ]; then
                        log_info "Из выбранного (${valid[*]}) уже всё применено"
                        sleep 1
                    else
                        log_info "Не применено из выбранного: ${pending[*]} (${#pending[@]} шт.)"
                        log_info "Каждый пункт применится со своими настройками по умолчанию, без вопросов по ходу"

                        # Всё, что нельзя молча задефолтить, спрашиваем ЗДЕСЬ — до
                        # BULK_MODE=true, пока ask_yn/ask_value ещё интерактивны.
                        # Сверяемся по id, а не по номеру пункта: номера меняются при
                        # добавлении пунктов, id — нет.
                        local pid
                        for pid in "${pending_ids[@]}"; do
                            case "$pid" in
                                zram)
                                    read_swap_state
                                    if ! { [ "$ZRAM_ACTIVE" = true ] && [ "$ZRAM_PRIO" = "100" ]; }; then
                                        ZRAM_BULK_PERCENT="$(ask_value "Размер zram в % от RAM?" 75)"
                                    fi
                                    if [ "$SWAP_ACTIVE" != true ]; then
                                        SWAP_BULK_MB="$(ask_value "Размер резервного swap-файла, МБ?" "$(suggest_swap_mb)")"
                                    elif [ "$SWAP_TYPE" = "file" ]; then
                                        # своп есть, но размер мог разъехаться с рекомендацией —
                                        # спрашиваем ЗДЕСЬ, пока ask_value ещё интерактивна
                                        local sw_want
                                        sw_want="$(suggest_swap_mb "$SWAP_SIZE_MB")"
                                        if swap_needs_resize "$SWAP_SIZE_MB" "$sw_want"; then
                                            log_info "Своп ${SWAP_PATH}: сейчас ${SWAP_SIZE_MB} МБ, рекомендуется ${sw_want} МБ"
                                            SWAP_BULK_MB="$(ask_value "Размер резервного swap-файла, МБ?" "$sw_want")"
                                        fi
                                    fi
                                    ;;
                                nginx)
                                    ask_yn "Запускать nginx после установки (и включать автозапуск)?" N \
                                        && NGINX_AUTOSTART=Y || NGINX_AUTOSTART=N
                                    ;;
                                docker)
                                    ask_yn "Запускать Docker после установки (и включать автозапуск)?" N \
                                        && DOCKER_AUTOSTART=Y || DOCKER_AUTOSTART=N
                                    ;;
                            esac
                        done

                        if ask_yn "Применить сразу?"; then
                            BULK_MODE=true
                            summary_reset
                            local pos=0 rc0 t0
                            for num in "${pending[@]}"; do
                                pos=$((pos + 1))
                                now_s; t0="$REPLY_NOW"
                                process_item "$num" "$pos" "${#pending[@]}"; rc0=$?
                                now_s
                                summary_record "$num" "$rc0" "$((REPLY_NOW - t0))"
                            done
                            BULK_MODE=false
                            show_summary
                        fi
                        ZRAM_BULK_PERCENT=""
                        SWAP_BULK_MB=""
                        # shellcheck disable=SC2034
                        NGINX_AUTOSTART=""
                        # shellcheck disable=SC2034
                        DOCKER_AUTOSTART=""
                        pause
                    fi
                fi
                ;;
        esac
    done

    print_relogin_hint

    if [ -f /var/run/reboot-required ]; then
        echo ""
        log_warn "Требуется перезагрузка сервера (было обновление ядра/библиотек)"
    fi
    echo ""
}

# USFC_SOURCE_ONLY=1 — загрузить функции, не запуская меню. Нужно тестам,
# заодно защищает от случайного `source setup.sh`
if [ -z "${USFC_SOURCE_ONLY:-}" ]; then
    parse_args "$@"
    main
fi
