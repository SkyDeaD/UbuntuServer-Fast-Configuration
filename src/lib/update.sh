# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# Самообновление — сверяется при каждом запуске
# ═══════════════════════════════════════════════════════════════
# Проверка обязательна на КАЖДОМ запуске, кэша по времени тут нет специально.
# Ускорение достигается иначе: curl уходит в фон первой же строкой main(), пока
# считается кэш пакетов и статусы. Итоговая цена — max(сеть, локальная работа),
# а не их сумма, как было раньше.
UPDATE_CHECK_FILE=""
UPDATE_CHECK_PID=""

# Проверка уходит в ОТДЕЛЬНУЮ СЕССИЮ, и это не перестраховка, а лечение
# зависания. Симптом: `curl … | sudo bash` на чистой машине доходил до
# «SSH-порт: 22» и вставал намертво — ни меню, ни ошибки. Замер на Ubuntu
# 26.04 (там уже sudo-rs и `Defaults use_pty`):
#
#     strace: --- SIGTTIN {si_signo=SIGTTIN, si_code=SI_KERNEL} ---
#             --- stopped by SIGTTIN ---
#     ps:     T+  curl -fsSL --max-time 5 …
#
# Механика: sudo крутит скрипт в своей псевдотерминальной сессии, и на первом
# же чтении терминала (вопрос о языке при первом запуске) группа процессов
# оказывается фоновой. Ядро шлёт SIGTTIN ВСЕЙ ГРУППЕ, а не одному читателю, —
# вместе со скриптом его получает и фоновая проверка. Скрипт sudo затем
# оживляет, а про проверку не знает: она остаётся в состоянии T навсегда,
# и `wait` за ней не возвращается никогда.
#
# Условие воспроизведения — ровно два слагаемых: скрипт пришёл в sudo по трубе
# И задаётся вопрос о языке. Поэтому запуск установленного usfc работал, а
# установка одной командой из README — нет.
#
# Проверено перебором, а не рассуждением: увод дескрипторов от терминала
# НЕ помогает (дело в группе, а не в fd), `setsid` помогает, `trap '' TTIN`
# тоже. Выбран setsid: SIGSTOP не игнорируется вовсе, а до чужой сессии он
# и не дойдёт. Тем же движением снимается прежняя болячка с Ctrl+C —
# сигнал терминала до чужой сессии не доходит.
start_update_check() {
    [ -n "${USFC_NO_UPDATE:-}" ] && return 0
    UPDATE_CHECK_FILE="$(mktemp)"
    if command -v setsid >/dev/null 2>&1; then
        setsid curl -fsSL --max-time 5 "${REPO_RAW_BASE}/VERSION" \
            -o "$UPDATE_CHECK_FILE" </dev/null >/dev/null 2>&1 &
    else
        # Запасной путь, если setsid вдруг нет: гасим сигналы управления
        # заданиями внутри подоболочки. Игнорируемые диспозиции переживают
        # exec, так что curl наследует их вместе с запуском
        ( trap '' INT TSTP TTIN TTOU
          curl -fsSL --max-time 5 "${REPO_RAW_BASE}/VERSION" \
              -o "$UPDATE_CHECK_FILE" ) </dev/null >/dev/null 2>&1 &
    fi
    UPDATE_CHECK_PID=$!
}

# Ожидание фоновой проверки ВСЕГДА конечно. Голый `wait` бесконечен по своей
# природе: остановленный процесс не завершится никогда, и пользователь получит
# не «проверка не удалась», а мёртвый экран. Один такой запуск уже случился,
# и цена ошибки здесь несимметрична — пропущенная проверка стоит строки
# в выводе, зависший старт стоит всего инструмента.
#
# Срок с запасом к --max-time 5 у самого curl: на здоровом запуске цикл
# отрабатывает за первую же итерацию, sleep не вызывается ни разу.
UPDATE_CHECK_WAIT_DS=80

# usfc_wait_check <pid> — 0 если дождались, 1 если вышел срок
usfc_wait_check() {
    local pid="$1" left="$UPDATE_CHECK_WAIT_DS"
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$left" -le 0 ]; then
            # Остановленный процесс не увидит TERM, пока его не разбудят,
            # поэтому сперва CONT — иначе он останется висеть до перезагрузки
            kill -CONT "$pid" 2>/dev/null
            kill -TERM "$pid" 2>/dev/null
            return 1
        fi
        sleep 0.1
        left=$((left - 1))
    done
    wait "$pid" 2>/dev/null
    return 0
}

