# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: unattended-upgrades ─────────────────────────────────────────
usfc_item unattended защита "unattended-upgrades" \
    "сам ставит security-обновления системы" \
    "unattended-upgrades" \
    "installs security updates on its own"
usfc_item_toggle unattended

usfc_item_full unattended "Сам ставит security-обновления системы, без твоего участия.

Полезно и одновременно коварно: именно unattended-upgrades держит блокировку
dpkg на только что загруженном сервере, из-за чего установка пакетов может
подождать несколько минут. Скрипт это учитывает и ждёт освобождения.

Окно перезагрузки. Часть обновлений (ядро, libc) действует только после
перезагрузки. usfc может разрешить unattended-upgrades перезагружать сервер
само, в заданное время (ЧЧ:ММ, например 04:00); off — никогда. По умолчанию
перезагрузка не делается, если по SSH кто-то вошёл; это можно отменить.
Настройка пишется в свой файл /etc/apt/apt.conf.d/52usfc-reboot, файл
50unattended-upgrades не правится. Флаги: --reboot-time, --reboot-with-users." \
"Installs security updates by itself, without your involvement.

The main argument for it is simple: a server nobody updates becomes
vulnerable through no fault of the software, just because a patch was
published and never applied.

Note that unattended-upgrades holds the dpkg lock while it works — that is
exactly why every apt call in this script waits for the lock instead of
failing instantly.

Reboot window. Some updates (kernel, libc) only take effect after a reboot.
usfc can let unattended-upgrades reboot the server by itself at a set time
(HH:MM, for example 04:00); off means never. By default it will not reboot
while someone is logged in over SSH; you can override that. The setting goes
to its own file, /etc/apt/apt.conf.d/52usfc-reboot; 50unattended-upgrades is
left untouched. Flags: --reboot-time, --reboot-with-users."


usfc_item_rollback unattended "sudo apt purge unattended-upgrades
     sudo rm -f /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/52usfc-reboot
     # security-обновления перестанут ставиться сами — придётся apt upgrade руками" \
"sudo apt purge unattended-upgrades
     sudo rm -f /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/52usfc-reboot
     # security updates stop installing themselves — you will need apt upgrade by hand"

# Наш файл с окном перезагрузки. Имя 52 > 50unattended-upgrades: apt читает
# apt.conf.d по алфавиту, позже прочитанное побеждает, а в 50unattended-upgrades
# (Ubuntu 24.04, Debian 12) эти ключи закомментированы, то есть не мешают
UA_REBOOT_FILE="${UA_REBOOT_FILE:-/etc/apt/apt.conf.d/52usfc-reboot}"

# 0 — пакет стоит и автоустановка включена итогом по всем файлам apt.conf.d,
# а не одним 20auto-upgrades: более поздний drop-in с "0" её выключает.
# Пакет должен стоять — после purge файл мог остаться
_ua_enabled() {
    pkg_installed unattended-upgrades \
        && apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null | grep '"1"' >/dev/null
}

# → REPLY_UA_EFF: время автоперезагрузки по итогу всех файлов apt.conf.d
# (HH:MM или now) или пусто, если перезагрузка выключена
REPLY_UA_EFF=''
_ua_reboot_effective() {
    local d
    REPLY_UA_EFF=''
    d="$(apt-config dump Unattended-Upgrade 2>/dev/null)"
    printf '%s\n' "$d" | grep '^Unattended-Upgrade::Automatic-Reboot "true"' >/dev/null || return 0
    REPLY_UA_EFF="$(printf '%s\n' "$d" | sed -n 's/^Unattended-Upgrade::Automatic-Reboot-Time "\(.*\)";.*/\1/p' | tail -n1)"
    [ -n "$REPLY_UA_EFF" ] || REPLY_UA_EFF=now
}

