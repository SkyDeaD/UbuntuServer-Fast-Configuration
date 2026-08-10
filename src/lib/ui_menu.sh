# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

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
    local idx_w=3 title_w=26 status_w inner_w=$TERM_W name_w
    # -10: 4 символа рамки (╭/│×2/╮ и аналоги) + по 2 паддинга на три колонки,
    # минус собственные "+2" статусной колонки, которую эта формула и вычисляет
    status_w=$(( inner_w - idx_w - title_w - 10 ))
    # 6 — минимум, при котором рамка ещё влезает в нижнюю границу TERM_W
    [ "$status_w" -lt 6 ] && status_w=6

    # последние 2 символа колонки «Пункт» отданы метке ⇄ — она стоит в своём
    # столбике справа, а не приклеена к названию (иначе край рваный)
    name_w=$(( title_w - 2 )); [ "$name_w" -lt 1 ] && name_w=1

    local c_idx c_title c_status
    box_line "$DIM" '╭' '┬' '╮' "$idx_w" "$title_w" "$status_w"
    printf -v c_idx "%${idx_w}s" "#"
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
            printf -v c_idx "%${idx_w}s" ""
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
        # Пункты, которые умеют отключаться повторным выбором, помечаем прямо
        # здесь. Раньше про это была строка в легенде, и она врала: обещала
        # «любой применённый пункт защиты», хотя SSH hardening — тоже защита,
        # но отключать его из меню нельзя. Метка избавляет от правила
        # с исключениями, которое всё равно не влезало в строку
        # mark занимает ровно 2 видимых символа в обоих случаях — за счёт этого
        # name_w + mark = title_w, и рамка не едет ни на одной строке
        local title_txt="  ${ITEM_TITLES[$((i-1))]}" t_pad mark='  '
        item_supports_disable "$id" && mark=" ${CYAN}⇄${NC}"
        truncate_colored "$title_txt" "$name_w"; c_title="$REPLY_TRUNC"
        visible_len "$c_title"; t_pad=$((name_w - REPLY_LEN)); [ "$t_pad" -lt 0 ] && t_pad=0
        printf -v c_idx "%${idx_w}s" "$i"
        printf "  ${DIM}│${NC} %s ${DIM}│${NC} %s%*s%b ${DIM}│${NC} %b%*s ${DIM}│${NC}\n" \
            "$c_idx" "$c_title" "$t_pad" "" "$mark" "$status_line" "$status_pad" ""
        i=$((i+1))
    done
    box_line "$DIM" '╰' '┴' '╯' "$idx_w" "$title_w" "$status_w"

    echo ""
    # legend_w = inner_w - 4: box_line/рамка сама добавляет 2 бордюрных символа
    # (┌/┐ или │/│) + 2 паддинга вокруг содержимого одной колонки — если отдать
    # ей inner_w напрямую, итоговая рамка окажется на 4 символа шире терминала
    local legend_w=$((inner_w - 4)) line
    local lbl_choice lbl_sections lbl_commands lbl_blank legend1 legend2 legend2b legend3 legend4
    pad_title "Выбор:"   10; lbl_choice="$REPLY_PAD"
    pad_title "Разделы:" 10; lbl_sections="$REPLY_PAD"
    pad_title "Команды:" 10; lbl_commands="$REPLY_PAD"
    pad_title ""         10; lbl_blank="$REPLY_PAD"
    legend1="${BOLD}${lbl_choice}${NC}${CYAN}${BOLD}5${NC} / ${CYAN}${BOLD}1 3 5${NC} / ${CYAN}${BOLD}1,3,5${NC} — один или несколько пунктов сразу"
    # Две короткие строки вместо одной длинной: прежняя не влезала даже в
    # 120 колонок и обрезалась на «предложит откл...», да ещё и обещала то,
    # чего нет — отключать умеют не все пункты «защиты» (см. метку ⇄ в таблице)
    legend2="${lbl_blank}${DIM}буквы разделов можно сочетать: B,S${NC}"
    # Метка стоит не только у «защиты», и раньше это читалось как «остальное
    # не откатывается». Откатывается всё, просто у остальных пунктов это
    # apt purge — команды лежат на экране I, куда строка теперь и отправляет
    legend2b="${lbl_blank}${CYAN}⇄${NC}${DIM} — выключается повторным выбором; удалить остальное — экран ${NC}${CYAN}${BOLD}I${NC}"

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
    # Отдельного «R откат» здесь больше нет: R и I открывают один и тот же
    # экран, и две клавиши в строке выглядели как два разных места.
    # Саму клавишу R скрипт по-прежнему принимает — она у людей в пальцах
    # A под аудит не годится: она уже занята под «применить всё». Берём D
    # (диагностика) — и раскладка становится симметричной строке разделов:
    # четыре ячейки плюс хвост
    grid_cell "${CYAN}${BOLD}I${NC} справка" "$item_w"; g1="$REPLY_CELL"
    grid_cell "${CYAN}${BOLD}H${NC} алиасы"  "$item_w"; g2="$REPLY_CELL"
    grid_cell "${CYAN}${BOLD}D${NC} аудит"   "$item_w"; g3="$REPLY_CELL"
    grid_cell "${CYAN}${BOLD}U${NC} удалить" "$item_w"; g4="$REPLY_CELL"
    legend4="${BOLD}${lbl_commands}${NC}${g1}${g2}${g3}${g4}${CYAN}${BOLD}Q${NC} выход"
    box_line "$DIM" '╭' '┬' '╮' "$legend_w"
    for line in "$legend1" "$legend2" "$legend2b" "$legend3" "$legend4"; do
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
        # У nginx и Docker disable_* — переключатель (см. комментарий там же),
        # и «Отключить» в шапке врало бы, когда сервис уже стоит и его поднимут
        local verb="Отключить"
        case "$id" in
            nginx|docker) service_is_up "$id" || verb="Включить" ;;
        esac
        echo -e "  ${prefix}${CYAN}${BOLD}▸ ${verb}: ${title}${NC}"
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
