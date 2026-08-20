# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# Короткие описания — чтобы после установки было видно не только ЧТО приехало,
# но и зачем оно нужно. Пишем руками по-русски: apt-cache show даёт английский
# текст на несколько абзацев и вразнобой по стилю, в одну строку он не ложится.
declare -A PKG_DESC=(   # i18n-ok: английская пара — PKG_DESC_EN ниже
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
    [btop]="монитор процессов и нагрузки, наглядная замена htop"
)

# Вторая карта, а не «ru|en» в одной строке: PKG_DESC читается ещё и тестом
# раскладки, и разделитель внутри значения ему пришлось бы разбирать.
declare -A PKG_DESC_EN=(
    [micro]="a terminal text editor that makes more sense than vim"
    [curl]="downloading over HTTP from the command line"
    [wget]="file downloads, handles resume and recursion"
    [git]="version control system"
    [nano]="simple editor, present on almost any server"
    [unzip]="unpacking zip archives"
    [htop]="interactive process and load monitor"
    [bind9-dnsutils]="dig and nslookup — DNS diagnostics"
    [jq]="parsing and filtering JSON in shell scripts"
    [software-properties-common]="provides add-apt-repository for PPAs"
    [ca-certificates]="root certificates, HTTPS does not work without them"
    [gnupg]="verifying package and repository signatures"
    [rsync]="syncing files and folders, including over SSH"
    [eza]="an ls replacement: icons, colours, directory trees"
    [bat]="a cat replacement with syntax highlighting"
    [fd-find]="a find replacement — simpler syntax, noticeably faster"
    [ripgrep]="fast search through file contents"
    [zoxide]="a smarter cd that jumps to frequently used directories"
    [ncdu]="shows what exactly is eating your disk space"
    [btop]="process and load monitor, a much nicer htop"
)

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

# pkg_candidate_mb <пакет> — знает ли apt такой пакет и сколько весит закачка.
# Размер попадает в REPLY_PKG_MB (0, если apt его не сообщил), возврат 1 —
# кандидата нет вовсе.
#
# Размер спрашиваем у apt, а не пишем числом прямо в сообщении: пакеты модулей
# ядра растут от выпуска к выпуску, и зашитая цифра устареет молча, ничего
# при этом не сломав, — то есть врать будет долго.
#
# awk без `exit` намеренно: досрочный выход в конвейере роняет продюсера по
# SIGPIPE ровно так же, как запрещённый в этом репозитории `| grep -q`
REPLY_PKG_MB=0
pkg_candidate_mb() {
    REPLY_PKG_MB=0
    local cand bytes
    cand="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{c=$2} END{print c}')"
    [ -n "$cand" ] && [ "$cand" != "(none)" ] || return 1
    bytes="$(apt-cache show "$1" 2>/dev/null | awk '/^Size:/{if (s == "") s=$2} END{print s}')"
    [[ "$bytes" =~ ^[0-9]+$ ]] && REPLY_PKG_MB=$(( bytes / 1048576 ))
    return 0
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
    # В сухом прогоне ничего не ставилось, и обычная логика («apt отчитался,
    # а пакета нет») пометила бы КАЖДЫЙ пакет крестом, будто всё сломалось
    local dry=false
    [ "$USFC_DRY_RUN" = true ] && dry=true
    # 5 — отступ слева и маркер с пробелом; остальное отдаём описанию
    desc_w=$(( TERM_W - 5 - name_w - 1 ))
    [ "$desc_w" -lt 10 ] && desc_w=10
    echo ""
    for p in "$@"; do
        if [ "$dry" = true ] && [ -z "${PKG_WAS[$p]:-}" ]; then
            mark='+'; color="$DIM"
        elif [ -n "${PKG_WAS[$p]:-}" ]; then
            mark='·'; color="$DIM"
        elif pkg_installed "$p"; then
            mark='+'; color="$GREEN"
        else
            # apt отчитался успехом, но пакета нет — например, имя оказалось
            # виртуальным. Молчать об этом нельзя
            mark='✗'; color="$RED"
        fi
        if [ "$USFC_LANG" = en ]; then desc="${PKG_DESC_EN[$p]:-}"; else desc="${PKG_DESC[$p]:-}"; fi
        truncate_colored "$desc" "$desc_w"; desc="$REPLY_TRUNC"
        pad_title "$p" "$name_w"
        printf "     %b%s%b %s${DIM}%s${NC}\n" "$color" "$mark" "$NC" "$REPLY_PAD" "$desc"
    done
    if [ "$dry" = true ]; then
        t "— был бы установлен    " "— would be installed   "; local _l1="$REPLY_T"
        t "— уже есть в системе" "— already present"
        echo -e "     ${DIM}+${NC}${DIM} ${_l1}${NC}${DIM}·${NC}${DIM} ${REPLY_T}${NC}"
    else
        t "— установлен сейчас    " "— installed just now   "; local _l1="$REPLY_T"
        t "— уже был в системе" "— was already there"
        echo -e "     ${GREEN}+${NC}${DIM} ${_l1}${NC}${DIM}·${NC}${DIM} ${REPLY_T}${NC}"
    fi
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
apt_get() {
    # Второй рубеж сухого прогона: часть вызовов идёт мимо run_logged
    # (например, apt_get update -qq внутри ensure_apt_updated). Читающие
    # подкоманды пропускаем — они системе ничего не делают, а без них
    # сухой прогон врал бы о том, что уже установлено
    if [ "$USFC_DRY_RUN" = true ]; then
        case "${1:-}" in
            list|show|policy|search|-v|--version) ;;
            *) _dry_say "apt-get $*"; return 0 ;;
        esac
    fi
    apt-get -o DPkg::Lock::Timeout="$APT_LOCK_TIMEOUT" "$@"
}

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
    t "Обновление списков пакетов apt" "Refreshing apt package lists"
    run_logged "$REPLY_T" apt_get update -qq
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
