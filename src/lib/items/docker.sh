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
без второго демон возвращается сам при первом обращении к сокету.

По желанию ставится lazydocker — консольный интерфейс для контейнеров, логов и
образов. Он берётся из GitHub-релиза jesseduffield/lazydocker с проверкой
sha256 по checksums.txt того же релиза; в пакетном режиме — только по явному
флагу --lazydocker." \
"Docker CE + the Compose plugin from Docker's official repository, not the
docker.io package from the distribution — that one is noticeably older.

Autostart is asked BEFORE installing and defaults to off: you do not always
want the daemon up right now. The user is added to the docker group so that
docker works without sudo (requires a re-login).

Once Docker is installed, this same item acts as a switch: it shows the
current state and offers the opposite — stop a running daemon or start a
stopped one. Switching it off takes down both docker.service and
docker.socket: without the second one the daemon comes back by itself on the
first request to the socket.

Optionally installs lazydocker, a terminal UI for containers, logs and images.
It is fetched from the jesseduffield/lazydocker GitHub release with its sha256
verified against the same release's checksums.txt; in batch mode only with the
explicit --lazydocker flag."


usfc_item_rollback docker "sudo systemctl disable --now docker.socket docker.service
     sudo apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
     sudo rm -rf /var/lib/docker /var/lib/containerd
     sudo rm -f /usr/local/bin/lazydocker      # если ставился этим же пунктом
     # УДАЛЯЕТ все контейнеры/образы/volume без возврата — сначала забэкапь данные" \
"sudo systemctl disable --now docker.socket docker.service
     sudo apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
     sudo rm -rf /var/lib/docker /var/lib/containerd
     sudo rm -f /usr/local/bin/lazydocker      # if it was installed by this item
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

# Вопросы пакетного режима (см. lib/bulk.sh)
preask_docker() {
    if ! { command -v docker >/dev/null 2>&1 && service_is_up docker; }; then
        echo ""
        log_info_t "Docker — запуск приложений в контейнерах. Если сейчас не нужен, можно не поднимать — включишь потом пунктом $(item_number docker)" \
"Docker runs applications in containers. If you do not need it right now, leave it down — enable it later via item $(item_number docker)"
        # shellcheck disable=SC2034  # читается через ask_bulk_yn / resolve_autostart
        ask_yn_t "Запускать Docker (и включать автозапуск)?" "Start Docker (and enable autostart)?" N \
            && DOCKER_AUTOSTART=Y || DOCKER_AUTOSTART=N
    fi
    if ! command -v lazydocker >/dev/null 2>&1 && [ -z "${LAZYDOCKER_BULK:-}" ]; then
        ask_yn_t "Поставить lazydocker (консольный интерфейс для Docker)?" "Install lazydocker (a terminal UI for Docker)?" N \
            && LAZYDOCKER_BULK=Y || LAZYDOCKER_BULK=N
    fi
    return 0
}

# ── lazydocker ────────────────────────────────────────────────────────────────
# Ставится не из apt (его там нет), а из GitHub-релиза. Всё, что скачано,
# проверяется по checksums.txt ТОГО ЖЕ релиза: без этого подменённый архив
# молча стал бы root-овым бинарником в /usr/local/bin.
LAZYDOCKER_REPO="jesseduffield/lazydocker"

# docker_install_lazydocker — 0, если lazydocker стоит после вызова. Тело в
# подоболочке: так trap на удаление временного каталога не затирает
# глобальные ловушки скрипта, а любой выход из неё чистит за собой
docker_install_lazydocker() {
    if [ "$USFC_DRY_RUN" = true ]; then
        t "скачал бы lazydocker из GitHub-релиза ${LAZYDOCKER_REPO} (sha256 по checksums.txt) в /usr/local/bin/lazydocker" \
          "would download lazydocker from the ${LAZYDOCKER_REPO} GitHub release (sha256 from checksums.txt) to /usr/local/bin/lazydocker"
        _dry_say "$REPLY_T"
        return 0
    fi
    (
        # имена ассетов релиза: lazydocker_<версия>_Linux_<x86_64|arm64|armv7|armv6|x86>.tar.gz
        local arch tag ver asset base tmp expected actual url c
        case "$(uname -m)" in
            x86_64|amd64)  arch=x86_64 ;;
            aarch64|arm64) arch=arm64 ;;
            armv7l)        arch=armv7 ;;
            armv6l)        arch=armv6 ;;
            i386|i686)     arch=x86 ;;
            *) log_error_t "lazydocker: архитектура $(uname -m) не поддерживается" \
