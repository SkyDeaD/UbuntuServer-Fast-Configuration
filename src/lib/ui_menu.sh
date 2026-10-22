# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# Сообщение для следующей отрисовки меню (ошибка ввода); show_menu его гасит
MENU_NOTICE=''

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
    # Три строки одной грамматики «метка  клавиша слово · …» вместо шести.
    # Ячейки идут по естественной ширине через два пробела, а не сеткой:
    # сетка требовала заранее мерить все подписи, и это стоило девяти форков
    # $(…) на каждый кадр. Строки рассчитаны на 74 символа (терминал 78);
    # на более узком их аккуратно обрежет truncate_colored ниже.
    local l_choice l_sec l_more lbl_w=0 _l
    t "Выбор" "Choose";     l_choice="$REPLY_T"
    t "Разделы" "Sections"; l_sec="$REPLY_T"
    t "Ещё" "More";         l_more="$REPLY_T"
    for _l in "$l_choice" "$l_sec" "$l_more"; do
        visible_len "$_l"; [ "$REPLY_LEN" -gt "$lbl_w" ] && lbl_w="$REPLY_LEN"
    done
    lbl_w=$((lbl_w + 2))
    pad_title "$l_choice" "$lbl_w"; l_choice="$REPLY_PAD"
    pad_title "$l_sec" "$lbl_w";    l_sec="$REPLY_PAD"
    pad_title "$l_more" "$lbl_w";   l_more="$REPLY_PAD"

    local k="${CYAN}${BOLD}" dot=" ${DIM}·${NC} " legend1 legend2 legend3 w_all w_prev
    t "всё" "all";                w_all="$REPLY_T"
    t "предпросмотр" "preview";   w_prev="$REPLY_T"
    legend1="${BOLD}${l_choice}${NC}${k}5${NC}${dot}${k}1 3 5${NC}${dot}${k}1-5${NC}${dot}${k}B,S${NC}${dot}${k}A${NC} ${w_all}${dot}${k}V 5${NC} ${w_prev}"

    # Буквы разделов — в цвете раздела, как подзаголовки в таблице. Метка ⇄
    # в конце строки объясняет столбик в таблице: что повторный выбор такого
    # пункта его выключает. Как убрать остальное — на экране I.
    legend2="${BOLD}${l_sec}${NC}"
    section_label система; legend2+="${YELLOW}${BOLD}C${NC} ${YELLOW}${REPLY_T}${NC}  "
    section_label база;    legend2+="${CYAN}${BOLD}B${NC} ${CYAN}${REPLY_T}${NC}  "
    section_label сервисы; legend2+="${BLUE}${BOLD}S${NC} ${BLUE}${REPLY_T}${NC}  "
    section_label защита;  legend2+="${MAGENTA}${BOLD}P${NC} ${MAGENTA}${REPLY_T}${NC}  "
    t "повтор выключает" "pick again to undo"; legend2+="${CYAN}⇄${NC} ${DIM}${REPLY_T}${NC}"

    # R принимается как синоним I (была отдельным экраном отката), но в строку
    # не выводится: две клавиши на один экран читались как два разных места
    legend3="${BOLD}${l_more}${NC}"
    t "справка" "help";    legend3+="${k}I${NC} ${REPLY_T}  "
    t "алиасы" "aliases";  legend3+="${k}H${NC} ${REPLY_T}  "
    t "аудит" "audit";     legend3+="${k}D${NC} ${REPLY_T}  "
    t "удалить" "remove";  legend3+="${k}U${NC} ${REPLY_T}  "
    t "язык" "language";   legend3+="${k}L${NC} ${REPLY_T}  "
    t "выход" "quit";      legend3+="${k}Q${NC} ${REPLY_T}"

    box_line "$DIM" '╭' '┬' '╮' "$legend_w"
    for line in "$legend1" "$legend2" "$legend3"; do
        local ltrunc lpad
        truncate_colored "$line" "$legend_w"; ltrunc="$REPLY_TRUNC"
        visible_len "$ltrunc"
        lpad=$((legend_w - REPLY_LEN))
        [ "$lpad" -lt 0 ] && lpad=0
        printf "  ${DIM}│${NC} %b%*s ${DIM}│${NC}\n" "$ltrunc" "$lpad" ""
    done
    box_line "$DIM" '╰' '┴' '╯' "$legend_w"
    # Ошибка ввода из прошлого круга — над приглашением, пока её видно.
    # Раньше она печаталась перед перерисовкой и через sleep 1 исчезала
    if [ -n "$MENU_NOTICE" ]; then
        echo -e "  ${RED}✗${NC} ${MENU_NOTICE}"
        MENU_NOTICE=''
    fi
    echo ""
}

