# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

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

# ── Доступен ли вообще модуль ядра zram ───────────────────────────────────────
# Появилось не из осторожности, а по факту: на VPS с ядром 6.8.0-137-generic
# zramswap.service падал при каждой загрузке —
#
#     modprobe: FATAL: Module zram not found in directory /lib/modules/6.8.0-137-generic
#     Error: inserting the zram kernel module
#
# — а скрипт про это знал ровно одно: «не удалось поднять zram, попробуйте
# вручную». Совет бесполезный: вручную выйдет то же самое, потому что модуля
# на диске нет. На части образов Ubuntu zram.ko лежит не в основном пакете
# модулей, а в linux-modules-extra, которого на облачных образах не бывает.
#
# Проверка строго читающая: modinfo только ищет файл модуля и ничего не грузит,
# поэтому её безопасно звать и из аудита, и из сухого прогона.
#
# Состояния в REPLY_ZRAM_MOD:
#   ok        — модуль загружен, встроен в ядро или лежит на диске
#   container — машина в контейнере, своего ядра у неё нет и модули не грузятся
#   stale     — каталога модулей для текущего ядра нет: ядро обновили,
#               а перезагрузиться забыли
#   absent    — модуля нет, но машина своё ядро имеет: поправимо пакетом
# Пути вынесены в переменные ради tests/test_zram_module.sh: пять состояний
# иначе воспроизводились бы только на пяти разных машинах, то есть не
# проверялись бы вовсе. В работе всегда значения по умолчанию.
USFC_SYSFS="${USFC_SYSFS:-/sys}"
# Тем же швом читаются vm.swappiness и vm.vfs_cache_pressure: подставить
# их значения иначе можно только на настоящей машине с нужным ядром
USFC_PROC_VM="${USFC_PROC_VM:-/proc/sys/vm}"
USFC_MODULES_DIR="${USFC_MODULES_DIR:-/lib/modules}"

REPLY_ZRAM_MOD=''
zram_module_state() {
    # Уже поднят или вкомпилирован в ядро (CONFIG_ZRAM=y) — искать нечего
    if [ -e "${USFC_SYSFS}/class/zram-control" ] || [ -e "${USFC_SYSFS}/block/zram0" ]; then
        REPLY_ZRAM_MOD=ok; return 0
    fi
    if modinfo zram >/dev/null 2>&1; then
        REPLY_ZRAM_MOD=ok; return 0
    fi
    if systemd-detect-virt --container --quiet 2>/dev/null; then
        REPLY_ZRAM_MOD=container; return 0
    fi
    if [ ! -d "${USFC_MODULES_DIR}/$(uname -r)" ]; then
        REPLY_ZRAM_MOD=stale; return 0
    fi
    REPLY_ZRAM_MOD=absent
    return 0
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
        log_info_t "fallocate не сработал — выделяю файл через dd (дольше)" \
"fallocate did not work — allocating with dd instead (slower)"
        dd if=/dev/zero of="$path" bs=1M count="$mb" status=none 2>/dev/null || return 1
    fi
    chmod 600 "$path"
    if ! mkswap "$path" >/dev/null 2>&1; then
        log_info_t "mkswap не принял файл — переделываю через dd" \
"mkswap rejected the file — redoing it with dd"
        rm -f "$path"
        dd if=/dev/zero of="$path" bs=1M count="$mb" status=none 2>/dev/null || return 1
        chmod 600 "$path"
        mkswap "$path" >/dev/null 2>&1 || return 1
    fi
    swapon "$path" 2>/dev/null || return 1
    return 0
}

# ═══════════════════════════════════════════════════════════════
# Приоритет свопа в /etc/fstab
# ═══════════════════════════════════════════════════════════════
# До 5.0 здесь стоял sed, понимавший ровно одну форму строки:
# `<путь> none swap sw …`. Всё остальное он молча пропускал — `defaults`,
# `sw,nofail`, уже стоящий `pri=5`, точку монтирования `swap`, UUID=/LABEL=
# у разделов, — а `swap swap` портил в `sw,pri=10ap`. Пункт при этом
# рапортовал «приоритет 10», и после перезагрузки своп поднимался с -2.
#
# Теперь строка разбирается по полям. Совпадение — по пути, UUID или LABEL
# устройства; в 4-м поле заменяется `pri=N` или дописывается `,pri=N`;
# повторные строки на то же устройство комментируются (своп смонтировался бы
# дважды); строки нет — добавляется. Запись через write_file: снимок для
# `usfc restore` и честный сухой прогон. Путь к fstab — переменная ради
# tests/test_fstab_swap.sh.
USFC_FSTAB="${USFC_FSTAB:-/etc/fstab}"

