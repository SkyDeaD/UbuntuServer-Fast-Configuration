# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: приветствие при входе (карточка сервера) ───────────────────
usfc_item motd база "Приветствие при входе" \
    "карточка сервера вместо стандартного приветствия" \
    "Login greeting" \
    "a server card instead of the stock greeting"
usfc_item_toggle motd

usfc_item_full motd "Ставит скрипт /etc/update-motd.d/01-usfc: при входе по SSH показывает
карточку сервера — имя, ОС, ядро, виртуализацию, IP, uptime, нагрузку, число
vCPU, полоски RAM и диска, swap (zram и файл отдельно), число запущенных
контейнеров Docker и предупреждения (есть обновления, нужна перезагрузка).

Скрипт самодостаточный, без сети и без внешних запросов: обновления берутся
только из кэша Ubuntu (/var/lib/update-notifier/updates-available), на Debian
этой строки нет. Язык надписей запоминается в момент установки.

Стандартное приветствие (Ubuntu: 00-header, 10-help-text, 50-motd-news,
50-landscape-sysinfo…; Debian: 10-uname и /etc/motd) и скрипты провайдера из
/etc/update-motd.d показываются списком; с вашего согласия у них снимается
право на запуск, а /etc/motd опустошается. Что именно выключено — записано в
/etc/usfc/motd-disabled, повторный выбор пункта возвращает всё как было." \
"Installs /etc/update-motd.d/01-usfc: on SSH login it prints a server card —
host name, OS, kernel, virtualisation, IP, uptime, load, vCPU count, RAM and
disk bars, swap (zram and file separately), the number of running Docker
containers and warnings (updates available, reboot required).

The script is self-contained and makes no network calls: updates come only
from the Ubuntu cache (/var/lib/update-notifier/updates-available); Debian
has no such line. The label language is fixed at install time.

The stock greeting (Ubuntu: 00-header, 10-help-text, 50-motd-news,
50-landscape-sysinfo…; Debian: 10-uname and /etc/motd) and provider scripts in
/etc/update-motd.d are listed; with your consent they lose the execute bit and
/etc/motd is emptied. What was switched off is recorded in
/etc/usfc/motd-disabled; choosing the item again restores everything."

usfc_item_rollback motd "sudo rm -f /etc/update-motd.d/01-usfc
     # вернуть выключенное: список — в /etc/usfc/motd-disabled (строки S: режим и путь)
     sudo chmod +x /etc/update-motd.d/00-header   # и так для каждого из списка
     sudo cp /etc/usfc/motd.orig /etc/motd        # если /etc/motd опустошали" \
"sudo rm -f /etc/update-motd.d/01-usfc
     # restore what was switched off: the list is in /etc/usfc/motd-disabled (S lines: mode and path)
     sudo chmod +x /etc/update-motd.d/00-header   # and so on for every listed file
     sudo cp /etc/usfc/motd.orig /etc/motd        # if /etc/motd was emptied"

MOTD_FILE="/etc/update-motd.d/01-usfc"
MOTD_DIR="/etc/update-motd.d"
MOTD_STATE="/etc/usfc/motd-disabled"
MOTD_ORIG="/etc/usfc/motd.orig"
MOTD_STATIC="/etc/motd"

status_motd() {
    if [ -f "$MOTD_FILE" ] && [ -x "$MOTD_FILE" ]; then
        st "$GREEN" "✓ карточка установлена" "✓ card installed"; return 0
    fi
    st "$DIM" "○ не включено" "○ not enabled"; return 1
}

# ── Скрипт карточки ──────────────────────────────────────────────────────────
# Подпись с переводом запекается в скрипт при генерации (t → REPLY_T → _motd_bake):
# так сам скрипт не знает про языки,
# а язык фиксируется на момент установки. Одинарных кавычек в текстах нет.
_motd_bake() { printf "%s='%s'\n" "$1" "$REPLY_T"; }

