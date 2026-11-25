# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# плотный ANSI Shadow и так выглядит хорошо.
LOGO_LINES=(
'██╗   ██╗███████╗███████╗ ██████╗'
'██║   ██║██╔════╝██╔════╝██╔════╝'
'██║   ██║███████╗█████╗  ██║     '
'██║   ██║╚════██║██╔══╝  ██║     '
'╚██████╔╝███████║██║     ╚██████╗'
' ╚═════╝ ╚══════╝╚═╝      ╚═════╝'
)
LOGO_W=33

# Перелив голубой → синий по строкам логотипа. 256-цветные коды поддерживают
# практически все современные терминалы, но если TERM не задан (cron, пайп) или
# палитра беднее — молча откатываемся на ровный CYAN, а не сыпем мусором.
LOGO_COLORS=()
init_logo_colors() {
    local ncolors i ramp=(51 45 39 33 27 21)
    LOGO_COLORS=()
    # цвет выключен целиком (NO_COLOR / не терминал) — никакого градиента,
    # иначе escape-коды полезли бы в файл вопреки просьбе пользователя
    if [ "$USFC_NO_COLOR" = true ]; then
        for i in "${!LOGO_LINES[@]}"; do LOGO_COLORS+=(''); done
        return
    fi
    ncolors="$(tput colors 2>/dev/null)"
    [[ "$ncolors" =~ ^[0-9]+$ ]] || ncolors=8
    for i in "${!LOGO_LINES[@]}"; do
        if [ "$ncolors" -ge 256 ]; then
            LOGO_COLORS+=("\033[38;5;${ramp[$i]}m")
        else
            LOGO_COLORS+=("$CYAN")
        fi
    done
}

# МБ → «1.6 ГБ» / «512 МБ» без внешних процессов
fmt_size_mb() {
    local mb="${1:-0}"
    if [ "$mb" -ge 1024 ]; then
        t "ГБ" "GB"; printf '%d.%d %s' "$((mb / 1024))" "$(( (mb % 1024) * 10 / 1024 ))" "$REPLY_T"
    else
        t "МБ" "MB"; printf '%d %s' "$mb" "$REPLY_T"
    fi
}

# сводка о машине справа от логотипа → массив HEADER_INFO.
# Всё читается из /proc и /etc — шапка рисуется раз на экран, это дёшево.
HEADER_INFO=()
build_header_info() {
    local host os ram_mb free_mb up_s up_txt k v
    host="$(< /proc/sys/kernel/hostname)"
    # os-release уже разобран в lib/os.sh — второй парсер здесь только
    # разъехался бы с первым
    os="$OS_PRETTY"
    ram_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    [[ "$ram_mb" =~ ^[0-9]+$ ]] || ram_mb=0
    free_mb="$(df -m / 2>/dev/null | awk 'NR==2{print $4}')"
    [[ "$free_mb" =~ ^[0-9]+$ ]] || free_mb=0
    up_s="$(< /proc/uptime)"; up_s="${up_s%%.*}"
    [[ "$up_s" =~ ^[0-9]+$ ]] || up_s=0
    # Единицы времени берём через t() ДО сборки строки: шапка рисуется на каждом
    # кадре меню, и подстановка $(...) на каждую единицу вернула бы форки
    local u_d u_h u_m
    t "дн" "d";  u_d="$REPLY_T"
    t "ч"  "h";  u_h="$REPLY_T"
    t "мин" "m"; u_m="$REPLY_T"
    if   [ "$up_s" -ge 86400 ]; then up_txt="$((up_s / 86400)) ${u_d} $(( (up_s % 86400) / 3600 )) ${u_h}"
    elif [ "$up_s" -ge 3600 ];  then up_txt="$((up_s / 3600)) ${u_h} $(( (up_s % 3600) / 60 )) ${u_m}"
    else                             up_txt="$((up_s / 60)) ${u_m}"
    fi
    local lbl_disk lbl_free
    t "Диск" "Disk";        lbl_disk="$REPLY_T"
    t "свободно" "free";    lbl_free="$REPLY_T"

    HEADER_INFO=(
        "${BOLD}${host}${NC}"
        "${DIM}${os:-Linux}${NC}"
        "${DIM}RAM${NC}    $(fmt_size_mb "$ram_mb")"
        "${DIM}${lbl_disk}${NC}   $(fmt_size_mb "$free_mb") ${lbl_free}"
        "${DIM}Uptime${NC} ${up_txt}"
    )
}