# _swap_ids <путь> → «путь UUID=… LABEL=… /dev/disk/by-uuid/…» через пробел.
# blkid читает и swap-файл: mkswap пишет UUID и в него, хотя ссылаться на
# файл через UUID= в fstab нельзя — такие строки тоже надо узнавать, чтобы
# не оставить рядом дубль
REPLY_SWAP_IDS=''
_swap_ids() {
    local path="$1" uuid label
    REPLY_SWAP_IDS="$path"
    uuid="$(blkid -o value -s UUID "$path" 2>/dev/null)"
    label="$(blkid -o value -s LABEL "$path" 2>/dev/null)"
    [ -n "$uuid" ]  && REPLY_SWAP_IDS="${REPLY_SWAP_IDS} UUID=${uuid} /dev/disk/by-uuid/${uuid}"
    [ -n "$label" ] && REPLY_SWAP_IDS="${REPLY_SWAP_IDS} LABEL=${label} /dev/disk/by-label/${label}"
    # LVM и dm: swapon называет устройство по ядру (/dev/dm-1), а в fstab оно
    # записано как /dev/mapper/vg-swap, /dev/vg/swap, by-id или PARTUUID=.
    # Строку, которая указывает на то же устройство, добавляем как есть —
    # иначе END в _fstab_swap_rewrite дописал бы вторую строку на тот же своп
    local real f1 typ dev
    real="$(readlink -f "$path" 2>/dev/null)"
    [ -n "$real" ] && [ -r "$USFC_FSTAB" ] || return 0
    while read -r f1 _ typ _; do
        [ "$typ" = swap ] || continue
        case "$f1" in
            ''|\#*) continue ;;
            UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*)
                dev="$(blkid -l -o device -t "$f1" 2>/dev/null)" ;;
            *)  dev="$f1" ;;
        esac
        [ -n "$dev" ] || continue
        [ "$(readlink -f "$dev" 2>/dev/null)" = "$real" ] && REPLY_SWAP_IDS="${REPLY_SWAP_IDS} ${f1}"
    done < "$USFC_FSTAB"
    return 0
}