# → REPLY_UA_TIME, REPLY_UA_USERS (true|false): что записано в НАШЕМ файле;
# пусто, если файла нет
REPLY_UA_TIME=''
REPLY_UA_USERS=''
_ua_reboot_read() {
    REPLY_UA_TIME=''; REPLY_UA_USERS=''
    [ -r "$UA_REBOOT_FILE" ] || return 0
    REPLY_UA_TIME="$(sed -n 's/^Unattended-Upgrade::Automatic-Reboot-Time "\(.*\)";.*/\1/p' "$UA_REBOOT_FILE" | tail -n1)"
    REPLY_UA_USERS="$(sed -n 's/^Unattended-Upgrade::Automatic-Reboot-WithUsers "\(.*\)";.*/\1/p' "$UA_REBOOT_FILE" | tail -n1)"
}

status_unattended() {
    if _ua_enabled; then
        _ua_reboot_effective
        if [ -n "$REPLY_UA_EFF" ]; then
            st "$GREEN" "✓ включено · ребут ${REPLY_UA_EFF}" "✓ enabled · reboot ${REPLY_UA_EFF}"
        else
            st "$GREEN" "✓ включено" "✓ enabled"
        fi
        return 0
    else
        st "$DIM" "○ выключено" "○ disabled"; return 1
    fi
}

# _ua_ask_time <дефолт> → REPLY_UA_TIME_NEW: ЧЧ:ММ или off. Верный ввод
# принимаем сразу; неверный в меню переспрашиваем, в пакете и после трёх
# попыток оставляем off. (ask_value_t тут не годится: он принимает только числа)
REPLY_UA_TIME_NEW=off
_ua_ask_time() {
    local def="$1" tries=0
    REPLY_UA_TIME_NEW=off
    while [ "$tries" -lt 3 ]; do
        tries=$((tries + 1))
        ask_text_t "Перезагружать сервер, когда обновлению это нужно? Время ЧЧ:ММ или off" \
"Reboot the server when an update needs it? Time HH:MM or off" "$def"
        if answer_normalize time "$REPLY_TEXT"; then
            REPLY_UA_TIME_NEW="$REPLY_ANS"; return 0
        fi
        log_warn_t "Не похоже на время: «${REPLY_TEXT}» — нужно ЧЧ:ММ (04:00) или off" \
"Not a valid time: \"${REPLY_TEXT}\" — use HH:MM (04:00) or off"
        [ "$BULK_MODE" = true ] && break
    done
    log_warn_t "Автоперезагрузку оставляю выключенной" "Leaving automatic reboot off"
    return 1
}

# Пакет: окно перезагрузки спрашивается заранее, если его не задали
# флагом или файлом ответов
preask_unattended() {
    local def
    if [ -z "$REBOOT_TIME_BULK" ]; then
        _ua_reboot_read
        def="${REPLY_UA_TIME:-off}"
        echo ""
        _ua_ask_time "$def"
        REBOOT_TIME_BULK="$REPLY_UA_TIME_NEW"
    fi
    if [ "$REBOOT_TIME_BULK" != off ] && [ -z "$REBOOT_WITH_USERS_BULK" ]; then
        _ua_reboot_read
        def=N; [ "$REPLY_UA_USERS" = true ] && def=Y
        ask_yn_t "Перезагружать, даже если кто-то вошёл по SSH?" \
"Reboot even if someone is logged in over SSH?" "$def" \
            && REBOOT_WITH_USERS_BULK=Y || REBOOT_WITH_USERS_BULK=N
    fi
    return 0
}