# Синхронная попытка — вторая и последняя. Одна фоновая проверка не переживала
# ничего: ни Ctrl+C, ни моргнувшую сеть, ни случайный 429 от GitHub, — и до
# следующего запуска пользователь оставался без проверки вовсе.
REPLY_REMOTE_VERSION=''
fetch_remote_version() {
    REPLY_REMOTE_VERSION="$(curl -fsSL --retry 1 --connect-timeout 5 --max-time 15 \
        "${REPO_RAW_BASE}/VERSION" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$REPLY_REMOTE_VERSION" ]
}

# ── Транзакционная установка новой версии ─────────────────────────────────────
# Скрипт состоит из точки входа и трёх десятков модулей, и обновлять их по
# одному поверх работающей установки нельзя: оборвётся сеть на середине —
# останется новый setup.sh со старыми модулями, то есть код, зовущий функции,
# которых ещё нет. Именно так устроено обновление в MTProxyL, откуда взята идея
# раскладки по lib/, и там это признают прямо в выводе: «часть библиотек
# не обновилась, можно продолжать работу». Продолжать нельзя.
#
# Поэтому здесь всё или ничего:
#   1. качаем ВСЁ в отдельный каталог lib.new, каждый файл через временный
#      и с bash -n;
#   2. любая осечка — rm -rf lib.new и выход, рабочая установка не тронута;
#   3. только когда всё на месте — короткая серия переименований.
#
# Побочная польза от подмены каталога целиком: модули, исчезнувшие из нового
# манифеста, пропадают сами. При пофайловом обновлении они оставались бы
# висеть и грузиться.

# usfc_fetch_to <url-хвост> <куда> — скачать, проверить синтаксис, положить.
# Через временный файл: оборванная закачка не должна оставить обрубок.
usfc_fetch_to() {
    local rel="$1" dest="$2" tmp
    tmp="$(mktemp)" || return 1
    if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 30 \
            "${REPO_RAW_BASE}/${rel}" -o "$tmp" 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    # .sh проверяем на синтаксис: битый модуль лучше не класть вовсе
    case "$rel" in
        *.sh) bash -n "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; } ;;
    esac
    mkdir -p "$(dirname "$dest")" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}

# Читает список модулей из файла манифеста в массив REPLY_MANIFEST
REPLY_MANIFEST=()
usfc_parse_manifest() {
    REPLY_MANIFEST=()
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        REPLY_MANIFEST+=("$line")
    done < "$1"
    [ "${#REPLY_MANIFEST[@]}" -gt 0 ]
}

# install_update <новая версия> — 0 если установили и можно перезапускаться
install_update() {
    local new_version="$1"
    local stage="${USFC_ROOT}/.usfc-stage"
    local live_lib="${USFC_ROOT}/lib"

    # хвост прерванной попытки нам не нужен
    rm -rf "$stage"
    mkdir -p "$stage/lib" || { log_error_t "Не удалось создать ${stage}" \
"Could not create ${stage}"; return 1; }

    # Манифест берём СКАЧАННЫЙ, а не свой: список модулей в новой версии может
    # отличаться. Выковыривать его регуляркой из кода (как делает MTProxyL)
    # значит однажды разойтись с реальностью
    if ! usfc_fetch_to "MODULES" "${stage}/MODULES" || ! usfc_parse_manifest "${stage}/MODULES"; then
        log_error_t "Не удалось получить список модулей — остаюсь на ${VERSION}" \
"Could not fetch the module list — staying on ${VERSION}"
        rm -rf "$stage"; return 1
    fi

    if ! usfc_fetch_to "setup.sh" "${stage}/setup.sh"; then
        log_error_t "Не удалось скачать setup.sh — остаюсь на ${VERSION}" \
"Could not download setup.sh — staying on ${VERSION}"
        rm -rf "$stage"; return 1
    fi

    local total="${#REPLY_MANIFEST[@]}" i=0 m
    log_info_t "Скачиваю модули (${total} шт.)" \
"Downloading modules (${total})"
    for m in "${REPLY_MANIFEST[@]}"; do
        i=$((i + 1))
        printf '  %s[%2d/%2d]%s %s' "$DIM" "$i" "$total" "$NC" "$m"
        if usfc_fetch_to "$m" "${stage}/${m}"; then
            printf ' %b✓%b\n' "$GREEN" "$NC"
        else
            printf ' %b✗%b\n' "$RED" "$NC"
            log_error_t "Модуль ${m} не скачался или не прошёл проверку синтаксиса" \
"Module ${m} failed to download or failed the syntax check"
            log_info_t "Ничего не меняю: установка ${VERSION} осталась как была" \
"Changing nothing: the ${VERSION} install is untouched"
            rm -rf "$stage"
            return 1
        fi
    done

    printf '%s' "$new_version" > "${stage}/VERSION" || {
        log_error_t "Не удалось записать версию" \
"Could not write the version file"; rm -rf "$stage"; return 1; }

    # ── Точка невозврата: дальше только переименования ────────────────────
    # Всё скачано и проверено. mv в пределах одной ФС атомарен на каждый файл,
    # а между ними нет ни сети, ни проверок — окно, в котором установка
    # смешанная, схлопнуто до нескольких системных вызовов.
    local old_lib="${USFC_ROOT}/lib.old.$$"
    if [ -d "$live_lib" ] && ! mv "$live_lib" "$old_lib"; then
        log_error_t "Не удалось освободить ${live_lib} — остаюсь на ${VERSION}" \
"Could not move ${live_lib} aside — staying on ${VERSION}"
        rm -rf "$stage"; return 1
    fi
    mv "${stage}/lib" "$live_lib"
    mv "${stage}/setup.sh" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    mv "${stage}/MODULES" "${USFC_ROOT}/MODULES"
    mv "${stage}/VERSION" "${USFC_ROOT}/VERSION"
    rm -rf "$stage" "$old_lib"
    return 0
}