# _fstab_swap_rewrite <ids> <pri> — печатает новое содержимое fstab.
# Отдельно от записи, чтобы тест мог сверить результат на таблице входов
_fstab_swap_rewrite() {
    awk -v ids=" $1 " -v pri="$2" -v path="${1%% *}" '
        function ours(f) { return index(ids, " " f " ") > 0 }
        /^[[:space:]]*(#|$)/ { print; next }
        {
            if (!(ours($1) && $3 == "swap")) { print; next }
            if (done) { print "# usfc: duplicate swap entry: " $0; next }
            done = 1
            opts = ($4 == "") ? "sw" : $4
            if (opts ~ /(^|,)pri=[0-9-]*(,|$)/) {
                gsub(/(^|,)pri=[0-9-]*/, "", opts)
                sub(/^,/, "", opts)
                opts = (opts == "" ? "sw" : opts) ",pri=" pri
            } else {
                opts = opts ",pri=" pri
            }
            mp = ($2 == "" ? "none" : $2)
            print $1 " " mp " swap " opts " " ($5 == "" ? 0 : $5) " " ($6 == "" ? 0 : $6)
        }
        END { if (!done) print path " none swap sw,pri=" pri " 0 0" }
    ' "$USFC_FSTAB" 2>/dev/null
}

# fstab_set_swap_pri <путь> [приоритет] — привести fstab в порядок.
# 0 — fstab содержит ровно одну строку на этот своп и в ней нужный pri
fstab_set_swap_pri() {
    local path="$1" pri="${2:-10}" new
    _swap_ids "$path"
    new="$(_fstab_swap_rewrite "$REPLY_SWAP_IDS" "$pri")" || return 1
    [ -n "$new" ] || return 1
    if [ -f "$USFC_FSTAB" ] && [ "$new" = "$(cat "$USFC_FSTAB")" ]; then
        return 0
    fi
    printf '%s\n' "$new" | write_file_atomic "$USFC_FSTAB"
}

# fstab_swap_pri <путь> → REPLY_FSTAB_PRI: приоритет из fstab для этого свопа,
# пусто — строки нет или в ней нет pri=. Нужен статусу: рабочий приоритет и
# записанный в fstab — разные вещи, и после перезагрузки остаётся только второй
REPLY_FSTAB_PRI=''
fstab_swap_pri() {
    _swap_ids "$1"
    REPLY_FSTAB_PRI="$(awk -v ids=" ${REPLY_SWAP_IDS} " '
        /^[[:space:]]*(#|$)/ { next }
        index(ids, " " $1 " ") && $3 == "swap" {
            if (match($4, /(^|,)pri=[0-9-]+/)) {
                s = substr($4, RSTART, RLENGTH); sub(/^,?pri=/, "", s); print s
            }
            exit
        }' "$USFC_FSTAB" 2>/dev/null)"
}

# swap_runtime_pri <путь> → REPLY_SWAP_RUNTIME_PRI: приоритет по swapon
REPLY_SWAP_RUNTIME_PRI=''
swap_runtime_pri() {
    REPLY_SWAP_RUNTIME_PRI="$(swapon --show --noheadings --raw 2>/dev/null | awk -v p="$1" '$1==p {print $5; exit}')"
}

# swap_set_pri <путь> [приоритет] — fstab + приоритет прямо сейчас + проверка.
# Сменить приоритет работающего свопа можно только через swapoff, а swapoff
# выгружает занятые страницы в RAM. Если они туда не влезут — не трогаем
# работающий своп: fstab уже исправлен, приоритет применится после
# перезагрузки, и мы так и говорим
swap_set_pri() {
    local path="$1" pri="${2:-10}" used_mb=0 avail_mb
    if ! fstab_set_swap_pri "$path" "$pri"; then
        log_error_t "Не удалось записать приоритет ${pri} для ${path} в ${USFC_FSTAB}" \
"Could not write priority ${pri} for ${path} to ${USFC_FSTAB}"
        return 1
    fi
    [ "$USFC_DRY_RUN" = true ] && return 0

    swap_runtime_pri "$path"
    [ "$REPLY_SWAP_RUNTIME_PRI" = "$pri" ] && return 0

    used_mb="$(human_to_mb "$(swapon --show --noheadings --raw 2>/dev/null | awk -v p="$path" '$1==p {print $4; exit}')")"
    avail_mb="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    [[ "$avail_mb" =~ ^[0-9]+$ ]] || avail_mb=0
    if [ -n "$REPLY_SWAP_RUNTIME_PRI" ] && [ "$used_mb" -gt 0 ] && [ "$used_mb" -ge $(( avail_mb - 200 )) ]; then
        log_warn_t "В ${path} занято ${used_mb} МБ, а свободной памяти ${avail_mb} МБ — не отключаю его сейчас" \
"${path} holds ${used_mb} MB and only ${avail_mb} MB of memory is free — not turning it off now"
        log_info_t "Приоритет ${pri} записан в fstab и применится после перезагрузки" \
"Priority ${pri} is written to fstab and takes effect after a reboot"
        return 0
    fi
    [ -n "$REPLY_SWAP_RUNTIME_PRI" ] && swapoff "$path" 2>/dev/null
    if ! swapon -p "$pri" "$path" 2>/dev/null; then
        # не включился с приоритетом — хотя бы вернуть как было, без свопа не оставлять
        swapon "$path" 2>/dev/null
        log_error_t "Не удалось включить ${path} с приоритетом ${pri}" \
"Could not enable ${path} with priority ${pri}"
        return 1
    fi
    swap_runtime_pri "$path"
    if [ "$REPLY_SWAP_RUNTIME_PRI" != "$pri" ]; then
        log_error_t "${path} работает с приоритетом ${REPLY_SWAP_RUNTIME_PRI:-?}, а не ${pri}" \
"${path} runs with priority ${REPLY_SWAP_RUNTIME_PRI:-?}, not ${pri}"
        return 1
    fi
    return 0
}

# resize_swapfile <путь> <новый_МБ> — пересоздание уже работающего свопа.
# Самая опасная операция в скрипте: между swapoff и swapon машина живёт без
# резервной памяти, поэтому все проверки — ДО того, как что-то трогать.
resize_swapfile() {
    local path="$1" new_mb="$2" old_mb="$3" used_mb="$4"

    if [ ! -f "$path" ]; then
        log_error_t "${path} — не обычный файл, пересоздавать не буду" \
"${path} is not a regular file — refusing to recreate it"
        return 1
    fi

    # swapoff выгружает занятые страницы обратно в RAM. Если они туда не
    # влезают — получим OOM и убитые процессы, поэтому просто отказываемся
    local avail_mb
    avail_mb="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    [[ "$avail_mb" =~ ^[0-9]+$ ]] || avail_mb=0
    if [ "$used_mb" -gt 0 ] && [ "$used_mb" -ge $(( avail_mb - 200 )) ]; then
        log_error_t "В свопе занято ${used_mb} МБ, а свободной памяти всего ${avail_mb} МБ" \
"Swap holds ${used_mb} MB while only ${avail_mb} MB of memory is free"
        log_error_t "Отключение свопа сейчас рискует уронить процессы — размер не меняю" \
"Turning swap off now risks killing processes — leaving the size alone"
        log_info_t "Освободи память (или перезагрузись) и вернись в этот пункт" \
"Free some memory (or reboot) and come back to this item"
        return 1
    fi

    # места должно хватить с учётом того, что старый файл освободится
    local free_mb
    free_mb="$(df -m / 2>/dev/null | awk 'NR==2{print $4}')"
    [[ "$free_mb" =~ ^[0-9]+$ ]] || free_mb=0
    if [ "$new_mb" -gt $(( free_mb + old_mb - 256 )) ]; then
        log_error_t "Не хватит места: нужно ${new_mb} МБ, доступно ~$(( free_mb + old_mb )) МБ" \
"Not enough space: ${new_mb} MB needed, about $(( free_mb + old_mb )) MB available"
        return 1
    fi

    log_info_t "Отключаю ${path} ${DIM}(занято ${used_mb} МБ, свободной памяти ${avail_mb} МБ)${NC}" \
"Turning off ${path} ${DIM}(${used_mb} MB used, ${avail_mb} MB memory free)${NC}"
    if ! swapoff "$path" 2>/dev/null; then
        log_error_t "swapoff ${path} не удался — ничего не менял" \
"swapoff ${path} failed — nothing was changed"
        return 1
    fi

    if create_swapfile "$path" "$new_mb"; then
        # успех объявляем только после проверки: раньше «приоритет 10»
        # печатался безусловно, даже когда fstab не поменялся
        if swap_set_pri "$path" 10; then
            log_success_t "swap пересоздан: ${new_mb} МБ, приоритет 10" \
"swap recreated: ${new_mb} MB, priority 10"
            return 0
        fi
        log_warn_t "swap пересоздан (${new_mb} МБ), но приоритет 10 выставить не удалось" \
"swap recreated (${new_mb} MB), but priority 10 could not be set"
        return 1
    fi

    # не получилось — машина сейчас без свопа, это надо исправить или хотя бы
    # сказать вслух, а не оставить молча
    log_error_t "Не удалось создать своп размером ${new_mb} МБ" \
"Could not create a ${new_mb} MB swap file"
    if create_swapfile "$path" "$old_mb"; then
        swap_set_pri "$path" 10
        log_warn_t "Вернул прежний размер ${old_mb} МБ — система со свопом" \
"Restored the previous size ${old_mb} MB — the system has swap again"
    else
        log_error_t "ВНИМАНИЕ: своп сейчас ВЫКЛЮЧЕН. Подними вручную:" \
"WARNING: swap is currently OFF. Bring it back by hand:"
        echo -e "      ${BOLD}sudo fallocate -l ${old_mb}M ${path} && sudo chmod 600 ${path}${NC}"
        echo -e "      ${BOLD}sudo mkswap ${path} && sudo swapon -a${NC}"
    fi
    return 1
}
