# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: ZRAM + swap + earlyoom ─────────────────────────────────────────
usfc_item zram защита "ZRAM + swap + earlyoom" \
    "сжатая память + резервный своп + защита от OOM" \
    "ZRAM + swap + earlyoom" \
    "compressed memory, backup swap, OOM protection"
usfc_item_toggle zram

usfc_item_full zram "zram — сжатая память прямо в оперативке (по умолчанию 75% RAM, приоритет 100),
плюс резервный swap-файл на диске с приоритетом 10, чтобы использовался только
когда zram закончился.

Размер свопа считается как min(RAM, свободно/4), зажатое в 512–4096 МБ. Если
swap-файл уже есть и его размер расходится с рекомендацией больше чем на 10%,
пункт предложит пересоздать. Разделы и LVM не трогаются.

Плюс vm.swappiness=80 / vm.vfs_cache_pressure=50 и опционально earlyoom —
защита от полного зависания сервера при нехватке памяти." \
"Three things about memory at once.

zram is compressed memory used as swap: several times faster than a disk
swap file, and it does not wear out an SSD. Priority 100, so the kernel uses
it first.

A backup swap file on disk, priority 10 — the reserve for when zram runs out.
Its size is min(RAM, free/4), clamped to 512-4096 MB: swap here backs zram up,
so it follows memory, and dividing by four keeps it from eating a small disk.

Plus vm.swappiness=80 / vm.vfs_cache_pressure=50, and optionally earlyoom —
it kills the heaviest process before the machine freezes completely."


usfc_item_rollback zram "sudo apt purge zram-tools earlyoom
     sudo swapoff /swapfile && sudo rm -f /swapfile
     sudo sed -i '/^\\/swapfile /d' /etc/fstab
     sudo rm -f /etc/sysctl.d/99-zram.conf && sudo sysctl --system
     # снимать своп имеет смысл, только если памяти заведомо хватает" \
"sudo apt purge zram-tools earlyoom
     sudo swapoff /swapfile && sudo rm -f /swapfile
     sudo sed -i '/^\\/swapfile /d' /etc/fstab
     sudo rm -f /etc/sysctl.d/99-zram.conf && sudo sysctl --system
     # removing swap only makes sense if you are certain memory is plentiful"

# Оставлять zramswap.service в failed нельзя: он краснеет в `systemctl status`
# при каждой загрузке и уводит внимание от настоящих поломок. Именно по этой
# красной строке проблема с отсутствующим модулем и обнаружилась.
zram_stand_down() {
    systemctl is-enabled zramswap.service >/dev/null 2>&1 || return 0
    log_info_t "Выключаю zramswap.service, чтобы он не падал при каждой загрузке" \
"Disabling zramswap.service so it stops failing on every boot"
    systemctl disable --now zramswap >/dev/null 2>&1 || true
    # Одного disable мало: состояние failed у юнита остаётся записанным, и
    # `systemctl --failed` показывает его дальше — ровно ту красную строку,
    # ради которой всё это и делалось. Проверено на живой машине
    systemctl reset-failed zramswap.service >/dev/null 2>&1 || true
}

# zram_ensure_module — 0, если zram на этой машине поднять реально (возможно,
# после установки недостающего пакета). 1 — нельзя, причина уже напечатана,
# и вызывающий спокойно идёт дальше к свопу и sysctl.
#
# Проверяем ДО установки zram-tools: ставить пакет, который заведомо не
# заработает, и оставлять после себя падающую службу — худший из исходов.
zram_ensure_module() {
    local kver pkg ru_size='' en_size=''
    zram_module_state
    case "$REPLY_ZRAM_MOD" in
        ok) return 0 ;;
        container)
            log_warn_t "Машина работает в контейнере: ядро у неё общее с хозяином, и загрузить в него модуль zram нельзя" \
"This machine runs in a container: it shares the host kernel, and the zram module cannot be loaded into it"
            log_info_t "zram здесь невозможен в принципе — резервный swap-файл и sysctl настрою как обычно" \
