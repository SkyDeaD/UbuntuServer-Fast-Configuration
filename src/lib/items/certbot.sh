# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# Cloudflare-плагин без credentials-файла нерабочий, поэтому «токен не задан» —
# отдельное видимое состояние в меню, а не тихая недоделка
CF_CREDENTIALS="/root/.secrets/certbot/cloudflare.ini"

# Запрос токена скрытым вводом → REPLY_CF_TOKEN. Вынесен отдельно, потому что
# спрашивать его приходится из двух мест: обычного прогона и предзапроса перед
# пакетным режимом
REPLY_CF_TOKEN=""

# Права на credentials-файл так, как их понимает сам certbot: он смотрит ТОЛЬКО
# биты «остальных» (filesystem.has_world_permissions) и на них лишь ругается
# в лог, не отказываясь выпускать сертификат. Поэтому проверяем ровно то же —
# иначе меню начнёт пугать там, где сам certbot молчит.
#
# Режим кладём в REPLY_CF_MODE, чтобы вызывающий не делал второй stat: функция
# дёргается из status_certbot, а это горячий путь отрисовки меню.
REPLY_CF_MODE=''
# ── Пункт меню: Certbot + плагины ─────────────────────────────────────────
usfc_item certbot сервисы "Certbot + плагины" \
    "TLS-сертификаты, в том числе wildcard через DNS" \
    "Certbot + plugins" \
    "TLS certificates, wildcard included via DNS"

usfc_item_full certbot "Сам certbot плюс, по выбору, плагин nginx (HTTP-01, обычные сертификаты)
и плагин dns-cloudflare (DNS-01 — без него не выпустить wildcard).

Для Cloudflare предлагается создать /root/.secrets/certbot/cloudflare.ini
с API-токеном (права 600, токену нужны права Zone:DNS:Edit). Без файла плагин
нерабочий, поэтому его отсутствие видно в меню отдельным статусом.

Отдельно предлагается положить в /etc/letsencrypt заготовки ssl-dhparams.pem
и options-ssl-nginx.conf: при выпуске wildcard через certonly они не создаются,
а типовой конфиг nginx на них ссылается и роняет сервер при старте." \
"certbot itself, plus — optionally — the nginx plugin (HTTP-01, ordinary
certificates) and the dns-cloudflare plugin (DNS-01, the only way to issue
wildcards).

For Cloudflare it offers to create /root/.secrets/certbot/cloudflare.ini with
an API token (hidden input, mode 600; the token needs Zone:DNS:Edit). Decline
and the menu keeps showing 'CF token not set', because the plugin is useless
without that file.

It also offers to place ssl-dhparams.pem and options-ssl-nginx.conf into
/etc/letsencrypt. Only certbot's nginx *installer* creates those, and issuing
a wildcard via certbot certonly does not — so a typical nginx config that
references them takes the server down on start. Both files are copied out of
the certbot packages; nothing is generated or downloaded."


usfc_item_rollback certbot "sudo apt purge certbot python3-certbot-nginx python3-certbot-dns-cloudflare
     sudo rm -f ${CF_CREDENTIALS}
     sudo rm -f /etc/letsencrypt/ssl-dhparams.pem /etc/letsencrypt/options-ssl-nginx.conf
     # /etc/letsencrypt/live и archive НЕ трогай, если сертификаты ещё используются" \
"sudo apt purge certbot python3-certbot-nginx python3-certbot-dns-cloudflare
     sudo rm -f ${CF_CREDENTIALS}
     sudo rm -f /etc/letsencrypt/ssl-dhparams.pem /etc/letsencrypt/options-ssl-nginx.conf
     # do NOT touch /etc/letsencrypt/live or archive while the certificates are in use"

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
        log_success_t "Credentials-файл уже есть: ${CF_CREDENTIALS}" \
