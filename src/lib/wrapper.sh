# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# Совет перезайти под новым пользователем — печатается и сразу, и ещё раз при
# выходе из меню, чтобы не потерялся за выводом последующих установок
RELOGIN_HINT_USER=""
ROOT_PROMPT_SHOWN=false

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
        # старые формы блока: alias, функция без usfc_rc или без маркера v2
        # (v2 пробрасывает NO_COLOR/USFC_* через sudo и не портит stdout
        # команд вроде `usfc audit --json` и `usfc export`)
        if ! grep -qF "# usfc:wrapper v2" "$bashrc" 2>/dev/null; then
            remove_block "$bashrc" vps-setup:self || return 1
            need_block=true
        fi
    else
        need_block=true
    fi
    [ "$need_block" = false ] && return 0
    append_file "$bashrc" <<'EOF'

# >>> vps-setup:self >>>
# usfc:wrapper v2
usfc() {
    local usfc_rc _usfc_env=()
    [ -n "${NO_COLOR+x}" ] && _usfc_env+=("NO_COLOR=${NO_COLOR}")
    [ -n "${USFC_LANG:-}" ] && _usfc_env+=("USFC_LANG=${USFC_LANG}")
    [ -n "${USFC_NO_UPDATE:-}" ] && _usfc_env+=("USFC_NO_UPDATE=${USFC_NO_UPDATE}")
    [ -n "${USFC_VERBOSE:-}" ] && _usfc_env+=("USFC_VERBOSE=${USFC_VERBOSE}")
    [ -n "${USFC_REPO_RAW_BASE:-}" ] && _usfc_env+=("USFC_REPO_RAW_BASE=${USFC_REPO_RAW_BASE}")
    case "${1:-}" in
        version|help|list|-V|--version|-h|--help)
            /usr/local/bin/usfc "$@"; return $? ;;
    esac
    if [ "${#_usfc_env[@]}" -gt 0 ]; then
        sudo env "${_usfc_env[@]}" /usr/local/bin/usfc "$@"; usfc_rc=$?
    else
        sudo /usr/local/bin/usfc "$@"; usfc_rc=$?
    fi
    case "${1:-}" in
        audit|export|status|backups|list|version|help|-V|--version|-h|--help) ;;
        *) USFC_RESOURCE=1 source ~/.bashrc >/dev/null 2>&1; unset USFC_RESOURCE ;;
    esac
    return "$usfc_rc"
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
        log_error_t "Не удалось определить домашний каталог ${user} — контекст не переключаю" \
"Could not determine the home directory of ${user} — not switching context"
        return 1
    fi
    TARGET_USER="$user"
    TARGET_HOME="$home"
    install_usfc_wrapper
    invalidate_statuses
    RELOGIN_HINT_USER="$user"
    log_info_t "Дальнейшие настройки применяются к ${BOLD}${user}${NC} ${DIM}(${home})${NC}" \
"Further settings apply to ${BOLD}${user}${NC} ${DIM}(${home})${NC}"
}

print_relogin_hint() {
    [ -z "$RELOGIN_HINT_USER" ] && return 0
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo ""
    log_warn_t "Разлогинься и подключись уже под новым пользователем:" \
"Log out and reconnect as the new user:"
    t "<ip-сервера>" "<server-ip>"
    echo -e "      ${BOLD}ssh ${RELOGIN_HINT_USER}@${ip:-$REPLY_T}${NC}"
    log_info_t "Дальше просто ${BOLD}usfc${NC} — sudo писать не нужно" \
"After that just ${BOLD}usfc${NC} — no need to type sudo"
}
