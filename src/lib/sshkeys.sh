# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ── Общая работа с ~/.ssh ─────────────────────────────────────────────────────
# Специально без `sudo -u`: на голом root-образе (а это ровно наш сценарий, когда
# пользователя ещё не создали) sudo может быть не установлен вообще, и такие
# строки падали бы молча. install(1) умеет владельца и права сам, без подмены uid.
REPLY_AUTHKEYS=''

ensure_ssh_dir() {
    local user="$1" home="$2" dir="${2}/.ssh" gid
    gid="$(id -g "$user" 2>/dev/null)" || gid="$user"
    install -d -o "$user" -g "$gid" -m 700 "$dir" || return 1
    REPLY_AUTHKEYS="${dir}/authorized_keys"
    if [ -f "$REPLY_AUTHKEYS" ]; then
        chown "${user}:${gid}" "$REPLY_AUTHKEYS"
        chmod 600 "$REPLY_AUTHKEYS"
    else
        install -o "$user" -g "$gid" -m 600 /dev/null "$REPLY_AUTHKEYS" || return 1
    fi
}

# просит вставить публичный ключ и дописывает его в authorized_keys.
# Возвращает 0, только если ключ реально добавлен (или уже был) — на это
# опирается apply_newuser, решая, можно ли оставить пользователя без пароля
add_pubkey_interactive() {
    local auth_keys="$1" pubkey_line
    echo -en "  ${BOLD}Вставь публичный ключ одной строкой:${NC} "
    read -r pubkey_line </dev/tty
    if [ -z "$pubkey_line" ]; then
        log_info "Пусто — ключ не добавлен"
        return 1
    fi
    if [[ ! "$pubkey_line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-|sk-ecdsa-) ]]; then
        log_error "Не похоже на публичный SSH-ключ — не добавляю"
        return 1
    fi
    if grep -qF "$pubkey_line" "$auth_keys" 2>/dev/null; then
        log_info "Такой ключ уже есть"
        return 0
    fi
    echo "$pubkey_line" >> "$auth_keys"
    log_success "Ключ добавлен"
    return 0
}