"Credentials file already exists: ${CF_CREDENTIALS}"
        # Права проверяем и чиним ЗДЕСЬ. Сами мы кладём файл с 600, но он мог
        # приехать не от нас: создан руками по подсказке ниже, восстановлен из
        # бэкапа, скопирован. Раньше эта ветка молча рапортовала успех, и файл
        # с чужими правами так и жил с зелёной галочкой в меню
        if cf_creds_world_readable; then
            log_warn_t "Права ${CF_CREDENTIALS}: ${REPLY_CF_MODE} — токен читает кто угодно" \
"Permissions on ${CF_CREDENTIALS}: ${REPLY_CF_MODE} — anyone can read the token"
            if ask_yn_t "Починить права на 600 (root:root)?" "Fix permissions to 600 (root:root)?" Y; then
                chmod 600 "$CF_CREDENTIALS" && chown root:root "$CF_CREDENTIALS" \
                    && log_success_t "Права исправлены: $(stat -c %a "$CF_CREDENTIALS" 2>/dev/null), root:root" \
                  "Permissions fixed: $(stat -c %a "$CF_CREDENTIALS" 2>/dev/null), root:root"
            else
                log_info_t "Оставляю как есть — certbot будет писать «Unsafe permissions» в лог" \
"Leaving it as is — certbot will log "Unsafe permissions""
            fi
        fi
        if ! ask_yn_t "Перезаписать его новым токеном?" "Overwrite it with a new token?" N; then return; fi
    elif ! ask_yn_t "Создать ${CF_CREDENTIALS} с API-токеном Cloudflare?" "Create ${CF_CREDENTIALS} with a Cloudflare API token?" N; then
        log_warn_t "Без токена плагин Cloudflare работать НЕ будет — выпуск сертификатов упадёт" \
"Without a token the Cloudflare plugin will NOT work — issuing certificates will fail"
        log_warn_t "В меню этот пункт так и будет показывать «токен CF не задан»" \
"This item will keep showing "CF token not set" in the menu"
        log_info_t "Создать вручную (права Zone:DNS:Edit):" \
"Create it by hand (token needs Zone:DNS:Edit):"
        echo -e "      ${DIM}mkdir -p $(dirname "$CF_CREDENTIALS") && chmod 700 $(dirname "$CF_CREDENTIALS")${NC}"
        t "ТОКЕН" "TOKEN"
        echo -e "      ${DIM}echo 'dns_cloudflare_api_token = ${REPLY_T}' > ${CF_CREDENTIALS}${NC}"
        echo -e "      ${DIM}chmod 600 ${CF_CREDENTIALS}${NC}"
        cf_wildcard_hint
        return
    fi

    ask_cf_token || return 1
    cf_write_credentials "$REPLY_CF_TOKEN"
    REPLY_CF_TOKEN=""
}

ask_cf_token() {
    t "API-токен Cloudflare" "Cloudflare API token"; local _p="$REPLY_T"
    t "(права Zone:DNS:Edit, ввод скрыт):" "(needs Zone:DNS:Edit, input hidden):"
    echo -en "  ${BOLD}${_p}${NC} ${DIM}${REPLY_T}${NC} "
    read -rs REPLY_CF_TOKEN </dev/tty; echo ""
    if [ -z "$REPLY_CF_TOKEN" ]; then
        log_error_t "Пустой токен — файл не создан" \
"Empty token — no file created"
        return 1
    fi
    return 0
}

