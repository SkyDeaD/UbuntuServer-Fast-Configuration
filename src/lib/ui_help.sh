# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

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
        echo -e "  ${BOLD}Справка и откат по пунктам${NC} ${DIM}— что делает каждый пункт и как его отменить${NC}"
        echo ""

        # Та же рамка и та же арифметика ширин, что у show_menu — справка
        # не должна выглядеть чужой на фоне меню. Колонка «Сейчас» делает её
        # заодно обзором: видно, что уже сделано, не возвращаясь в меню.
        # title_w=26, как в меню, а не 24: самый длинный заголовок с отступом
        # занимает ровно 24 символа, а pad_title форсирует ещё минимум один
        # пробел — при 24 такие строки выпирали за колонку на единицу
        local idx_w=3 title_w=26 st_w=8 desc_w
        desc_w=$(( TERM_W - idx_w - title_w - st_w - 13 ))
        # На тесном терминале колонки не влезают. Поднимать desc_w клэмпом нельзя:
        # ширина рамки перестанет совпадать с TERM_W и её порвёт переносом строки.
        # Поэтому недостачу забираем у названий, а если мало — у статуса.
        if [ "$desc_w" -lt 12 ]; then
            local need=$(( 12 - desc_w )) shrink
            shrink=$(( title_w - 16 )); [ "$shrink" -gt "$need" ] && shrink="$need"
            if [ "$shrink" -gt 0 ]; then title_w=$((title_w - shrink)); need=$((need - shrink)); fi
            if [ "$need" -gt 0 ]; then
                shrink=$(( st_w - 3 )); [ "$shrink" -gt "$need" ] && shrink="$need"
                [ "$shrink" -gt 0 ] && st_w=$((st_w - shrink))
            fi
            desc_w=$(( TERM_W - idx_w - title_w - st_w - 13 ))
        fi

        # как и в меню: 2 последних символа колонки названий — под метку ⇄
        local name_w=$(( title_w - 2 )); [ "$name_w" -lt 1 ] && name_w=1

        local c_idx c_title c_desc c_st
        box_line "$DIM" '╭' '┬' '╮' "$idx_w" "$title_w" "$desc_w" "$st_w"
        printf -v c_idx "%${idx_w}s" "#"
        pad_title "Пункт"      "$title_w"; c_title="$REPLY_PAD"
        pad_title "Что делает" "$desc_w";  c_desc="$REPLY_PAD"
        pad_title "Сейчас"     "$st_w";    c_st="$REPLY_PAD"
        printf "  ${DIM}│${NC} ${BOLD}%s${NC} ${DIM}│${NC} ${BOLD}%s${NC} ${DIM}│${NC} ${BOLD}%s${NC} ${DIM}│${NC} ${BOLD}%s${NC} ${DIM}│${NC}\n" \
            "$c_idx" "$c_title" "$c_desc" "$c_st"
        box_line "$DIM" '├' '┼' '┤' "$idx_w" "$title_w" "$desc_w" "$st_w"

        local i=1 id section section_color prev_section=""
        for id in "${ITEM_IDS[@]}"; do
            section="${ITEM_SECTIONS[$((i-1))]}"
            section_color_for "$section"; section_color="$REPLY_COLOR"
            # Колонка названий на тесном терминале ужимается, а pad_title умеет
            # только добивать — длинные заголовки выпирали бы за рамку. Поэтому
            # везде сначала обрезаем, потом добиваем вручную (та же схема, что
            # уже используется для статусной колонки в show_menu)
            local t_pad
            if [ "$section" != "$prev_section" ]; then
                prev_section="$section"
                section_label "$section"
                truncate_colored "● ${REPLY_T^^}" "$title_w"; c_title="$REPLY_TRUNC"
                visible_len "$c_title"; t_pad=$((title_w - REPLY_LEN)); [ "$t_pad" -lt 0 ] && t_pad=0
                printf -v c_idx "%${idx_w}s" ""
                pad_title "" "$desc_w"; c_desc="$REPLY_PAD"
                pad_title "" "$st_w";   c_st="$REPLY_PAD"
                printf "  ${DIM}│${NC} %s ${DIM}│${NC} ${section_color}${BOLD}%s${NC}%*s ${DIM}│${NC} %s ${DIM}│${NC} %s ${DIM}│${NC}\n" \
                    "$c_idx" "$c_title" "$t_pad" "" "$c_desc" "$c_st"
            fi
            local short st_pad desc_pad mark='  '
            truncate_colored "${ITEM_SHORT[$((i-1))]}" "$desc_w"; short="$REPLY_TRUNC"
            visible_len "$short"; desc_pad=$((desc_w - REPLY_LEN)); [ "$desc_pad" -lt 0 ] && desc_pad=0
            item_supports_disable "$id" && mark=" ${CYAN}⇄${NC}"
            truncate_colored "  ${ITEM_TITLES[$((i-1))]}" "$name_w"; c_title="$REPLY_TRUNC"
            visible_len "$c_title"; t_pad=$((name_w - REPLY_LEN)); [ "$t_pad" -lt 0 ] && t_pad=0
            status_marker "$id"
            visible_len "$REPLY_MARKER"; st_pad=$((st_w - REPLY_LEN)); [ "$st_pad" -lt 0 ] && st_pad=0
            printf -v c_idx "%${idx_w}s" "$i"
            printf "  ${DIM}│${NC} %s ${DIM}│${NC} %s%*s%b ${DIM}│${NC} ${DIM}%s${NC}%*s ${DIM}│${NC} %b%*s ${DIM}│${NC}\n" \
                "$c_idx" "$c_title" "$t_pad" "" "$mark" "$short" "$desc_pad" "" "$REPLY_MARKER" "$st_pad" ""
            i=$((i+1))
        done
        box_line "$DIM" '╰' '┴' '╯' "$idx_w" "$title_w" "$desc_w" "$st_w"

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
# (там же, где раньше жил отдельный экран R).
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
    # Два способа отката показываются вместе, а не «или-или»: у ⇄-пунктов есть
    # и переключатель в меню, и команды на удаление совсем. Раньше вторая
    # половина у них просто не показывалась
    if item_supports_disable "$id"; then
        echo -e "  ${BOLD}Выключить:${NC} ${DIM}выбери пункт ${idx} в меню ещё раз — скрипт предложит обратное${NC}"
    fi
    if [ -n "${ROLLBACK_NOTES[$i]}" ]; then
        echo -e "  ${BOLD}Удалить совсем${NC} ${DIM}(вручную, скрипт этого не делает):${NC}"
        echo -e "     ${DIM}${ROLLBACK_NOTES[$i]}${NC}"
    fi
    pause
}
