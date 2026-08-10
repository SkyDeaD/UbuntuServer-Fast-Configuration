# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── root / целевой пользователь ────────────────────────────────
# root нужен, чтобы что-то ДЕЛАТЬ. Просто загрузить функции (тесты, CI) можно и
# без него — иначе линтер пришлось бы гонять от root на ровном месте
if [ "$(id -u)" -ne 0 ] && [ -z "${USFC_SOURCE_ONLY:-}" ]; then
    echo "Root required: curl -fsSL .../install.sh | sudo bash && source ~/.bashrc" >&2
    exit 1
fi

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
else
    # ОСТОРОЖНО с logname: когда login-сессии нет (консоль хостера на свежей VPS,
    # cloud-init, запуск из systemd-юнита), он печатает "no login name" в stderr
    # и выходит с кодом НОЛЬ. То есть "logname || echo root" не спасает: подстановка
    # молча даёт пустую строку, и дальше скрипт падал на getent с пустым именем —
    # ровно на том сценарии голого root, ради которого всё и затевалось.
    TARGET_USER="$(logname 2>/dev/null)"
fi
# нет имени или такого пользователя не существует — значит login-сессии нет,
# работаем от root: это нормальное состояние свежей виртуалки, а не ошибка
if [ -z "$TARGET_USER" ] || ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    TARGET_USER=root
fi
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    if [ -n "${USFC_SOURCE_ONLY:-}" ]; then
        TARGET_HOME="${HOME:-/root}"
    else
        echo "Could not determine the home directory of $TARGET_USER" >&2
        exit 1
    fi
fi

# sshd -T — не самый быстрый вызов, а нужен он в двух местах (порт при старте и
# passwordauthentication в status_sshhardening, который считается на каждой
# перерисовке меню). Разбираем один раз в глобальные, обновляем только после
# реальной правки конфига в apply_sshhardening()
SSH_PORT=22
SSHD_PASSWORDAUTH=''
refresh_sshd_config() {
    local out key val
    out="$(sshd -T 2>/dev/null)"
    SSH_PORT=''; SSHD_PASSWORDAUTH=''
    while read -r key val _; do
        case "$key" in
            port)                   [ -z "$SSH_PORT" ] && SSH_PORT="$val" ;;
            passwordauthentication) SSHD_PASSWORDAUTH="$val" ;;
        esac
    done <<< "$out"
    [ -z "$SSH_PORT" ] && SSH_PORT=22
}
refresh_sshd_config

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

VERSION="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]')"
[ -z "$VERSION" ] && VERSION="0.0.0"