cf_write_credentials() {
    local token="$1"
    [ -z "$token" ] && { log_error_t "Пустой токен — файл не создан" \
"Empty token — no file created"; return 1; }
    install -d -m 700 "$(dirname "$CF_CREDENTIALS")" || { log_error_t "Не удалось создать каталог" \
"Could not create the directory"; return 1; }
    # Файл заводим ПУСТЫМ и сразу с нужными правами, а токен пишем уже в него.
    # Раньше здесь стоял `umask 077` перед перенаправлением: он, во-первых,
    # не восстанавливался и утекал на весь остаток прогона (все конфиги,
    # которые пункты 9-14 писали после certbot, получали 600 вместо 644),
    # во-вторых, оставлял окно между созданием файла и chmod.
    install -m 600 -o root -g root /dev/null "$CF_CREDENTIALS" || {
        log_error_t "Не удалось создать ${CF_CREDENTIALS}" \
"Could not create ${CF_CREDENTIALS}"; return 1; }
    printf 'dns_cloudflare_api_token = %s\n' "$token" | write_file "$CF_CREDENTIALS" || {
        log_error_t "Не удалось записать ${CF_CREDENTIALS}" \
"Could not write ${CF_CREDENTIALS}"; return 1; }
    log_success_t "Credentials-файл создан: ${CF_CREDENTIALS} ($(stat -c %a "$CF_CREDENTIALS" 2>/dev/null), root:root)" \
                  "Credentials file created: ${CF_CREDENTIALS} ($(stat -c %a "$CF_CREDENTIALS" 2>/dev/null), root:root)"
    cf_wildcard_hint
}

