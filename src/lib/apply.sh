# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# APPLY-функции
# ═══════════════════════════════════════════════════════════════
# usfc-обёртка — не отдельный пункт меню, ставится сама при первом запуске,
# свой маркер, идемпотентно. Пропускаем для прямого root — sudo тут бесполезен
# (и может быть даже не установлен на такой машине); зато сразу после создания
# пользователя (switch_target_user) она ставится уже ему.
# Это bash-ФУНКЦИЯ, а не alias: после того как дочерний sudo-процесс меню
# завершится, функция сама делает "source ~/.bashrc" — но уже в ТЕКУЩЕЙ
# интерактивной оболочке (функции выполняются в вызывающем шелле, не в
# подпроцессе), так что новые алиасы/промпт подхватываются без ручного
# source и без переподключения. USFC_RESOURCE гейтит fastfetch-автозапуск
# (см. apply_fastfetch) — иначе баннер печатался бы второй раз при каждом
# выходе из меню.
install_usfc_wrapper() {
    [ "$TARGET_USER" = "root" ] && return 0
    local bashrc="${TARGET_HOME}/.bashrc" need_block=false
    if grep -qF "# >>> vps-setup:self >>>" "$bashrc" 2>/dev/null; then
        if grep -qF "alias usfc='sudo usfc'" "$bashrc" 2>/dev/null; then
            sed -i '/# >>> vps-setup:self >>>/,/# <<< vps-setup:self <<</d' "$bashrc"
            need_block=true
        fi
    else
        need_block=true
    fi
    [ "$need_block" = false ] && return 0
    cat >> "$bashrc" <<'EOF'

# >>> vps-setup:self >>>
usfc() {
    sudo /usr/local/bin/usfc "$@"
    USFC_RESOURCE=1 source ~/.bashrc 2>/dev/null
    unset USFC_RESOURCE
}
# <<< vps-setup:self <<<
EOF
    chown "${TARGET_USER}:$(id -g "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$bashrc" 2>/dev/null
}

# Совет перезайти под новым пользователем — печатается и сразу, и ещё раз при
# выходе из меню, чтобы не потерялся за выводом последующих установок
RELOGIN_HINT_USER=""
ROOT_PROMPT_SHOWN=false

# переключает весь дальнейший контекст скрипта на нового пользователя: всё, что
# ставится дальше (алиасы, fastfetch, tmux, starship), должно лечь ЕМУ, а не в
# /root, откуда оно исчезнет из виду сразу после перелогина
switch_target_user() {
    local user="$1" home
    home="$(getent passwd "$user" | cut -d: -f6)"
    if [ -z "$home" ] || [ ! -d "$home" ]; then
        log_error "Не удалось определить домашний каталог ${user} — контекст не переключаю"
        return 1
    fi
    TARGET_USER="$user"
    TARGET_HOME="$home"
    install_usfc_wrapper
    invalidate_statuses
    RELOGIN_HINT_USER="$user"
    log_info "Дальнейшие настройки применяются к ${BOLD}${user}${NC} ${DIM}(${home})${NC}"
}

