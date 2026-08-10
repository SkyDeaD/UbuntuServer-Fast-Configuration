# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: nginx-full ─────────────────────────────────────────
usfc_item nginx сервисы "nginx-full" \
    "веб-сервер и реверс-прокси"
usfc_item_toggle nginx

usfc_item_full nginx "Веб-сервер и реверс-прокси, пакет nginx-full.

Автозапуск спрашивается ДО установки, по умолчанию выключен. Чтобы «не
запускать» означало именно это, а не «поднять и тут же погасить» (nginx успел
бы занять :80), установка оборачивается в policy-rc.d. Намеренно выключенный
сервис считается законченным состоянием и больше не переспрашивается.

Когда nginx уже стоит, этот же пункт работает выключателем: остановит
работающий сервер или поднимет остановленный — смотря что сейчас."


usfc_item_rollback nginx "sudo systemctl disable --now nginx
     sudo apt purge nginx-full
     sudo rm -rf /etc/nginx
     # УДАЛЯЕТ конфиги сайтов в /etc/nginx — если уже настраивал поверх, забэкапь"

# ПРО «автозапуск выкл.» ниже: сервис, который пользователь сознательно попросил не
# запускать (см. apply_service_autostart), — это законченное состояние, а не недоделка.
# Если бы он числился «не применён», режим A переспрашивал бы про него при каждом
# прогоне. Само состояние хранит systemd, отдельный файл-состояния не нужен.
status_nginx() {
    if ! pkg_installed nginx-full; then
        echo -e "${DIM}○ не установлен${NC}"; return 1
    fi
    if systemctl is-active nginx &>/dev/null; then
        echo -e "${GREEN}✓ установлен и запущен${NC}"; return 0
    fi
    if [ "$(systemctl is-enabled nginx 2>/dev/null)" = "disabled" ]; then
        echo -e "${GREEN}✓ установлен, автозапуск выкл.${NC}"; return 0
    fi
    echo -e "${YELLOW}! установлен, не запущен${NC}"; return 1
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

# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# DISABLE-функции — только для безопасно обратимых пунктов
# ═══════════════════════════════════════════════════════════════
# У пунктов «защиты» disable_* только выключает, и этого достаточно: их статус
# после выключения становится «не применено», так что повторный выбор сам уходит
# в apply_* и включает обратно.
#
# С nginx и Docker так нельзя. Их статус намеренно остаётся ЗЕЛЁНЫМ и для
# сознательно выключенного сервиса — иначе режим A предлагал бы его при каждом
# прогоне (это чинили в 2.6.0). Значит повторный выбор всегда приходит сюда,
# и включать обратно приходится тоже здесь. Поэтому обе функции ниже —
# переключатели: смотрят на текущее состояние и предлагают противоположное.
disable_nginx() {
    if service_is_up nginx; then
        if ! ask_yn "Остановить nginx и убрать из автозапуска? Сайты на :80 и :443 перестанут отвечать" N; then
            log_info "Оставляю nginx как есть"; return 0
        fi
        apply_service_autostart nginx false
    else
        if ! ask_yn "nginx выключен. Запустить и включить автозапуск?" Y; then
            log_info "Оставляю nginx выключенным"; return 0
        fi
        apply_service_autostart nginx true
    fi
}