# process_item <номер> [позиция-в-пачке] [всего-в-пачке]
# Два последних аргумента нужны только для шапки "[3/7]" в пакетном режиме.
# Возвращает код возврата apply_*/disable_* — на нём строится итоговая сводка.
# preview_item <номер> — показать, что пункт СДЕЛАЛ БЫ, ничего не делая.
#
# Пункт идёт в ПОДОБОЛОЧКЕ, и это главное решение здесь. dry_run_enable
# определяет два десятка функций-заглушек и обратно их не снимает; снимать
# руками пришлось бы двумя новыми механизмами — автосписком подменённых имён
# и сохранением оригинала log_success, который подменяется как функция, а не
# как внешняя команда. Оба тонкие и ломаются молча. Подоболочка же гарантирует
# уборку по построению: вместе с ней умирают и заглушки, и все побочные
# переменные, которые пункт мог тронуть, — APT_UPDATED, TARGET_USER после
# switch_target_user, POLICY_RC_D_OURS, кэш пакетов, предзаданные ответы.
#
# Зовём process_item, а не apply_$id: у ⇄-пунктов он уходит в disable_$id,
# и честный предпросмотр обязан показать ту ветку, которая реально сработала бы.
preview_item() {
    local idx="$1"
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#ITEM_IDS[@]}" ]; then
        log_warn_t "Нужен номер пункта от 1 до ${#ITEM_IDS[@]}" \
"Give an item number between 1 and ${#ITEM_IDS[@]}"
        return 1
    fi
    show_header
    log_info_t "Предпросмотр: показываю, что было бы сделано, и ничего не меняю" \
"Preview: showing what would be done, changing nothing"
    ( USFC_DRY_RUN=true; dry_run_enable >/dev/null; process_item "$idx" )
    # Пункт мог читать состояние системы на лету — кэшу статусов больше не верим
    invalidate_statuses
    reset_bulk_answers
    return 0
}

process_item() {
    local idx="$1" pos="${2:-}" total="${3:-}"
    local id="${ITEM_IDS[$((idx-1))]}" title="${ITEM_TITLES[$((idx-1))]}" prefix=""
    [ -n "$pos" ] && [ -n "$total" ] && prefix="${DIM}[${pos}/${total}]${NC} "
    echo ""
    local rc=0
    ITEM_SKIP_REASON=''
    if item_supports_disable "$id" && item_applied "$id"; then
        # У nginx и Docker disable_* — переключатель (см. комментарий там же),
        # и «Отключить» в шапке врало бы, когда сервис уже стоит и его поднимут
        local verb
        t "Отключить" "Disable"; verb="$REPLY_T"
        case "$id" in
            nginx|docker) service_is_up "$id" || { t "Включить" "Enable"; verb="$REPLY_T"; } ;;
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

# ── Итог пункта и сводка пакетного прогона ────────────────────────────────────
# Результат берём из РЕАЛЬНОГО состояния системы, а не из самоотчёта функций:
# многие apply_* возвращают 0 и когда пользователь просто отказался.
#
# item_result <номер> <код> → REPLY_RESULT (цветная метка), REPLY_RESULT_KIND
# (ok|fail|skip). Одна классификация на сводку и на итог одиночного пункта —
# две копии разошлись бы на первой же правке.
REPLY_RESULT=''
REPLY_RESULT_KIND=''
item_result() {
    local id="${ITEM_IDS[$(($1 - 1))]}" rc="$2"
    if [ "$rc" -ne 0 ]; then
        t "✗ ошибка" "✗ failed"; REPLY_RESULT="${RED}${REPLY_T}${NC}"; REPLY_RESULT_KIND=fail
    elif "status_${id}" >/dev/null 2>&1; then
        t "✓ готово" "✓ done"; REPLY_RESULT="${GREEN}${REPLY_T}${NC}"; REPLY_RESULT_KIND=ok
    else
        t "— пропущено" "— skipped"; REPLY_RESULT="${DIM}${REPLY_T}${NC}"; REPLY_RESULT_KIND=skip
    fi
}

