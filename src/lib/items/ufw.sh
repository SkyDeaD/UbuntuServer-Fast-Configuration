# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: UFW firewall ─────────────────────────────────────────
usfc_item ufw защита "UFW firewall" \
    "файрвол: закрывает всё, кроме нужного" \
    "UFW firewall" \
    "closes everything except what is needed"
usfc_item_toggle ufw

usfc_item_full ufw "Файрвол: закрывает все порты, кроме нужных — SSH-порта и того, что сервер уже
реально слушает на момент включения.

Автоопределение занятых портов сделано именно для того, чтобы включение UFW
не отрезало уже поднятые Docker и nginx. Но если на сервере крутится VPN или
прокси, его порт всё равно стоит проверить глазами перед включением." \
"A firewall: closes every port except the ones you need — the SSH port and
whatever the server is actually listening on at the moment it is enabled.

Detecting the busy ports exists precisely so that enabling UFW does not cut
off Docker and nginx that are already up. But if a VPN or a proxy is running
here, check its port with your own eyes before enabling."

usfc_item_rollback ufw "sudo ufw reset          # сбросить правила и выключить
     sudo apt purge ufw      # снести совсем
     # сервер останется без файрвола — открыты все порты, которые слушают сервисы" \
"sudo ufw reset          # reset the rules and disable it
     sudo apt purge ufw      # remove it entirely
     # the server is left with no firewall — every listening port becomes reachable"

status_ufw() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep "Status: active" >/dev/null; then
        st "$GREEN" "✓ включён" "✓ enabled"; return 0
    else
        st "$DIM" "○ выключен" "○ disabled"; return 1
    fi
}

# Вопрос пакетного режима (см. lib/bulk.sh): тот же, что в apply_ufw, и с
# тем же предупреждением — включённый вслепую файрвол рвёт VPN и прокси
preask_ufw() {
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep "Status: active" >/dev/null && return 0
    local listening
    listening="$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\])' | grep -oE '[0-9]+$' | sort -un | tr '\n' ' ')"
    echo ""
    log_info_t "UFW закроет всё, кроме SSH (${SSH_PORT}) и портов, которые сервер слушает сейчас: ${listening:-нет}" \
"UFW will close everything except SSH (${SSH_PORT}) and the ports the server listens on now: ${listening:-none}"
    log_warn_t "Если тут крутится VPN/прокси на UDP или ещё не запущенный сервис — его порт будет закрыт" \
"If a VPN or proxy runs here over UDP, or a service is not started yet, its port will be closed"
    ask_yn_t "Включить UFW в этом прогоне?" "Enable UFW in this run?" N \
        && UFW_BULK=Y || UFW_BULK=N
}

apply_ufw() {
    log_info_t "Обнаруженные слушающие TCP-порты:" \
"Detected listening TCP ports:"
    local listening
    listening="$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\])' | grep -oE '[0-9]+$' | sort -un)"
    echo "$listening" | sed 's/^/      /'
    echo ""
    log_warn_t "Если на сервере уже крутится VPN/прокси — включение без разрешения ЕГО портов оборвёт его" \
"If a VPN or proxy is already running here, enabling UFW without allowing ITS ports will cut it off"
    # В пакете — только по ответу, данному заранее (preask_ufw или файл
    # ответов). Раньше UFW здесь пропускался всегда, и профили web/secure,
    # в которых он есть, на деле его никогда не включали
    if [ "$BULK_MODE" = true ] && [ "$UFW_BULK" != Y ]; then
        log_info_t "UFW не включаю: в этом прогоне на него не было согласия" \
"Not enabling UFW: there was no consent to it in this run"
        return
    fi
    if ! ask_bulk_yn UFW_BULK "Включить UFW, разрешив SSH-порт (${SSH_PORT}) и все порты выше?" "Enable UFW, allowing the SSH port (${SSH_PORT}) and every port listed above?" N; then return; fi
    ensure_pkg "UFW" ufw || return 1
    ufw allow "${SSH_PORT}"/tcp >/dev/null
    while read -r p; do
        [ -n "$p" ] && ufw allow "${p}"/tcp >/dev/null
    done <<< "$listening"
    ufw --force enable >/dev/null
    log_success_t "UFW включён" \
"UFW enabled"
    ufw status | sed 's/^/      /'
}

disable_ufw() {
    ask_yn_t "Выключить UFW?" "Disable UFW?" N && { ufw disable &>/dev/null; log_success_t "UFW выключен" \
"UFW disabled"; }
}
