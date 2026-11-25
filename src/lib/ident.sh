# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── root / целевой пользователь ────────────────────────────────
# Справочные команды (version, help, list) работают без sudo, поэтому проверку
# прав и тяжёлый sshd -T не делаем на этапе source: их вызывает usfc_require_root
# в main() для команд, которым root действительно нужен.
TARGET_USER=""
TARGET_HOME=""

usfc_detect_target_user() {
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
    # работаем от текущего пользователя (под root это root — норма свежей виртуалки)
    if [ -z "$TARGET_USER" ] || ! id -u "$TARGET_USER" >/dev/null 2>&1; then
        if [ "$(id -u)" -eq 0 ]; then
            TARGET_USER=root
        else
            TARGET_USER="$(id -un 2>/dev/null || echo root)"
        fi
    fi
    TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
    if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
        if [ -n "${USFC_SOURCE_ONLY:-}" ] || [ "$(id -u)" -ne 0 ]; then
            TARGET_HOME="${HOME:-/root}"
        else
            echo "Could not determine the home directory of $TARGET_USER" >&2
            exit 1
        fi
    fi
}
usfc_detect_target_user

# sshd -T — не самый быстрый вызов, а нужен он в двух местах (порт при старте и
# passwordauthentication в status_sshhardening, который считается на каждой
# перерисовке меню). Разбираем один раз в глобальные, обновляем только после
# реальной правки конфига в apply_sshhardening()
#
# Читаем ВСЕ ключи, которые задаёт hardening, а не только пароль: раньше
# проверялся один passwordauthentication, и чужой drop-in с
# `PermitRootLogin yes` проходил незамеченным
# SSHD_PORTS — все порты через пробел в порядке sshd -T: директива Port
# аддитивна, и во время переноса порта (apply_sshhardening) их два. SSH_PORT —
# первый из них, то есть старый, по которому человек сейчас и сидит
SSH_PORT=22
SSHD_PORTS='22'
SSHD_PASSWORDAUTH=''
SSHD_PERMITROOT=''
SSHD_KBDINTERACTIVE=''
SSHD_PUBKEY=''
refresh_sshd_config() {
    local out key val
    out="$(sshd -T 2>/dev/null)"
    SSH_PORT=''; SSHD_PORTS=''; SSHD_PASSWORDAUTH=''; SSHD_PERMITROOT=''; SSHD_KBDINTERACTIVE=''; SSHD_PUBKEY=''
    while read -r key val _; do
        case "$key" in
            port)                          [ -z "$SSH_PORT" ] && SSH_PORT="$val"
                                           [[ " $SSHD_PORTS " == *" $val "* ]] || SSHD_PORTS="${SSHD_PORTS}${SSHD_PORTS:+ }${val}" ;;
            passwordauthentication)        SSHD_PASSWORDAUTH="$val" ;;
            permitrootlogin)               SSHD_PERMITROOT="$val" ;;
            kbdinteractiveauthentication)  SSHD_KBDINTERACTIVE="$val" ;;
            pubkeyauthentication)          SSHD_PUBKEY="$val" ;;
        esac
    done <<< "$out"
    [ -z "$SSH_PORT" ] && SSH_PORT=22
    [ -z "$SSHD_PORTS" ] && SSHD_PORTS="$SSH_PORT"
}

# Вызывается в main() перед действиями, которым нужен root.
# При USFC_SOURCE_ONLY=1 тесты сами вызывают refresh_sshd_config при нужде.
usfc_require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Нужны права root: sudo usfc / Root required: sudo usfc" >&2   # i18n-ok: может зваться до выбора языка, обе строки сразу
        exit 1
    fi
    usfc_detect_target_user
    refresh_sshd_config
}

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

VERSION="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]')"
[ -z "$VERSION" ] && VERSION="0.0.0"
