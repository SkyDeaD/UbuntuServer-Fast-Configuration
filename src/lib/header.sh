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
        printf '%d.%d ГБ' "$((mb / 1024))" "$(( (mb % 1024) * 10 / 1024 ))"
    else
        printf '%d МБ' "$mb"
    fi
}

# сводка о машине справа от логотипа → массив HEADER_INFO.
# Всё читается из /proc и /etc — шапка рисуется раз на экран, это дёшево.
# ВАЖНО: /etc/os-release нельзя просто `source` — там есть переменная VERSION,
# которая затрёт версию самого скрипта. Поэтому разбираем построчно.
HEADER_INFO=()
build_header_info() {
    local host os ram_mb free_mb up_s up_txt k v
    host="$(< /proc/sys/kernel/hostname)"
    while IFS='=' read -r k v; do
        [ "$k" = "PRETTY_NAME" ] || continue
        v="${v%\"}"; v="${v#\"}"; os="$v"; break
    done < /etc/os-release 2>/dev/null
    ram_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    [[ "$ram_mb" =~ ^[0-9]+$ ]] || ram_mb=0
    free_mb="$(df -m / 2>/dev/null | awk 'NR==2{print $4}')"
    [[ "$free_mb" =~ ^[0-9]+$ ]] || free_mb=0
    up_s="$(< /proc/uptime)"; up_s="${up_s%%.*}"
    [[ "$up_s" =~ ^[0-9]+$ ]] || up_s=0
    if   [ "$up_s" -ge 86400 ]; then up_txt="$((up_s / 86400)) дн $(( (up_s % 86400) / 3600 )) ч"
    elif [ "$up_s" -ge 3600 ];  then up_txt="$((up_s / 3600)) ч $(( (up_s % 3600) / 60 )) мин"
    else                             up_txt="$((up_s / 60)) мин"
    fi

    HEADER_INFO=(
        "${BOLD}${host}${NC}"
        "${DIM}${os:-Linux}${NC}"
        "${DIM}RAM${NC}    $(fmt_size_mb "$ram_mb")"
        "${DIM}Диск${NC}   $(fmt_size_mb "$free_mb") свободно"
        "${DIM}Uptime${NC} ${up_txt}"
    )
}

# «применено 9 из 14 ██████░░░░» из уже посчитанного кэша статусов — бесплатно.
# Пока кэш не построен (самый первый показ шапки), просто ничего не печатаем.
REPLY_PROGRESS=''
build_progress() {
    REPLY_PROGRESS=''
    [ "${#STATUS_RC[@]}" -eq 0 ] && return 0
    local id done=0 total="${#ITEM_IDS[@]}" cells filled i bar='' ch_full ch_empty
    for id in "${ITEM_IDS[@]}"; do
        [ "${STATUS_RC[$id]:-1}" -eq 0 ] && done=$((done + 1))
    done
    [ "$total" -le 0 ] && return 0
    # ровно 2 ячейки на пункт: деление точное, ошибок округления нет по построению
    cells=$(( total * 2 ))
    filled=$(( done * 2 ))
    # ASCII-фолбэк при небитом locale — "#" и ".", но НЕ "=" и "-": шрифты
    # с лигатурами (FiraCode, JetBrains Mono) склеивают их в стрелки и полосы
    if [ "$CHARLEN_NATIVE" = true ]; then ch_full='█'; ch_empty='░'
    else                                  ch_full='#'; ch_empty='.'
    fi
    for ((i = 0; i < cells; i++)); do
        if [ "$i" -lt "$filled" ]; then bar+="$ch_full"; else bar+="$ch_empty"; fi
    done
    REPLY_PROGRESS="${DIM}применено${NC} ${BOLD}${done}${NC}${DIM} из ${total}${NC}  ${GREEN}${bar:0:filled}${NC}${DIM}${bar:filled}${NC}"
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

    echo ""
    local i line info
    for i in "${!LOGO_LINES[@]}"; do
        line="${LOGO_COLORS[$i]}${LOGO_LINES[$i]}${NC}"
        info=""
        [ "$with_info" = true ] && info="${HEADER_INFO[$i]:-}"
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
    echo -en "  ${DIM}Enter — продолжить...${NC}"
    read -r _ </dev/tty
}