# item_result_line <номер> <код> <секунды> — одна строка после одиночного
# пункта: чем кончилось и, если не применилось, почему или где лог
item_result_line() {
    local title="${ITEM_TITLES[$(($1 - 1))]}"
    item_result "$1" "$2"
    echo ""
    case "$REPLY_RESULT_KIND" in
        ok)   echo -e "  ${REPLY_RESULT}${GREEN}: ${title}${NC} ${DIM}— ${3}s${NC}" ;;
        fail) t "лог" "log"
              echo -e "  ${REPLY_RESULT}${RED}: ${title}${NC} ${DIM}— ${REPLY_T}: ${USFC_LOG}${NC}" ;;
        skip) echo -e "  ${REPLY_RESULT}${DIM}: ${title}${ITEM_SKIP_REASON:+ — ${ITEM_SKIP_REASON}}${NC}" ;;
    esac
}

SUMMARY_TITLES=()
SUMMARY_RESULTS=()
SUMMARY_TIMES=()
SUMMARY_WHY=()
SUMMARY_FAILED=()

summary_reset() { SUMMARY_TITLES=(); SUMMARY_RESULTS=(); SUMMARY_TIMES=(); SUMMARY_WHY=(); SUMMARY_FAILED=(); }

summary_record() {
    local idx="$1" rc="$2" secs="$3" title="${ITEM_TITLES[$(($1 - 1))]}" why=''
    item_result "$idx" "$rc"
    [ "$REPLY_RESULT_KIND" = fail ] && SUMMARY_FAILED+=("$title")
    [ "$REPLY_RESULT_KIND" = skip ] && why="$ITEM_SKIP_REASON"
    SUMMARY_TITLES+=("$title")
    SUMMARY_RESULTS+=("$REPLY_RESULT")
    SUMMARY_TIMES+=("${secs}s")
    SUMMARY_WHY+=("$why")
}

show_summary() {
    [ "${#SUMMARY_TITLES[@]}" -eq 0 ] && return 0
    refresh_term_width
    echo ""
    t "Итоги прогона" "Run summary"
    echo -e "  ${BOLD}${REPLY_T}${NC}"
    local name_w=26 res_w=14 time_w=6 why_w=0 i t r w pad any_why=false
    for w in "${SUMMARY_WHY[@]}"; do [ -n "$w" ] && any_why=true && break; done
    # Колонка «почему» — только если есть что в неё писать и она влезает:
    # три колонки занимают 26+14+6 и 10 символов рамки, четвёртая — ещё 3.
    # Не влезла — причины идут строками под таблицей
    if [ "$any_why" = true ]; then
        why_w=$(( TERM_W - name_w - res_w - time_w - 13 ))
        [ "$why_w" -lt 12 ] && why_w=0
    fi
    local -a cols=("$name_w" "$res_w" "$time_w")
    [ "$why_w" -gt 0 ] && cols+=("$why_w")
    box_line "$DIM" '╭' '┬' '╮' "${cols[@]}"
    for i in "${!SUMMARY_TITLES[@]}"; do
        truncate_colored "${SUMMARY_TITLES[$i]}" "$name_w"; t="$REPLY_TRUNC"
        pad_title "$t" "$name_w"; t="$REPLY_PAD"
        truncate_colored "${SUMMARY_RESULTS[$i]}" "$res_w"; r="$REPLY_TRUNC"
        visible_len "$r"; pad=$((res_w - REPLY_LEN)); [ "$pad" -lt 0 ] && pad=0
        printf "  ${DIM}│${NC} %s ${DIM}│${NC} %b%*s ${DIM}│${NC} %${time_w}s ${DIM}│${NC}" \
            "$t" "$r" "$pad" "" "${SUMMARY_TIMES[$i]}"
        if [ "$why_w" -gt 0 ]; then
            truncate_colored "${SUMMARY_WHY[$i]}" "$why_w"; w="$REPLY_TRUNC"
            visible_len "$w"; pad=$((why_w - REPLY_LEN)); [ "$pad" -lt 0 ] && pad=0
            printf " ${DIM}%s%*s${NC} ${DIM}│${NC}" "$w" "$pad" ""
        fi
        printf '\n'
    done
    box_line "$DIM" '╰' '┴' '╯' "${cols[@]}"
    if [ "$any_why" = true ] && [ "$why_w" -eq 0 ]; then
        for i in "${!SUMMARY_WHY[@]}"; do
            [ -n "${SUMMARY_WHY[$i]}" ] && echo -e "  ${DIM}— ${SUMMARY_TITLES[$i]}: ${SUMMARY_WHY[$i]}${NC}"
        done
    fi
    if [ "${#SUMMARY_FAILED[@]}" -gt 0 ]; then
        echo ""
        for t in "${SUMMARY_FAILED[@]}"; do
            log_warn_t "${t}: подробности в ${USFC_LOG}" "${t}: details in ${USFC_LOG}"
        done
    fi
}