print_relogin_hint() {
    [ -z "$RELOGIN_HINT_USER" ] && return 0
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo ""
    log_warn "Разлогинься и подключись уже под новым пользователем:"
    echo -e "      ${BOLD}ssh ${RELOGIN_HINT_USER}@${ip:-<ip-сервера>}${NC}"
    log_info "Дальше просто ${BOLD}usfc${NC} — sudo писать не нужно"
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

apply_cli() {
    local need_install=false p
    for p in $CLI_PKGS; do
        pkg_installed "$p" || need_install=true
    done
    command -v starship &>/dev/null || need_install=true

    if [ "$need_install" = true ]; then
        if ask_yn "Установить ${CLI_PKGS// /, }, starship?"; then
            ensure_apt_updated
            # shellcheck disable=SC2086
            snapshot_pkgs $CLI_PKGS
            # shellcheck disable=SC2086
            run_logged "CLI-утилиты (${CLI_PKGS// /, })" apt_get install -y $CLI_PKGS
            refresh_pkg_cache
            if ! command -v starship &>/dev/null; then
                run_logged "starship" bash -c 'curl -sS https://starship.rs/install.sh | sh -s -- -y'
            fi
            # shellcheck disable=SC2086
            show_pkg_report $CLI_PKGS
        fi
    else
        log_success "eza/bat/fd/ripgrep/zoxide/ncdu/starship уже установлены"
    fi

    # алиасы и промпт пишем сразу следом — не отдельным пунктом меню, но только если
    # утилиты реально стоят: если пользователь отказался ставить или apt не смог,
    # алиасы на несуществующие eza/batcat сломают ls/cat в следующей сессии
    if ! command -v eza &>/dev/null && ! command -v batcat &>/dev/null; then
        log_warn "eza/batcat не установлены — алиасы в .bashrc не пишу"
        return
    fi
    local BASHRC="${TARGET_HOME}/.bashrc"
    if grep -qF "# >>> vps-setup:cli >>>" "$BASHRC" 2>/dev/null; then
        log_info "Алиасы CLI-утилит в .bashrc уже есть"
    else
        cat >> "$BASHRC" <<EOF

# >>> vps-setup:cli >>>
alias ls='eza --icons --group-directories-first -1 --long --no-permissions --no-user --no-time'
alias ll='eza -lah --icons --group-directories-first'
alias la='eza -a --icons --group-directories-first -1 --long --no-permissions --no-user --no-time'
alias lt='eza --tree --icons --level=2 --group-directories-first'
alias cat='batcat --paging=never'
alias catp='batcat'
alias scat='sudo batcat --paging=never'
alias fd='fdfind'
command -v zoxide &>/dev/null && eval "\$(zoxide init bash)"
command -v starship &>/dev/null && eval "\$(starship init bash)"
# <<< vps-setup:cli <<<
EOF
        chown "${TARGET_USER}:${TARGET_USER}" "$BASHRC"
        log_success "Алиасы добавлены в .bashrc"
    fi
}

apply_basepkgs() {
    if ask_yn "Установить базовый набор пакетов (${BASE_PKGS})?"; then
        ensure_apt_updated
        # shellcheck disable=SC2086
        snapshot_pkgs $BASE_PKGS
        # shellcheck disable=SC2086
        run_logged "Базовый набор пакетов" apt_get install -y $BASE_PKGS
        refresh_pkg_cache
        # shellcheck disable=SC2086
        show_pkg_report $BASE_PKGS
    fi
}

apply_nginx() {
    if ! pkg_installed nginx-full; then
        if ! ask_yn "Установить nginx-full?"; then return; fi
        # спрашиваем ДО установки: ответ решает, дать ли postinst поднять сервис
        local autostart=false
        resolve_autostart NGINX_AUTOSTART "Запустить nginx и включить автозапуск?" && autostart=true
        ensure_apt_updated
        with_no_service_start run_logged "nginx-full" apt_get install -y nginx-full || return 1
        refresh_pkg_cache
        apply_service_autostart nginx "$autostart"
        return
    fi

    log_info "nginx-full уже установлен"
    local enabled active
    enabled="$(systemctl is-enabled nginx 2>/dev/null)"
    active="$(systemctl is-active nginx 2>/dev/null)"
    if [ "$active" = "active" ]; then
        log_success "nginx запущен ${DIM}(автозапуск: ${enabled:-?})${NC}"
        if [ "$enabled" != "enabled" ] && ask_yn "Включить автозапуск nginx при загрузке?" N; then
            systemctl enable nginx >/dev/null 2>&1 && log_success "Автозапуск включён"
        fi
    elif ask_yn "nginx не запущен. Запустить и включить автозапуск?" N; then
        apply_service_autostart nginx true
    else
        log_info "Оставляю nginx выключенным"
    fi
}

apply_certbot() {
    ensure_apt_updated
    if ! pkg_installed certbot; then
        if ! ask_yn "Установить certbot (Let's Encrypt)?"; then return; fi
        run_logged "certbot" apt_get install -y certbot || return 1
        refresh_pkg_cache
    else
        log_info "certbot уже установлен: $(certbot --version 2>&1 | head -n1)"
    fi

    # ── плагин nginx (HTTP-01) ────────────────────────────────────────────────
    if pkg_installed python3-certbot-nginx; then
        log_success "Плагин nginx уже установлен"
    elif ! pkg_installed nginx-full; then
        log_info "nginx не установлен — плагин nginx пропускаю (поставь nginx и вернись сюда)"
    elif ask_yn "Установить плагин nginx (HTTP-01, обычные сертификаты)?"; then
        run_logged "python3-certbot-nginx" apt_get install -y python3-certbot-nginx && refresh_pkg_cache
    fi

    # ── плагин Cloudflare (DNS-01) ────────────────────────────────────────────
    local want_cf=false install_cf=false
    if pkg_installed python3-certbot-dns-cloudflare; then
        want_cf=true
        log_success "Плагин Cloudflare уже установлен"
    else
        # В пакетном режиме ask_yn вернёт дефолт N и плагин молча не поставится —
        # поэтому согласие спрашивается заранее в main() и приезжает сюда готовым
        if [ "$BULK_MODE" = true ]; then
            [ "$CERTBOT_CF_BULK" = "Y" ] && install_cf=true
        elif ask_yn "Установить плагин Cloudflare (DNS-01, нужен для wildcard-сертификатов)?" N; then
            install_cf=true
        fi
    fi
    if [ "$install_cf" = true ]; then
        if run_logged "python3-certbot-dns-cloudflare" apt_get install -y python3-certbot-dns-cloudflare; then
            refresh_pkg_cache
            want_cf=true
            # apt тянет python3-cloudflare 2.20.x — единственную версию в архиве.
            # Она печатает большой WARNING про «апгрейд без пиннинга»: срабатывает
            # в конструкторе клиента (CloudFlare/cloudflare.py), то есть при
            # РЕАЛЬНОМ выпуске сертификата, а не при установке. Заглушить нельзя —
            # warn_warning_2_20() сам делает simplefilter('always'), перебивая
            # PYTHONWARNINGS и -W ignore. К apt-установке претензия не относится:
            # версия закреплена зависимостью пакета (<< 3.0), это не pip-апгрейд.
            # Предупреждаем заранее, чтобы баннер не выглядел поломкой.
            if dpkg-query -W -f='${Version}' python3-cloudflare 2>/dev/null | grep '^2\.20' >/dev/null; then
                log_warn "При выпуске сертификата certbot напечатает большой WARNING про"
                log_warn "python-cloudflare 2.20. Это безвредно и не отключается: версия"
                log_warn "закреплена пакетом (<< 3.0), на выпуск сертификатов не влияет."
            fi
        fi
    fi

    [ "$want_cf" = true ] && apply_cloudflare_credentials
    apply_certbot_tls_assets
}

# Токен Cloudflare. Кладём в /root: certbot всегда запускается от root, а при более
# открытых правах он сам ругается на небезопасный credentials-файл
apply_cloudflare_credentials() {
    local token=""

    # Токен, введённый заранее в предзапросе пакетного режима. Спрашивать его
    # здесь нельзя: в BULK_MODE вопросов не задают, и файл остался бы несозданным
    if [ -n "$CF_TOKEN_BULK" ]; then
        token="$CF_TOKEN_BULK"
        CF_TOKEN_BULK=""
        cf_write_credentials "$token"
        return
    fi

    if [ -s "$CF_CREDENTIALS" ]; then
        log_success "Credentials-файл уже есть: ${CF_CREDENTIALS}"
        # Права проверяем и чиним ЗДЕСЬ. Сами мы кладём файл с 600, но он мог
        # приехать не от нас: создан руками по подсказке ниже, восстановлен из
        # бэкапа, скопирован. Раньше эта ветка молча рапортовала успех, и файл
        # с чужими правами так и жил с зелёной галочкой в меню
        if cf_creds_world_readable; then
            log_warn "Права ${CF_CREDENTIALS}: ${REPLY_CF_MODE} — токен читает кто угодно"
            if ask_yn "Починить права на 600 (root:root)?" Y; then
                chmod 600 "$CF_CREDENTIALS" && chown root:root "$CF_CREDENTIALS" \
                    && log_success "Права исправлены: $(stat -c %a "$CF_CREDENTIALS" 2>/dev/null), root:root"
            else
                log_info "Оставляю как есть — certbot будет писать «Unsafe permissions» в лог"
            fi
        fi
        if ! ask_yn "Перезаписать его новым токеном?" N; then return; fi
    elif ! ask_yn "Создать ${CF_CREDENTIALS} с API-токеном Cloudflare?" N; then
        log_warn "Без токена плагин Cloudflare работать НЕ будет — выпуск сертификатов упадёт"
        log_warn "В меню этот пункт так и будет показывать «токен CF не задан»"
        log_info "Создать вручную (права Zone:DNS:Edit):"
        echo -e "      ${DIM}mkdir -p $(dirname "$CF_CREDENTIALS") && chmod 700 $(dirname "$CF_CREDENTIALS")${NC}"
        echo -e "      ${DIM}echo 'dns_cloudflare_api_token = ТОКЕН' > ${CF_CREDENTIALS}${NC}"
        echo -e "      ${DIM}chmod 600 ${CF_CREDENTIALS}${NC}"
        cf_wildcard_hint
        return
    fi

    ask_cf_token || return 1
    cf_write_credentials "$REPLY_CF_TOKEN"
    REPLY_CF_TOKEN=""
}

# Запрос токена скрытым вводом → REPLY_CF_TOKEN. Вынесен отдельно, потому что
# спрашивать его приходится из двух мест: обычного прогона и предзапроса перед
# пакетным режимом
REPLY_CF_TOKEN=""
ask_cf_token() {
    echo -en "  ${BOLD}API-токен Cloudflare${NC} ${DIM}(права Zone:DNS:Edit, ввод скрыт):${NC} "
    read -rs REPLY_CF_TOKEN </dev/tty; echo ""
    if [ -z "$REPLY_CF_TOKEN" ]; then
        log_error "Пустой токен — файл не создан"
        return 1
    fi
    return 0
}

cf_write_credentials() {
    local token="$1"
    [ -z "$token" ] && { log_error "Пустой токен — файл не создан"; return 1; }
    install -d -m 700 "$(dirname "$CF_CREDENTIALS")" || { log_error "Не удалось создать каталог"; return 1; }
    # Файл заводим ПУСТЫМ и сразу с нужными правами, а токен пишем уже в него.
    # Раньше здесь стоял `umask 077` перед перенаправлением: он, во-первых,
    # не восстанавливался и утекал на весь остаток прогона (все конфиги,
    # которые пункты 9-14 писали после certbot, получали 600 вместо 644),
    # во-вторых, оставлял окно между созданием файла и chmod.
    install -m 600 -o root -g root /dev/null "$CF_CREDENTIALS" || {
        log_error "Не удалось создать ${CF_CREDENTIALS}"; return 1; }
    printf 'dns_cloudflare_api_token = %s\n' "$token" > "$CF_CREDENTIALS" || {
        log_error "Не удалось записать ${CF_CREDENTIALS}"; return 1; }
    log_success "Credentials-файл создан: ${CF_CREDENTIALS} ($(stat -c %a "$CF_CREDENTIALS" 2>/dev/null), root:root)"
    cf_wildcard_hint
}

# Права на credentials-файл так, как их понимает сам certbot: он смотрит ТОЛЬКО
# биты «остальных» (filesystem.has_world_permissions) и на них лишь ругается
# в лог, не отказываясь выпускать сертификат. Поэтому проверяем ровно то же —
# иначе меню начнёт пугать там, где сам certbot молчит.
#
# Режим кладём в REPLY_CF_MODE, чтобы вызывающий не делал второй stat: функция
# дёргается из status_certbot, а это горячий путь отрисовки меню.
REPLY_CF_MODE=''
cf_creds_world_readable() {
    REPLY_CF_MODE=''
    [ -s "$CF_CREDENTIALS" ] || return 1
    REPLY_CF_MODE="$(stat -c %a "$CF_CREDENTIALS" 2>/dev/null)" || return 1
    [ -n "$REPLY_CF_MODE" ] || return 1
    [ $(( 8#${REPLY_CF_MODE: -1} & 7 )) -ne 0 ]
}

cf_wildcard_hint() {
    log_info "Выпуск wildcard-сертификата:"
    echo -e "      ${DIM}certbot certonly --dns-cloudflare \\\\${NC}"
    echo -e "      ${DIM}  --dns-cloudflare-credentials ${CF_CREDENTIALS} \\\\${NC}"
    echo -e "      ${DIM}  -d example.com -d \"*.example.com\"${NC}"
}

# ssl-dhparams.pem и options-ssl-nginx.conf создаёт только nginx-*installer* certbot'а.
# При выпуске wildcard через `certbot certonly` (а это ровно то, ради чего ставят
# DNS-01) их не появится — и типовой конфиг nginx, который на них ссылается, положит
# сервер при старте. Оба файла уже лежат внутри пакета certbot: генерировать
# dhparam через openssl не нужно, там та же стандартная группа ffdhe2048.
apply_certbot_tls_assets() {
    if ! pkg_installed nginx-full; then
        return
    fi
    local want=false name src dst
    for name in ssl-dhparams.pem options-ssl-nginx.conf; do
        [ -f "/etc/letsencrypt/${name}" ] || want=true
    done
    if [ "$want" = false ]; then
        log_success "TLS-заготовки в /etc/letsencrypt уже на месте"
        return
    fi
    if ! ask_yn "Положить TLS-заготовки certbot (ssl-dhparams.pem, options-ssl-nginx.conf) в /etc/letsencrypt?" N; then
        return
    fi

    install -d -m 755 /etc/letsencrypt
    for name in ssl-dhparams.pem options-ssl-nginx.conf; do
        dst="/etc/letsencrypt/${name}"
        if [ -f "$dst" ]; then
            log_info "${name} уже есть — не трогаю"
            continue
        fi
        # путь внутри пакета ищем в рантайме: он менялся между версиями certbot,
        # хардкодить его — напрашиваться на молчаливую поломку
        src="$(find /usr/lib/python3/dist-packages /usr/lib/python3*/site-packages \
                -name "$name" -type f 2>/dev/null | head -n1)"
        if [ -z "$src" ]; then
            log_warn "${name} не найден внутри пакетов certbot — пропускаю (не выдумываю содержимое)"
            continue
        fi
        if install -m 644 "$src" "$dst"; then
            log_success "${name} → ${dst}"
        else
            log_error "Не удалось скопировать ${name}"
        fi
    done
}

apply_docker() {
    # Ветка «уже установлен» — как у apply_nginx. Без неё выбор этого пункта на
    # системе с Docker уходил в полную переустановку: ключ, репозиторий, apt.
    # Условие то же, что у status_docker, иначе меню и действие разойдутся
    if command -v docker &>/dev/null; then
        log_info "Docker уже установлен: $(docker --version 2>/dev/null)"
        local enabled active
        active="$(systemctl is-active docker.service 2>/dev/null)"
        enabled="$(systemctl is-enabled docker.service 2>/dev/null)"
        if [ "$active" = "active" ]; then
            log_success "Docker запущен ${DIM}(автозапуск: ${enabled:-?})${NC}"
            if [ "$enabled" != "enabled" ] && ask_yn "Включить автозапуск Docker при загрузке?" N; then
                service_units docker
                systemctl enable "${REPLY_UNITS[@]}" >/dev/null 2>&1 && log_success "Автозапуск включён"
            fi
        elif ask_yn "Docker не запущен. Запустить и включить автозапуск?" N; then
            apply_service_autostart docker true
        else
            log_info "Оставляю Docker выключенным"
        fi
        # Docker мог приехать не отсюда (docker.io, ручная установка) — тогда
        # группы у пользователя нет, и sudo требуется на каждый docker-вызов
        if [ "$TARGET_USER" != "root" ] && ! id -nG "$TARGET_USER" 2>/dev/null | grep -w docker >/dev/null; then
            if ask_yn "Добавить ${TARGET_USER} в группу docker (работа без sudo)?" Y; then
                usermod -aG docker "$TARGET_USER"
                log_info "Готово — перелогинься, чтобы группа применилась"
            fi
        fi
        return 0
    fi

    if ! ask_yn "Установить Docker + Docker Compose (официальный репозиторий)?"; then return; fi
    # спрашиваем ДО установки — ответ решает, дать ли postinst поднять демон
    local autostart=false
    resolve_autostart DOCKER_AUTOSTART "Запустить Docker и включить автозапуск?" && autostart=true

    ensure_pkg "Зависимости Docker" ca-certificates curl || return 1
    install -m 0755 -d /etc/apt/keyrings
    run_logged "GPG-ключ Docker" \
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || return 1
    chmod a+r /etc/apt/keyrings/docker.asc
    local codename
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list
    run_logged "Списки пакетов Docker" apt_get update -qq
    # grep БЕЗ -q — иначе SIGPIPE и вечно ложное условие, см. блок про ловушку
    # в начале файла. Здесь это и вскрылось: фолбэк срабатывал на каждой машине
    if ! apt-cache policy docker-ce-cli 2>/dev/null | grep 'Candidate:.*[0-9]' >/dev/null; then
        # Падать на noble некуда: это и есть та версия, на которую переключаются.
        # Раньше сюда приезжали все подряд и читали «нет пакетов под 'noble' —
        # переключаюсь на noble»
        if [ "$codename" = "noble" ]; then
            log_error "Репозиторий Docker не отдал пакеты для noble — переключаться некуда"
            log_info "Проверь сеть и ${USFC_LOG}; вручную: ${BOLD}apt-cache policy docker-ce-cli${NC}"
            return 1
        fi
        log_warn "У Docker пока нет пакетов под '${codename}' — переключаюсь на noble (24.04, совместимо)"
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
            > /etc/apt/sources.list.d/docker.list
        run_logged "Списки пакетов Docker (noble)" apt_get update -qq
    fi
    with_no_service_start run_logged "Docker CE + Compose" \
        apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    refresh_pkg_cache

    apply_service_autostart docker "$autostart"

    # под прямым root группа docker бессмысленна: root и так может всё,
    # а usermod -aG docker root только путает вывод
    if [ "$TARGET_USER" != "root" ]; then
        usermod -aG docker "$TARGET_USER"
        log_info "Пользователь ${TARGET_USER} добавлен в группу docker — перелогинься для работы без sudo"
    else
        log_info "Работаем от root — в группу docker никого не добавляю"
    fi
    log_success "Docker установлен: $(docker --version 2>/dev/null)"
}

apply_fastfetch() {
    local need_ppa=true
    if command -v fastfetch &>/dev/null; then
        local v lowest
        v="$(fastfetch --version | grep -oP '\d+\.\d+\.\d+' | head -n1)"
        lowest="$(printf '%s\n%s\n' "$v" "2.64.0" | sort -V | head -n1)"
        [ "$lowest" = "2.64.0" ] && need_ppa=false
    fi
    if [ "$need_ppa" = true ]; then
        if ask_yn "Установить/обновить fastfetch (через PPA)?"; then
            ensure_apt_updated
            # -n (--no-update): add-apt-repository в конце сам дёргает apt update,
            # но опцию DPkg::Lock::Timeout ему не передать — значит он споткнётся
            # о ту же блокировку dpkg. Добавляем только репозиторий, а списки
            # обновляем своим apt_get, у которого таймаут уже есть.
            run_logged "PPA fastfetch" add-apt-repository -y -n ppa:zhangsongcui3371/fastfetch
            run_logged "Списки пакетов PPA" apt_get update -qq
            if run_logged "fastfetch" apt_get install -y fastfetch; then
                refresh_pkg_cache
                log_info "Версия: $(fastfetch --version 2>/dev/null)"
            fi
        fi
    else
        log_success "fastfetch уже подходящей версии"
    fi

    # конфиг и автозапуск в .bashrc пишем сразу следом — не отдельным пунктом меню
    if ! command -v fastfetch &>/dev/null; then return; fi

    install -d -o "$TARGET_USER" -g "$(id -g "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" \
        -m 755 "${TARGET_HOME}/.config/fastfetch"
    if [ -f "${TARGET_HOME}/.config/fastfetch/config.jsonc" ]; then
        log_info "config.jsonc уже есть"
    elif curl -fsSL "${REPO_RAW_BASE}/config.jsonc" -o "${TARGET_HOME}/.config/fastfetch/config.jsonc" 2>/dev/null; then
        chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.config/fastfetch/config.jsonc"
        log_success "config.jsonc установлен"
    else
        log_warn "Не удалось скачать config.jsonc из ${REPO_RAW_BASE}"
    fi

    local BASHRC="${TARGET_HOME}/.bashrc" need_fastfetch_block=false
    if grep -qF "# >>> vps-setup:fastfetch >>>" "$BASHRC" 2>/dev/null; then
        # старый блок (без гейта USFC_RESOURCE) печатал бы fastfetch второй раз
        # при каждом auto-source из usfc-обёртки (см. main()) — апгрейдим его
        if grep -qF "USFC_RESOURCE:-" "$BASHRC" 2>/dev/null; then
            log_info "Автозапуск fastfetch в .bashrc уже есть"
        else
            sed -i '/# >>> vps-setup:fastfetch >>>/,/# <<< vps-setup:fastfetch <<</d' "$BASHRC"
            need_fastfetch_block=true
        fi
    else
        need_fastfetch_block=true
    fi
    if [ "$need_fastfetch_block" = true ]; then
        cat >> "$BASHRC" <<'EOF'

# >>> vps-setup:fastfetch >>>
if [ -z "${USFC_RESOURCE:-}" ] && [ -x "$(command -v fastfetch)" ]; then
    fastfetch
fi
# <<< vps-setup:fastfetch <<<
EOF
        chown "${TARGET_USER}:${TARGET_USER}" "$BASHRC"
        log_success "Автозапуск добавлен в .bashrc"
    fi
}

apply_tmux() {
    if ! command -v tmux &>/dev/null; then
        if ask_yn "Установить tmux?"; then
            ensure_apt_updated
            run_logged "tmux" apt_get install -y tmux || return 1
            refresh_pkg_cache
        else
            return
        fi
    fi
    local TMUX_CONF="${TARGET_HOME}/.tmux.conf"
    if [ -f "$TMUX_CONF" ]; then
        log_info ".tmux.conf уже существует — не трогаю"
    elif ask_yn "Положить базовый .tmux.conf (мышь, история 10000, статус-бар)?"; then
        cat > "$TMUX_CONF" <<'EOF'
set -g mouse on
set -g history-limit 10000
set -g status-bg colour234
set -g status-fg colour250
set -g status-left '#[fg=colour39,bold]#S '
set -g status-right '%H:%M %d-%b-%y'
setw -g automatic-rename on
EOF
        chown "${TARGET_USER}:${TARGET_USER}" "$TMUX_CONF"
        log_success ".tmux.conf установлен"
    fi
}

apply_dockerlog() {
    if ! command -v docker &>/dev/null; then
        log_info "Docker не установлен — сначала установи Docker (пункт $(item_number docker))"
        return
    fi
    [ -f /etc/docker/daemon.json ] && log_warn "daemon.json уже существует, будет дополнен (не перезаписан целиком)"
    if ! ask_yn "Ограничить логи контейнеров (max-size=10m, max-file=3)?"; then return; fi
    mkdir -p /etc/docker
    python3 - /etc/docker/daemon.json <<'PYEOF'
import json, sys, os
path = sys.argv[1]
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
data["log-driver"] = "json-file"
data.setdefault("log-opts", {})
data["log-opts"]["max-size"] = "10m"
data["log-opts"]["max-file"] = "3"
json.dump(data, open(path, "w"), indent=2)
PYEOF
    log_success "daemon.json обновлён"
    if ask_yn "Перезапустить Docker сейчас? ВСЕ контейнеры перезапустятся вместе с демоном" N; then
        systemctl restart docker && log_success "Docker перезапущен"
    else
        log_info "Применится при следующем перезапуске Docker/сервера"
    fi
}

apply_fail2ban() {
    if ! ask_yn "Установить fail2ban?"; then return; fi
    ensure_pkg "fail2ban" fail2ban || return 1
    cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    systemctl enable --now fail2ban >/dev/null
    log_success "fail2ban установлен и настроен на порт ${SSH_PORT}"
}

apply_unattended() {
    if ! ask_yn "Включить автообновление security-патчей?"; then return; fi
    ensure_pkg "unattended-upgrades" unattended-upgrades || return 1
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    systemctl enable --now unattended-upgrades >/dev/null
    log_success "unattended-upgrades включён"
}

# suggest_swap_mb [место_которое_освободится_МБ] — рекомендуемый размер
# резервного swap-файла: min(RAM, свободно/4), зажатое в 512-4096 МБ.
#
# Почему так, а не «10% диска», как было раньше: своп здесь — резерв ПОД zram
# (приоритет 10 против 100), то есть его роль определяется объёмом памяти,
# а старая формула про RAM не знала вообще. Деление на 4 не даёт свопу съесть
# тесный диск, кламп снизу спасает совсем маленькие машины.
#
# Аргумент нужен при ПЕРЕсоздании: место под текущим swap-файлом освободится,
# и без этого слагаемого своп нельзя было бы увеличить даже когда диск позволяет.
suggest_swap_mb() {
    local extra_mb="${1:-0}" free_mb ram_mb suggested
    free_mb="$(df -m / 2>/dev/null | awk 'NR==2{print $4}')"
    [[ "$free_mb" =~ ^[0-9]+$ ]] || free_mb=0
    [[ "$extra_mb" =~ ^[0-9]+$ ]] || extra_mb=0
    free_mb=$(( free_mb + extra_mb ))

    ram_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    [[ "$ram_mb" =~ ^[0-9]+$ ]] || ram_mb=1024

    suggested=$(( free_mb / 4 ))
    [ "$ram_mb" -lt "$suggested" ] && suggested="$ram_mb"
    [ "$suggested" -lt 512 ] && suggested=512
    [ "$suggested" -gt 4096 ] && suggested=4096
    echo "$suggested"
}

# swap_needs_resize <текущий_МБ> <рекомендуемый_МБ> — расходятся ли больше
# чем на 10%. Ниже порога не пристаём: своп «примерно правильного» размера
# трогать незачем, а лишний вопрос на каждом заходе в пункт раздражает
swap_needs_resize() {
    local cur="${1:-0}" want="${2:-0}" diff
    [ "$want" -le 0 ] && return 1
    diff=$(( cur > want ? cur - want : want - cur ))
    [ $(( diff * 100 )) -gt $(( want * 10 )) ]
}

# читает текущее состояние zram/swap в глобальные переменные — общий
# парсинг для apply_zram() и предзапроса значений перед bulk-режимом в main()
# SWAP_TYPE/SWAP_SIZE_MB/SWAP_USED_MB нужны, чтобы решить, можно ли безопасно
# пересоздать своп: раздел трогать нельзя, а занятое должно влезть обратно в RAM
read_swap_state() {
    ZRAM_ACTIVE=false; ZRAM_PRIO=""
    SWAP_ACTIVE=false; SWAP_PRIO=""; SWAP_PATH=""
    SWAP_TYPE=""; SWAP_SIZE_MB=0; SWAP_USED_MB=0
    local n t s u p
    while read -r n t s u p; do
        case "$n" in
            /dev/zram*) ZRAM_ACTIVE=true; ZRAM_PRIO="$p" ;;
            *)
                SWAP_ACTIVE=true; SWAP_PRIO="$p"; SWAP_PATH="$n"; SWAP_TYPE="$t"
                SWAP_SIZE_MB="$(human_to_mb "$s")"
                SWAP_USED_MB="$(human_to_mb "$u")"
                ;;
        esac
    done < <(swapon --show --noheadings --raw 2>/dev/null)
}

# "1.9G" / "12.1M" / "512K" / "0B" → целые МБ. swapon --raw печатает именно так
human_to_mb() {
    local v="${1:-0}" num unit
    num="${v%[BKMGTbkmgt]}"
    unit="${v#"$num"}"
    [[ "$num" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo 0; return; }
    case "${unit^^}" in
        G) awk -v n="$num" 'BEGIN{printf "%d", n*1024}' ;;
        T) awk -v n="$num" 'BEGIN{printf "%d", n*1024*1024}' ;;
        M) awk -v n="$num" 'BEGIN{printf "%d", n}' ;;
        K) awk -v n="$num" 'BEGIN{printf "%d", n/1024}' ;;
        *) awk -v n="$num" 'BEGIN{printf "%d", n/1048576}' ;;
    esac
}

