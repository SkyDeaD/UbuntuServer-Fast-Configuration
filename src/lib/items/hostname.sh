# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: имя сервера, часовой пояс, NTP ──────────────────────────────
usfc_item hostname система "Имя, время, NTP" \
    "имя сервера, часовой пояс, синхронизация времени" \
    "Hostname, time, NTP" \
    "server name, time zone, time synchronisation"

usfc_item_full hostname "Задаёт имя сервера, часовой пояс и включает синхронизацию времени.

Имя пишется через hostnamectl, а в /etc/hosts строка 127.0.1.1 приводится в
соответствие с ним — иначе sudo и часть служб при каждом вызове ждут
разрешения имени. Если стоит cloud-init, ему запрещается сбрасывать имя при
перезагрузке (preserve_hostname). Часовой пояс — timedatectl; вместо точного
названия можно ввести часть («mosc»), usfc покажет подходящие.

Время синхронизирует systemd-timesyncd. Если уже работает chrony или другой
NTP-демон, он остаётся как есть." \
"Sets the server name and time zone and turns on time synchronisation.

The name is set with hostnamectl, and the 127.0.1.1 line in /etc/hosts is
made to match it — otherwise sudo and some services stall on name lookups.
When cloud-init is installed it is told not to reset the name on reboot
(preserve_hostname). The time zone is set with timedatectl; instead of the
exact name you can type a part of it (\"mosc\") and usfc lists the matches.

Time is synchronised by systemd-timesyncd. If chrony or another NTP daemon
is already in place, it is left alone."

usfc_item_rollback hostname "sudo hostnamectl set-hostname <старое-имя>
     sudo timedatectl set-timezone <старый-пояс>
     sudo rm -f /etc/cloud/cloud.cfg.d/99-usfc-hostname.cfg
     # строку 127.0.1.1 в /etc/hosts верни из снимка: usfc → откат" \
"sudo hostnamectl set-hostname <old-name>
     sudo timedatectl set-timezone <old-zone>
     sudo rm -f /etc/cloud/cloud.cfg.d/99-usfc-hostname.cfg
     # restore the 127.0.1.1 line in /etc/hosts from the snapshot: usfc → rollback"

# ── Текущее состояние ────────────────────────────────────────────────────────
# systemd как init: без него (контейнер) timedatectl/hostnamectl не работают
_hn_systemd() { [ -d /run/systemd/system ]; }

# → REPLY_HN_TZ: текущий пояс или пусто
REPLY_HN_TZ=''
_hn_tz_now() {
    local v=''
    REPLY_HN_TZ=''
    if _hn_systemd; then
        v="$(timedatectl show -p Timezone --value 2>/dev/null)"
    fi
    # без systemd: /etc/timezone (Debian), затем симлинк /etc/localtime (Ubuntu)
    if [ -z "$v" ] && [ -r /etc/timezone ]; then v="$(head -n1 /etc/timezone 2>/dev/null)"; fi
    # мусор в /etc/timezone (бывает в образах контейнеров) не принимаем на веру
    valid_timezone "$v" || v=''
    if [ -z "$v" ] && [ -L /etc/localtime ]; then
        v="$(readlink /etc/localtime 2>/dev/null)"; v="${v##*/zoneinfo/}"
        valid_timezone "$v" || v=''
    fi
    REPLY_HN_TZ="$v"
}

# → REPLY_HN_NTP: other (chrony, ntp…) | timesyncd | off
# Другой демон ищем по пакету, а не по активности: остановленный chrony
# тоже нельзя затирать установкой timesyncd — они конфликтуют (time-daemon)
REPLY_HN_NTP=off
_hn_ntp_now() {
    local p
    REPLY_HN_NTP=off
    for p in chrony ntp ntpsec openntpd; do
        if pkg_installed "$p"; then REPLY_HN_NTP=other; return 0; fi
    done
    _hn_systemd || return 0
    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then REPLY_HN_NTP=timesyncd; fi
}

# 0 — в /etc/hosts есть 127.0.1.1 с текущим именем
_hn_hosts_ok() {
    local h="${1:-}"
    [ -n "$h" ] && [ -r /etc/hosts ] || return 1
    awk -v h="$h" '$1 == "127.0.1.1" { for (i = 2; i <= NF; i++) if ($i == h) ok = 1 } END { exit !ok }' /etc/hosts
}

status_hostname() {
    local h tz
    h="$(hostname 2>/dev/null)"
    _hn_tz_now; tz="$REPLY_HN_TZ"
    _hn_ntp_now
    local label="$h"
    [ -n "$tz" ] && label="${h} · ${tz}"
    if ! _hn_hosts_ok "$h"; then
        st "$YELLOW" "! ${label} · нет 127.0.1.1" "! ${label} · no 127.0.1.1"; return 1
    fi
    if [ "$REPLY_HN_NTP" = off ]; then
        st "$YELLOW" "! ${label} · NTP выкл" "! ${label} · NTP off"; return 1
    fi
    st "$GREEN" "✓ ${label}" "✓ ${label}"; return 0
}

# ── Вопросы ──────────────────────────────────────────────────────────────────
# _hn_tz_matches <часть> — до 10 поясов, в имени которых есть эта часть
# (без учёта регистра; пробел == «_», как в «New York»)
_hn_tz_matches() {
    local q="${1// /_}" list
    if _hn_systemd && list="$(timedatectl list-timezones 2>/dev/null)" && [ -n "$list" ]; then
        :
    else
        list="$(cd /usr/share/zoneinfo 2>/dev/null && find . -type f 2>/dev/null | sed 's|^\./||' | grep -E '^[A-Z]' | grep -vE '^(posix|right)/')"
    fi
    printf '%s\n' "$list" | grep -iF -- "$q" | head -n 10
}

# _hn_ask_name <дефолт> → REPLY_HN: допустимое имя или пусто («не менять»).
# В меню при ошибке переспрашивает; в пакете ask_text вернёт дефолт и цикл
# закончится сам
REPLY_HN=''
_hn_ask_name() {
    local def="$1" tries=0 v
    REPLY_HN=''
    while [ "$tries" -lt 5 ]; do
        tries=$((tries + 1))
        ask_text_t "Имя сервера (hostname)?" "Server hostname?" "$def"
        v="${REPLY_TEXT,,}"
        [ -n "$v" ] || return 0
        if valid_hostname "$v"; then REPLY_HN="$v"; return 0; fi
        log_warn_t "Недопустимое имя «${v}»: буквы, цифры, дефис и точки, дефис не с краю" \
"Invalid name \"${v}\": letters, digits, hyphens and dots, no hyphen at either end"
        [ "$BULK_MODE" = true ] && return 1
    done
    return 1
}

# _hn_ask_tz <дефолт> → REPLY_HN: допустимый пояс или пусто. Не нашёл —
# показывает совпадения по введённому и спрашивает снова
_hn_ask_tz() {
    local def="$1" tries=0 v m
    REPLY_HN=''
    while [ "$tries" -lt 5 ]; do
        tries=$((tries + 1))
        ask_text_t "Часовой пояс (Europe/Moscow, UTC; можно часть названия)?" \
"Time zone (Europe/Moscow, UTC; part of the name works)?" "$def"
        v="$REPLY_TEXT"
        [ -n "$v" ] || return 0
        if valid_timezone "$v"; then REPLY_HN="$v"; return 0; fi
        log_warn_t "Нет часового пояса «${v}»" "No time zone \"${v}\""
        [ "$BULK_MODE" = true ] && return 1
        m="$(_hn_tz_matches "$v")"
        if [ -n "$m" ]; then
            log_info_t "Похожие:" "Similar:"
            while IFS= read -r v; do printf '      %s\n' "$v"; done <<< "$m"
        else
            log_info_t "Ничего похожего не нашлось — попробуй часть названия города" \
"Nothing similar found — try a part of the city name"
        fi
    done
    return 1
}

# Пакет: имя и пояс спрашиваются заранее, если их не задали флагом или файлом
preask_hostname() {
    local cur tz
    if [ -z "$HOSTNAME_BULK" ]; then
        cur="$(hostname 2>/dev/null)"
        echo ""
        _hn_ask_name "$cur" && HOSTNAME_BULK="$REPLY_HN"
    fi
    if [ -z "$TIMEZONE_BULK" ]; then
        _hn_tz_now; tz="$REPLY_HN_TZ"
        _hn_ask_tz "$tz" && TIMEZONE_BULK="$REPLY_HN"
    fi
    return 0
}

# ── Имя и /etc/hosts ────────────────────────────────────────────────────────
# Строка 127.0.1.1: заменяет существующую (лишние дубли убирает), иначе
# добавляется в конец. Формат «полное короткое» — как в шаблоне cloud-init
_hn_write_hosts() {
    local want="$1" short="${1%%.*}" line tmp rc=0
    line="127.0.1.1 ${want}"
    [ "$short" != "$want" ] && line="${line} ${short}"
    tmp="$(mktemp)" || return 1
    if [ -f /etc/hosts ]; then
        awk -v line="$line" '
            $1 == "127.0.1.1" { if (!done) { print line; done = 1 } ; next }
            { print }
            END { if (!done) print line }' /etc/hosts > "$tmp"
    else
        printf '%s\n' "$line" > "$tmp"
    fi
    if cmp -s "$tmp" /etc/hosts 2>/dev/null; then
        rm -f "$tmp"; return 0
    fi
    write_file /etc/hosts < "$tmp" || rc=1
    rm -f "$tmp"
    return "$rc"
}

# cloud-init при каждой загрузке выставляет имя из метаданных провайдера
# (модули set_hostname/update_hostname) — без preserve_hostname наше имя
# к следующей перезагрузке пропадёт. Отдельная беда — manage_etc_hosts:
# true/localhost: модуль update_etc_hosts на каждой загрузке переписывает
# /etc/hosts по имени из метаданных и затирает нашу строку
# Пути переопределяются переменными (тест работает во временном каталоге)
HN_CLOUD_ETC="${HN_CLOUD_ETC:-/etc/cloud}"
HN_CLOUD_LIB="${HN_CLOUD_LIB:-/var/lib/cloud}"
_hn_cloud_init() {
    [ -f "${HN_CLOUD_ETC}/cloud.cfg" ] || return 0
    local tmp rc=0 mgmt=''
    mgmt="$(cat "${HN_CLOUD_ETC}/cloud.cfg" "${HN_CLOUD_ETC}"/cloud.cfg.d/*.cfg "${HN_CLOUD_LIB}/instance/cloud-config.txt" 2>/dev/null \
        | grep -E '^[[:space:]]*manage_etc_hosts:[[:space:]]*(true|yes|on|1|localhost|template)' | grep -v '^[[:space:]]*#')"
    tmp="$(mktemp)" || return 1
    {
        echo "# Создано usfc: cloud-init не должен сбрасывать имя сервера при перезагрузке"   # i18n-ok: служебный файл, не интерфейс
        echo "preserve_hostname: true"
        if [ -n "$mgmt" ]; then
            echo "# и не должен переписывать /etc/hosts по имени из метаданных"   # i18n-ok: служебный файл, не интерфейс
            echo "manage_etc_hosts: false"
        fi
    } > "$tmp"
    if ! cmp -s "$tmp" "${HN_CLOUD_ETC}/cloud.cfg.d/99-usfc-hostname.cfg" 2>/dev/null; then
        mkdir -p "${HN_CLOUD_ETC}/cloud.cfg.d"
        write_file "${HN_CLOUD_ETC}/cloud.cfg.d/99-usfc-hostname.cfg" < "$tmp" || rc=1
        [ "$rc" -eq 0 ] && log_success_t "cloud-init: имя не будет сбрасываться при перезагрузке (preserve_hostname)" \
"cloud-init: the name will survive reboots (preserve_hostname)"
    fi
    rm -f "$tmp"
    if [ -n "$mgmt" ] && grep -qE 'manage_etc_hosts' "${HN_CLOUD_LIB}/instance/cloud-config.txt" 2>/dev/null; then
        log_warn_t "manage_etc_hosts включён в user-data провайдера — он сильнее нашего файла; если после перезагрузки в /etc/hosts пропадёт строка 127.0.1.1, выключи его в панели провайдера" \
"manage_etc_hosts is set in the provider's user-data, which outranks our file; if the 127.0.1.1 line vanishes from /etc/hosts after a reboot, turn it off in the provider panel"
    fi
    return "$rc"
}

_hn_apply_name() {
    local cur def
    cur="$(hostname 2>/dev/null)"
    def="${HOSTNAME_BULK:-$cur}"
    _hn_ask_name "$def" || return 1
    if [ -z "$REPLY_HN" ]; then
        log_info_t "Имя не задано — не меняю" "No name given — leaving it as is"
        return 0
    fi
    local want="$REPLY_HN"
    if [ "$want" != "$cur" ]; then
        if ! hostnamectl set-hostname "$want"; then
            log_error_t "hostnamectl не смог задать имя (нужен systemd)" \
"hostnamectl could not set the name (systemd is required)"
            return 1
        fi
        log_success_t "Имя сервера: ${want}" "Server hostname: ${want}"
    else
        log_info_t "Имя уже ${want}" "The name is already ${want}"
    fi
    _hn_write_hosts "$want" || { log_error_t "Не удалось обновить /etc/hosts" "Could not update /etc/hosts"; return 1; }
    # всегда, а не только при смене имени: если имя уже задано руками, cloud-init
    # без preserve_hostname вернёт имя из метаданных после перезагрузки
    # (функция идемпотентна: файл переписывается, только если содержимое иное)
    _hn_cloud_init || return 1
    return 0
}

# ── Часовой пояс ────────────────────────────────────────────────────────────
_hn_apply_tz() {
    local cur def
    # без tzdata нет списка поясов вообще (минимальные образы Debian)
    if [ ! -d /usr/share/zoneinfo ]; then
        ensure_pkg "tzdata" tzdata || return 1
    fi
    _hn_tz_now; cur="$REPLY_HN_TZ"
    def="${TIMEZONE_BULK:-$cur}"
    _hn_ask_tz "$def" || return 1
    if [ -z "$REPLY_HN" ]; then
        log_info_t "Пояс не задан — не меняю" "No time zone given — leaving it as is"
        return 0
    fi
    if [ "$REPLY_HN" = "$cur" ]; then
        log_info_t "Часовой пояс уже ${cur}" "The time zone is already ${cur}"
        return 0
    fi
    if ! _hn_systemd; then
        log_warn_t "systemd не запущен (контейнер?) — часовой пояс не изменён" \
"systemd is not running (a container?) — the time zone was not changed"
        return 1
    fi
    if ! timedatectl set-timezone "$REPLY_HN"; then
        log_error_t "timedatectl не смог задать пояс ${REPLY_HN}" "timedatectl could not set the zone ${REPLY_HN}"
        return 1
    fi
    log_success_t "Часовой пояс: ${REPLY_HN}" "Time zone: ${REPLY_HN}"
}

# ── NTP ──────────────────────────────────────────────────────────────────────
_hn_apply_ntp() {
    _hn_ntp_now
    if [ "$REPLY_HN_NTP" = other ]; then
        log_info_t "Время уже синхронизирует другой NTP-демон (chrony/ntp) — не трогаю" \
"Another NTP daemon (chrony/ntp) already handles time — leaving it alone"
        return 0
    fi
    if ! _hn_systemd; then
        log_warn_t "systemd не запущен (контейнер?) — синхронизацию времени не включить" \
"systemd is not running (a container?) — cannot enable time synchronisation"
        return 1
    fi
    # с systemd 255 (Ubuntu 24.04) и в Debian timesyncd — отдельный пакет
    ensure_pkg "systemd-timesyncd" systemd-timesyncd || return 1
    if ! timedatectl set-ntp true; then
        log_error_t "timedatectl set-ntp не сработал" "timedatectl set-ntp failed"
        return 1
    fi
    log_success_t "Синхронизация времени включена (systemd-timesyncd)" \
"Time synchronisation is on (systemd-timesyncd)"
}

apply_hostname() {
    local h tz rc=0
    h="$(hostname 2>/dev/null)"; _hn_tz_now; tz="$REPLY_HN_TZ"; _hn_ntp_now
    log_info_t "Сейчас: имя ${BOLD}${h}${NC}, пояс ${BOLD}${tz:-?}${NC}, NTP ${REPLY_HN_NTP}" \
"Now: name ${BOLD}${h}${NC}, zone ${BOLD}${tz:-?}${NC}, NTP ${REPLY_HN_NTP}"
    _hn_apply_name || rc=1
    _hn_apply_tz || rc=1
    _hn_apply_ntp || rc=1
    return "$rc"
}
