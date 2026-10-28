# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: UFW firewall ─────────────────────────────────────────
# Логика файрвола — в lib/firewall.sh, её же использует `usfc firewall`
usfc_item ufw защита "UFW firewall" \
    "файрвол: закрывает всё, кроме нужного" \
    "UFW firewall" \
    "closes everything except what is needed"
usfc_item_toggle ufw

usfc_item_full ufw "Файрвол: закрывает входящие подключения ко всем портам, кроме SSH и тех,
что вы разрешили. Список предлагается по тому, что сервер слушает сейчас —
TCP и UDP, с именем процесса, — и его можно поправить: добавить порт ещё не
запущенного сервиса (443, 51820/udp, 1000:2000/tcp) или убрать лишний.

Здесь же — ответ на ping (выключается правкой /etc/ufw/before.rules) и, если
стоит Docker, связка с ним: Docker публикует порты контейнеров МИМО UFW, и без
связки -p 8080:80 открыт всему миру даже при включённом файрволе.

Потом порты меняются командой: usfc firewall --allow 8443 / --deny 8443." \
"A firewall: blocks incoming connections to every port except SSH and the ones
you allow. The list is suggested from what the server listens on right now —
TCP and UDP, with the process name — and you can edit it: add the port of a
service that is not running yet (443, 51820/udp, 1000:2000/tcp) or drop one.

Also here: ping replies (turned off by editing /etc/ufw/before.rules) and, if
Docker is installed, tying it to UFW: Docker publishes container ports PAST
UFW, so without this -p 8080:80 is open to the world even with the firewall on.

Change ports later with: usfc firewall --allow 8443 / --deny 8443."

usfc_item_rollback ufw "sudo ufw disable        # выключить, правила останутся
     sudo usfc restore       # вернуть before.rules/after.rules (ping, Docker)
     sudo ufw reset          # сбросить все правила
     # без файрвола открыты все порты, которые слушают сервисы" \
"sudo ufw disable        # turn it off, the rules stay
     sudo usfc restore       # bring back before.rules/after.rules (ping, Docker)
     sudo ufw reset          # reset every rule
     # with no firewall every listening port is reachable"

status_ufw() {
    if ufw_active; then
        st "$GREEN" "✓ включён" "✓ enabled"; return 0
    else
        st "$DIM" "○ выключен" "○ disabled"; return 1
    fi
}

# Таблица того, что слушает наружу, — чтобы человек видел, что закроется
_ufw_show_listening() {
    fw_listening
    log_info_t "Сервер слушает наружу (TCP и UDP):" "The server listens publicly on (TCP and UDP):"
    if [ -z "$REPLY_FW_LISTEN" ]; then
        t "ничего, кроме SSH" "nothing but SSH"; printf '      %s\n' "$REPLY_T"
    else
        local p proc
        while read -r p proc; do
            printf '      %-14s %s\n' "$p" "$proc"
        done <<< "$REPLY_FW_LISTEN"
    fi
}

# _ufw_proposed → REPLY_FW_PORTS: заданный список (--allow, UFW_ALLOW или
# ответ preask), пусто после ответа «-» (UFW_SSH_ONLY_BULK) или всё, что
# слушает наружу, кроме SSH (он разрешается всегда)
_ufw_proposed() {
    if [ "$UFW_SSH_ONLY_BULK" = Y ]; then
        REPLY_FW_PORTS=''; REPLY_FW_ERR=''; return 0
    fi
    if [ -n "$UFW_ALLOW_BULK" ]; then
        fw_parse_ports "$UFW_ALLOW_BULK"; return
    fi
    fw_listening
    local p proc list=''
    while read -r p proc; do
        [ -n "$p" ] || continue
        fw_is_ssh_port "$p" && continue
        list="${list} ${p}"
    done <<< "$REPLY_FW_LISTEN"
    fw_parse_ports "$list"
}

