# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# STATUS-функции — только читают состояние, ничего не меняют
# ═══════════════════════════════════════════════════════════════
# не-root пользователи в группе sudo → REPLY_SUDOERS (через запятую)
REPLY_SUDOERS=''
# ── Пункт меню: Пользователь + sudo ─────────────────────────────────────────
usfc_item newuser система "Пользователь + sudo" \
    "создаёт обычного юзера с sudo на голой VPS" \
    "User + sudo" \
    "creates a normal sudo user on a bare VPS"

usfc_item_full newuser "Нужен, когда хостер выдал сервер с одним лишь root. Работать из-под root
не стоит: SSH hardening без отдельного пользователя не работает в принципе,
а всё, что кладётся в домашний каталог (алиасы, fastfetch, tmux, starship),
осядет в /root и исчезнет, как только ты перезайдёшь под нормальным аккаунтом.

Спрашивает имя и пароль (скрытым вводом, с повтором), добавляет в группу sudo
и — самое важное — копирует ключи из /root/.ssh/authorized_keys. Без этого
новый пользователь не сможет войти вообще, а после SSH hardening доступ
к серверу будет потерян. Дальше вся настройка переключается на него прямо
в работающей сессии." \
"Needed when the host handed you a server with nothing but root. Working as
root is a bad idea: SSH hardening does not work at all without a separate
user, and everything that goes into a home directory (aliases, fastfetch,
tmux, starship) would land in /root and disappear the moment you log in
as a normal account.

It asks for a name and a password (hidden input, typed twice), adds the user
to the sudo group and — most importantly — copies the keys from
/root/.ssh/authorized_keys. Without that the new user cannot log in at all,
and after SSH hardening you would lose access to the server. From then on the
whole setup continues as that user, inside the running session."


usfc_item_rollback newuser "sudo deluser --remove-home <имя>          # удалить пользователя вместе с /home
     sudo gpasswd -d <имя> sudo               # или просто отобрать sudo, оставив аккаунт
     # СНАЧАЛА убедись, что остаётся хоть один способ попасть на сервер (root по ключу
     # или другой sudo-пользователь) — иначе закроешь себе доступ насовсем" \
"sudo deluser --remove-home <имя>          # delete the user together with /home
     sudo gpasswd -d <имя> sudo               # or just take sudo away, keeping the account
     # FIRST make sure at least one way into the server remains (root by key
     # or another sudo user) — otherwise you lock yourself out for good"

list_sudo_users() {
    local members u
    members="$(getent group sudo 2>/dev/null | cut -d: -f4)"
    REPLY_SUDOERS=''
    IFS=',' read -ra members <<< "$members"
    for u in "${members[@]}"; do
        [ -z "$u" ] && continue
        [ "$u" = "root" ] && continue
        REPLY_SUDOERS="${REPLY_SUDOERS}${REPLY_SUDOERS:+, }${u}"
    done
}

status_newuser() {
    if [ "$TARGET_USER" != "root" ]; then
        st "$GREEN" "✓ работаем от ${TARGET_USER}" "✓ running as ${TARGET_USER}"; return 0
    fi
    list_sudo_users
    if [ -n "$REPLY_SUDOERS" ]; then
        st "$YELLOW" "! есть: ${REPLY_SUDOERS}, но вы под root" "! exists: ${REPLY_SUDOERS}, but you are root"; return 1
    fi
    st "$DIM" "○ только root" "○ root only"; return 1
}

