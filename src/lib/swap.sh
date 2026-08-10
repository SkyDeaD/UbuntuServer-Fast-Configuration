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
        echo "${path} none swap sw,pri=10 0 0" | append_file /etc/fstab
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
