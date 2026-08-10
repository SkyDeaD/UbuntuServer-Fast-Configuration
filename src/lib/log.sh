# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# Лог и запуск длинных команд
# ═══════════════════════════════════════════════════════════════
# Сырой вывод apt/curl/systemctl всегда уезжает в файл, а на экране остаётся одна
# живая строка со спиннером. Лог обязателен: без него сворачивание вывода
# превратило бы любую неудачную установку в неотлаживаемую.
USFC_LOG="/var/log/usfc.log"
USFC_LOG_MAX=5242880   # 5 МБ, дальше — ротация в .1
USFC_VERBOSE="${USFC_VERBOSE:-}"

log_init() {
    local size
    size="$(stat -c %s "$USFC_LOG" 2>/dev/null)" || size=0
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    [ "$size" -gt "$USFC_LOG_MAX" ] && mv -f "$USFC_LOG" "${USFC_LOG}.1" 2>/dev/null
    if ! touch "$USFC_LOG" 2>/dev/null; then
        # некуда писать (только чтение / нет прав) — не падаем, просто теряем лог
        USFC_LOG="/dev/null"
        return
    fi
    chmod 640 "$USFC_LOG" 2>/dev/null
    chgrp adm "$USFC_LOG" 2>/dev/null
    printf '\n===== %s  usfc %s  user=%s =====\n' \
        "$(date '+%F %T')" "${VERSION:-?}" "${TARGET_USER:-?}" >> "$USFC_LOG"
}

# брайлевские кадры красивее, но при несобранном locale порежутся на мусорные
# байты — там честнее обычная ASCII-вертушка
if [ "$CHARLEN_NATIVE" = true ]; then
    SPINNER_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; SPINNER_N=10
else
    SPINNER_FRAMES='|/-\'; SPINNER_N=4
fi

# Текущее время в секундах → REPLY_NOW.
# Специально НЕ через магическую переменную SECONDS: её присваивание глобально
# сбрасывает счётчик, и вложенный замер (run_logged внутри пункта) обнулял бы
# внешний замер этого пункта — в сводке получались отрицательные секунды.
# EPOCHSECONDS есть в bash 5 и не стоит ни одного форка; date — запасной путь.
REPLY_NOW=0
now_s() {
    if [ -n "${EPOCHSECONDS:-}" ]; then
        REPLY_NOW="$EPOCHSECONDS"
    else
        REPLY_NOW="$(date +%s)"
    fi
}

RUN_LOGGED_PID=''
CURSOR_HIDDEN=false
# курсор возвращаем в любом случае — иначе Ctrl-C посреди установки оставит
# пользователя в терминале без курсора. Но только если мы его реально прятали:
# безусловный tput cnorm подмешивал управляющие последовательности в вывод
# даже при обычном выходе из меню, в том числе при перенаправлении в файл
cleanup_spinner() {
    [ -n "$RUN_LOGGED_PID" ] && kill "$RUN_LOGGED_PID" 2>/dev/null
    RUN_LOGGED_PID=''
    if [ "$CURSOR_HIDDEN" = true ]; then
        tput cnorm 2>/dev/null
        CURSOR_HIDDEN=false
    fi
}

_spin_wait() {
    local pid="$1" desc="$2" started="$3" offset="${4:-0}" i=0 frame note='' line
    tput civis 2>/dev/null && CURSOR_HIDDEN=true
    while kill -0 "$pid" 2>/dev/null; do
        # Раз в ~3 секунды заглядываем в свежий хвост лога. Установка, застрявшая
        # на блокировке dpkg, выглядит как обычный растущий таймер — пользователь
        # видит «213s» и не понимает, чего ждёт. Причину сообщает сам apt
        # («Waiting for cache lock: ... held by process N (unattended-upgr)»),
        # поэтому не гадаем, а читаем её оттуда.
        if [ $(( i % 20 )) -eq 0 ]; then
            note=''
            local lock_line holder
            lock_line="$(tail -c "+$((offset + 1))" "$USFC_LOG" 2>/dev/null \
                        | grep -F 'Waiting for cache lock' | tail -n1)"
            if [ -n "$lock_line" ]; then
                holder="${lock_line##*\(}"; holder="${holder%%)*}"
                note=" ${YELLOW}— жду блокировку dpkg${NC}"
                [ -n "$holder" ] && [ "$holder" != "$lock_line" ] && \
                    note=" ${YELLOW}— жду: пакетный менеджер занят (${holder})${NC}"
            fi
        fi
        frame="${SPINNER_FRAMES:$((i % SPINNER_N)):1}"
        now_s
        # Строку добиваем до ширины терминала: примечание то появляется, то
        # исчезает, и без добивки от длинного варианта оставались бы хвосты
        line="${CYAN}${frame}${NC} ${desc}...  $((REPLY_NOW - started))s${note}"
        truncate_colored "$line" "$((TERM_W - 2))"
        pad_title "$REPLY_TRUNC" "$((TERM_W - 2))"
        printf '\r  %b' "$REPLY_PAD"
        i=$((i + 1))
        sleep 0.15
    done
    if [ "$CURSOR_HIDDEN" = true ]; then
        tput cnorm 2>/dev/null
        CURSOR_HIDDEN=false
    fi
    printf '\r%*s\r' "$((TERM_W + 6))" ''
}

