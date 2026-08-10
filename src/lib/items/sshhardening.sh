# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: SSH hardening ─────────────────────────────────────────
usfc_item sshhardening защита "SSH hardening" \
    "вход только по ключу, root-логин закрыт"

usfc_item_full sshhardening "Переводит вход только на ключ: выключает пароль и запрещает root-логин.

Самый рискованный пункт меню, поэтому единственный с самопроверкой. Перед тем
как выключить пароль, скрипт заводит одноразовый ключ и реально проверяет вход
по нему. Если проверка не прошла — автоматически откатывает конфиг и оставляет
пароль включённым. Текущая сессия при этом не разрывается.

Требует отдельного пользователя (пункт 1) — из-под root не работает."


usfc_item_rollback sshhardening "sudo rm -f /etc/ssh/sshd_config.d/10-hardening.conf
     sudo systemctl restart ssh
     sudo rm -f /etc/sudoers.d/${TARGET_USER}
     # возвращает вход по паролю — убедись, что есть другой способ попасть на сервер"

status_sshhardening() {
    if [ ! -f /etc/ssh/sshd_config.d/10-hardening.conf ]; then
        # под прямым root пункт неприменим в принципе (нужен отдельный пользователь) —
        # честнее сказать это сразу, чем показывать «не применено» и молчать о причине
        if [ "$TARGET_USER" = "root" ]; then
            echo -e "${DIM}— нужен обычный пользователь${NC}"; return 1
        fi
        echo -e "${DIM}○ не применено${NC}"; return 1
    fi
    if [ "$SSHD_PASSWORDAUTH" = "no" ]; then
        echo -e "${GREEN}✓ применено (пароль выключен)${NC}"; return 0
    fi
    echo -e "${YELLOW}! конфиг есть, но passwordauthentication=${SSHD_PASSWORDAUTH:-?}${NC}"; return 1
}

apply_sshhardening() {
    if [ "$TARGET_USER" = "root" ]; then
        log_warn "Скрипт запущен напрямую под root — hardening требует отдельного пользователя"
        log_warn "Создай его (adduser <имя> && usermod -aG sudo <имя>) и перезайди под ним"
        return
    fi
    if [ "$BULK_MODE" = true ]; then
        log_warn "SSH hardening требует явного подтверждения — пропущено в пакетном режиме. Настройте отдельно пунктом $(item_number sshhardening)."
        return
    fi
    if ! ask_yn "Настроить SSH hardening для ${TARGET_USER} (ключи вместо пароля, запрет root-логина)?" N; then return; fi

    ensure_ssh_dir "$TARGET_USER" "$TARGET_HOME" || { log_error "Не удалось подготовить ~/.ssh"; return 1; }
    local AUTH_KEYS="$REPLY_AUTHKEYS"

    if [ -s "$AUTH_KEYS" ]; then
        log_info "В authorized_keys уже есть $(grep -c '^ssh-\|^ecdsa-\|^sk-' "$AUTH_KEYS" 2>/dev/null || echo 0) ключ(ей)"
    else
        log_info "authorized_keys пока пуст"
    fi

    if ask_yn "Добавить новый публичный ключ (вставить содержимое .pub со своей машины)?"; then
        add_pubkey_interactive "$AUTH_KEYS"
    fi

    if [ ! -s "$AUTH_KEYS" ]; then
        log_error "authorized_keys пуст — отключать пароль нельзя. Hardening прерван."
        return 1
    fi

    if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
        log_info "Найден 50-cloud-init.conf — наш 10-hardening.conf побеждает при слиянии (10 < 50)"
    fi

    local TEST_KEY="/tmp/vps-setup-selftest-$$"
    ssh-keygen -t ed25519 -N '' -f "$TEST_KEY" -C "vps-setup-selftest" -q
    local TEST_PUB
    TEST_PUB="$(cat "${TEST_KEY}.pub")"
    echo "$TEST_PUB" >> "$AUTH_KEYS"

    ssh_selftest() {
        ssh -i "$TEST_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "$SSH_PORT" \
            "${TARGET_USER}@127.0.0.1" 'echo VPS_SETUP_KEY_OK' 2>/dev/null | grep VPS_SETUP_KEY_OK >/dev/null
    }
    cleanup_test_key() {
        grep -vF "$TEST_PUB" "$AUTH_KEYS" > "${AUTH_KEYS}.tmp" 2>/dev/null && mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
        chown "${TARGET_USER}:${TARGET_USER}" "$AUTH_KEYS"
        chmod 600 "$AUTH_KEYS"
        rm -f "$TEST_KEY" "${TEST_KEY}.pub"
    }

    log_info "Проверяю базовый вход по ключу (до изменений конфига)..."
    if ! ssh_selftest; then
        log_error "Вход по ключу не проходит даже сейчас — hardening не запускаю"
        cleanup_test_key
        return 1
    fi
    log_success "Базовый вход по ключу подтверждён"
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
    write_file /etc/ssh/sshd_config.d/10-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers ${TARGET_USER}
EOF

    if ! sshd -t 2>/dev/null; then
        log_error "sshd -t не прошёл — откатываю"
        rm -f /etc/ssh/sshd_config.d/10-hardening.conf
        cleanup_test_key
        return 1
    fi

    systemctl restart ssh
    sleep 1
    log_info "Проверяю вход по ключу ПОСЛЕ применения hardening..."
    if ssh_selftest; then
        # вход по ключу подтверждает только то, что ключевая аутентификация жива —
        # отдельно сверяем через sshd -T, что PasswordAuthentication реально no
        # (например, без "Include .../sshd_config.d/*.conf" в базовом sshd_config
        # наш дроп-ин просто не подхватился бы, а ключевой вход при этом всё равно работал)
        refresh_sshd_config
        local pa="$SSHD_PASSWORDAUTH"
        if [ "$pa" != "no" ]; then
            log_error "Вход по ключу работает, но sshd -T показывает passwordauthentication=${pa:-?} — конфиг не применился"
            log_error "Вероятная причина: в /etc/ssh/sshd_config нет 'Include /etc/ssh/sshd_config.d/*.conf'"
            log_warn "Дроп-ин не откатываю — он и так не действует, откат ничего не изменит"
            cleanup_test_key
            return 1
        fi
        log_success "SSH hardening применён: root-логин выключен, пароль выключен"
        log_info "Текущая сессия не разрывалась — рестарт sshd не убивает открытые соединения"
        cleanup_test_key
        if ask_yn "Настроить passwordless sudo для ${TARGET_USER}?"; then
            local SUDOERS_FILE="/etc/sudoers.d/${TARGET_USER}"
            echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > "${SUDOERS_FILE}.tmp"
            if visudo -c -f "${SUDOERS_FILE}.tmp" >/dev/null 2>&1; then
                mv "${SUDOERS_FILE}.tmp" "$SUDOERS_FILE"
                chmod 440 "$SUDOERS_FILE"
                log_success "Passwordless sudo настроен"
            else
                log_error "Синтаксическая ошибка в sudoers — не применяю"
                rm -f "${SUDOERS_FILE}.tmp"
            fi
        fi
    else
        log_error "После рестарта sshd вход по ключу НЕ проходит — АВАРИЙНЫЙ ОТКАТ"
        rm -f /etc/ssh/sshd_config.d/10-hardening.conf
        systemctl restart ssh
        refresh_sshd_config
        cleanup_test_key
        log_error "Конфиг откачен. Текущая сессия жива — ничего не сломано."
        return 1
    fi
}