cf_creds_world_readable() {
    REPLY_CF_MODE=''
    [ -s "$CF_CREDENTIALS" ] || return 1
    REPLY_CF_MODE="$(stat -c %a "$CF_CREDENTIALS" 2>/dev/null)" || return 1
    [ -n "$REPLY_CF_MODE" ] || return 1
    [ $(( 8#${REPLY_CF_MODE: -1} & 7 )) -ne 0 ]
}

cf_wildcard_hint() {
    log_info_t "Выпуск wildcard-сертификата:" \
"Issuing a wildcard certificate:"
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
        log_success_t "TLS-заготовки в /etc/letsencrypt уже на месте" \
"The TLS boilerplate in /etc/letsencrypt is already there"
        return
    fi
    if ! ask_yn_t "Положить TLS-заготовки certbot (ssl-dhparams.pem, options-ssl-nginx.conf) в /etc/letsencrypt?" "Place certbot's TLS boilerplate (ssl-dhparams.pem, options-ssl-nginx.conf) into /etc/letsencrypt?" N; then
        return
    fi

    install -d -m 755 /etc/letsencrypt
    for name in ssl-dhparams.pem options-ssl-nginx.conf; do
        dst="/etc/letsencrypt/${name}"
        if [ -f "$dst" ]; then
            log_info_t "${name} уже есть — не трогаю" \
"${name} already exists — leaving it alone"
            continue
        fi
        # путь внутри пакета ищем в рантайме: он менялся между версиями certbot,
        # хардкодить его — напрашиваться на молчаливую поломку
        src="$(find /usr/lib/python3/dist-packages /usr/lib/python3*/site-packages \
                -name "$name" -type f 2>/dev/null | head -n1)"
        if [ -z "$src" ]; then
            log_warn_t "${name} не найден внутри пакетов certbot — пропускаю (не выдумываю содержимое)" \
"${name} was not found inside the certbot packages — skipping (not inventing its contents)"
            continue
        fi
        if install -m 644 "$src" "$dst"; then
            log_success "${name} → ${dst}"
        else
            log_error_t "Не удалось скопировать ${name}" \
"Could not copy ${name}"
        fi
    done
}

status_certbot() {
    if ! pkg_installed certbot; then
        st "$DIM" "○ не установлен" "○ not installed"; return 1
    fi
    local has_nginx=false has_cf=false
    pkg_installed python3-certbot-nginx && has_nginx=true
    pkg_installed python3-certbot-dns-cloudflare && has_cf=true

    if [ "$has_cf" = true ] && [ ! -s "$CF_CREDENTIALS" ]; then
        st "$YELLOW" "! токен CF не задан" "! CF token not set"; return 1
    fi
    # Файл на месте, но читается кем угодно — по сути тот же «не готово»:
    # certbot будет ругаться в лог, а токен от DNS-зоны лежит открытым.
    # Возврат 1 не косметика: пункт снова считается неприменённым, попадает
    # в режим A и в повторном прогоне права чинятся
    if [ "$has_cf" = true ] && cf_creds_world_readable; then
        st "$YELLOW" "! права токена CF: ${REPLY_CF_MODE}" "! CF token permissions: ${REPLY_CF_MODE}"; return 1
    fi
    if [ "$has_nginx" = false ] && [ "$has_cf" = false ]; then
        st "$YELLOW" "! без плагинов" "! no plugins"; return 1
    fi
    # Отсутствие CF раньше было видно только по тому, чего в строке НЕТ, —
    # зелёная галочка при этом читалась как «всё стоит». Пишем прямо.
    # Цвет остаётся зелёным: wildcard нужен не всем, и делать пункт вечно
    # жёлтым (а значит и вечно «не применённым» для режима A) было бы враньём
    # в другую сторону.
    local plugins=""
    [ "$has_nginx" = true ] && plugins="nginx"
    if [ "$has_cf" = true ]; then
        plugins="${plugins}${plugins:+, }CF"
    else
        t "без CF" "no CF"
        plugins="${plugins}${plugins:+, }${REPLY_T}"
    fi
    echo -e "${GREEN}✓ certbot + ${plugins}${NC}"; return 0
}

apply_certbot() {
    ensure_apt_updated
    if ! pkg_installed certbot; then
        if ! ask_yn_t "Установить certbot (Let's Encrypt)?" "Install certbot (Let's Encrypt)?"; then return; fi
        run_logged "certbot" apt_get install -y certbot || return 1
        refresh_pkg_cache
    else
        log_info_t "certbot уже установлен: $(certbot --version 2>&1 | head -n1)" \
"certbot is already installed: $(certbot --version 2>&1 | head -n1)"
    fi

    # ── плагин nginx (HTTP-01) ────────────────────────────────────────────────
    if pkg_installed python3-certbot-nginx; then
        log_success_t "Плагин nginx уже установлен" \
"The nginx plugin is already installed"
    elif ! pkg_installed nginx-full; then
        log_info_t "nginx не установлен — плагин nginx пропускаю (поставь nginx и вернись сюда)" \
"nginx is not installed — skipping its plugin (install nginx and come back)"
    elif ask_yn_t "Установить плагин nginx (HTTP-01, обычные сертификаты)?" "Install the nginx plugin (HTTP-01, ordinary certificates)?"; then
        run_logged "python3-certbot-nginx" apt_get install -y python3-certbot-nginx && refresh_pkg_cache
    fi

    # ── плагин Cloudflare (DNS-01) ────────────────────────────────────────────
    local want_cf=false install_cf=false
    if pkg_installed python3-certbot-dns-cloudflare; then
        want_cf=true
        log_success_t "Плагин Cloudflare уже установлен" \
"The Cloudflare plugin is already installed"
    else
        # В пакетном режиме ask_yn вернёт дефолт N и плагин молча не поставится —
        # поэтому согласие спрашивается заранее в main() и приезжает сюда готовым
        if [ "$BULK_MODE" = true ]; then
            [ "$CERTBOT_CF_BULK" = "Y" ] && install_cf=true
        elif ask_yn_t "Установить плагин Cloudflare (DNS-01, нужен для wildcard-сертификатов)?" "Install the Cloudflare plugin (DNS-01, required for wildcard certificates)?" N; then
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
                log_warn_t "При выпуске сертификата certbot напечатает большой WARNING про" \
"When issuing a certificate, certbot prints a big WARNING about"
                log_warn_t "python-cloudflare 2.20. Это безвредно и не отключается: версия" \
"python-cloudflare 2.20. It is harmless and cannot be silenced: the version"
                log_warn_t "закреплена пакетом (<< 3.0), на выпуск сертификатов не влияет." \
"is pinned by the package (<< 3.0) and does not affect issuance."
            fi
        fi
    fi

    [ "$want_cf" = true ] && apply_cloudflare_credentials
    apply_certbot_tls_assets
}