apply_newuser() {
    if [ "$BULK_MODE" = true ]; then
        log_warn_t "Создание пользователя требует ввода имени и пароля — пропущено в пакетном режиме." \
"Creating a user needs a name and a password — skipped in batch mode."
        log_warn_t "Настройте отдельно пунктом $(item_number newuser)." \
"Set it up separately via item $(item_number newuser)."
        return
    fi
    if [ "$TARGET_USER" != "root" ]; then
        log_info_t "Скрипт уже работает от имени ${TARGET_USER} — отдельный пользователь не нужен" \
"The script already runs as ${TARGET_USER} — a separate user is not needed"
        if ! ask_yn_t "Всё равно создать ещё одного пользователя с sudo?" "Create another sudo user anyway?" N; then return; fi
    fi

    # на совсем минимальных образах sudo может отсутствовать — без него
    # «добавить в группу sudo» превратилось бы в бессмысленный жест
    if ! command -v sudo &>/dev/null || ! getent group sudo &>/dev/null; then
        log_info_t "sudo не установлен — ставлю (без него группа sudo ничего не даёт)" \
"sudo is not installed — installing it (the sudo group is useless without it)"
        ensure_pkg "sudo" sudo || return 1
    fi

    # ── имя ───────────────────────────────────────────────────────────────────
    local name="" attempt=0 existing=false
    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        t "Имя нового пользователя" "New user name"; local _p="$REPLY_T"
        t "(латиница, начиная с буквы):" "(letters/digits, starting with a letter):"
        echo -en "  ${BOLD}${_p}${NC} ${DIM}${REPLY_T}${NC} "
        read -r name </dev/tty
        if [ -z "$name" ]; then
            log_error_t "Пустое имя" \
"Empty name"; name=""; continue
        fi
        if [[ ! "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            log_error_t "Недопустимое имя «${name}» — только строчные латинские буквы, цифры, _ и -, начиная с буквы" \
"Invalid name ${name} — lowercase letters, digits, _ and - only, starting with a letter"
            name=""; continue
        fi
        if id -u "$name" &>/dev/null; then
            log_warn_t "Пользователь ${name} уже существует" \
"User ${name} already exists"
            if ask_yn_t "Использовать его и просто добавить в группу sudo?" "Use that account and just add it to the sudo group?" N; then
                existing=true
                break
            fi
            name=""; continue
        fi
        break
    done
    if [ -z "$name" ]; then
        log_error_t "Имя так и не задано — пользователь не создан" \
"No name was given — no user created"
        return 1
    fi

    # ── ключи из /root: без них новый пользователь просто не сможет зайти ─────
    # решаем это ДО пароля: пустой пароль допустим, только если ключ реально есть
    local key_ok=false
    if [ "$existing" = false ]; then
        useradd -m -s /bin/bash "$name" || { log_error_t "Не удалось создать пользователя" \
"Could not create the user"; return 1; }
        log_success_t "Пользователь ${name} создан" \
"User ${name} created"
    fi

    ensure_ssh_dir "$name" "$(getent passwd "$name" | cut -d: -f6)" || {
        log_error_t "Не удалось подготовить ~/.ssh для ${name}" \
"Could not prepare ~/.ssh for ${name}"; return 1; }
    local auth_keys="$REPLY_AUTHKEYS"
    [ -s "$auth_keys" ] && key_ok=true

    # Один и тот же шаблон и для счёта, и для копирования: иначе легко получить
    # «найдено 0» с одновременным предложением их скопировать
    local key_re='^(ssh-|ecdsa-|sk-)'
    local root_keys="/root/.ssh/authorized_keys" n_keys=0 line
    if [ -f "$root_keys" ]; then
        while IFS= read -r line; do
            [[ "$line" =~ $key_re ]] && n_keys=$((n_keys + 1))
        done < "$root_keys"
    fi
    # Условие именно на счётчике, а не на размере файла: файл из одной пустой
    # строки или комментария непустой, но копировать в нём нечего — а раньше
    # мы всё равно предлагали это сделать и пугали потерей доступа
    if [ "$n_keys" -gt 0 ]; then
        log_info_t "В /root/.ssh/authorized_keys найдено ключей: ${n_keys}" \
"Keys found in /root/.ssh/authorized_keys: ${n_keys}"
        log_warn_t "Если ты заходишь на сервер по ключу — без копирования ${name} не сможет войти вообще" \
"If you reach this server by key, ${name} will not be able to log in at all without copying them"
        if ask_yn_t "Скопировать эти ключи для ${name}?" "Copy these keys for ${name}?" Y; then
            local copied=0
            while IFS= read -r line; do
                [[ "$line" =~ $key_re ]] || continue
                grep -qxF "$line" "$auth_keys" 2>/dev/null && continue
                echo "$line" | append_file "$auth_keys"
                copied=$((copied + 1))
            done < "$root_keys"
            log_success_t "Скопировано ключей: ${copied}" \
"Keys copied: ${copied}"
            [ -s "$auth_keys" ] && key_ok=true
        fi
    elif [ -f "$root_keys" ]; then
        log_info_t "В /root/.ssh/authorized_keys ключей нет — копировать нечего" \
"There are no keys in /root/.ssh/authorized_keys — nothing to copy"
    fi
    if ask_yn_t "Добавить ещё один публичный ключ вручную?" "Add another public key by hand?" N; then
        add_pubkey_interactive "$auth_keys" && key_ok=true
    fi
    # права могли уехать после дозаписи от root
    local gid; gid="$(id -g "$name" 2>/dev/null || echo "$name")"
    chown "${name}:${gid}" "$auth_keys" 2>/dev/null
    chmod 600 "$auth_keys" 2>/dev/null

    # ── пароль ────────────────────────────────────────────────────────────────
    local pw1 pw2 pw_set=false
    attempt=0
    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        t "Пароль для ${name}" "Password for ${name}"; local _p="$REPLY_T"
        t "(Enter — без пароля, вход только по ключу):" "(Enter for none — key-only login):"
        echo -en "  ${BOLD}${_p}${NC} ${DIM}${REPLY_T}${NC} "
        read -rs pw1 </dev/tty; echo ""
        if [ -z "$pw1" ]; then
            if [ "$key_ok" = true ]; then
                passwd -l "$name" >/dev/null 2>&1
                log_success_t "Пароль не задан и заблокирован — вход только по SSH-ключу" \
"No password set, and it is locked — SSH key login only"
                pw_set=true
                break
            fi
            log_error_t "Ни пароля, ни ключей — так пользователь не сможет войти вообще. Задай пароль." \
"Neither a password nor keys — the user could not log in at all. Set a password."
            continue
        fi
        t "Повтори пароль:" "Repeat the password:"
        echo -en "  ${BOLD}${REPLY_T}${NC} "
        read -rs pw2 </dev/tty; echo ""
        if [ "$pw1" != "$pw2" ]; then
            log_error_t "Пароли не совпали" \
"Passwords did not match"
            continue
        fi
        # Раньше здесь было предупреждение и проход дальше — то есть слабый
        # пароль всё равно ставился. Для сервера, смотрящего в интернет, это
        # не предупреждение, а отказ: перебор идёт круглосуточно.
        if [ "${#pw1}" -lt 8 ]; then
            log_error_t "Пароль короче 8 символов — слишком слабо для сервера" \
"Shorter than 8 characters — too weak for a server"
            [ "$key_ok" = true ] && \
                log_info_t "Ключ уже добавлен — можно нажать Enter и обойтись без пароля вовсе" \
"A key is already in place — press Enter to skip the password entirely"
            continue
        fi
        if printf '%s:%s\n' "$name" "$pw1" | chpasswd; then
            log_success_t "Пароль установлен" \
"Password set"
            pw_set=true
        else
            log_error_t "Не удалось установить пароль" \
"Could not set the password"
        fi
        break
    done
    unset pw1 pw2
    if [ "$pw_set" = false ]; then
        if [ "$key_ok" = false ]; then
            log_error_t "У ${name} нет ни пароля, ни ключа — зайти под ним будет невозможно" \
"${name} has neither a password nor a key — logging in as them will be impossible"
            log_warn_t "Задай пароль вручную: sudo passwd ${name}" \
"Set a password by hand: sudo passwd ${name}"
        else
            # попытки кончились, но ключ есть — молчать нельзя, иначе непонятно,
            # с чем в итоге остался пользователь
            passwd -l "$name" >/dev/null 2>&1
            log_warn_t "Пароль так и не задан — вход только по SSH-ключу" \
"No password was set — SSH key login only"
            log_info_t "Задать позже: sudo passwd ${name}" \
"Set one later: sudo passwd ${name}"
        fi
    fi

    # ── sudo ──────────────────────────────────────────────────────────────────
    if usermod -aG sudo "$name"; then
        log_success_t "Пользователь ${name} добавлен в группу sudo" \
"User ${name} added to the sudo group"
    else
        log_error_t "Не удалось добавить ${name} в группу sudo" \
"Could not add ${name} to the sudo group"
        return 1
    fi

    invalidate_statuses
    switch_target_user "$name"
    print_relogin_hint
}
