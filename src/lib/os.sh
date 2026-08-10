# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# Определение дистрибутива
# ═══════════════════════════════════════════════════════════════
# Раньше проверки ОС не было вообще: /etc/os-release читался только ради
# строчки в шапке. На чужой системе скрипт падал где-то в середине с невнятной
# ошибкой вместо честного «не поддерживается» — а часть пунктов к тому моменту
# уже успевала что-то сделать.
#
# ВАЖНО: /etc/os-release нельзя просто `source` — там есть переменная VERSION,
# которая затрёт версию самого скрипта. Разбираем построчно.
OS_ID=""
OS_CODENAME=""
OS_VERSION_ID=""
OS_PRETTY=""

detect_os() {
    local k v ubuntu_codename=""
    OS_ID=""; OS_CODENAME=""; OS_VERSION_ID=""; OS_PRETTY=""
    while IFS='=' read -r k v; do
        v="${v%\"}"; v="${v#\"}"
        case "$k" in
            ID)               OS_ID="$v" ;;
            VERSION_ID)       OS_VERSION_ID="$v" ;;
            VERSION_CODENAME) OS_CODENAME="$v" ;;
            UBUNTU_CODENAME)  ubuntu_codename="$v" ;;
            PRETTY_NAME)      OS_PRETTY="$v" ;;
        esac
    done < /etc/os-release 2>/dev/null
    # На Ubuntu предпочитаем UBUNTU_CODENAME — так было и раньше в apply_docker.
    # На Debian его нет вовсе, остаётся VERSION_CODENAME (bookworm/trixie).
    [ -n "$ubuntu_codename" ] && OS_CODENAME="$ubuntu_codename"
    return 0
}

os_is_ubuntu() { [ "$OS_ID" = "ubuntu" ]; }
os_is_debian() { [ "$OS_ID" = "debian" ]; }

# os_version_at_least <версия> — сравнение VERSION_ID через sort -V.
# Нужно там, где пакет появился в репозиториях начиная с какого-то выпуска
# (например, fastfetch в Debian 13).
os_version_at_least() {
    local want="$1" newest
    [ -n "$OS_VERSION_ID" ] || return 1
    newest="$(printf '%s\n%s\n' "$OS_VERSION_ID" "$want" | sort -V | tail -n1)"
    [ "$newest" = "$OS_VERSION_ID" ]
}

# Гейт. Ubuntu и Debian проверяются, остальное — на усмотрение пользователя,
# и то лишь когда есть apt: без него ставить пакеты просто нечем.
require_supported_os() {
    case "$OS_ID" in
        ubuntu|debian) return 0 ;;
    esac
    echo ""
    if ! command -v apt-get >/dev/null 2>&1; then
        log_error "usfc рассчитан на Ubuntu и Debian, а здесь ${OS_PRETTY:-неизвестная система}"
        log_info "apt-get не найден — ставить пакеты нечем, прекращаю"
        return 1
    fi
    log_warn "Система ${OS_PRETTY:-?} ${DIM}(ID=${OS_ID:-?})${NC} не проверялась"
    log_info "usfc рассчитан на Ubuntu и Debian. apt на месте, так что многое"
    log_info "скорее всего сработает, но ручаться за это я не могу"
    ask_yn "Продолжить на свой риск?" N
}

# Определяем сразу при загрузке: OS_* читают и шапка, и пункты меню, а стоит
# это одно чтение файла. Гейт при этом отдельный — его зовёт main(), потому что
# он задаёт вопросы и умеет прерывать работу.
detect_os