# Окно автоперезагрузки: свой файл 52usfc-reboot; off — файл удаляется
_ua_reboot_apply() {
    local def want users
    _ua_reboot_read
    # заготовленный ответ (флаг, файл ответов, предзапрос) сильнее прежнего значения
    def="${REBOOT_TIME_BULK:-${REPLY_UA_TIME:-off}}"
    _ua_ask_time "$def" || true
    want="$REPLY_UA_TIME_NEW"
    if [ "$want" = off ]; then
        if [ -e "$UA_REBOOT_FILE" ]; then
            remove_file "$UA_REBOOT_FILE"
            log_success_t "Автоперезагрузка выключена" "Automatic reboot turned off"
        fi
        return 0
    fi
    users=false
    def=N; [ "$REPLY_UA_USERS" = true ] && def=Y
    if ask_bulk_yn REBOOT_WITH_USERS_BULK "Перезагружать, даже если кто-то вошёл по SSH?" \
"Reboot even if someone is logged in over SSH?" "$def"; then users=true; fi
    write_file "$UA_REBOOT_FILE" <<EOF
// Managed by usfc: automatic reboot window for unattended-upgrades
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${want}";
Unattended-Upgrade::Automatic-Reboot-WithUsers "${users}";
EOF
    [ "${USFC_DRY_RUN:-false}" = true ] && return 0
    _ua_reboot_effective
    if [ "$REPLY_UA_EFF" != "$want" ]; then
        # свой файл не победил: чужой файл позже по алфавиту переопределяет ключ
        log_warn_t "Записал $(basename "$UA_REBOOT_FILE"), но другой файл в /etc/apt/apt.conf.d задаёт Automatic-Reboot иначе:" \
"Wrote $(basename "$UA_REBOOT_FILE"), but another file in /etc/apt/apt.conf.d sets Automatic-Reboot differently:"
        grep -l '^[^/#]*Automatic-Reboot' /etc/apt/apt.conf.d/* 2>/dev/null | grep -vF "$UA_REBOOT_FILE" | sed 's/^/      /'
        return 1
    fi
    log_success_t "Автоперезагрузка в ${want}, даже при вошедших по SSH: ${users}" \
"Automatic reboot at ${want}, even with SSH users logged in: ${users}"
}

_ua_enable() {
    if ! ask_yn_t "Включить автообновление security-патчей?" "Enable automatic security updates?"; then return 2; fi
    ensure_pkg "unattended-upgrades" unattended-upgrades || return 1
    write_file /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    if ! systemctl enable --now unattended-upgrades >/dev/null 2>&1; then
        log_error_t "Сервис unattended-upgrades не запустился — подробности: journalctl -u unattended-upgrades" \
"The unattended-upgrades service did not start — details: journalctl -u unattended-upgrades"
        return 1
    fi
    if ! apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null | grep '"1"' >/dev/null; then
        log_warn_t "Записал 20auto-upgrades, но другой файл в /etc/apt/apt.conf.d выключает автообновление:" \
"Wrote 20auto-upgrades, but another file in /etc/apt/apt.conf.d turns automatic updates off:"
        grep -l 'Unattended-Upgrade' /etc/apt/apt.conf.d/* 2>/dev/null | sed 's/^/      /'
        return 1
    fi
    log_success_t "unattended-upgrades включён" \
"unattended-upgrades enabled"
}

apply_unattended() {
    local rc=0
    # Уже включён, а в пакет пришло только окно перезагрузки (--reboot-time,
    # --reboot-with-users): filter_pending пропустил пункт ради него. Включать
    # нечего и согласия не нужно — меняем только окно
    if [ "$BULK_MODE" = true ] && [ -n "${REBOOT_TIME_BULK}${REBOOT_WITH_USERS_BULK}" ] && _ua_enabled; then
        _ua_reboot_apply
        return
    fi
    _ua_enable || rc=$?
    [ "$rc" -eq 2 ] && return 0
    [ "$rc" -eq 0 ] || return 1
    _ua_reboot_apply
}

disable_unattended() {
    if ask_yn_t "Выключить unattended-upgrades?" "Disable unattended-upgrades?" N; then
        # Выключаем только автоустановку. Update-Package-Lists "0" отключал бы
        # ежедневное обновление списков apt для всей системы — это шире, чем
        # обещает вопрос, и на эти списки опирается проверка свежести apt
        printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "0";\n' | write_file /etc/apt/apt.conf.d/20auto-upgrades
        remove_file "$UA_REBOOT_FILE"
        systemctl disable unattended-upgrades &>/dev/null || true
        log_success_t "unattended-upgrades выключен" \
"unattended-upgrades disabled"
    fi
}