"lazydocker: architecture $(uname -m) is not supported"; exit 1 ;;
        esac
        for c in curl sha256sum tar install; do
            command -v "$c" >/dev/null 2>&1 || { log_error_t "lazydocker: нужна утилита ${c}" \
"lazydocker: ${c} is required"; exit 1; }
        done
        # Редирект /releases/latest, а не api.github.com: у API анонимный лимит
        # 60 запросов в час на адрес, а за NAT хостинга он общий
        url="$(curl -fsSL --max-time 20 -o /dev/null -w '%{url_effective}' "https://github.com/${LAZYDOCKER_REPO}/releases/latest" 2>/dev/null)" || url=''
        tag="${url##*/}"
        if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_error_t "lazydocker: не удалось узнать последнюю версию (нет сети до github.com?) — ничего не ставлю" \
"lazydocker: could not determine the latest version (no network to github.com?) — installing nothing"
            exit 1
        fi
        ver="${tag#v}"
        asset="lazydocker_${ver}_Linux_${arch}.tar.gz"
        base="https://github.com/${LAZYDOCKER_REPO}/releases/download/${tag}"
        tmp="$(mktemp -d)" || exit 1
        trap 'rm -rf "$tmp"' EXIT
        t "lazydocker ${ver}: загрузка" "lazydocker ${ver}: download"
        run_logged "$REPLY_T" curl -fsSL --max-time 120 --retry 2 -o "${tmp}/${asset}" "${base}/${asset}" || {
            log_error_t "lazydocker: не скачался архив ${asset} — ничего не ставлю" \
"lazydocker: could not download ${asset} — installing nothing"; exit 1; }
        curl -fsSL --max-time 30 --retry 2 -o "${tmp}/checksums.txt" "${base}/checksums.txt" 2>/dev/null || {
            log_error_t "lazydocker: не скачался checksums.txt — без проверки хэша не ставлю" \
"lazydocker: could not download checksums.txt — not installing without a hash check"; exit 1; }
        expected="$(awk -v f="$asset" '$2 == f { print $1 }' "${tmp}/checksums.txt")"
        actual="$(sha256sum "${tmp}/${asset}" | awk '{ print $1 }')"
        if ! [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || [ "$expected" != "$actual" ]; then
            log_error_t "lazydocker: sha256 архива ${asset} не совпал с checksums.txt — ничего не ставлю" \
"lazydocker: the sha256 of ${asset} does not match checksums.txt — installing nothing"; exit 1
        fi
        mkdir "${tmp}/x" && tar -xzf "${tmp}/${asset}" -C "${tmp}/x" lazydocker 2>/dev/null || {
            log_error_t "lazydocker: в архиве нет бинарника lazydocker — ничего не ставлю" \
"lazydocker: no lazydocker binary in the archive — installing nothing"; exit 1; }
        install -m 755 "${tmp}/x/lazydocker" /usr/local/bin/lazydocker || {
            log_error_t "lazydocker: не удалось записать /usr/local/bin/lazydocker" \
"lazydocker: could not write /usr/local/bin/lazydocker"; exit 1; }
        log_success_t "lazydocker ${ver} установлен (sha256 проверен): запуск командой lazydocker" \
"lazydocker ${ver} installed (sha256 verified): run it with lazydocker"
    )
}

# docker_offer_lazydocker — спросить и поставить. Уже стоящий не переустанавливаем.
# В пакете без явного ответа (--lazydocker / LAZYDOCKER=Y) — НЕТ: ask_bulk_yn под
# --yes отвечал бы «да», а скачивать из сети бинарник в /usr/local/bin без
# явной просьбы пакетный прогон не должен
docker_offer_lazydocker() {
    if command -v lazydocker >/dev/null 2>&1; then
        log_info_t "lazydocker уже установлен" "lazydocker is already installed"
        return 0
    fi
    if [ "$BULK_MODE" = true ] && [ -z "${LAZYDOCKER_BULK:-}" ]; then
        log_info_t "lazydocker не ставлю: в пакетном режиме нужен флаг --lazydocker" \
"Not installing lazydocker: batch mode needs the --lazydocker flag"
        return 0
    fi
    ask_bulk_yn LAZYDOCKER_BULK "Поставить lazydocker (консольный интерфейс для Docker)?" "Install lazydocker (a terminal UI for Docker)?" N || return 0
    docker_install_lazydocker
}

# Группы docker может не быть, если Docker поставлен не отсюда (docker.io,
# вручную) — тогда usermod падает, а мы раньше всё равно писали «готово»
docker_add_user() {
    groupadd -f docker 2>/dev/null
    if usermod -aG docker "$TARGET_USER"; then
        log_info_t "Пользователь ${TARGET_USER} добавлен в группу docker — перелогинься для работы без sudo" \
"${TARGET_USER} added to the docker group — re-login to use it without sudo"
    else
        log_error_t "Не удалось добавить ${TARGET_USER} в группу docker" \
"Could not add ${TARGET_USER} to the docker group"
        return 1
    fi
}