# create_swapfile <путь> <МБ> — выделяет файл и делает из него своп.
# fallocate быстрее, но на btrfs даёт файл с дырами, непригодный для свопа —
# тогда честно переписываем нулями через dd. Возвращает 0 только если своп
# реально поднялся.
create_swapfile() {
    local path="$1" mb="$2"
    rm -f "$path"
    if ! fallocate -l "${mb}M" "$path" 2>/dev/null; then
        log_info "fallocate не сработал — выделяю файл через dd (дольше)"
        dd if=/dev/zero of="$path" bs=1M count="$mb" status=none 2>/dev/null || return 1
    fi
    chmod 600 "$path"
    if ! mkswap "$path" >/dev/null 2>&1; then
        log_info "mkswap не принял файл — переделываю через dd"
        rm -f "$path"
        dd if=/dev/zero of="$path" bs=1M count="$mb" status=none 2>/dev/null || return 1
        chmod 600 "$path"
        mkswap "$path" >/dev/null 2>&1 || return 1
    fi
    swapon "$path" 2>/dev/null || return 1
    return 0
}

# ensure_fstab_swap <путь> — ровно одна запись с pri=10, без дублей.
# Дубль опаснее, чем кажется: после ребута своп смонтируется дважды
ensure_fstab_swap() {
    local path="$1" esc
    esc="$(printf '%s' "$path" | sed 's/[.[\*^$/]/\\&/g')"
    if grep -qE "^${esc}\s" /etc/fstab 2>/dev/null; then
        sed -i -E "s#^(${esc}\s+none\s+swap\s+)sw([^,].*)?\$#\1sw,pri=10\2#" /etc/fstab
    else
        echo "${path} none swap sw,pri=10 0 0" >> /etc/fstab
    fi
}