"zram is simply not possible here — the backup swap file and sysctl will be set up as usual"
            zram_stand_down
            return 1 ;;
        stale)
            kver="$(uname -r)"
            log_warn_t "Ядро обновлено, а машина всё ещё работает на ${BOLD}${kver}${NC} — каталога модулей для него больше нет" \
"The kernel was upgraded but the machine still runs ${BOLD}${kver}${NC} — its module directory is gone"
            log_info_t "Перезагрузите сервер и прогоните пункт ещё раз" \
"Reboot the server and run this item again"
            zram_stand_down
            return 1 ;;
    esac

    kver="$(uname -r)"
    pkg="linux-modules-extra-${kver}"
    log_warn_t "Модуля ядра zram нет в /lib/modules/${kver}" \
"The zram kernel module is missing from /lib/modules/${kver}"
    log_info_t "На части образов Ubuntu он лежит в отдельном пакете модулей, которого на облачных образах обычно не бывает" \
"On some Ubuntu images it lives in a separate kernel-modules package that cloud images usually do not ship"

    ensure_apt_updated
    if ! pkg_candidate_mb "$pkg"; then
        # Причину не называем: доступных фактов ровно два — модуля нет и пакета
        # нет. Почему именно, отсюда не видно, а угаданный диагноз в сообщении
        # живёт дольше и врёт убедительнее, чем его отсутствие
        log_error_t "Модуля нет, и пакета ${pkg} в apt тоже нет — доставать неоткуда" \
"The module is missing and apt has no ${pkg} either — there is nowhere to get it from"
        log_info_t "Так бывает с ядрами, собранными провайдером. Посмотреть своё: ${BOLD}uname -r${NC}, ${BOLD}apt policy linux-image-generic${NC}" \
"This happens with provider-built kernels. Check yours: ${BOLD}uname -r${NC}, ${BOLD}apt policy linux-image-generic${NC}"
        zram_stand_down
        return 1
    fi
    if [ "$REPLY_PKG_MB" -gt 0 ]; then
        ru_size=", скачать ${REPLY_PKG_MB} МБ"   # i18n-ok: пара — en_size строкой ниже
        en_size=", ${REPLY_PKG_MB} MB to download"
    fi
    if ! ask_yn_t "Установить ${pkg}${ru_size}?" "Install ${pkg}${en_size}?"; then
        log_info_t "Пропускаю zram — резервный swap-файл и sysctl настрою как обычно" \
"Skipping zram — the backup swap file and sysctl will be set up as usual"
        zram_stand_down
        return 1
    fi
    t "модули ядра" "kernel modules"
    if ! ensure_pkg "$REPLY_T" "$pkg"; then
        log_error_t "Установка ${pkg} не удалась" "Installing ${pkg} failed"
        zram_stand_down
        return 1
    fi
    # В сухом прогоне пакет не ставился, модуля не появится, и общая ветка
    # ниже честно объявила бы неудачу — про установку, которой не было
    if [ "$USFC_DRY_RUN" = true ]; then
        log_info_t "Сухой прогон: дальше считаю, что модуль появился" \
"Dry run: assuming the module is available from here on"
        return 0
    fi
    modprobe zram 2>/dev/null || true
    zram_module_state
    if [ "$REPLY_ZRAM_MOD" != ok ]; then
        log_error_t "Пакет установлен, но модуль zram так и не появился — скорее всего нужна перезагрузка" \
"The package is installed but the zram module still is not there — a reboot is most likely needed"
        zram_stand_down
        return 1
    fi
    log_success_t "Модуль zram доступен" "The zram module is available"
    return 0
}

# Печатается, когда zram-tools стоит и настроен, а устройство не поднялось.
# Модуль к этому моменту уже проверен, поэтому причину не выдумываем, а
# отправляем туда, где она написана, — в журнал самой службы.
zram_report_start_failure() {
    log_error_t "Не удалось поднять zram" "Could not bring zram up"
    log_info_t "Что говорит служба: ${BOLD}journalctl -u zramswap -n 20 --no-pager${NC}" \
"What the service says: ${BOLD}journalctl -u zramswap -n 20 --no-pager${NC}"
    zram_stand_down
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
        st "$GREEN" "✓ настроено" "✓ configured"; return 0
    elif [ "$zram_ok" = true ] || [ "$swap_ok" = true ]; then
        st "$YELLOW" "! настроено частично" "! partially configured"; return 1
    else
        st "$DIM" "○ не настроено" "○ not configured"; return 1
    fi
}

