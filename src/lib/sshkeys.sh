# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# authkeys_add <файл> <строка> — дописать ключ отдельной строкой. Если файл
# кончается без перевода строки (правили руками), новый ключ приклеился бы
# к последнему, и оба перестали бы работать
authkeys_add() {
    local f="$1" line="$2"
    if [ -s "$f" ] && [ -n "$(tail -c1 "$f" 2>/dev/null)" ]; then
        printf '\n%s\n' "$line" | append_file "$f"
    else
        printf '%s\n' "$line" | append_file "$f"
    fi
}

# authkeys_count <файл> → REPLY_AUTHKEYS_COUNT — сколько в нём ключей. Ключи
# бывают и с опциями впереди (`restrict ssh-ed25519 …`), поэтому тип ключа
# ищем в любом поле, а не только в начале строки; комментарии не считаются
REPLY_AUTHKEYS_COUNT=0
authkeys_count() {
    REPLY_AUTHKEYS_COUNT="$(grep -vE '^[[:space:]]*#' "$1" 2>/dev/null \
        | grep -cE '(^|[[:space:]])(ssh-(ed25519|rsa|dss)|ecdsa-sha2-[a-z0-9]+|sk-(ssh|ecdsa)-[^[:space:]]+)[[:space:]]+[A-Za-z0-9+/]')"
    [[ "$REPLY_AUTHKEYS_COUNT" =~ ^[0-9]+$ ]] || REPLY_AUTHKEYS_COUNT=0
}

# ── sudo без пароля ──────────────────────────────────────────────────────────
# Пользователь «только по ключу» с заблокированным паролем в группе sudo
# не может sudo вовсе: правило %sudo требует пароль. Раньше NOPASSWD
# ставился только в SSH hardening и только после его успеха — пункт
# «новый пользователь» сам по себе оставлял сервер без рабочего админа.
SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"

# sudo_nopasswd_file <пользователь> → REPLY_SUDOERS. Точку в имени файла
# sudo молча пропускает (как и ~ в конце), поэтому она заменяется
REPLY_SUDOERS=''
sudo_nopasswd_file() { REPLY_SUDOERS="${SUDOERS_DIR}/90-usfc-${1//./_}"; }

# sudo_nopasswd_set <пользователь> — уже настроено (наш файл или файл до 5.0)
sudo_nopasswd_set() {
    sudo_nopasswd_file "$1"
    [ -f "$REPLY_SUDOERS" ] || [ -f "${SUDOERS_DIR}/$1" ]
}

# sudo_nopasswd <пользователь> — записать drop-in, проверив его visudo
sudo_nopasswd() {
    local user="$1" tmp
    if sudo_nopasswd_set "$user"; then
        log_info_t "sudo без пароля для ${user} уже настроен" \
"Passwordless sudo for ${user} is already set up"
        return 0
    fi
    sudo_nopasswd_file "$user"
    tmp="$(mktemp)" || return 1
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" > "$tmp"
    if ! visudo -cf "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        log_error_t "visudo отверг правило для ${user} — sudoers не трогаю" \
"visudo rejected the rule for ${user} — leaving sudoers alone"
        return 1
    fi
    write_file "$REPLY_SUDOERS" < "$tmp"; rm -f "$tmp"
    chmod 440 "$REPLY_SUDOERS"
    log_success_t "sudo без пароля для ${user}: ${REPLY_SUDOERS}" \
"Passwordless sudo for ${user}: ${REPLY_SUDOERS}"
}

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
    t "Вставь публичный ключ одной строкой" "Paste the public key on one line"
    ui_prompt "$REPLY_T"
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
    if grep -qxF -- "$pubkey_line" "$auth_keys" 2>/dev/null; then
        log_info_t "Такой ключ уже есть" \
"That key is already there"
        return 0
    fi
    authkeys_add "$auth_keys" "$pubkey_line"
    log_success_t "Ключ добавлен" \
"Key added"
    return 0
}