# _ufw_ask_ports — поправить список руками; «-» — только SSH.
# Ответ — в UFW_ALLOW_BULK, его же прочтёт apply_ufw. «-» нельзя хранить
# пустым UFW_ALLOW_BULK: пустой список значит «не задан», и _ufw_proposed
# подставил бы всё, что слушает. Поэтому отдельный признак UFW_SSH_ONLY_BULK
_ufw_ask_ports() {
    _ufw_proposed
    local def="${REPLY_FW_PORTS// /,}"
    while :; do
        ask_text_t "Какие порты открыть кроме SSH (${SSH_PORT})? «-» — никаких" "Which ports to open besides SSH (${SSH_PORT})? «-» — none" "${def:--}"
        if [ "$REPLY_TEXT" = - ]; then UFW_ALLOW_BULK=''; UFW_SSH_ONLY_BULK=Y; return 0; fi
        if fw_parse_ports "$REPLY_TEXT"; then UFW_ALLOW_BULK="$REPLY_FW_PORTS"; UFW_SSH_ONLY_BULK=''; return 0; fi
        log_warn "$REPLY_FW_ERR"
    done
}

# Ping и Docker в пакете меняются только по явному ответу. Дефолт вопроса —
# текущее состояние: Enter ничего не меняет, а `--yes` не включает ответ на
# ping обратно на сервере, где его выключили руками. «Частично» (before.rules
# правили руками, например DROP только на echo-request) — тоже N: Y вернул бы
# ACCEPT туда, где его кто-то сознательно убрал
_ufw_ping_default() {
    fw_ping_state
    case "$REPLY_FW_PING" in off|mixed) REPLY_T=N ;; *) REPLY_T=Y ;; esac
}
_ufw_ask_ping() {
    _ufw_ping_default
    ask_yn_t "Отвечать на ping?" "Reply to ping?" "$REPLY_T" && UFW_PING_BULK=Y || UFW_PING_BULK=N
}
_ufw_ask_docker() {
    fw_docker_published
    if [ -n "$REPLY_FW_DOCKER" ]; then
        log_info_t "Опубликованные порты контейнеров (сейчас открыты всем):" "Published container ports (open to everyone now):"
        local hp cp name
        while read -r hp cp name; do printf '      %-14s → %-6s %s\n' "$hp" "$cp" "$name"; done <<< "$REPLY_FW_DOCKER"
        log_warn_t "После связки снаружи останутся доступны только те из них, что в списке разрешённых" \
"Once tied, only those of them that are in the allowed list stay reachable from outside"
    fi
    local def=N
    fw_docker_on && def=Y
    ask_yn_t "Подчинить порты Docker-контейнеров UFW?" "Put Docker container ports behind UFW?" "$def" \
        && UFW_DOCKER_BULK=Y || UFW_DOCKER_BULK=N
}

# Вопросы пакетного режима (см. lib/bulk.sh): те же, что в apply_ufw, и с
# тем же предупреждением — включённый вслепую файрвол рвёт VPN и прокси
preask_ufw() {
    ufw_active && return 0
    echo ""
    _ufw_show_listening
    log_warn_t "UFW закроет всё, кроме SSH (${SSH_PORT}) и портов из списка ниже — проверьте VPN и прокси (UDP!)" \
"UFW will close everything except SSH (${SSH_PORT}) and the ports listed below — check VPNs and proxies (UDP!)"
    ask_yn_t "Включить UFW в этом прогоне?" "Enable UFW in this run?" N \
        && UFW_BULK=Y || { UFW_BULK=N; return 0; }
    _ufw_ask_ports
    _ufw_ask_ping
    if command -v docker >/dev/null 2>&1 || [[ "$USFC_PREASK_IDS" == *" docker "* ]]; then
        _ufw_ask_docker
    fi
}

# Ping и Docker по ответам UFW_PING / UFW_DOCKER; в меню — спросить
_ufw_extras() {
    local rc=0
    [ "$BULK_MODE" = true ] || _ufw_ask_ping
    case "$UFW_PING_BULK" in Y) fw_ping_set on || rc=1 ;; N) fw_ping_set off || rc=1 ;; esac

    if command -v docker >/dev/null 2>&1; then
        [ "$BULK_MODE" = true ] || _ufw_ask_docker
        case "$UFW_DOCKER_BULK" in
            Y) fw_docker_set on || rc=1 ;;
            N) fw_docker_set off || rc=1 ;;
            *) fw_docker_on || log_warn_t "Порты Docker-контейнеров открыты мимо UFW. Закрыть: usfc firewall docker on" \
