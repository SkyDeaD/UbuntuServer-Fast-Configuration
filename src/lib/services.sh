# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# Автозапуск сервисов
# ═══════════════════════════════════════════════════════════════
# deb-пакеты nginx и docker поднимают сервис сами, из postinst — раньше, чем
# скрипт вообще получит управление. Чтобы «не запускать» означало именно это, а не
# «поднять и тут же погасить» (nginx успел бы занять :80 — а если порт уже занят,
# то и сама установка ругнётся), установка оборачивается в policy-rc.d: штатный
# для Debian способ сказать пакетам «сервисы не трогать».
POLICY_RC_D=/usr/sbin/policy-rc.d
POLICY_RC_D_OURS=false

drop_policy_rc_d() {
    [ "$POLICY_RC_D_OURS" = true ] || return 0
    rm -f "$POLICY_RC_D"
    POLICY_RC_D_OURS=false
}

with_no_service_start() {
    # чужой policy-rc.d не трогаем вообще: он не наш и, возможно, кому-то нужен
    if [ ! -e "$POLICY_RC_D" ]; then
        printf '#!/bin/sh\nexit 101\n' | write_file "$POLICY_RC_D"
        chmod +x "$POLICY_RC_D"
        POLICY_RC_D_OURS=true
    fi
    "$@"
    local rc=$?
    drop_policy_rc_d
    return "$rc"
}

# Забытый policy-rc.d тихо ломает старт сервисов при ЛЮБОЙ будущей apt install
# в системе — поэтому убираем его и при аварийном выходе, не только при штатном
trap 'cleanup_spinner; drop_policy_rc_d' EXIT INT TERM

# Предзаданные ответы для пакетного режима (см. main): пусто — спрашиваем.
# Читаются косвенно, через ${!1} в resolve_autostart — shellcheck этого не видит.
# shellcheck disable=SC2034
NGINX_AUTOSTART=""
# shellcheck disable=SC2034
DOCKER_AUTOSTART=""
# Cloudflare-плагин и токен к нему. В BULK_MODE вопросов не задают by design,
# поэтому и согласие, и сам токен спрашиваются заранее, в предзапросе main().
# Без токена плагин нерабочий, так что спрашивать их порознь смысла нет.
CERTBOT_CF_BULK=""
CF_TOKEN_BULK=""

# resolve_autostart <имя_переменной> <вопрос> — 0 если запускать, 1 если нет
resolve_autostart() {
    local preset="${!1:-}"
    case "$preset" in
        Y) return 0 ;;
        N) return 1 ;;
    esac
    ask_yn "$2" N
}

# service_units <docker|nginx> → REPLY_UNITS, все юниты сервиса разом.
#
# Для Docker их два, и это не формальность: docker.service поднимается
# СОКЕТ-АКТИВАЦИЕЙ. Пока docker.socket включён, «systemctl disable --now docker»
# гасит только демона, а первое же обращение к /var/run/docker.sock поднимает
# его обратно — и статус «автозапуск выкл.» оказывается враньём. Проверено:
# после disable сокет оставался enabled/active.
#
# Порядок в массиве — это порядок остановки И порядок запуска, и он тоже важен:
# сокет должен подниматься ПЕРВЫМ. Если сначала стартовать docker.service, тот
# создаст /var/run/docker.sock сам, и docker.socket потом не сможет к нему
# привязаться.
REPLY_UNITS=()
service_units() {
    case "${1:-}" in
        docker) REPLY_UNITS=(docker.socket docker.service) ;;
        *)      REPLY_UNITS=("${1}") ;;
    esac
}

# service_is_up <docker|nginx> — 0, если сервис работает ИЛИ поднимется сам:
# при загрузке (enabled) или по обращению к сокету. «Выключен» — это когда
# ни один из юнитов не активен и не включён.
service_is_up() {
    local u
    service_units "$1"
    for u in "${REPLY_UNITS[@]}"; do
        systemctl is-active "$u" &>/dev/null && return 0
        [ "$(systemctl is-enabled "$u" 2>/dev/null)" = "enabled" ] && return 0
    done
    return 1
}

apply_service_autostart() {
    local svc="$1" want="$2"
    service_units "$svc"
    if [ "$USFC_DRY_RUN" = true ]; then
        if [ "$want" = true ]; then
            log_info_t "[сухой прогон] systemctl enable --now ${REPLY_UNITS[*]}" \
"[dry run] systemctl enable --now ${REPLY_UNITS[*]}"
        else
            log_info_t "[сухой прогон] systemctl disable --now ${REPLY_UNITS[*]}" \
"[dry run] systemctl disable --now ${REPLY_UNITS[*]}"
        fi
        return 0
    fi
    if [ "$want" = true ]; then
        if systemctl enable --now "${REPLY_UNITS[@]}" >/dev/null 2>&1; then
            log_success_t "${svc}: запущен, автозапуск включён" \
"${svc}: started, autostart enabled"
        else
            log_error_t "Не удалось запустить ${svc} — подробности: journalctl -u ${svc}" \
"Could not start ${svc} — details: journalctl -u ${svc}"
        fi
    else
        systemctl disable --now "${REPLY_UNITS[@]}" >/dev/null 2>&1
        log_success_t "${svc}: установлен, но НЕ запущен (автозапуск выключен)" \
"${svc}: installed but NOT running (autostart disabled)"
        log_info_t "Включить позже: пункт $(item_number "$svc") в меню" \
               "Enable it later: menu item $(item_number "$svc")"
    fi
}
