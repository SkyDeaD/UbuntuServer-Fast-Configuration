# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

show_aliases_help() {
    refresh_term_width
    show_header
    t "Алиасы" "Aliases"; local _h="$REPLY_T"
    t "(usfc — сам при первом запуске; ls/ll/la/lt/cat/catp/scat/fd — пункт «CLI-утилиты»)" \
      "(usfc is added on first run; ls/ll/la/lt/cat/catp/scat/fd come from the CLI tools item)"
    echo -e "  ${BOLD}${_h}${NC} ${DIM}${REPLY_T}${NC}"
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
    t "Что делает" "What it does"; local hdr3="$REPLY_T" hdr3_pad h1 h2
    # col3 динамический (зависит от TERM_W) и на узких терминалах может
    # совпасть по длине с заголовком — та же ловушка pad_title(), что и у cmd_t/desc_t
    visible_len "$hdr3"; hdr3_pad=$((col3 - REPLY_LEN)); [ "$hdr3_pad" -lt 0 ] && hdr3_pad=0
    t "Алиас" "Alias"; pad_title "$REPLY_T" "$col1";            h1="$REPLY_PAD"
    t "Реальная команда" "Real command"; pad_title "$REPLY_T" "$col2"; h2="$REPLY_PAD"
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
    log_info_t "eza/bat умеют работать и без алиасов: eza --icons -la, batcat file.txt и т.д." \
               "eza/bat work fine without aliases too: eza --icons -la, batcat file.txt and so on"
    log_info_t "Почему у cat/ls вообще другое поведение под sudo — см. README, раздел FAQ" \
               "Why cat/ls behave differently under sudo — see the FAQ section of the README"
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
        t "Справка и откат по пунктам" "Help and rollback per item"; local _h="$REPLY_T"
        t "— что делает каждый пункт и как его отменить" "— what each item does and how to undo it"
        echo -e "  ${BOLD}${_h}${NC} ${DIM}${REPLY_T}${NC}"
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
        # Заголовки колонок обрезаем и добиваем ВРУЧНУЮ, а не через pad_title:
        # та форсирует минимум один пробел, и заголовок длиной ровно в колонку
        # вылезает за рамку. По-русски «Что делает» короче ширины и это не
        # проявлялось, а английское «What it does» на 58 колонках совпало
        # с desc_w — рамка поехала ровно на один символ
        local _hp
        t "Пункт" "Item";              truncate_colored "$REPLY_T" "$title_w"; c_title="$REPLY_TRUNC"
        visible_len "$c_title"; _hp=$((title_w - REPLY_LEN)); [ "$_hp" -lt 0 ] && _hp=0
        printf -v c_title '%s%*s' "$c_title" "$_hp" ""
        t "Что делает" "What it does"; truncate_colored "$REPLY_T" "$desc_w";  c_desc="$REPLY_TRUNC"
        visible_len "$c_desc";  _hp=$((desc_w - REPLY_LEN));  [ "$_hp" -lt 0 ] && _hp=0
        printf -v c_desc '%s%*s' "$c_desc" "$_hp" ""
        t "Сейчас" "Now";              truncate_colored "$REPLY_T" "$st_w";    c_st="$REPLY_TRUNC"
        visible_len "$c_st";    _hp=$((st_w - REPLY_LEN));    [ "$_hp" -lt 0 ] && _hp=0
        printf -v c_st '%s%*s' "$c_st" "$_hp" ""
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
        t "Номер пункта — подробности, Enter — назад:" "Item number for details, Enter to go back:"
        echo -en "  ${BOLD}${REPLY_T}${NC} "
        local choice
        read -r choice </dev/tty
        [ -z "$choice" ] && return 0
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#ITEM_IDS[@]}" ]; then
            show_item_detail "$choice"
        else
            log_error_t "Нет пункта «${choice}» — введи число от 1 до ${#ITEM_IDS[@]} или Enter для выхода" \
                "No item ${choice} — enter a number from 1 to ${#ITEM_IDS[@]}, or Enter to go back"
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
    section_label "$section"; local _sec="$REPLY_T"
    t "раздел:" "section:"
    echo -e "  ${REPLY_COLOR}${BOLD}${idx}. ${ITEM_TITLES[$i]}${NC}   ${DIM}${REPLY_T} ${_sec}${NC}"
    hr
    echo ""
    # описание печатаем как есть: переносы строк расставлены в тексте руками,
    # чтобы не заниматься переносом слов в шелле
    while IFS= read -r line; do
        echo -e "  ${line}"
    done <<< "${ITEM_FULL[$i]}"
    echo ""
    hr
    t "Статус сейчас:" "Current status:"
    echo -e "  ${BOLD}${REPLY_T}${NC} ${STATUS_TEXT[$id]:-—}"
    # Два способа отката показываются вместе, а не «или-или»: у ⇄-пунктов есть
    # и переключатель в меню, и команды на удаление совсем. Раньше вторая
    # половина у них просто не показывалась
    if item_supports_disable "$id"; then
        t "Выключить:" "Switch off:"; local _h="$REPLY_T"
        t "выбери пункт ${idx} в меню ещё раз — скрипт предложит обратное" \
          "pick item ${idx} in the menu again — it will offer the opposite action"
        echo -e "  ${BOLD}${_h}${NC} ${DIM}${REPLY_T}${NC}"
    fi
    if [ -n "${ROLLBACK_NOTES[$i]}" ]; then
        t "Удалить совсем" "Remove completely"; local _h="$REPLY_T"
        t "(вручную, скрипт этого не делает):" "(by hand — the script does not do this):"
        echo -e "  ${BOLD}${_h}${NC} ${DIM}${REPLY_T}${NC}"
        echo -e "     ${DIM}${ROLLBACK_NOTES[$i]}${NC}"
    fi
    pause
}