apply_zram() {
    read_swap_state
    local zram_active="$ZRAM_ACTIVE" zram_prio="$ZRAM_PRIO" \
          swap_active="$SWAP_ACTIVE" swap_prio="$SWAP_PRIO" swap_path="$SWAP_PATH"

    if [ "$zram_active" = true ]; then
        if [ "$zram_prio" = "100" ]; then
            log_success_t "zram уже настроен (приоритет 100) — пропускаю" \
"zram is already configured (priority 100) — skipping"
        else
            log_warn_t "zram активен, но приоритет ${zram_prio} (рекомендуется 100), похоже настраивали вручную" \
"zram is active but its priority is ${zram_prio} (100 recommended) — looks hand-tuned"
            if ask_yn_t "Перенастроить под рекомендованные значения?" "Reconfigure it to the recommended values?" N; then
                local cur_percent zram_percent
                cur_percent="$(grep -oP '^PERCENT=\K[0-9]+' /etc/default/zramswap 2>/dev/null)"
                [ -z "$cur_percent" ] && cur_percent=75
                zram_percent="$(ask_value_t "Размер zram в % от RAM?" "zram size, % of RAM?" "$cur_percent")"
                if ensure_pkg "zram-tools" zram-tools; then
                    systemctl stop zramswap 2>/dev/null
                    swapoff /dev/zram0 2>/dev/null || true
                    printf 'ALGO=lz4\nPERCENT=%s\nPRIORITY=100\n' "$zram_percent" | write_file /etc/default/zramswap
                    if ! systemctl start zramswap; then
                        sleep 2
                        systemctl start zramswap
                    fi
                    if swapon --show --noheadings --raw 2>/dev/null | awk '{print $1}' | grep '^/dev/zram' >/dev/null; then
                        log_success_t "zram перенастроен (${zram_percent}% RAM)" \
"zram reconfigured (${zram_percent}% of RAM)"
                    else
                        zram_report_start_failure
                    fi
                else
                    log_error_t "Установка zram-tools не удалась" \
"Installing zram-tools failed"
                fi
            fi
        fi
    elif ask_yn_t "Установить и настроить zram (lz4, приоритет 100)?" "Install and configure zram (lz4, priority 100)?"; then
        # Модуль проверяем ПЕРВЫМ делом: без него zram-tools встанет, служба
        # будет падать при каждой загрузке, а пользователь получит совет
        # «попробуйте вручную», который заведомо не поможет
        if zram_ensure_module; then
            local zram_percent
            zram_percent="$(ask_value_t "Размер zram в % от RAM?" "zram size, % of RAM?" "${ZRAM_BULK_PERCENT:-75}")"
            if ensure_pkg "zram-tools" zram-tools; then
                systemctl stop zramswap 2>/dev/null
                swapoff /dev/zram0 2>/dev/null || true
                printf 'ALGO=lz4\nPERCENT=%s\nPRIORITY=100\n' "$zram_percent" | write_file /etc/default/zramswap
                if ! systemctl start zramswap; then
                    sleep 2
                    systemctl start zramswap
                fi
                if swapon --show --noheadings --raw 2>/dev/null | awk '{print $1}' | grep '^/dev/zram' >/dev/null; then
                    log_success_t "zram-tools установлен и настроен (${zram_percent}% RAM)" \
"zram-tools installed and configured (${zram_percent}% of RAM)"
                else
                    zram_report_start_failure
                fi
            else
                log_error_t "Установка zram-tools не удалась" \
"Installing zram-tools failed"
            fi
        fi
    fi

    if [ "$swap_active" = true ]; then
        if [ "$swap_prio" = "10" ]; then
            local sw_suggest
            sw_suggest="$(suggest_swap_mb "$SWAP_SIZE_MB")"
            log_success_t "Резервный своп: ${swap_path}, ${SWAP_SIZE_MB} МБ, приоритет 10 ${DIM}(занято ${SWAP_USED_MB} МБ)${NC}" \
"Backup swap: ${swap_path}, ${SWAP_SIZE_MB} MB, priority 10 ${DIM}(${SWAP_USED_MB} MB used)${NC}"

            if [ "$SWAP_TYPE" != "file" ]; then
                # раздел или LVM: менять его размер — это про parted/lvresize и
                # риск для данных, такое не место в меню быстрой настройки
                log_info_t "Тип свопа — ${SWAP_TYPE:-?}, размер разделов этот скрипт не меняет" \
"Swap type is ${SWAP_TYPE:-?}; this script does not resize partitions"
            elif swap_needs_resize "$SWAP_SIZE_MB" "$sw_suggest"; then
                log_info_t "Рекомендуемый размер для этой машины: ${BOLD}${sw_suggest} МБ${NC} ${DIM}(min(RAM, свободно/4))${NC}" \
"Recommended size for this machine: ${BOLD}${sw_suggest} MB${NC} ${DIM}(min(RAM, free/4))${NC}"
                # В пакетном режиме ask_yn всегда вернёт дефолт N, поэтому
                # согласием считаем сам факт того, что размер уже спросили
                # заранее в main() — иначе предзаданное значение пропало бы зря
                local want_resize=false
                if [ "$BULK_MODE" = true ]; then
                    [ -n "$SWAP_BULK_MB" ] && want_resize=true
                elif ask_yn_t "Изменить размер swap-файла?" "Resize the swap file?" N; then
                    want_resize=true
                fi
                if [ "$want_resize" = true ]; then
                    local new_mb
                    new_mb="$(ask_value_t "Размер swap-файла, МБ?" "Swap file size, MB?" "${SWAP_BULK_MB:-$sw_suggest}")"
                    if [ "$new_mb" -lt 64 ]; then
                        log_error_t "Слишком мало (${new_mb} МБ) — размер не меняю" \
"Too small (${new_mb} MB) — leaving the size alone"
                    else
                        resize_swapfile "$swap_path" "$new_mb" "$SWAP_SIZE_MB" "$SWAP_USED_MB"
                    fi
                fi
            else
                log_success_t "Размер близок к рекомендуемому (${sw_suggest} МБ) — оставляю как есть" \
"Close enough to the recommendation (${sw_suggest} MB) — leaving it as is"
            fi
        else
            log_warn_t "Своп на диске (${swap_path}) активен, но приоритет ${swap_prio} (рекомендуется 10)" \
"On-disk swap (${swap_path}) is active but its priority is ${swap_prio} (10 recommended)"
            if ask_yn_t "Исправить приоритет ${swap_path} в /etc/fstab на 10?" "Set the priority of ${swap_path} to 10 in /etc/fstab?"; then
                local esc_path
                esc_path="$(printf '%s' "$swap_path" | sed 's/[.[\*^$/]/\\&/g')"
                sed -i -E "s#^(${esc_path}\s+none\s+swap\s+)sw([^,].*)?\$#\1sw,pri=10\2#" /etc/fstab
                swapoff "$swap_path" 2>/dev/null || true
                swapon -a
                # sed молча не найдёт строку, если своп в fstab указан через
                # UUID=/LABEL=, а не путём (типично для разделов) — тогда без
                # этой проверки log_success был бы враньём
                if swapon --show --noheadings --raw 2>/dev/null | awk -v p="$swap_path" '$1==p {print $5}' | grep '^10$' >/dev/null; then
                    log_success_t "Приоритет исправлен" \
"Priority fixed"
                else
                    log_error_t "Не удалось исправить приоритет ${swap_path} — возможно, в /etc/fstab он указан через UUID=/LABEL=, а не путём. Поправьте вручную: pri=10 в опциях монтирования" \
"Could not fix the priority of ${swap_path} — /etc/fstab may reference it by UUID= or LABEL= rather than by path. Fix it by hand: pri=10 in the mount options"
                fi
            fi
        fi
    else
        local suggested_mb
        suggested_mb="$(suggest_swap_mb)"
        if ask_yn_t "Создать резервный swap-файл (по умолчанию ${suggested_mb} МБ, приоритет 10)?" "Create a backup swap file (${suggested_mb} MB by default, priority 10)?"; then
            local swap_mb
            swap_mb="$(ask_value_t "Размер swap-файла, МБ?" "Swap file size, MB?" "${SWAP_BULK_MB:-$suggested_mb}")"
            if create_swapfile /swapfile "$swap_mb"; then
                ensure_fstab_swap /swapfile
                swapoff /swapfile 2>/dev/null
                swapon -a 2>/dev/null       # поднимаем уже с приоритетом из fstab
                log_success_t "swapfile создан (${swap_mb} МБ, приоритет 10)" \
"swapfile created (${swap_mb} MB, priority 10)"
            else
                log_error_t "Не удалось создать /swapfile на ${swap_mb} МБ — подробности выше" \
"Could not create a ${swap_mb} MB /swapfile — details above"
            fi
        fi
    fi

    local cur_sw cur_vfs
    cur_sw="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo '?')"
    cur_vfs="$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo '?')"
    if [ "$cur_sw" = "80" ] && [ "$cur_vfs" = "50" ]; then
        log_success_t "sysctl уже настроен как рекомендуется" \
"sysctl already matches the recommendation"
    else
        log_info_t "Сейчас: swappiness=${cur_sw}, vfs_cache_pressure=${cur_vfs} ${DIM}(рекомендуется 80/50)${NC}" \
"Currently: swappiness=${cur_sw}, vfs_cache_pressure=${cur_vfs} ${DIM}(80/50 recommended)${NC}"
        local sysctl_default=Y
        [ "$cur_sw" != "60" ] || [ "$cur_vfs" != "100" ] && sysctl_default=N
        if ask_yn_t "Применить рекомендованные значения sysctl?" "Apply the recommended sysctl values?" "$sysctl_default"; then
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
                log_success_t "sysctl применён: swappiness ${cur_sw} → ${new_sw}, vfs_cache_pressure ${cur_vfs} → ${new_vfs}" \
"sysctl applied: swappiness ${cur_sw} → ${new_sw}, vfs_cache_pressure ${cur_vfs} → ${new_vfs}"
            else
                log_warn_t "sysctl не применился: swappiness=${new_sw}, vfs_cache_pressure=${new_vfs}" \
"sysctl did not take effect: swappiness=${new_sw}, vfs_cache_pressure=${new_vfs}"
                log_info_t "Что-то перебивает /etc/sysctl.d/99-zram.conf — смотри ${BOLD}sysctl --system${NC}" \
"Something overrides /etc/sysctl.d/99-zram.conf — check ${BOLD}sysctl --system${NC}"
            fi
        else
            log_info_t "Оставляю sysctl как есть (swappiness=${cur_sw}, vfs_cache_pressure=${cur_vfs})" \
"Leaving sysctl alone (swappiness=${cur_sw}, vfs_cache_pressure=${cur_vfs})"
        fi
    fi

    if systemctl is-enabled earlyoom &>/dev/null 2>&1; then
        log_success_t "earlyoom уже включён" \
"earlyoom is already enabled"
    elif ask_yn_t "Установить earlyoom (защита от полного падения при нехватке памяти)?" "Install earlyoom (keeps the box alive when memory runs out)?"; then
        if ensure_pkg "earlyoom" earlyoom; then
            systemctl enable --now earlyoom >/dev/null
            log_success_t "earlyoom включён" \
"earlyoom enabled"
        fi
        refresh_pkg_cache
    fi

    echo ""
    log_info_t "Текущее состояние свопа:" \
"Current swap state:"
    swapon --show 2>/dev/null | sed 's/^/      /'
}

disable_zram() {
    if ask_yn_t "Выключить zram-устройство (swapfile на диске НЕ трогается)?" "Disable the zram device (the on-disk swapfile is NOT touched)?" N; then
        systemctl disable --now zramswap &>/dev/null || true
        log_success_t "zram выключен. swapfile (если есть) продолжает работать" \
"zram disabled. The swapfile, if any, keeps working"
    fi
}
