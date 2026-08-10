# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: ZRAM + swap + earlyoom ─────────────────────────────────────────
usfc_item zram защита "ZRAM + swap + earlyoom" \
    "сжатая память + резервный своп + защита от OOM"
usfc_item_toggle zram

usfc_item_full zram "zram — сжатая память прямо в оперативке (по умолчанию 75% RAM, приоритет 100),
плюс резервный swap-файл на диске с приоритетом 10, чтобы использовался только
когда zram закончился.

Размер свопа считается как min(RAM, свободно/4), зажатое в 512–4096 МБ. Если
swap-файл уже есть и его размер расходится с рекомендацией больше чем на 10%,
пункт предложит пересоздать. Разделы и LVM не трогаются.

Плюс vm.swappiness=80 / vm.vfs_cache_pressure=50 и опционально earlyoom —
защита от полного зависания сервера при нехватке памяти."


usfc_item_rollback zram "sudo apt purge zram-tools earlyoom
     sudo swapoff /swapfile && sudo rm -f /swapfile
     sudo sed -i '/^\\/swapfile /d' /etc/fstab
     sudo rm -f /etc/sysctl.d/99-zram.conf && sudo sysctl --system
     # снимать своп имеет смысл, только если памяти заведомо хватает"

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
                if ensure_pkg "zram-tools" zram-tools; then
                    systemctl stop zramswap 2>/dev/null
                    swapoff /dev/zram0 2>/dev/null || true
                    printf 'ALGO=lz4\nPERCENT=%s\nPRIORITY=100\n' "$zram_percent" | write_file /etc/default/zramswap
                    if ! systemctl start zramswap; then
                        sleep 2
                        systemctl start zramswap
                    fi
                    if swapon --show --noheadings --raw 2>/dev/null | awk '{print $1}' | grep '^/dev/zram' >/dev/null; then
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
        if ensure_pkg "zram-tools" zram-tools; then
            systemctl stop zramswap 2>/dev/null
            swapoff /dev/zram0 2>/dev/null || true
            printf 'ALGO=lz4\nPERCENT=%s\nPRIORITY=100\n' "$zram_percent" | write_file /etc/default/zramswap
            if ! systemctl start zramswap; then
                sleep 2
                systemctl start zramswap
            fi
            if swapon --show --noheadings --raw 2>/dev/null | awk '{print $1}' | grep '^/dev/zram' >/dev/null; then
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
                if swapon --show --noheadings --raw 2>/dev/null | awk -v p="$swap_path" '$1==p {print $5}' | grep '^10$' >/dev/null; then
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
            printf 'vm.swappiness=80\nvm.vfs_cache_pressure=50\n' | write_file /etc/sysctl.d/99-zram.conf
            sysctl --system >/dev/null 2>&1
            # Не верим на слово: перечитываем /proc. Раньше здесь безусловно
            # печаталось «sysctl применён» сразу под строкой со СТАРЫМИ числами —
            # и это читалось как «рекомендуется, но не сделано». Теперь видно
            # результат, а если файл кто-то переопределяет — видно и это
            local new_sw new_vfs
            new_sw="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo '?')"
            new_vfs="$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo '?')"
            if [ "$new_sw" = "80" ] && [ "$new_vfs" = "50" ]; then
                log_success "sysctl применён: swappiness ${cur_sw} → ${new_sw}, vfs_cache_pressure ${cur_vfs} → ${new_vfs}"
            else
                log_warn "sysctl не применился: swappiness=${new_sw}, vfs_cache_pressure=${new_vfs}"
                log_info "Что-то перебивает /etc/sysctl.d/99-zram.conf — смотри ${BOLD}sysctl --system${NC}"
            fi
        else
            log_info "Оставляю sysctl как есть (swappiness=${cur_sw}, vfs_cache_pressure=${cur_vfs})"
        fi
    fi

    if systemctl is-enabled earlyoom &>/dev/null 2>&1; then
        log_success "earlyoom уже включён"
    elif ask_yn "Установить earlyoom (защита от полного падения при нехватке памяти)?"; then
        if ensure_pkg "earlyoom" earlyoom; then
            systemctl enable --now earlyoom >/dev/null
            log_success "earlyoom включён"
        fi
        refresh_pkg_cache
    fi

    echo ""
    log_info "Текущее состояние свопа:"
    swapon --show 2>/dev/null | sed 's/^/      /'
}

disable_zram() {
    if ask_yn "Выключить zram-устройство (swapfile на диске НЕ трогается)?" N; then
        systemctl disable --now zramswap &>/dev/null || true
        log_success "zram выключен. swapfile (если есть) продолжает работать"
    fi
}
