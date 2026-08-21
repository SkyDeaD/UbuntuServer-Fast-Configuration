# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: SSH hardening ─────────────────────────────────────────
usfc_item sshhardening защита "SSH hardening" \
    "вход только по ключу, root-логин закрыт" \
    "SSH hardening" \
    "key-only login, root login disabled"

usfc_item_full sshhardening "Переводит вход только на ключ: выключает пароль и запрещает root-логин.

Самый рискованный пункт меню, поэтому единственный с самопроверкой. Перед тем
как выключить пароль, скрипт заводит одноразовый ключ и реально проверяет вход
по нему. Если проверка не прошла — автоматически откатывает конфиг и оставляет
пароль включённым. Текущая сессия при этом не разрывается.

Требует отдельного пользователя (пункт 1) — из-под root не работает." \
"Switches login to keys only, disables password authentication and root login.
The riskiest item in the menu, and therefore the only one with a self-test:
before turning the password off, the script creates a one-time key and
actually logs in with it. If that check fails, it rolls the config back
automatically and leaves password login enabled. Your current session is
never interrupted.

Requires a separate user (item 1) — it does not work from root."


usfc_item_rollback sshhardening "sudo rm -f /etc/ssh/sshd_config.d/10-hardening.conf
     sudo systemctl restart ssh
     sudo rm -f /etc/sudoers.d/${TARGET_USER}
     # возвращает вход по паролю — убедись, что есть другой способ попасть на сервер" \
"sudo rm -f /etc/ssh/sshd_config.d/10-hardening.conf
     sudo systemctl restart ssh
     sudo rm -f /etc/sudoers.d/${TARGET_USER}
     # restores password login — make sure you have another way into the server"

status_sshhardening() {
    if [ ! -f /etc/ssh/sshd_config.d/10-hardening.conf ]; then
        # под прямым root пункт неприменим в принципе (нужен отдельный пользователь) —
        # честнее сказать это сразу, чем показывать «не применено» и молчать о причине
        if [ "$TARGET_USER" = "root" ]; then
            st "$DIM" "— нужен обычный пользователь" "— needs a normal user"; return 1
        fi
        st "$DIM" "○ не применено" "○ not applied"; return 1
    fi
    if [ "$SSHD_PASSWORDAUTH" = "no" ]; then
        st "$GREEN" "✓ применено (пароль выключен)" "✓ applied (password login off)"; return 0
    fi
    st "$YELLOW" "! конфиг есть, но passwordauthentication=${SSHD_PASSWORDAUTH:-?}" "! config present, but passwordauthentication=${SSHD_PASSWORDAUTH:-?}"; return 1
}

