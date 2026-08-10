# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

show_menu() {
    refresh_term_width
    refresh_statuses
    show_header
    t "Пользователь:" "User:";   local _lu="$REPLY_T"
    t "SSH-порт:"     "SSH port:"; local _lp="$REPLY_T"
    echo -e "  ${DIM}${_lu}${NC} ${BOLD}${TARGET_USER}${NC}   ${DIM}${_lp}${NC} ${BOLD}${SSH_PORT}${NC}"
    if [ "$TARGET_USER" = "root" ]; then
        t "Работа из-под root: часть настроек ляжет в /root и пропадёт после перелогина" \
          "Running as root: some settings land in /root and vanish after you re-login"
        echo -e "  ${YELLOW}${BOLD}!${NC} ${YELLOW}${REPLY_T}${NC}"
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
    t "Пункт" "Item"; pad_title "$REPLY_T" "$title_w";  c_title="$REPLY_PAD"
    t "Статус" "Status"; pad_title "$REPLY_T" "$status_w"; c_status="$REPLY_PAD"
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
            section_label "$section"; local _sec="$REPLY_T"
            pad_title "● ${_sec^^}" "$title_w";           c_title="$REPLY_PAD"
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
    t "Выбор:" "Choose:";     pad_title "$REPLY_T" 10; lbl_choice="$REPLY_PAD"
    t "Разделы:" "Sections:"; pad_title "$REPLY_T" 10; lbl_sections="$REPLY_PAD"
    t "Команды:" "Keys:";     pad_title "$REPLY_T" 10; lbl_commands="$REPLY_PAD"
    pad_title ""         10; lbl_blank="$REPLY_PAD"
    t "— один или несколько пунктов сразу" "— one item or several at once"
    legend1="${BOLD}${lbl_choice}${NC}${CYAN}${BOLD}5${NC} / ${CYAN}${BOLD}1 3 5${NC} / ${CYAN}${BOLD}1,3,5${NC} ${REPLY_T}"
    # Две короткие строки вместо одной длинной: прежняя не влезала даже в
    # 120 колонок и обрезалась на «предложит откл...», да ещё и обещала то,
    # чего нет — отключать умеют не все пункты «защиты» (см. метку ⇄ в таблице)
    t "буквы разделов можно сочетать: B,S" "section letters can be combined: B,S"
    legend2="${lbl_blank}${DIM}${REPLY_T}${NC}"
    # Метка стоит не только у «защиты», и раньше это читалось как «остальное
    # не откатывается». Откатывается всё, просто у остальных пунктов это
    # apt purge — команды лежат на экране I, куда строка теперь и отправляет
    t "— выключается повторным выбором; удалить остальное — экран" \
      "— toggles off when picked again; how to remove the rest — screen"
    legend2b="${lbl_blank}${CYAN}⇄${NC}${DIM} ${REPLY_T} ${NC}${CYAN}${BOLD}I${NC}"

    # Разделы:/Команды: — сеткой в равные колонки вместо инлайн-списка через
    # три пробела, чтобы пункты стояли ровно друг под другом, а не вразнобой.
    # Делим на 5, а не на 4: разделов теперь четыре (C/B/S/P) плюс хвостовое «A всё»
    # Делим на 6: четыре раздела (C/B/S/P) плюс хвостовое «A всё», а в строке
    # команд теперь пять пунктов вместо четырёх — добавилась справка I
    # Ширина ячейки считается ПО СОДЕРЖИМОМУ, а не константой. Раньше здесь
    # стояло (legend_w-10)/6, и на русском это давало 10 — ровно столько,
    # сколько занимает самое длинное «S сервисы». По-английски «P security»
    # занимает те же 10, но без остатка на пробел, и ячейки слипались:
    # «S servicesP securityA all». Считаем максимум и добавляем разделитель.
    local item_w=0 _lbl g1 g2 g3 g4
    for _lbl in "C $(section_label система; printf '%s' "$REPLY_T")" \
                "B $(section_label база;    printf '%s' "$REPLY_T")" \
                "S $(section_label сервисы; printf '%s' "$REPLY_T")" \
                "P $(section_label защита;  printf '%s' "$REPLY_T")" \
                "I $(t "справка" "help";    printf '%s' "$REPLY_T")" \
                "H $(t "алиасы" "aliases";  printf '%s' "$REPLY_T")" \
                "D $(t "аудит" "audit";     printf '%s' "$REPLY_T")" \
                "U $(t "удалить" "remove";  printf '%s' "$REPLY_T")"; do
        visible_len "$_lbl"
        [ "$REPLY_LEN" -gt "$item_w" ] && item_w="$REPLY_LEN"
    done
    # +1 — ровно один пробел-разделитель. Не +2: на русском самое длинное
    # «C система» занимает 9, и +1 даёт прежние 10 символов, то есть вывод
    # по-русски не меняется ни на знак.
    #
    # Зажимать ширину сверху под legend_w НЕЛЬЗЯ: на 58 колонках это ужимало
    # ячейку ниже содержимого, и вместо аккуратной обрезки строки получалось
    # «C системаB база» — слипшиеся ячейки. Длинную строку и так обрежет
    # truncate_colored ниже, как это было всегда.
    item_w=$((item_w + 1))
    # На широком терминале ячейки растягиваются, как и раньше: прежняя формула
    # (legend_w-10)/6 давала 14 при 100 колонках и 17 при 120, и строка
    # выглядела сеткой, а не кучкой слева. Берём наибольшее из двух — так
    # русский вывод совпадает с прежним на любой ширине, а английский
    # не слипается там, где содержимое шире пропорции.
    local _prop=$(( (legend_w - 10) / 6 ))
    [ "$_prop" -gt "$item_w" ] && item_w="$_prop"
    [ "$item_w" -lt 8 ] && item_w=8
    section_label система; grid_cell "${YELLOW}${BOLD}C${NC} ${YELLOW}${REPLY_T}${NC}" "$item_w"; g1="$REPLY_CELL"
    section_label база;    grid_cell "${CYAN}${BOLD}B${NC} ${CYAN}${REPLY_T}${NC}" "$item_w"; g2="$REPLY_CELL"
    section_label сервисы; grid_cell "${BLUE}${BOLD}S${NC} ${BLUE}${REPLY_T}${NC}" "$item_w"; g3="$REPLY_CELL"
    section_label защита;  grid_cell "${MAGENTA}${BOLD}P${NC} ${MAGENTA}${REPLY_T}${NC}" "$item_w"; g4="$REPLY_CELL"
    t "всё" "all"
    legend3="${BOLD}${lbl_sections}${NC}${g1}${g2}${g3}${g4}${BOLD}A${NC} ${REPLY_T}"
    # Отдельного «R откат» здесь больше нет: R и I открывают один и тот же
    # экран, и две клавиши в строке выглядели как два разных места.
    # Саму клавишу R скрипт по-прежнему принимает — она у людей в пальцах
    # A под аудит не годится: она уже занята под «применить всё». Берём D
    # (диагностика) — и раскладка становится симметричной строке разделов:
    # четыре ячейки плюс хвост
    t "справка" "help";   grid_cell "${CYAN}${BOLD}I${NC} ${REPLY_T}" "$item_w"; g1="$REPLY_CELL"
    t "алиасы" "aliases"; grid_cell "${CYAN}${BOLD}H${NC} ${REPLY_T}" "$item_w"; g2="$REPLY_CELL"
    t "аудит" "audit";    grid_cell "${CYAN}${BOLD}D${NC} ${REPLY_T}" "$item_w"; g3="$REPLY_CELL"
    t "удалить" "remove"; grid_cell "${CYAN}${BOLD}U${NC} ${REPLY_T}" "$item_w"; g4="$REPLY_CELL"
    t "выход" "quit"
    legend4="${BOLD}${lbl_commands}${NC}${g1}${g2}${g3}${g4}${CYAN}${BOLD}Q${NC} ${REPLY_T}"
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
    t "Итоги прогона" "Run summary"
    echo -e "  ${BOLD}${REPLY_T}${NC}"
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
            log_warn_t "${t}: подробности в ${USFC_LOG}" "${t}: details in ${USFC_LOG}"
        done
    fi
}
