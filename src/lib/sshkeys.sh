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

# ensure_user_dir <путь внутри TARGET_HOME> — создать каталог так, чтобы КАЖДЫЙ
# уровень принадлежал пользователю.
#
# `install -d -o user …/.config/fastfetch` даёт владельца только последнему
# компоненту: промежуточный ~/.config создавался от root, и btop потом не мог
# завести ~/.config/btop («could not be created: Permission denied … config
# changes are not persistent»). Здесь каждый уровень создаётся отдельно, а
# уже существующий, но root-овый каталог внутри домашнего — машины, настроенные
# до 5.0, — возвращается пользователю. Рекурсивного chown нет: чинится ровно
# путь, который мы сами и испортили
ensure_user_dir() {
    local target="$1" gid cur part
    local -a parts
    case "$target" in
        "$TARGET_HOME"/*) ;;
        *) install -d -m 755 "$target"; return ;;
    esac
    gid="$(id -g "$TARGET_USER" 2>/dev/null)" || gid="$TARGET_USER"
    IFS='/' read -ra parts <<< "${target#"$TARGET_HOME"/}"
    cur="$TARGET_HOME"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        cur="${cur}/${part}"
        if [ ! -d "$cur" ]; then
            install -d -o "$TARGET_USER" -g "$gid" -m 755 "$cur" || return 1
        elif [ "$TARGET_USER" != root ] && [ "$(stat -c %u "$cur" 2>/dev/null)" = 0 ]; then
            chown "${TARGET_USER}:${gid}" "$cur"
        fi
    done
}

# просит вставить публичный ключ и дописывает его в authorized_keys.
# Возвращает 0, только если ключ реально добавлен (или уже был) — на это
# опирается apply_newuser, решая, можно ли оставить пользователя без пароля
add_pubkey_interactive() {
    local auth_keys="$1" pubkey_line
    t "Вставь публичный ключ одной строкой:" "Paste the public key on one line:"
    echo -en "  ${BOLD}${REPLY_T}${NC} "
    read -r pubkey_line </dev/tty
    if [ -z "$pubkey_line" ]; then
        log_info_t "Пусто — ключ не добавлен" \
"Empty — no key added"
        return 1
    fi
    if [[ ! "$pubkey_line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-|sk-ecdsa-) ]]; then
        log_error_t "Не похоже на публичный SSH-ключ — не добавляю" \
"Does not look like an SSH public key — not adding it"
        return 1
    fi
    if grep -qF "$pubkey_line" "$auth_keys" 2>/dev/null; then
        log_info_t "Такой ключ уже есть" \
"That key is already there"
        return 0
    fi
    echo "$pubkey_line" | append_file "$auth_keys"
    log_success_t "Ключ добавлен" \
"Key added"
    return 0
}