# resize_swapfile <путь> <новый_МБ> — пересоздание уже работающего свопа.
# Самая опасная операция в скрипте: между swapoff и swapon машина живёт без
# резервной памяти, поэтому все проверки — ДО того, как что-то трогать.
resize_swapfile() {
    local path="$1" new_mb="$2" old_mb="$3" used_mb="$4"

    if [ ! -f "$path" ]; then
        log_error "${path} — не обычный файл, пересоздавать не буду"
        return 1
    fi

    # swapoff выгружает занятые страницы обратно в RAM. Если они туда не
    # влезают — получим OOM и убитые процессы, поэтому просто отказываемся
    local avail_mb
    avail_mb="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    [[ "$avail_mb" =~ ^[0-9]+$ ]] || avail_mb=0
    if [ "$used_mb" -gt 0 ] && [ "$used_mb" -ge $(( avail_mb - 200 )) ]; then
        log_error "В свопе занято ${used_mb} МБ, а свободной памяти всего ${avail_mb} МБ"
        log_error "Отключение свопа сейчас рискует уронить процессы — размер не меняю"
        log_info "Освободи память (или перезагрузись) и вернись в этот пункт"
        return 1
    fi

    # места должно хватить с учётом того, что старый файл освободится
    local free_mb
    free_mb="$(df -m / 2>/dev/null | awk 'NR==2{print $4}')"
    [[ "$free_mb" =~ ^[0-9]+$ ]] || free_mb=0
    if [ "$new_mb" -gt $(( free_mb + old_mb - 256 )) ]; then
        log_error "Не хватит места: нужно ${new_mb} МБ, доступно ~$(( free_mb + old_mb )) МБ"
        return 1
    fi

    log_info "Отключаю ${path} ${DIM}(занято ${used_mb} МБ, свободной памяти ${avail_mb} МБ)${NC}"
    if ! swapoff "$path" 2>/dev/null; then
        log_error "swapoff ${path} не удался — ничего не менял"
        return 1
    fi

    if create_swapfile "$path" "$new_mb"; then
        ensure_fstab_swap "$path"
        swapoff "$path" 2>/dev/null
        swapon -a 2>/dev/null           # поднимаем уже с приоритетом из fstab
        log_success "swap пересоздан: ${new_mb} МБ, приоритет 10"
        return 0
    fi

    # не получилось — машина сейчас без свопа, это надо исправить или хотя бы
    # сказать вслух, а не оставить молча
    log_error "Не удалось создать своп размером ${new_mb} МБ"
    if create_swapfile "$path" "$old_mb"; then
        ensure_fstab_swap "$path"
        swapoff "$path" 2>/dev/null
        swapon -a 2>/dev/null
        log_warn "Вернул прежний размер ${old_mb} МБ — система со свопом"
    else
        log_error "ВНИМАНИЕ: своп сейчас ВЫКЛЮЧЕН. Подними вручную:"
        echo -e "      ${BOLD}sudo fallocate -l ${old_mb}M ${path} && sudo chmod 600 ${path}${NC}"
        echo -e "      ${BOLD}sudo mkswap ${path} && sudo swapon -a${NC}"
    fi
    return 1
}