apply_docker() {
    local start_rc=0
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
            # bulk-ok: работающий Docker уже применён и в пакет не попадает
            if [ "$enabled" != "enabled" ] && ask_yn_t "Включить автозапуск Docker при загрузке?" "Enable Docker autostart at boot?" N; then
                service_units docker
                systemctl enable "${REPLY_UNITS[@]}" >/dev/null 2>&1 && log_success_t "Автозапуск включён" \
"Autostart enabled"
            fi
        elif ask_bulk_yn DOCKER_AUTOSTART "Docker не запущен. Запустить и включить автозапуск?" "Docker is not running. Start it and enable autostart?" N; then
            apply_service_autostart docker true || start_rc=1
        else
            log_info_t "Оставляю Docker выключенным" \
"Leaving Docker switched off"
        fi
        # Docker мог приехать не отсюда (docker.io, ручная установка) — тогда
        # группы у пользователя нет, и sudo требуется на каждый docker-вызов
        # -x по строкам, а не -w: для grep дефис — граница слова, и группа
        # docker-users сходила бы за docker
        if [ "$TARGET_USER" != "root" ] && ! id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -x docker >/dev/null; then
            if ask_yn_t "Добавить ${TARGET_USER} в группу docker (работа без sudo)?" "Add ${TARGET_USER} to the docker group (use it without sudo)?" Y; then
                docker_add_user
            fi
        fi
        docker_offer_lazydocker
        return "$start_rc"
    fi

    if ! ask_yn_t "Установить Docker + Docker Compose (официальный репозиторий)?" "Install Docker + Docker Compose (official repository)?"; then return; fi
    # спрашиваем ДО установки — ответ решает, дать ли postinst поднять демон
    local autostart=false
    resolve_autostart_t DOCKER_AUTOSTART "Запустить Docker и включить автозапуск?" \
        "Start Docker and enable autostart?" && autostart=true

    t "Зависимости Docker" "Docker prerequisites"
    ensure_pkg "$REPLY_T" ca-certificates curl || return 1
    install -m 0755 -d /etc/apt/keyrings
    # У Docker отдельные ветки репозитория под каждый дистрибутив, и путь
    # различается только идентификатором: /linux/ubuntu против /linux/debian.
    # Проверено — обе отдают пакеты и для noble, и для bookworm с trixie
    local docker_repo="https://download.docker.com/linux/${OS_ID}"
    t "GPG-ключ Docker" "Docker GPG key"
    run_logged "$REPLY_T" \
        curl -fsSL "${docker_repo}/gpg" -o /etc/apt/keyrings/docker.asc || return 1
    chmod a+r /etc/apt/keyrings/docker.asc
    local codename="$OS_CODENAME"
    docker_write_repo "$docker_repo" "$codename"
    t "Списки пакетов Docker" "Docker package lists"
    run_logged "$REPLY_T" apt_get update -qq
    # grep БЕЗ -q — иначе SIGPIPE и вечно ложное условие, см. блок про ловушку
    # в начале файла. Здесь это и вскрылось: фолбэк срабатывал на каждой машине
    # В сухом прогоне repo-файл не записан и apt update не выполнялся —
    # кандидата нет по построению, и проверка рапортовала ложный провал
    if [ "$USFC_DRY_RUN" = true ]; then
        log_info_t "[сухой прогон] наличие пакетов в репозитории Docker не проверяется" \
"[dry run] not checking whether the Docker repository has packages"
    elif ! apt-cache policy docker-ce-cli 2>/dev/null | grep 'Candidate:.*[0-9]' >/dev/null; then
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
        t "Списки пакетов Docker (noble)" "Docker package lists (noble)"
        run_logged "$REPLY_T" apt_get update -qq
    fi
    with_no_service_start run_logged "Docker CE + Compose" \
        apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    refresh_pkg_cache

    apply_service_autostart docker "$autostart" || start_rc=1

    # под прямым root группа docker бессмысленна: root и так может всё,
    # а usermod -aG docker root только путает вывод
    if [ "$TARGET_USER" != "root" ]; then
        docker_add_user
    else
        log_info_t "Работаем от root — в группу docker никого не добавляю" \
"Running as root — not adding anyone to the docker group"
    fi
    log_success_t "Docker установлен: $(docker --version 2>/dev/null)" \
"Docker installed: $(docker --version 2>/dev/null)"
    docker_offer_lazydocker
    # установлен, но не запустился — пункт не выполнен, сводка должна это показать
    return "$start_rc"
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
