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
без второго демон возвращается сам при первом обращении к сокету." \
"Docker CE + the Compose plugin from Docker's official repository, not the
docker.io package from the distribution — that one is noticeably older.

Autostart is asked BEFORE installing and defaults to off: you do not always
want the daemon up right now. The user is added to the docker group so that
docker works without sudo (requires a re-login).

Once Docker is installed, this same item acts as a switch: it shows the
current state and offers the opposite — stop a running daemon or start a
stopped one. Switching it off takes down both docker.service and
docker.socket: without the second one the daemon comes back by itself on the
first request to the socket."


usfc_item_rollback docker "sudo systemctl disable --now docker.socket docker.service
     sudo apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
     sudo rm -rf /var/lib/docker /var/lib/containerd
     # УДАЛЯЕТ все контейнеры/образы/volume без возврата — сначала забэкапь данные" \
"sudo systemctl disable --now docker.socket docker.service
     sudo apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
     sudo rm -rf /var/lib/docker /var/lib/containerd
     # DELETES every container, image and volume for good — back your data up first"

status_docker() {
    if ! command -v docker &>/dev/null; then
        st "$DIM" "○ не установлен" "○ not installed"; return 1
    fi
    local ver
    ver="$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)"
    if systemctl is-active docker.service &>/dev/null; then
        st "$GREEN" "✓ установлен (${ver})" "✓ installed (${ver})"; return 0
    fi
    # Демон стоит, но сокет жив — Docker поднимется по первому обращению.
    # Писать тут «автозапуск выкл.» нельзя: это ровно то состояние, в котором
    # оставлял систему прежний «systemctl disable --now docker» (см. service_units)
    if systemctl is-active docker.socket &>/dev/null \
       || [ "$(systemctl is-enabled docker.socket 2>/dev/null)" = "enabled" ]; then
        st "$GREEN" "✓ ${ver}, старт по запросу" "✓ ${ver}, socket-activated"; return 0
    fi
    if [ "$(systemctl is-enabled docker.service 2>/dev/null)" = "disabled" ]; then
        st "$GREEN" "✓ ${ver}, автозапуск выкл." "✓ ${ver}, autostart off"; return 0
    fi
    st "$YELLOW" "! ${ver}, не запущен" "! ${ver}, not running"; return 1
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
        log_info_t "Docker уже установлен: $(docker --version 2>/dev/null)" \
"Docker is already installed: $(docker --version 2>/dev/null)"
        local enabled active
        active="$(systemctl is-active docker.service 2>/dev/null)"
        enabled="$(systemctl is-enabled docker.service 2>/dev/null)"
        if [ "$active" = "active" ]; then
            log_success_t "Docker запущен ${DIM}(автозапуск: ${enabled:-?})${NC}" \
"Docker is running ${DIM}(autostart: ${enabled:-?})${NC}"
            if [ "$enabled" != "enabled" ] && ask_yn_t "Включить автозапуск Docker при загрузке?" "Enable Docker autostart at boot?" N; then
                service_units docker
                systemctl enable "${REPLY_UNITS[@]}" >/dev/null 2>&1 && log_success_t "Автозапуск включён" \
"Autostart enabled"
            fi
        elif ask_yn_t "Docker не запущен. Запустить и включить автозапуск?" "Docker is not running. Start it and enable autostart?" N; then
            apply_service_autostart docker true
        else
            log_info_t "Оставляю Docker выключенным" \
"Leaving Docker switched off"
        fi
        # Docker мог приехать не отсюда (docker.io, ручная установка) — тогда
        # группы у пользователя нет, и sudo требуется на каждый docker-вызов
        if [ "$TARGET_USER" != "root" ] && ! id -nG "$TARGET_USER" 2>/dev/null | grep -w docker >/dev/null; then
            if ask_yn_t "Добавить ${TARGET_USER} в группу docker (работа без sudo)?" "Add ${TARGET_USER} to the docker group (use it without sudo)?" Y; then
                usermod -aG docker "$TARGET_USER"
                log_info_t "Готово — перелогинься, чтобы группа применилась" \
"Done — re-login for the group to take effect"
            fi
        fi
        return 0
    fi

    if ! ask_yn_t "Установить Docker + Docker Compose (официальный репозиторий)?" "Install Docker + Docker Compose (official repository)?"; then return; fi
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
            log_error_t "Репозиторий Docker не отдал пакеты для '${codename}' (${OS_ID})" \
"The Docker repository has no packages for '${codename}' (${OS_ID})"
            log_info_t "Проверь сеть и ${USFC_LOG}; вручную: ${BOLD}apt-cache policy docker-ce-cli${NC}" \
"Check the network and ${USFC_LOG}; by hand: ${BOLD}apt-cache policy docker-ce-cli${NC}"
            return 1
        fi
        log_warn_t "У Docker пока нет пакетов под '${codename}' — переключаюсь на noble (24.04, совместимо)" \
"Docker has no packages for '${codename}' yet — switching to noble (24.04, compatible)"
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
        log_info_t "Пользователь ${TARGET_USER} добавлен в группу docker — перелогинься для работы без sudo" \
"${TARGET_USER} added to the docker group — re-login to use it without sudo"
    else
        log_info_t "Работаем от root — в группу docker никого не добавляю" \
"Running as root — not adding anyone to the docker group"
    fi
    log_success_t "Docker установлен: $(docker --version 2>/dev/null)" \
"Docker installed: $(docker --version 2>/dev/null)"
}

disable_docker() {
    if service_is_up docker; then
        if ! ask_yn_t "Остановить Docker и убрать из автозапуска? Все запущенные контейнеры встанут" "Stop Docker and remove it from autostart? Every running container will stop" N; then
            log_info_t "Оставляю Docker как есть" \
"Leaving Docker as it is"; return 0
        fi
        apply_service_autostart docker false
    else
        if ! ask_yn_t "Docker выключен. Запустить и включить автозапуск?" "Docker is off. Start it and enable autostart?" Y; then
            log_info_t "Оставляю Docker выключенным" \
"Leaving Docker switched off"; return 0
        fi
        apply_service_autostart docker true
    fi
}
