# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: Docker + Compose ─────────────────────────────────────────
usfc_item docker сервисы "Docker + Compose" \
    "Docker CE + Compose из официального репозитория" \
    "Docker + Compose" \
    "Docker CE + Compose from the official repository"
usfc_item_toggle docker

usfc_item_full docker "Docker CE + Compose plugin из официального репозитория Docker, а не пакет
docker.io из репозиториев Ubuntu — тот заметно старее.

Автозапуск спрашивается ДО установки и по умолчанию выключен: сервер не всегда
нужно поднимать прямо сейчас. Пользователь добавляется в группу docker, чтобы
работать без sudo (нужен перелогин).

Когда Docker уже стоит, этот же пункт работает выключателем: показывает
текущее состояние и предлагает обратное — остановить работающий демон или
поднять остановленный. Выключение снимает и docker.service, и docker.socket:
без второго демон возвращается сам при первом обращении к сокету."


usfc_item_rollback docker "sudo systemctl disable --now docker.socket docker.service
     sudo apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
     sudo rm -rf /var/lib/docker /var/lib/containerd
     # УДАЛЯЕТ все контейнеры/образы/volume без возврата — сначала забэкапь данные"

status_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${DIM}○ не установлен${NC}"; return 1
    fi
    local ver
    ver="$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)"
    if systemctl is-active docker.service &>/dev/null; then
        echo -e "${GREEN}✓ установлен (${ver})${NC}"; return 0
    fi
    # Демон стоит, но сокет жив — Docker поднимется по первому обращению.
    # Писать тут «автозапуск выкл.» нельзя: это ровно то состояние, в котором
    # оставлял систему прежний «systemctl disable --now docker» (см. service_units)
    if systemctl is-active docker.socket &>/dev/null \
       || [ "$(systemctl is-enabled docker.socket 2>/dev/null)" = "enabled" ]; then
        echo -e "${GREEN}✓ ${ver}, старт по запросу${NC}"; return 0
    fi
    if [ "$(systemctl is-enabled docker.service 2>/dev/null)" = "disabled" ]; then
        echo -e "${GREEN}✓ ${ver}, автозапуск выкл.${NC}"; return 0
    fi
    echo -e "${YELLOW}! ${ver}, не запущен${NC}"; return 1
}

# docker_write_repo <база репозитория> <codename> — строчка sources.list.
# Отдельной функцией, потому что при фолбэке на noble она пишется второй раз,
# а расходиться эти две строки не должны
docker_write_repo() {
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] ${1} ${2} stable" \
        | write_file /etc/apt/sources.list.d/docker.list
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
    # У Docker отдельные ветки репозитория под каждый дистрибутив, и путь
    # различается только идентификатором: /linux/ubuntu против /linux/debian.
    # Проверено — обе отдают пакеты и для noble, и для bookworm с trixie
    local docker_repo="https://download.docker.com/linux/${OS_ID}"
    run_logged "GPG-ключ Docker" \
        curl -fsSL "${docker_repo}/gpg" -o /etc/apt/keyrings/docker.asc || return 1
    chmod a+r /etc/apt/keyrings/docker.asc
    local codename="$OS_CODENAME"
    docker_write_repo "$docker_repo" "$codename"
    run_logged "Списки пакетов Docker" apt_get update -qq
    # grep БЕЗ -q — иначе SIGPIPE и вечно ложное условие, см. блок про ловушку
    # в начале файла. Здесь это и вскрылось: фолбэк срабатывал на каждой машине
    if ! apt-cache policy docker-ce-cli 2>/dev/null | grep 'Candidate:.*[0-9]' >/dev/null; then
        # Фолбэк на noble осмыслен только для Ubuntu: на Debian это чужая ветка
        # репозитория, её пакеты собраны под другие версии библиотек.
        # И падать на саму noble некуда — это и есть цель переключения
        if ! os_is_ubuntu || [ "$codename" = "noble" ]; then
            log_error "Репозиторий Docker не отдал пакеты для '${codename}' (${OS_ID})"
            log_info "Проверь сеть и ${USFC_LOG}; вручную: ${BOLD}apt-cache policy docker-ce-cli${NC}"
            return 1
        fi
        log_warn "У Docker пока нет пакетов под '${codename}' — переключаюсь на noble (24.04, совместимо)"
        docker_write_repo "$docker_repo" noble
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

disable_docker() {
    if service_is_up docker; then
        if ! ask_yn "Остановить Docker и убрать из автозапуска? Все запущенные контейнеры встанут" N; then
            log_info "Оставляю Docker как есть"; return 0
        fi
        apply_service_autostart docker false
    else
        if ! ask_yn "Docker выключен. Запустить и включить автозапуск?" Y; then
            log_info "Оставляю Docker выключенным"; return 0
        fi
        apply_service_autostart docker true
    fi
}