apply_zram() {
    read_swap_state
    local zram_active="$ZRAM_ACTIVE" zram_prio="$ZRAM_PRIO" \
          swap_active="$SWAP_ACTIVE" swap_prio="$SWAP_PRIO" swap_path="$SWAP_PATH"

    if [ "$zram_active" = true ]; then
        if [ "$zram_prio" = "100" ]; then
            log_success "zram уже настроен (приоритет 100) — пропускаю"
        else
            log_warn "zram активен, но приоритет ${zram_prio} (рекомендуется 100), похоже настраивали вручную"
            if ask_yn "Перенастроить под рекомендованные значения?" N; then
                local cur_percent zram_percent
                cur_percent="$(grep -oP '^PERCENT=\K[0-9]+' /etc/default/zramswap 2>/dev/null)"
                [ -z "$cur_percent" ] && cur_percent=75
                zram_percent="$(ask_value "Размер zram в % от RAM?" "$cur_percent")"
                if ensure_pkg "zram-tools" zram-tools; then
                    systemctl stop zramswap 2>/dev/null
                    swapoff /dev/zram0 2>/dev/null || true
                    printf 'ALGO=lz4\nPERCENT=%s\nPRIORITY=100\n' "$zram_percent" > /etc/default/zramswap
                    if ! systemctl start zramswap; then
                        sleep 2
                        systemctl start zramswap
                    fi
                    if swapon --show --noheadings --raw 2>/dev/null | awk '{print $1}' | grep '^/dev/zram' >/dev/null; then
                        log_success "zram перенастроен (${zram_percent}% RAM)"
                    else
                        log_error "Не удалось поднять zram — попробуйте вручную: systemctl restart zramswap"
                    fi
                else
                    log_error "Установка zram-tools не удалась"
                fi
            fi
        fi
    elif ask_yn "Установить и настроить zram (lz4, приоритет 100)?"; then
        local zram_percent
        zram_percent="$(ask_value "Размер zram в % от RAM?" "${ZRAM_BULK_PERCENT:-75}")"
        if ensure_pkg "zram-tools" zram-tools; then
            systemctl stop zramswap 2>/dev/null
            swapoff /dev/zram0 2>/dev/null || true
            printf 'ALGO=lz4\nPERCENT=%s\nPRIORITY=100\n' "$zram_percent" > /etc/default/zramswap
            if ! systemctl start zramswap; then
                sleep 2
                systemctl start zramswap
            fi
            if swapon --show --noheadings --raw 2>/dev/null | awk '{print $1}' | grep '^/dev/zram' >/dev/null; then
                log_success "zram-tools установлен и настроен (${zram_percent}% RAM)"
            else
                log_error "Не удалось поднять zram — попробуйте вручную: systemctl restart zramswap"
            fi
        else
            log_error "Установка zram-tools не удалась"
        fi
    fi

    if [ "$swap_active" = true ]; then
        if [ "$swap_prio" = "10" ]; then
            local sw_suggest
            sw_suggest="$(suggest_swap_mb "$SWAP_SIZE_MB")"
            log_success "Резервный своп: ${swap_path}, ${SWAP_SIZE_MB} МБ, приоритет 10 ${DIM}(занято ${SWAP_USED_MB} МБ)${NC}"

            if [ "$SWAP_TYPE" != "file" ]; then
                # раздел или LVM: менять его размер — это про parted/lvresize и
                # риск для данных, такое не место в меню быстрой настройки
                log_info "Тип свопа — ${SWAP_TYPE:-?}, размер разделов этот скрипт не меняет"
            elif swap_needs_resize "$SWAP_SIZE_MB" "$sw_suggest"; then
                log_info "Рекомендуемый размер для этой машины: ${BOLD}${sw_suggest} МБ${NC} ${DIM}(min(RAM, свободно/4))${NC}"
                # В пакетном режиме ask_yn всегда вернёт дефолт N, поэтому
                # согласием считаем сам факт того, что размер уже спросили
                # заранее в main() — иначе предзаданное значение пропало бы зря
                local want_resize=false
                if [ "$BULK_MODE" = true ]; then
                    [ -n "$SWAP_BULK_MB" ] && want_resize=true
                elif ask_yn "Изменить размер swap-файла?" N; then
                    want_resize=true
                fi
                if [ "$want_resize" = true ]; then
                    local new_mb
                    new_mb="$(ask_value "Размер swap-файла, МБ?" "${SWAP_BULK_MB:-$sw_suggest}")"
                    if [ "$new_mb" -lt 64 ]; then
                        log_error "Слишком мало (${new_mb} МБ) — размер не меняю"
                    else
                        resize_swapfile "$swap_path" "$new_mb" "$SWAP_SIZE_MB" "$SWAP_USED_MB"
                    fi
                fi
            else
                log_success "Размер близок к рекомендуемому (${sw_suggest} МБ) — оставляю как есть"
            fi
        else
            log_warn "Своп на диске (${swap_path}) активен, но приоритет ${swap_prio} (рекомендуется 10)"
            if ask_yn "Исправить приоритет ${swap_path} в /etc/fstab на 10?"; then
                local esc_path
                esc_path="$(printf '%s' "$swap_path" | sed 's/[.[\*^$/]/\\&/g')"
                sed -i -E "s#^(${esc_path}\s+none\s+swap\s+)sw([^,].*)?\$#\1sw,pri=10\2#" /etc/fstab
                swapoff "$swap_path" 2>/dev/null || true
                swapon -a
                # sed молча не найдёт строку, если своп в fstab указан через
                # UUID=/LABEL=, а не путём (типично для разделов) — тогда без
                # этой проверки log_success был бы враньём
                if swapon --show --noheadings --raw 2>/dev/null | awk -v p="$swap_path" '$1==p {print $5}' | grep '^10$' >/dev/null; then
                    log_success "Приоритет исправлен"
                else
                    log_error "Не удалось исправить приоритет ${swap_path} — возможно, в /etc/fstab он указан через UUID=/LABEL=, а не путём. Поправьте вручную: pri=10 в опциях монтирования"
                fi
            fi
        fi
    else
        local suggested_mb
        suggested_mb="$(suggest_swap_mb)"
        if ask_yn "Создать резервный swap-файл (по умолчанию ${suggested_mb} МБ, приоритет 10)?"; then
            local swap_mb
            swap_mb="$(ask_value "Размер swap-файла, МБ?" "${SWAP_BULK_MB:-$suggested_mb}")"
            if create_swapfile /swapfile "$swap_mb"; then
                ensure_fstab_swap /swapfile
                swapoff /swapfile 2>/dev/null
                swapon -a 2>/dev/null       # поднимаем уже с приоритетом из fstab
                log_success "swapfile создан (${swap_mb} МБ, приоритет 10)"
            else
                log_error "Не удалось создать /swapfile на ${swap_mb} МБ — подробности выше"
            fi
        fi
    fi

    local cur_sw cur_vfs
    cur_sw="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo '?')"
    cur_vfs="$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo '?')"
    if [ "$cur_sw" = "80" ] && [ "$cur_vfs" = "50" ]; then
        log_success "sysctl уже настроен как рекомендуется"
    else
        log_info "Сейчас: swappiness=${cur_sw}, vfs_cache_pressure=${cur_vfs} ${DIM}(рекомендуется 80/50)${NC}"
        local sysctl_default=Y
        [ "$cur_sw" != "60" ] || [ "$cur_vfs" != "100" ] && sysctl_default=N
        if ask_yn "Применить рекомендованные значения sysctl?" "$sysctl_default"; then
            printf 'vm.swappiness=80\nvm.vfs_cache_pressure=50\n' > /etc/sysctl.d/99-zram.conf
            sysctl --system >/dev/null 2>&1
            # Не верим на слово: перечитываем /proc. Раньше здесь безусловно
            # печаталось «sysctl применён» сразу под строкой со СТАРЫМИ числами —
            # и это читалось как «рекомендуется, но не сделано». Теперь видно
            # результат, а если файл кто-то переопределяет — видно и это
            local new_sw new_vfs
            new_sw="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo '?')"
            new_vfs="$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo '?')"
            if [ "$new_sw" = "80" ] && [ "$new_vfs" = "50" ]; then
                log_success "sysctl применён: swappiness ${cur_sw} → ${new_sw}, vfs_cache_pressure ${cur_vfs} → ${new_vfs}"
            else
                log_warn "sysctl не применился: swappiness=${new_sw}, vfs_cache_pressure=${new_vfs}"
                log_info "Что-то перебивает /etc/sysctl.d/99-zram.conf — смотри ${BOLD}sysctl --system${NC}"
            fi
        else
            log_info "Оставляю sysctl как есть (swappiness=${cur_sw}, vfs_cache_pressure=${cur_vfs})"
        fi
    fi

    if systemctl is-enabled earlyoom &>/dev/null 2>&1; then
        log_success "earlyoom уже включён"
    elif ask_yn "Установить earlyoom (защита от полного падения при нехватке памяти)?"; then
        if ensure_pkg "earlyoom" earlyoom; then
            systemctl enable --now earlyoom >/dev/null
            log_success "earlyoom включён"
        fi
        refresh_pkg_cache
    fi

    echo ""
    log_info "Текущее состояние свопа:"
    swapon --show 2>/dev/null | sed 's/^/      /'
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
    cat > /etc/ssh/sshd_config.d/10-hardening.conf <<EOF
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

apply_ufw() {
    log_info "Обнаруженные слушающие TCP-порты:"
    local listening
    listening="$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\])' | grep -oE '[0-9]+$' | sort -un)"
    echo "$listening" | sed 's/^/      /'
    echo ""
    log_warn "Если на сервере уже крутится VPN/прокси — включение без разрешения ЕГО портов оборвёт его"
    if [ "$BULK_MODE" = true ]; then
        log_warn "UFW требует явного подтверждения — пропущено в пакетном режиме. Настройте отдельно пунктом $(item_number ufw)."
        return
    fi
    if ! ask_yn "Включить UFW, разрешив SSH-порт (${SSH_PORT}) и все порты выше?" N; then return; fi
    ensure_pkg "UFW" ufw || return 1
    ufw allow "${SSH_PORT}"/tcp >/dev/null
    while read -r p; do
        [ -n "$p" ] && ufw allow "${p}"/tcp >/dev/null
    done <<< "$listening"
    ufw --force enable >/dev/null
    log_success "UFW включён"
    ufw status | sed 's/^/      /'
}