# «применено 9 из 14 ██████░░░░» из уже посчитанного кэша статусов — бесплатно.
# Пока кэш не построен (самый первый показ шапки), просто ничего не печатаем.
REPLY_PROGRESS=''
build_progress() {
    REPLY_PROGRESS=''
    [ "${#STATUS_RC[@]}" -eq 0 ] && return 0
    local id done=0 total="${#ITEM_IDS[@]}"
    for id in "${ITEM_IDS[@]}"; do
        [ "${STATUS_RC[$id]:-1}" -eq 0 ] && done=$((done + 1))
    done
    [ "$total" -le 0 ] && return 0

    local w_done w_of text_plain text_colored avail cells=0 filled=0
    t "применено" "applied"; w_done="$REPLY_T"
    t "из" "of";             w_of="$REPLY_T"
    text_plain="${w_done} ${done} ${w_of} ${total}"
    text_colored="${DIM}${w_done}${NC} ${BOLD}${done}${NC}${DIM} ${w_of} ${total}${NC}"
    visible_len "$text_plain"
    # Бюджет ширины бара: TERM_W минус 2 пробела отступа, 32 колонки версии слева,
    # 2 пробела, видимая длина текста прогресса и 2 пробела перед баром — строка
    # никогда не превышает TERM_W контента после 2 пробелов отступа
    avail=$(( ${TERM_W:-78} - 2 - 32 - 2 - REPLY_LEN - 2 ))
    if [ "$avail" -ge $(( total * 2 )) ]; then
        # ровно 2 ячейки на пункт: деление точное, ошибок округления нет по построению
        cells=$(( total * 2 ))
        filled=$(( done * 2 ))
    elif [ "$avail" -ge "$total" ]; then
        # 1 ячейка на пункт: на 80-колоночном терминале бар помещается целиком
        cells="$total"
        filled="$done"
    elif [ "$avail" -ge 8 ]; then
        # пропорциональный бар на тесных экранах
        cells="$avail"
        filled=$(( done * avail / total ))
    fi

    if [ "$cells" -le 0 ]; then
        REPLY_PROGRESS="$text_colored"
        return 0
    fi

    # ASCII-фолбэк при небитом locale — "#" и ".", но НЕ "=" и "-": шрифты
    # с лигатурами (FiraCode, JetBrains Mono) склеивают их в стрелки и полосы
    local ch_full ch_empty bar_full='' bar_empty='' i
    if [ "$CHARLEN_NATIVE" = true ]; then ch_full='█'; ch_empty='░'
    else                                  ch_full='#'; ch_empty='.'
    fi
    for ((i = 0; i < cells; i++)); do
        if [ "$i" -lt "$filled" ]; then bar_full+="$ch_full"; else bar_empty+="$ch_empty"; fi
    done
    REPLY_PROGRESS="${text_colored}  ${GREEN}${bar_full}${NC}${DIM}${bar_empty}${NC}"
}

show_header() {
    # Очистка экрана осмысленна только в терминале: при перенаправлении в файл
    # или в пайп это просто мусорные управляющие байты в начале вывода
    if [ -t 1 ]; then
        clear 2>/dev/null || printf '\033[2J\033[H'
    fi
    [ "${#LOGO_COLORS[@]}" -eq 0 ] && init_logo_colors

    # сводку показываем, только если она реально помещается рядом с логотипом:
    # 33 колонки логотипа + 3 отступа + ~34 на самую длинную строку сводки
    local with_info=false
    if [ "$TERM_W" -ge 70 ]; then
        with_info=true
        build_header_info
    fi

    # Бейдж сухого прогона ставим в 6-ю (свободную) строку рядом с логотипом:
    # 34 + 3 + 14 = 51 <= 58, поэтому влезает на любой ширине, не крадёт высоту
    # экрана и не ломает выравнивание строки с версией и прогресс-баром
    local dry_badge=''
    if [ "${USFC_DRY_RUN:-false}" = true ]; then
        t "[СУХОЙ ПРОГОН]" "[DRY-RUN]"
        dry_badge="${YELLOW}${BOLD}${REPLY_T}${NC}"
    fi

    echo ""
    local i line info
    for i in "${!LOGO_LINES[@]}"; do
        line="${LOGO_COLORS[$i]}${LOGO_LINES[$i]}${NC}"
        info=""
        [ "$with_info" = true ] && info="${HEADER_INFO[$i]:-}"
        if [ "$i" -eq 5 ] && [ -n "$dry_badge" ]; then
            info="$dry_badge"
        fi
        if [ -n "$info" ]; then
            pad_title "${LOGO_LINES[$i]}" "$LOGO_W"
            printf "  %b%s%b   %b\n" "${LOGO_COLORS[$i]}" "$REPLY_PAD" "$NC" "$info"
        else
            echo -e "  ${line}"
        fi
    done

    build_progress
    if [ -n "$REPLY_PROGRESS" ] && [ "$with_info" = true ]; then
        pad_title "USFC v${VERSION} by SkyDeaD" 32
        printf "  ${BOLD}%s${NC}  %b\n" "$REPLY_PAD" "$REPLY_PROGRESS"
    else
        echo -e "  ${BOLD}USFC${NC} ${DIM}v${VERSION} by SkyDeaD${NC}   ${DIM}UbuntuServer Fast Configuration${NC}"
    fi
    hr_heavy "$CYAN"
}

pause() {
    echo ""
    t "Enter — продолжить..." "Enter to continue..."
    echo -en "  ${DIM}${REPLY_T}${NC}"
    read -r _ </dev/tty || true
}