# Печатает готовый скрипт в stdout. Отдельной функцией, чтобы тест мог
# запустить его, не трогая систему
motd_card_script() {
    printf '%s\n' '#!/bin/bash'
    t "# Создано usfc (пункт «Приветствие при входе»), версия карточки 1." \
"# Created by usfc (item \"Login greeting\"), card version 1."
    printf '%s\n' "$REPLY_T"
    t "# Не редактируйте: usfc перезапишет файл. Убрать — повторный выбор пункта в usfc." \
"# Do not edit: usfc will overwrite it. To remove, select the item again in usfc."
    printf '%s\n' "$REPLY_T"
    t "аптайм" "uptime"; _motd_bake L_UP
    t "нагрузка" "load"; _motd_bake L_LOAD
    t "Диск" "Disk"; _motd_bake L_DISK
    t "Swap" "Swap"; _motd_bake L_SWAP
    t "диск" "disk"; _motd_bake L_SWAPF
    t "Docker" "Docker"; _motd_bake L_DOCKER
    t "контейнеров запущено" "containers running"; _motd_bake L_DRUN
    t "демон не запущен" "daemon not running"; _motd_bake L_DDOWN
    t "обновлений" "updates"; _motd_bake L_UPD
    t "безопасности" "security"; _motd_bake L_SEC
    t "нужна перезагрузка" "reboot required"; _motd_bake L_REBOOT
    t "д" "d"; _motd_bake U_D
    t "ч" "h"; _motd_bake U_H
    t "мин" "min"; _motd_bake U_M
    cat <<'BODY'
set -u
shopt -s extglob nullglob

W=60   # внутренняя ширина рамки; вся карточка — W+2 колонки
BW=20  # ширина полоски

# Считает ли ${#s} символы. В C-локали это байты: тогда рамку рисуем ASCII,
# а длину кириллицы считаем по ведущим байтам UTF-8 (как делает сам usfc)
_p='─'
if [ "${#_p}" -eq 1 ]; then
    NATIVE=1; TL='╭'; TR='╮'; BL='╰'; BR='╯'; H='─'; V='│'; FULL='█'; EMPTY='░'; DOT='·'
else
    NATIVE=0; TL='+'; TR='+'; BL='+'; BR='+'; H='-'; V='|'; FULL='#'; EMPTY='.'; DOT='-'
fi

E=$'\e'
C0="${E}[0m"; DIM="${E}[2m"; CYN="${E}[36m"; GRN="${E}[32m"; YEL="${E}[33m"; RED="${E}[31m"; BLD="${E}[1m"

# видимая длина (без ANSI) → L
L=0
vlen() {
    local s="${1//"$E"\[*([0-9;])m/}"
    if [ "$NATIVE" = 1 ]; then L=${#s}
    else s="${s//[$'\x80'-$'\xbf']/}"; L=${#s}; fi
}

OUT=''
row() {
    local pad
    vlen "$1"
    pad=$((W - 2 - L)); [ "$pad" -lt 0 ] && pad=0
    printf -v pad '%*s' "$pad" ''
    OUT+="${CYN}${V}${C0} $1${pad} ${CYN}${V}${C0}"$'\n'
}

# метка, дополненная до 7 колонок → LB
LB=''
lab() {
    local pad
    vlen "$1"
    pad=$((7 - L)); [ "$pad" -lt 1 ] && pad=1
    printf -v pad '%*s' "$pad" ''
    LB="${CYN}$1${C0}${pad}"
}

# KiB → «280M» / «1.9G» → HS
HS=''
hsz() {
    local k=$1 t
    if [ "$k" -ge 1048576 ]; then t=$((k * 10 / 1048576)); HS="$((t / 10)).$((t % 10))G"
    else HS="$((k / 1024))M"; fi
}

# процент → BAR (цвет по порогам)
BAR=''
bar() {
    local p=$1 n c full empty
    n=$((p * BW / 100)); [ "$n" -gt "$BW" ] && n=$BW
    printf -v full '%*s' "$n" ''; full=${full// /$FULL}
    printf -v empty '%*s' "$((BW - n))" ''; empty=${empty// /$EMPTY}
    if [ "$p" -ge 90 ]; then c=$RED; elif [ "$p" -ge 70 ]; then c=$YEL; else c=$GRN; fi
    BAR="${c}${full}${DIM}${empty}${C0}"
}

# строка-метр: метка, used KiB, total KiB
meter() {
    local p=0
    [ "$3" -gt 0 ] && p=$(($2 * 100 / $3))
    lab "$1"; bar "$p"
    local u t; hsz "$2"; u=$HS; hsz "$3"; t=$HS
    row "$LB$BAR $(printf '%3d%%' "$p")  $u / $t"
}

# ── сбор данных (только чтение /proc, /sys и несколько утилит) ──
HOST=''; read -r HOST < /proc/sys/kernel/hostname 2>/dev/null
[ -n "$HOST" ] || HOST='?'
HOST=${HOST:0:36}
KERN=''; read -r KERN < /proc/sys/kernel/osrelease 2>/dev/null
KERN=${KERN:0:22}
OS=''
if [ -r /etc/os-release ]; then
    while IFS='=' read -r k v; do
        if [ "$k" = PRETTY_NAME ]; then v=${v#\"}; OS=${v%\"}; break; fi
    done < /etc/os-release
fi
[ -n "$OS" ] || OS=Linux
OS=${OS:0:32}

VIRT=''
if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT=$(systemd-detect-virt 2>/dev/null) || VIRT=''
    [ "$VIRT" = none ] && VIRT=''
fi

IP=''
if command -v ip >/dev/null 2>&1; then
    r=$(ip -4 -o route get 1.1.1.1 2>/dev/null) || r=''
    [[ $r =~ src\ ([0-9.]+) ]] && IP=${BASH_REMATCH[1]}
fi
if [ -z "$IP" ] && command -v hostname >/dev/null 2>&1; then
    set -- $(hostname -I 2>/dev/null)
    IP=${1:-}
fi
[ -n "$IP" ] || IP='-'

cpus=0
if [ -r /sys/devices/system/cpu/online ]; then
    read -r on < /sys/devices/system/cpu/online
    IFS=, read -ra parts <<< "$on"
    for r in "${parts[@]}"; do cpus=$((cpus + ${r#*-} - ${r%-*} + 1)); done
fi
if [ "$cpus" -lt 1 ] && command -v nproc >/dev/null 2>&1; then cpus=$(nproc 2>/dev/null) || cpus=0; fi

up=0; read -r up _ < /proc/uptime 2>/dev/null; up=${up%.*}
d=$((up / 86400)); h=$((up % 86400 / 3600)); m=$((up % 3600 / 60))
if [ "$d" -gt 0 ]; then UPT="$d $U_D $h $U_H"
elif [ "$h" -gt 0 ]; then UPT="$h $U_H $m $U_M"
else UPT="$m $U_M"; fi
l1=0; l5=0; l15=0; read -r l1 l5 l15 _ < /proc/loadavg 2>/dev/null

mt=0; ma=0
while IFS=': ' read -r k v _; do
    case $k in
        MemTotal) mt=$v ;;
        MemAvailable) ma=$v; break ;;
    esac
done < /proc/meminfo
mu=$((mt - ma))

dt=0; du=0
dfo=$(df -Pk / 2>/dev/null) || dfo=''
if [ -n "$dfo" ]; then
    read -r _ dt du _ <<< "${dfo##*$'\n'}"
fi
[[ $dt =~ ^[0-9]+$ ]] || dt=0
[[ $du =~ ^[0-9]+$ ]] || du=0

zt=0; zu=0; ft=0; fu=0
if [ -r /proc/swaps ]; then
    while read -r name _ size used _; do
        [[ $size =~ ^[0-9]+$ ]] || continue
        case $name in
            /dev/zram*) zt=$((zt + size)); zu=$((zu + used)) ;;
            *) ft=$((ft + size)); fu=$((fu + used)) ;;
        esac
    done < /proc/swaps
fi

# Docker: считаем cgroup запущенных контейнеров — без обращения к демону, оно
# может висеть. Нулевой счёт перепроверяем CLI с жёстким таймаутом
DK=''
if command -v docker >/dev/null 2>&1 || [ -x /usr/bin/docker ]; then
    if [ -S /run/docker.sock ] || [ -S /var/run/docker.sock ]; then
        cg=( /sys/fs/cgroup/system.slice/docker-*.scope /sys/fs/cgroup/docker/*/ \
             /sys/fs/cgroup/memory/docker/*/ /sys/fs/cgroup/memory/system.slice/docker-*.scope )
        # в каталоге docker/ бывают и служебные имена (buildkit…): считаем
        # только 64-значные идентификаторы контейнеров
        n=0
        for r in "${cg[@]}"; do
            [[ ${r%/} =~ [0-9a-f]{64}(\.scope)?$ ]] && n=$((n + 1))
        done
        if [ "$n" -eq 0 ] && command -v timeout >/dev/null 2>&1; then
            if mapfile -t ids < <(timeout 2 docker ps -q 2>/dev/null); then n=${#ids[@]}; fi
        fi
        DK="$L_DRUN: $n"
    else
        DK="$L_DDOWN"
    fi
fi

UPD=0; SEC=''
f=/var/lib/update-notifier/updates-available
if [ -r "$f" ]; then
    while IFS= read -r line; do
        if [[ $line =~ ^([0-9]+)\ updates?\ can\ be\ applied ]]; then UPD=${BASH_REMATCH[1]}
        elif [[ $line =~ ^([0-9]+)\ of\ these ]]; then SEC=${BASH_REMATCH[1]}; fi
    done < "$f"
fi

# ── вывод ──
sep=" $DOT "
vlen "$HOST"
printf -v fill '%*s' "$((W - 3 - L))" ''; fill=${fill// /$H}
OUT+=$'\n'"${CYN}${TL}${H} ${C0}${BLD}${HOST}${C0}${CYN} ${fill}${TR}${C0}"$'\n'

row "$OS$sep$KERN"
l2="$IP"
[ -n "$VIRT" ] && l2+="$sep$VIRT"
[ "$cpus" -gt 0 ] && l2+="$sep$cpus vCPU"
row "$l2"
row "$L_UP $UPT$sep$L_LOAD $l1 $l5 $l15"
row ''
meter RAM "$mu" "$mt"
meter "$L_DISK" "$du" "$dt"
if [ "$zt" -gt 0 ] || [ "$ft" -gt 0 ]; then
    lab "$L_SWAP"; s=''
    if [ "$zt" -gt 0 ]; then hsz "$zu"; a=$HS; hsz "$zt"; s="zram $a / $HS"; fi
    if [ "$ft" -gt 0 ]; then
        hsz "$fu"; a=$HS; hsz "$ft"
        [ -n "$s" ] && s+="$sep"
        s+="$L_SWAPF $a / $HS"
    fi
    row "$LB$s"
fi
if [ -n "$DK" ]; then lab "$L_DOCKER"; row "$LB$DK"; fi

warn=''
if [ "$UPD" -gt 0 ]; then
    w="$L_UPD: $UPD"; [ -n "$SEC" ] && w+=" ($L_SEC: $SEC)"
    warn+="${YEL}! $w${C0}"$'\n'
fi
[ -f /var/run/reboot-required ] && warn+="${YEL}! $L_REBOOT${C0}"$'\n'
if [ -n "$warn" ]; then
    row ''
    while IFS= read -r line; do row "$line"; done <<< "${warn%$'\n'}"
fi

printf -v fill '%*s' "$W" ''; fill=${fill// /$H}
OUT+="${CYN}${BL}${fill}${BR}${C0}"$'\n\n'
printf '%s' "$OUT"
BODY
}

# ── Стандартное приветствие ──────────────────────────────────────────────────
# pam_motd (sshd, login) на Ubuntu 24.04/26.04 и Debian 12/13 запускает всё
# исполняемое из /etc/update-motd.d, складывает вывод в /run/motd.dynamic и
# следом показывает статичный /etc/motd; PrintMotd в sshd_config — no, чтобы
# не дублировать (проверено в контейнерах). Поэтому «выключить» скрипт —
# снять +x, а статичное — опустошить файл.
#
# MOTD_FOUND — исполняемые скрипты, кроме нашего; MOTD_HAS_STATIC — в /etc/motd
# что-то есть
MOTD_FOUND=()
MOTD_HAS_STATIC=false
motd_scan() {
    local f
    MOTD_FOUND=()
    MOTD_HAS_STATIC=false
    for f in "$MOTD_DIR"/*; do
        [ "$f" = "$MOTD_FILE" ] && continue
        [ -f "$f" ] && [ -x "$f" ] && MOTD_FOUND+=("$f")
    done
    [ -s "$MOTD_STATIC" ] && MOTD_HAS_STATIC=true
    return 0
}

_motd_show_found() {
    local f
    log_info_t "Найдено стандартное приветствие и скрипты провайдера:" \
"Found the stock greeting and provider scripts:"
    for f in "${MOTD_FOUND[@]+"${MOTD_FOUND[@]}"}"; do echo "    ${f}"; done
    [ "$MOTD_HAS_STATIC" = true ] && echo "    ${MOTD_STATIC}"
    return 0
}

# Вопрос пакетного режима: заранее, тем же ответом, что даст меню
preask_motd() {
    [ -n "${MOTD_CLEAN_BULK:-}" ] && return 0
    motd_scan
    [ "${#MOTD_FOUND[@]}" -gt 0 ] || [ "$MOTD_HAS_STATIC" = true ] || return 0
    echo ""
    _motd_show_found
    ask_yn_t "Отключить всё это и оставить только карточку?" "Turn all of this off and keep only the card?" Y \
        && MOTD_CLEAN_BULK=Y || MOTD_CLEAN_BULK=N
}

# Снять +x и опустошить /etc/motd, записав сделанное в MOTD_STATE.
# Снимок write_file хранит содержимое, но не права — поэтому режимы и список
# пишем сами: по нему disable_motd вернёт ровно то, что выключили мы
_motd_silence() {
    local f mode state="" old=""
    [ -f "$MOTD_STATE" ] && old="$(cat "$MOTD_STATE" 2>/dev/null)"
    for f in "${MOTD_FOUND[@]+"${MOTD_FOUND[@]}"}"; do
        mode="$(stat -L -c %a "$f" 2>/dev/null)" || continue
        state+="S	${mode}	${f}"$'\n'
        chmod a-x "$f"
    done
    if [ "$MOTD_HAS_STATIC" = true ]; then
        mkdir -p "$(dirname "$MOTD_ORIG")"
        # оригинал не затираем при повторе: второй раз /etc/motd уже пуст
        [ -e "$MOTD_ORIG" ] || write_file "$MOTD_ORIG" < "$MOTD_STATIC"
        state+="M"$'\n'
        : | write_file "$MOTD_STATIC"
    fi
    [ -n "$state" ] || return 0
    mkdir -p "$(dirname "$MOTD_STATE")"
    # старые записи сохраняем (повторный прогон), дубли убираем
    printf '%s\n%s' "$old" "$state" | awk 'NF && !seen[$0]++' | write_file "$MOTD_STATE"
}

apply_motd() {
    local tmp rc=0
    tmp="$(mktemp)" || return 1
    motd_card_script > "$tmp"
    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        log_error_t "Сгенерированный скрипт карточки не прошёл проверку синтаксиса" \
"The generated card script failed the syntax check"
        return 1
    fi
    mkdir -p "$MOTD_DIR"
    write_file "$MOTD_FILE" < "$tmp"; rc=$?
    rm -f "$tmp"
    [ "$rc" -eq 0 ] || return 1
    chmod 755 "$MOTD_FILE"
    log_success_t "Карточка сервера установлена: ${MOTD_FILE}" \
"Server card installed: ${MOTD_FILE}"

    motd_scan
    if [ "${#MOTD_FOUND[@]}" -eq 0 ] && [ "$MOTD_HAS_STATIC" = false ]; then return 0; fi
    echo ""
    _motd_show_found
    if ask_bulk_yn MOTD_CLEAN_BULK "Отключить всё это и оставить только карточку?" \
"Turn all of this off and keep only the card?" Y; then
        _motd_silence
        log_success_t "Стандартное приветствие выключено (вернуть — повторный выбор пункта)" \
"Stock greeting turned off (choose the item again to restore it)"
    else
        log_info_t "Стандартное приветствие оставлено — карточка будет под ним" \
"Stock greeting left in place — the card will show below it"
    fi
}

disable_motd() {
    local kind mode path restored=0
    remove_file "$MOTD_FILE"
    log_success_t "Карточка сервера удалена" "Server card removed"
    [ -f "$MOTD_STATE" ] || return 0
    if ! ask_yn_t "Вернуть стандартное приветствие, которое выключал usfc?" \
"Restore the stock greeting that usfc turned off?" Y; then
        return 0
    fi
    while IFS=$'\t' read -r kind mode path; do
        case "$kind" in
            S)
                [ -e "$path" ] || continue
                chmod "$mode" "$path" && restored=$((restored + 1))
                ;;
            M)
                [ -f "$MOTD_ORIG" ] || continue
                if [ -s "$MOTD_STATIC" ]; then
                    log_warn_t "${MOTD_STATIC} уже изменён после нас — не трогаю, оригинал в ${MOTD_ORIG}" \
"${MOTD_STATIC} was changed after us — leaving it, the original is in ${MOTD_ORIG}"
                else
                    write_file "$MOTD_STATIC" < "$MOTD_ORIG" && remove_file "$MOTD_ORIG"
                fi
                ;;
        esac
    done < "$MOTD_STATE"
    remove_file "$MOTD_STATE"
    log_success_t "Стандартное приветствие возвращено (скриптов: ${restored})" \
"Stock greeting restored (scripts: ${restored})"
}
