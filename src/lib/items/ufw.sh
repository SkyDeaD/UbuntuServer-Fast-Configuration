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
прокси, его порт всё равно стоит проверить глазами перед включением."

usfc_item_rollback ufw "sudo ufw reset          # сбросить правила и выключить
     sudo apt purge ufw      # снести совсем
     # сервер останется без файрвола — открыты все порты, которые слушают сервисы"

status_ufw() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep "Status: active" >/dev/null; then
        echo -e "${GREEN}✓ включён${NC}"; return 0
    else
        echo -e "${DIM}○ выключен${NC}"; return 1
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

disable_ufw() {
    ask_yn "Выключить UFW?" N && { ufw disable &>/dev/null; log_success "UFW выключен"; }
}
