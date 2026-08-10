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
        local tmp
        tmp="$(mktemp)"
        if curl -fsSL "${REPO_RAW_BASE}/setup.sh" -o "$tmp"; then
            if bash -n "$tmp" 2>/dev/null; then
                cp "$tmp" "$SCRIPT_PATH"
                chmod +x "$SCRIPT_PATH"
                rm -f "$tmp"
                printf '%s' "$remote_version" > "${SCRIPT_DIR}/VERSION"
                log_success "Обновлено до ${remote_version}, перезапускаю..."
                exec "$SCRIPT_PATH"
            else
                log_error "Новая версия не прошла проверку синтаксиса (bash -n) — не обновляю, остаюсь на ${VERSION}"
                rm -f "$tmp"
            fi
        else
            log_error "Не удалось скачать новую версию — остаюсь на ${VERSION}"
            rm -f "$tmp"
        fi
    fi
    return 0
}
