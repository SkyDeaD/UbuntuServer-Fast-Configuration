# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: nginx-full ─────────────────────────────────────────
usfc_item nginx сервисы "nginx-full" \
    "веб-сервер и реверс-прокси" \
    "nginx-full" \
    "web server and reverse proxy"
usfc_item_toggle nginx

usfc_item_full nginx "Веб-сервер и реверс-прокси, пакет nginx-full.

Автозапуск спрашивается ДО установки, по умолчанию выключен. Чтобы «не
запускать» означало именно это, а не «поднять и тут же погасить» (nginx успел
бы занять :80), установка оборачивается в policy-rc.d. Намеренно выключенный
сервис считается законченным состоянием и больше не переспрашивается.

Когда nginx уже стоит, этот же пункт работает выключателем: остановит
работающий сервер или поднимет остановленный — смотря что сейчас." \
"A web server and reverse proxy, the nginx-full package.

Autostart is asked BEFORE installing and defaults to off. So that 'do not
start it' means exactly that, rather than 'start it and immediately kill it'
(nginx would grab :80 in between), the install is wrapped in policy-rc.d.
A deliberately disabled service counts as a finished state and is not asked
about again.

Once nginx is installed, this same item acts as a switch: it stops a running
server or starts a stopped one, depending on the current state."


usfc_item_rollback nginx "sudo systemctl disable --now nginx
     sudo apt purge nginx-full
     sudo rm -rf /etc/nginx
     # УДАЛЯЕТ конфиги сайтов в /etc/nginx — если уже настраивал поверх, забэкапь" \
"sudo systemctl disable --now nginx
     sudo apt purge nginx-full
     sudo rm -rf /etc/nginx
     # DELETES the site configs in /etc/nginx — back them up if you configured anything"

# ПРО «автозапуск выкл.» ниже: сервис, который пользователь сознательно попросил не
# запускать (см. apply_service_autostart), — это законченное состояние, а не недоделка.
# Если бы он числился «не применён», режим A переспрашивал бы про него при каждом
# прогоне. Само состояние хранит systemd, отдельный файл-состояния не нужен.
status_nginx() {
    if ! pkg_installed nginx-full; then
        st "$DIM" "○ не установлен" "○ not installed"; return 1
    fi
    if systemctl is-active nginx &>/dev/null; then
        st "$GREEN" "✓ установлен и запущен" "✓ installed and running"; return 0
    fi
    if [ "$(systemctl is-enabled nginx 2>/dev/null)" = "disabled" ]; then
        st "$GREEN" "✓ установлен, автозапуск выкл." "✓ installed, autostart off"; return 0
    fi
    st "$YELLOW" "! установлен, не запущен" "! installed, not running"; return 1
}

apply_nginx() {
    if ! pkg_installed nginx-full; then
        if ! ask_yn_t "Установить nginx-full?" "Install nginx-full?"; then return; fi
        # спрашиваем ДО установки: ответ решает, дать ли postinst поднять сервис
        local autostart=false
        resolve_autostart NGINX_AUTOSTART "Запустить nginx и включить автозапуск?" && autostart=true
        ensure_apt_updated
        with_no_service_start run_logged "nginx-full" apt_get install -y nginx-full || return 1
        refresh_pkg_cache
        apply_service_autostart nginx "$autostart"
        return
    fi

    log_info_t "nginx-full уже установлен" \
"nginx-full is already installed"
    local enabled active
    enabled="$(systemctl is-enabled nginx 2>/dev/null)"
    active="$(systemctl is-active nginx 2>/dev/null)"
    if [ "$active" = "active" ]; then
        log_success_t "nginx запущен ${DIM}(автозапуск: ${enabled:-?})${NC}" \
"nginx is running ${DIM}(autostart: ${enabled:-?})${NC}"
        if [ "$enabled" != "enabled" ] && ask_yn_t "Включить автозапуск nginx при загрузке?" "Enable nginx autostart at boot?" N; then
            systemctl enable nginx >/dev/null 2>&1 && log_success_t "Автозапуск включён" \
"Autostart enabled"
        fi
    elif ask_yn_t "nginx не запущен. Запустить и включить автозапуск?" "nginx is not running. Start it and enable autostart?" N; then
        apply_service_autostart nginx true
    else
        log_info_t "Оставляю nginx выключенным" \
"Leaving nginx switched off"
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
        if ! ask_yn_t "Остановить nginx и убрать из автозапуска? Сайты на :80 и :443 перестанут отвечать" "Stop nginx and remove it from autostart? Sites on :80 and :443 will stop responding" N; then
            log_info_t "Оставляю nginx как есть" \
"Leaving nginx as it is"; return 0
        fi
        apply_service_autostart nginx false
    else
        if ! ask_yn_t "nginx выключен. Запустить и включить автозапуск?" "nginx is off. Start it and enable autostart?" Y; then
            log_info_t "Оставляю nginx выключенным" \
"Leaving nginx switched off"; return 0
        fi
        apply_service_autostart nginx true
    fi
}