"Docker container ports bypass UFW. To close them: usfc firewall docker on" ;;
        esac
    fi
    return "$rc"
}

apply_ufw() {
    # UFW уже включён, а в пакет пришли явные порты, ping или Docker —
    # filter_pending пропускает пункт дальше именно ради них. Включать нечего
    # и согласия не нужно: только добавить правила, ничего не закрывая
    if [ "$BULK_MODE" = true ] && ufw_active; then
        local rc=0
        if [ -n "$UFW_ALLOW_BULK" ]; then
            fw_parse_ports "$UFW_ALLOW_BULK" || { log_error "$REPLY_FW_ERR"; return 1; }
            local -a add=()
            read -ra add <<< "$REPLY_FW_PORTS"
            if fw_allow "$UFW_FROM_BULK" "${add[@]}"; then
                log_success_t "UFW уже включён, добавлены: ${REPLY_FW_PORTS}" "UFW is already on, added: ${REPLY_FW_PORTS}"
            else
                rc=1
            fi
        fi
        _ufw_extras || rc=1
        return "$rc"
    fi
    _ufw_show_listening
    echo ""
    # В пакете — только по ответу, данному заранее (preask_ufw, файл
    # ответов, --ufw, --allow). Раньше UFW здесь пропускался всегда, и
    # профили web/secure, в которых он есть, на деле его никогда не включали
    if [ "$BULK_MODE" = true ] && [ "$UFW_BULK" != Y ]; then
        log_info_t "UFW не включаю: в этом прогоне на него не было согласия" \
"Not enabling UFW: there was no consent to it in this run"
        item_skip_t "нет согласия (--ufw или --allow)" "no consent (--ufw or --allow)"
        return
    fi
    [ "$BULK_MODE" = true ] || _ufw_ask_ports
    # --from без --allow сузил бы до одного адреса всё, что слушает сервер:
    # сайт и VPN стали бы недоступны всем, кроме этого IP
    if [ -n "$UFW_FROM_BULK" ] && [ -z "$UFW_ALLOW_BULK" ] && [ "$UFW_SSH_ONLY_BULK" != Y ]; then
        log_error_t "UFW_FROM (--from) задан без списка портов (--allow) — не включаю UFW" \
"UFW_FROM (--from) is set without a port list (--allow) — not enabling UFW"
        return 1
    fi
    _ufw_proposed || { log_error "$REPLY_FW_ERR"; return 1; }
    local -a ports=()
    [ -n "$REPLY_FW_PORTS" ] && read -ra ports <<< "$REPLY_FW_PORTS"
    t "только SSH" "SSH only"
    local shown="${REPLY_FW_PORTS:-$REPLY_T}"
    [ -n "$UFW_FROM_BULK" ] && [ -n "$REPLY_FW_PORTS" ] && shown="${shown} (← ${UFW_FROM_BULK})"
    log_warn_t "Будут открыты: SSH ${SSH_PORT}/tcp, ${shown}. Остальное закроется" \
"Will be open: SSH ${SSH_PORT}/tcp, ${shown}. Everything else gets closed"
    if ! ask_bulk_yn UFW_BULK "Включить UFW?" "Enable UFW?" N; then return; fi
    ensure_pkg "UFW" ufw || return 1
    if ! fw_enable "$UFW_FROM_BULK" "${ports[@]+"${ports[@]}"}"; then
        ufw_active || return 1
        log_warn_t "UFW включён, но не все порты разрешились — см. ошибки выше" \
"UFW is on, but not every port was allowed — see the errors above"
    else
        log_success_t "UFW включён" "UFW enabled"
    fi

    local rc=0
    _ufw_extras || rc=1
    # Таблица правил — только для глаз: в сухом прогоне ufw ещё не стоит,
    # и её код не должен превращать пункт в «ошибку»
    ufw status 2>/dev/null | sed 's/^/      /' || true
    return "$rc"
}

disable_ufw() {
    ask_yn_t "Выключить UFW?" "Disable UFW?" N || return 0
    if _fw_ufw disable; then
        log_success_t "UFW выключен" "UFW disabled"
    else
        return 1
    fi
}