apply_sshhardening() {
    if [ "$TARGET_USER" = "root" ]; then
        log_warn_t "Скрипт запущен напрямую под root — hardening требует отдельного пользователя" \
"Running directly as root — hardening needs a separate user"
        log_warn_t "Создай его (adduser <имя> && usermod -aG sudo <имя>) и перезайди под ним" \
"Create one (adduser <name> && usermod -aG sudo <name>) and log back in as them"
        return
    fi
    if [ "$BULK_MODE" = true ]; then
        log_warn_t "SSH hardening требует явного подтверждения — пропущено в пакетном режиме. Настройте отдельно пунктом $(item_number sshhardening)." \
"SSH hardening needs explicit confirmation — skipped in batch mode. Set it up separately via item $(item_number sshhardening)."
        return
    fi
    if ! ask_yn_t "Настроить SSH hardening для ${TARGET_USER} (ключи вместо пароля, запрет root-логина)?" "Set up SSH hardening for ${TARGET_USER} (keys instead of password, root login disabled)?" N; then return; fi

    # Сухой прогон здесь заканчивается описанием, а не имитацией. Пункт держится
    # на самопроверке: он заводит временный ключ, кладёт его в authorized_keys
    # и реально ходит по ssh на localhost. С заглушенным ssh-keygen проверка
    # провалилась бы и сообщила «вход по ключу не проходит даже сейчас» —
    # то есть соврала бы про исправную машину. Пугать таким в режиме, который
    # обещает ничего не менять, нельзя.
    if [ "$USFC_DRY_RUN" = true ]; then
        t "ssh-keygen: временный ключ для самопроверки входа" \
          "ssh-keygen: a temporary key for the login self-check"; _dry_say "$REPLY_T"
        t "запись /etc/ssh/sshd_config.d/10-hardening.conf" \
          "writing /etc/ssh/sshd_config.d/10-hardening.conf"; _dry_say "$REPLY_T"
        t "копия /etc/ssh/sshd_config рядом, с меткой времени" \
          "a timestamped copy of /etc/ssh/sshd_config next to it"; _dry_say "$REPLY_T"
        t "systemctl reload ssh и повторная самопроверка входа по ключу" \
          "systemctl reload ssh and a second key-login self-check"; _dry_say "$REPLY_T"
        log_info_t "Самопроверку входа в сухом прогоне не делаю: она требует настоящего ssh на localhost" \
"Not running the login self-check in a dry run: it needs a real ssh to localhost"
        return 0
    fi

    ensure_ssh_dir "$TARGET_USER" "$TARGET_HOME" || { log_error_t "Не удалось подготовить ~/.ssh" \
"Could not prepare ~/.ssh"; return 1; }
    local AUTH_KEYS="$REPLY_AUTHKEYS"

    if [ -s "$AUTH_KEYS" ]; then
        log_info_t "В authorized_keys уже есть $(grep -c '^ssh-\|^ecdsa-\|^sk-' "$AUTH_KEYS" 2>/dev/null || echo 0) ключ(ей)" \
               "authorized_keys already holds $(grep -c '^ssh-\|^ecdsa-\|^sk-' "$AUTH_KEYS" 2>/dev/null || echo 0) key(s)"
    else
        log_info_t "authorized_keys пока пуст" \
"authorized_keys is empty so far"
    fi

    if ask_yn_t "Добавить новый публичный ключ (вставить содержимое .pub со своей машины)?" "Add a new public key (paste the contents of your .pub file)?"; then
        add_pubkey_interactive "$AUTH_KEYS"
    fi

    if [ ! -s "$AUTH_KEYS" ]; then
        log_error_t "authorized_keys пуст — отключать пароль нельзя. Hardening прерван." \
"authorized_keys is empty — disabling the password is not safe. Hardening aborted."
        return 1
    fi

    if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
        log_info_t "Найден 50-cloud-init.conf — наш 10-hardening.conf побеждает при слиянии (10 < 50)" \
"Found 50-cloud-init.conf — our 10-hardening.conf wins on merge (10 < 50)"
    fi

    local TEST_KEY="/tmp/vps-setup-selftest-$$"
    ssh-keygen -t ed25519 -N '' -f "$TEST_KEY" -C "vps-setup-selftest" -q
    local TEST_PUB
    TEST_PUB="$(cat "${TEST_KEY}.pub")"
    echo "$TEST_PUB" | append_file "$AUTH_KEYS"

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

    log_info_t "Проверяю базовый вход по ключу (до изменений конфига)..." \
"Checking that key login works at all (before touching the config)..."
    if ! ssh_selftest; then
        log_error_t "Вход по ключу не проходит даже сейчас — hardening не запускаю" \
"Key login does not work even now — not starting hardening"
        cleanup_test_key
        return 1
    fi
    log_success_t "Базовый вход по ключу подтверждён" \
"Key login confirmed"
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
    write_file /etc/ssh/sshd_config.d/10-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers ${TARGET_USER}
EOF

    if ! sshd -t 2>/dev/null; then
        log_error_t "sshd -t не прошёл — откатываю" \
"sshd -t failed — rolling back"
        rm -f /etc/ssh/sshd_config.d/10-hardening.conf
        cleanup_test_key
        return 1
    fi

    systemctl restart ssh
    sleep 1
    log_info_t "Проверяю вход по ключу ПОСЛЕ применения hardening..." \
"Checking key login AFTER applying hardening..."
    if ssh_selftest; then
        # вход по ключу подтверждает только то, что ключевая аутентификация жива —
        # отдельно сверяем через sshd -T, что PasswordAuthentication реально no
        # (например, без "Include .../sshd_config.d/*.conf" в базовом sshd_config
        # наш дроп-ин просто не подхватился бы, а ключевой вход при этом всё равно работал)
        refresh_sshd_config
        local pa="$SSHD_PASSWORDAUTH"
        if [ "$pa" != "no" ]; then
            log_error_t "Вход по ключу работает, но sshd -T показывает passwordauthentication=${pa:-?} — конфиг не применился" \
"Key login works, but sshd -T reports passwordauthentication=${pa:-?} — the config did not take effect"
            log_error_t "Вероятная причина: в /etc/ssh/sshd_config нет 'Include /etc/ssh/sshd_config.d/*.conf'" \
"Likely cause: /etc/ssh/sshd_config has no 'Include /etc/ssh/sshd_config.d/*.conf'"
            log_warn_t "Дроп-ин не откатываю — он и так не действует, откат ничего не изменит" \
"Not rolling the drop-in back — it has no effect anyway, so rolling back changes nothing"
            cleanup_test_key
            return 1
        fi
        log_success_t "SSH hardening применён: root-логин выключен, пароль выключен" \
"SSH hardening applied: root login disabled, password login disabled"
        log_info_t "Текущая сессия не разрывалась — рестарт sshd не убивает открытые соединения" \
"Your current session was not dropped — restarting sshd does not kill open connections"
        cleanup_test_key
        if ask_yn_t "Настроить passwordless sudo для ${TARGET_USER}?" "Set up passwordless sudo for ${TARGET_USER}?"; then
            local SUDOERS_FILE="/etc/sudoers.d/${TARGET_USER}"
            if [ "$USFC_DRY_RUN" = true ]; then
                # visudo проверял бы несуществующий файл и сообщил про ошибку
                # синтаксиса — соврал бы там, где всё в порядке
                log_info_t "[сухой прогон] запись ${SUDOERS_FILE} с проверкой через visudo" \
"[dry run] write ${SUDOERS_FILE} and validate it with visudo"
                return 0
            fi
            echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > "${SUDOERS_FILE}.tmp"
            if visudo -c -f "${SUDOERS_FILE}.tmp" >/dev/null 2>&1; then
                mv "${SUDOERS_FILE}.tmp" "$SUDOERS_FILE"
                chmod 440 "$SUDOERS_FILE"
                log_success_t "Passwordless sudo настроен" \
"Passwordless sudo configured"
            else
                log_error_t "Синтаксическая ошибка в sudoers — не применяю" \
"Syntax error in sudoers — not applying it"
                rm -f "${SUDOERS_FILE}.tmp"
            fi
        fi
    else
        log_error_t "После рестарта sshd вход по ключу НЕ проходит — АВАРИЙНЫЙ ОТКАТ" \
"Key login does NOT work after restarting sshd — EMERGENCY ROLLBACK"
        rm -f /etc/ssh/sshd_config.d/10-hardening.conf
        systemctl restart ssh
        refresh_sshd_config
        cleanup_test_key
        log_error_t "Конфиг откачен. Текущая сессия жива — ничего не сломано." \
"Config rolled back. Your session is alive — nothing is broken."
        return 1
    fi
}