# best-effort статистика из вывода apt → REPLY_STATS. Локаль форсирована в C.UTF-8,
# так что строки apt английские и предсказуемые; не распарсилось — молча опускаем
REPLY_STATS=''
_apt_stats_since() {
    REPLY_STATS=''
    local offset="$1" line pkgs='' size=''
    while IFS= read -r line; do
        if [[ "$line" =~ ([0-9]+)\ upgraded,\ ([0-9]+)\ newly\ installed ]]; then
            pkgs=$(( BASH_REMATCH[1] + BASH_REMATCH[2] ))
        elif [[ "$line" =~ ^Need\ to\ get\ ([0-9.,]+\ [kMG]?B) ]]; then
            size="${BASH_REMATCH[1]}"
        fi
    done < <(tail -c "+$((offset + 1))" "$USFC_LOG" 2>/dev/null)
    [ -n "$pkgs" ] && [ "$pkgs" -gt 0 ] && REPLY_STATS="${pkgs} пакет(ов)"
    [ -n "$size" ] && REPLY_STATS="${REPLY_STATS}${REPLY_STATS:+, }${size}"
}

# run_logged "<описание>" команда аргументы... — выполняет команду, пряча её вывод
# в лог и показывая одну строку со спиннером. Возвращает код возврата команды.
# ВАЖНО: только для НЕинтерактивных команд — спиннер затрёт любой вопрос.
run_logged() {
    local desc="${1:-Выполнение}"; shift
    [ "$#" -eq 0 ] && return 0

    # Сухой прогон. Перехват стоит именно здесь, а не в каждой apply_-функции:
    # через run_logged проходят все длительные внешние команды — apt, curl,
    # add-apt-repository. Размазывать проверку по три десятка мест значило бы
    # однажды забыть одно из них, причём молча
    if [ "$USFC_DRY_RUN" = true ]; then
        printf '  %b[сухой прогон]%b %s\n' "$DIM" "$NC" "$*"
        return 0
    fi

    local offset
    offset="$(stat -c %s "$USFC_LOG" 2>/dev/null)" || offset=0
    [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
    printf '\n--- %s $ %s\n' "$(date '+%F %T')" "$*" >> "$USFC_LOG"

    local rc elapsed started
    now_s; started="$REPLY_NOW"
    # stdin у команды всегда /dev/null: это заведомо неинтерактивные вызовы, а без
    # закрытого stdin фоновый apt способен вычитать ввод, предназначенный
    # следующему вопросу скрипта, и вопрос молча «проскочит»
    if [ -n "$USFC_VERBOSE" ] || [ ! -t 1 ]; then
        # verbose или вывод не в терминал (перенаправление в файл, CI) — спиннер
        # там бесполезен и только насорит управляющими последовательностями
        "$@" </dev/null 2>&1 | tee -a "$USFC_LOG"
        rc="${PIPESTATUS[0]}"
    else
        "$@" </dev/null >> "$USFC_LOG" 2>&1 &
        RUN_LOGGED_PID=$!
        _spin_wait "$RUN_LOGGED_PID" "$desc" "$started" "$offset"
        wait "$RUN_LOGGED_PID"; rc=$?
        RUN_LOGGED_PID=''
    fi
    now_s; elapsed=$((REPLY_NOW - started))

    if [ "$rc" -eq 0 ]; then
        _apt_stats_since "$offset"
        local extra="${elapsed}s"
        [ -n "$REPLY_STATS" ] && extra="${REPLY_STATS}, ${elapsed}s"
        log_success "${desc} ${DIM}(${extra})${NC}"
    else
        log_error_t "${desc} — не удалось (код ${rc}, ${elapsed}s)" \
"${desc} — failed (code ${rc}, ${elapsed}s)"
        t "последние строки вывода:" "last lines of output:"
        echo -e "  ${DIM}${REPLY_T}${NC}"
        tail -c "+$((offset + 1))" "$USFC_LOG" 2>/dev/null | tail -n 20 | sed 's/^/      /'
        log_info_t "полный лог: ${USFC_LOG}" \
"full log: ${USFC_LOG}"
    fi
    return "$rc"
}
