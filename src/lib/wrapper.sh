# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# Совет перезайти под новым пользователем — печатается и сразу, и ещё раз при
# выходе из меню, чтобы не потерялся за выводом последующих установок
RELOGIN_HINT_USER=""
ROOT_PROMPT_SHOWN=false

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
