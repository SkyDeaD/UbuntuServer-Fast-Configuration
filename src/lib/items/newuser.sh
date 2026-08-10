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
    "создаёт обычного юзера с sudo на голой VPS"

usfc_item_full newuser "Нужен, когда хостер выдал сервер с одним лишь root. Работать из-под root
не стоит: SSH hardening без отдельного пользователя не работает в принципе,
а всё, что кладётся в домашний каталог (алиасы, fastfetch, tmux, starship),
осядет в /root и исчезнет, как только ты перезайдёшь под нормальным аккаунтом.

Спрашивает имя и пароль (скрытым вводом, с повтором), добавляет в группу sudo
и — самое важное — копирует ключи из /root/.ssh/authorized_keys. Без этого
новый пользователь не сможет войти вообще, а после SSH hardening доступ
к серверу будет потерян. Дальше вся настройка переключается на него прямо
в работающей сессии."


usfc_item_rollback newuser "sudo deluser --remove-home <имя>          # удалить пользователя вместе с /home
     sudo gpasswd -d <имя> sudo               # или просто отобрать sudo, оставив аккаунт
     # СНАЧАЛА убедись, что остаётся хоть один способ попасть на сервер (root по ключу
     # или другой sudo-пользователь) — иначе закроешь себе доступ насовсем"

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
        echo -e "${GREEN}✓ работаем от ${TARGET_USER}${NC}"; return 0
    fi
    list_sudo_users
    if [ -n "$REPLY_SUDOERS" ]; then
        echo -e "${YELLOW}! есть: ${REPLY_SUDOERS}, но вы под root${NC}"; return 1
    fi
    echo -e "${DIM}○ только root${NC}"; return 1
}

apply_newuser() {
    if [ "$BULK_MODE" = true ]; then
        log_warn "Создание пользователя требует ввода имени и пароля — пропущено в пакетном режиме."
        log_warn "Настройте отдельно пунктом $(item_number newuser)."
        return
    fi
    if [ "$TARGET_USER" != "root" ]; then
        log_info "Скрипт уже работает от имени ${TARGET_USER} — отдельный пользователь не нужен"
        if ! ask_yn "Всё равно создать ещё одного пользователя с sudo?" N; then return; fi
    fi

    # на совсем минимальных образах sudo может отсутствовать — без него
    # «добавить в группу sudo» превратилось бы в бессмысленный жест
    if ! command -v sudo &>/dev/null || ! getent group sudo &>/dev/null; then
        log_info "sudo не установлен — ставлю (без него группа sudo ничего не даёт)"
        ensure_pkg "sudo" sudo || return 1
    fi

    # ── имя ───────────────────────────────────────────────────────────────────
    local name="" attempt=0 existing=false
    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        echo -en "  ${BOLD}Имя нового пользователя${NC} ${DIM}(латиница, начиная с буквы):${NC} "
        read -r name </dev/tty
        if [ -z "$name" ]; then
            log_error "Пустое имя"; name=""; continue
        fi
        if [[ ! "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            log_error "Недопустимое имя «${name}» — только строчные латинские буквы, цифры, _ и -, начиная с буквы"
            name=""; continue
        fi
        if id -u "$name" &>/dev/null; then
            log_warn "Пользователь ${name} уже существует"
            if ask_yn "Использовать его и просто добавить в группу sudo?" N; then
                existing=true
                break
            fi
            name=""; continue
        fi
        break
    done
    if [ -z "$name" ]; then
        log_error "Имя так и не задано — пользователь не создан"
        return 1
    fi

    # ── ключи из /root: без них новый пользователь просто не сможет зайти ─────
    # решаем это ДО пароля: пустой пароль допустим, только если ключ реально есть
    local key_ok=false
    if [ "$existing" = false ]; then
        useradd -m -s /bin/bash "$name" || { log_error "Не удалось создать пользователя"; return 1; }
        log_success "Пользователь ${name} создан"
    fi

    ensure_ssh_dir "$name" "$(getent passwd "$name" | cut -d: -f6)" || {
        log_error "Не удалось подготовить ~/.ssh для ${name}"; return 1; }
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
        log_info "В /root/.ssh/authorized_keys найдено ключей: ${n_keys}"
        log_warn "Если ты заходишь на сервер по ключу — без копирования ${name} не сможет войти вообще"
        if ask_yn "Скопировать эти ключи для ${name}?" Y; then
            local copied=0
            while IFS= read -r line; do
                [[ "$line" =~ $key_re ]] || continue
                grep -qxF "$line" "$auth_keys" 2>/dev/null && continue
                echo "$line" >> "$auth_keys"
                copied=$((copied + 1))
            done < "$root_keys"
            log_success "Скопировано ключей: ${copied}"
            [ -s "$auth_keys" ] && key_ok=true
        fi
    elif [ -f "$root_keys" ]; then
        log_info "В /root/.ssh/authorized_keys ключей нет — копировать нечего"
    fi
    if ask_yn "Добавить ещё один публичный ключ вручную?" N; then
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
        echo -en "  ${BOLD}Пароль для ${name}${NC} ${DIM}(Enter — без пароля, вход только по ключу):${NC} "
        read -rs pw1 </dev/tty; echo ""
        if [ -z "$pw1" ]; then
            if [ "$key_ok" = true ]; then
                passwd -l "$name" >/dev/null 2>&1
                log_success "Пароль не задан и заблокирован — вход только по SSH-ключу"
                pw_set=true
                break
            fi
            log_error "Ни пароля, ни ключей — так пользователь не сможет войти вообще. Задай пароль."
            continue
        fi
        echo -en "  ${BOLD}Повтори пароль:${NC} "
        read -rs pw2 </dev/tty; echo ""
        if [ "$pw1" != "$pw2" ]; then
            log_error "Пароли не совпали"
            continue
        fi
        # Раньше здесь было предупреждение и проход дальше — то есть слабый
        # пароль всё равно ставился. Для сервера, смотрящего в интернет, это
        # не предупреждение, а отказ: перебор идёт круглосуточно.
        if [ "${#pw1}" -lt 8 ]; then
            log_error "Пароль короче 8 символов — слишком слабо для сервера"
            [ "$key_ok" = true ] && \
                log_info "Ключ уже добавлен — можно нажать Enter и обойтись без пароля вовсе"
            continue
        fi
        if printf '%s:%s\n' "$name" "$pw1" | chpasswd; then
            log_success "Пароль установлен"
            pw_set=true
        else
            log_error "Не удалось установить пароль"
        fi
        break
    done
    unset pw1 pw2
    if [ "$pw_set" = false ]; then
        if [ "$key_ok" = false ]; then
            log_error "У ${name} нет ни пароля, ни ключа — зайти под ним будет невозможно"
            log_warn "Задай пароль вручную: sudo passwd ${name}"
        else
            # попытки кончились, но ключ есть — молчать нельзя, иначе непонятно,
            # с чем в итоге остался пользователь
            passwd -l "$name" >/dev/null 2>&1
            log_warn "Пароль так и не задан — вход только по SSH-ключу"
            log_info "Задать позже: sudo passwd ${name}"
        fi
    fi

    # ── sudo ──────────────────────────────────────────────────────────────────
    if usermod -aG sudo "$name"; then
        log_success "Пользователь ${name} добавлен в группу sudo"
    else
        log_error "Не удалось добавить ${name} в группу sudo"
        return 1
    fi

    invalidate_statuses
    switch_target_user "$name"
    print_relogin_hint
}
