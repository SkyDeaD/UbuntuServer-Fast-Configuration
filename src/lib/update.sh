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

start_update_check() {
    [ -n "${USFC_NO_UPDATE:-}" ] && return 0
    UPDATE_CHECK_FILE="$(mktemp)"
    curl -fsSL --max-time 5 "${REPO_RAW_BASE}/VERSION" -o "$UPDATE_CHECK_FILE" 2>/dev/null &
    UPDATE_CHECK_PID=$!
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
    mkdir -p "$stage/lib" || { log_error "Не удалось создать ${stage}"; return 1; }

    # Манифест берём СКАЧАННЫЙ, а не свой: список модулей в новой версии может
    # отличаться. Выковыривать его регуляркой из кода (как делает MTProxyL)
    # значит однажды разойтись с реальностью
    if ! usfc_fetch_to "MODULES" "${stage}/MODULES" || ! usfc_parse_manifest "${stage}/MODULES"; then
        log_error "Не удалось получить список модулей — остаюсь на ${VERSION}"
        rm -rf "$stage"; return 1
    fi

    if ! usfc_fetch_to "setup.sh" "${stage}/setup.sh"; then
        log_error "Не удалось скачать setup.sh — остаюсь на ${VERSION}"
        rm -rf "$stage"; return 1
    fi

    local total="${#REPLY_MANIFEST[@]}" i=0 m
    log_info "Скачиваю модули (${total} шт.)"
    for m in "${REPLY_MANIFEST[@]}"; do
        i=$((i + 1))
        printf '  %s[%2d/%2d]%s %s' "$DIM" "$i" "$total" "$NC" "$m"
        if usfc_fetch_to "$m" "${stage}/${m}"; then
            printf ' %b✓%b\n' "$GREEN" "$NC"
        else
            printf ' %b✗%b\n' "$RED" "$NC"
            log_error "Модуль ${m} не скачался или не прошёл проверку синтаксиса"
            log_info "Ничего не меняю: установка ${VERSION} осталась как была"
            rm -rf "$stage"
            return 1
        fi
    done

    printf '%s' "$new_version" > "${stage}/VERSION" || {
        log_error "Не удалось записать версию"; rm -rf "$stage"; return 1; }

    # ── Точка невозврата: дальше только переименования ────────────────────
    # Всё скачано и проверено. mv в пределах одной ФС атомарен на каждый файл,
    # а между ними нет ни сети, ни проверок — окно, в котором установка
    # смешанная, схлопнуто до нескольких системных вызовов.
    local old_lib="${USFC_ROOT}/lib.old.$$"
    if [ -d "$live_lib" ] && ! mv "$live_lib" "$old_lib"; then
        log_error "Не удалось освободить ${live_lib} — остаюсь на ${VERSION}"
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
        log_info "Проверка обновлений отключена (--no-update)"
        return 1
    fi

    local remote_version=""
    if [ -n "$UPDATE_CHECK_PID" ]; then
        wait "$UPDATE_CHECK_PID" 2>/dev/null
        UPDATE_CHECK_PID=""
        remote_version="$(tr -d '[:space:]' < "$UPDATE_CHECK_FILE" 2>/dev/null)"
        rm -f "$UPDATE_CHECK_FILE"
    fi

    if [ -z "$remote_version" ]; then
        log_warn "Не удалось проверить обновления (нет сети или файла VERSION в репо)"
        return 0
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
        log_info "В репозитории ${remote_version}, у вас ${VERSION} — обновляться некуда"
        return 1
    fi

    log_info "Доступна новая версия: ${BOLD}${remote_version}${NC} ${DIM}(у вас ${VERSION})${NC}"
    if ask_yn "Обновить usfc до ${remote_version} сейчас?"; then
        if install_update "$remote_version"; then
            log_success "Обновлено до ${remote_version}, перезапускаю..."
            exec "$SCRIPT_PATH"
        fi
    fi
    return 0
}
