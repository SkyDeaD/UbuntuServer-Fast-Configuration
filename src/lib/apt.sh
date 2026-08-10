# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

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

# Отдельного предупреждения «пакетный менеджер занят» здесь больше нет. Оно
# гадало по pgrep и срабатывало от одного факта, что unattended-upgrades
# запущен, — даже когда ставить было нечего и ждать не пришлось ни секунды.
# Настоящую причину задержки сообщает спиннер: он читает её из вывода самого
# apt («Waiting for cache lock: ... held by process N») и говорит только тогда,
# когда ожидание реально происходит.

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
    run_logged "Обновление списков пакетов apt" apt_get update -qq
    APT_UPDATED=true
    refresh_pkg_cache
}

# ensure_pkg <описание> <пакет...> — ставит только то, чего ещё нет.
# Раньше apt install звался безусловно: на уже установленном пакете это no-op,
# но перед ним успевал сходить по сети apt update. Пункт «UFW» на сервере, где
# ufw уже стоит, из-за этого выглядел так, будто чего-то ждёт от пакетного
# менеджера, хотя ставить было нечего.
ensure_pkg() {
    local desc="$1"; shift
    # имя намеренно уникальное: shellcheck сводит одноимённые локальные
    # переменные разных функций в одну и ругается на смену типа
    local p to_install=()
    for p in "$@"; do
        pkg_installed "$p" || to_install+=("$p")
    done
    [ "${#to_install[@]}" -eq 0 ] && return 0
    ensure_apt_updated
    run_logged "$desc" apt_get install -y "${to_install[@]}" || return 1
    refresh_pkg_cache
    return 0
}