check_for_update() {
    if [ -n "${USFC_NO_UPDATE:-}" ]; then
        log_info_t "Проверка обновлений отключена (--no-update)" \
"Update check disabled (--no-update)"
        return 1
    fi

    local remote_version=""
    if [ -n "$UPDATE_CHECK_PID" ]; then
        usfc_wait_check "$UPDATE_CHECK_PID"
        UPDATE_CHECK_PID=""
        remote_version="$(tr -d '[:space:]' < "$UPDATE_CHECK_FILE" 2>/dev/null)"
        rm -f "$UPDATE_CHECK_FILE"
    fi

    # Пусто — пробуем ещё раз, уже синхронно. Причину при этом не выдумываем:
    # прежний текст называл сеть и отсутствие файла, хотя не проверял ни того,
    # ни другого, — и врал ровно в том случае, когда проверку просто прервали
    if [ -z "$remote_version" ]; then
        log_info_t "Проверяю обновления ещё раз..." "Retrying the update check..."
        if fetch_remote_version; then
            remote_version="$REPLY_REMOTE_VERSION"
        else
            log_warn_t "Не удалось проверить обновления — остаюсь на ${VERSION}" \
"Could not check for updates — staying on ${VERSION}"
            log_info_t "Отключить проверку: ${BOLD}usfc --no-update${NC}" \
"Skip the check with: ${BOLD}usfc --no-update${NC}"
            return 0
        fi
    fi

    if [ "$remote_version" = "$VERSION" ]; then
        return 1
    fi

    # sort -V — версии сравниваются по-настоящему (4.2.0 > 4.1.1), а не строковым "!="
    local newest
    newest="$(printf '%s\n%s\n' "$VERSION" "$remote_version" | sort -V | tail -n1)"
    if [ "$newest" = "$VERSION" ]; then
        # Локальная версия новее той, что в репозитории. Обновляться назад мы не
        # станем — молча откатить себя хуже, чем ничего не сделать. Но и молчать
        # тут нельзя: ровно это молчание сделало бы невидимой перенумерацию
        # релизов (в репозитории номер стал бы ниже, а на экране — «всё свежее»).
        log_info_t "В репозитории ${remote_version}, у вас ${VERSION} — обновляться некуда" \
"Repository has ${remote_version}, you have ${VERSION} — nothing to update to"
        return 1
    fi

    log_info_t "Доступна новая версия: ${BOLD}${remote_version}${NC} ${DIM}(у вас ${VERSION})${NC}" \
"New version available: ${BOLD}${remote_version}${NC} ${DIM}(you have ${VERSION})${NC}"
    if ask_yn_t "Обновить usfc до ${remote_version} сейчас?" "Update usfc to ${remote_version} now?"; then
        if install_update "$remote_version"; then
            log_success_t "Обновлено до ${remote_version}, перезапускаю..." \
"Updated to ${remote_version}, restarting..."
            exec "$SCRIPT_PATH"
        fi
    fi
    return 0
}
