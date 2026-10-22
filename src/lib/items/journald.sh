# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: лимит журнала systemd ───────────────────────────────────────
usfc_item journald защита "Лимит журнала systemd" \
    "ограничивает размер journald, чтобы не съел диск" \
    "systemd journal cap" \
    "caps journald size so it cannot eat the disk"
usfc_item_toggle journald

usfc_item_full journald "Ограничивает объём журнала systemd (journald).

По умолчанию journald занимает до 10% диска (но не больше 4 ГБ). На маленькой
VPS это лишние гигабайты логов, которых никто не читает. usfc задаёт
SystemMaxUse в /etc/systemd/journald.conf.d/usfc.conf: по умолчанию 5% диска,
но от 100 до 1000 МБ, минимум 50. Журнал сразу сжимается до лимита." \
"Caps the size of the systemd journal (journald).

By default journald may take up to 10% of the disk (but not more than 4 GB).
On a small VPS that is gigabytes of logs nobody reads. usfc sets SystemMaxUse
in /etc/systemd/journald.conf.d/usfc.conf: 5% of the disk by default, kept
between 100 and 1000 MB, 50 at the very least. The journal is trimmed to the
cap right away."

usfc_item_rollback journald "sudo rm -f /etc/systemd/journald.conf.d/usfc.conf
     sudo systemctl restart systemd-journald" \
"sudo rm -f /etc/systemd/journald.conf.d/usfc.conf
     sudo systemctl restart systemd-journald"

JOURNALD_DROPIN=/etc/systemd/journald.conf.d/usfc.conf

# → REPLY_JD_USED: «48.0M» из journalctl --disk-usage или пусто
REPLY_JD_USED=''
_jd_usage() {
    local out=''
    REPLY_JD_USED=''
    command -v journalctl >/dev/null 2>&1 || return 0
    out="$(timeout 5 journalctl --disk-usage 2>/dev/null)"
    if [[ "$out" =~ take\ up\ ([0-9.]+[BKMGT]) ]]; then REPLY_JD_USED="${BASH_REMATCH[1]}"; fi
    return 0
}

# → REPLY_JD_DEF: 5% корневой ФС в МБ, но не меньше 100 и не больше 1000
REPLY_JD_DEF=100
_jd_default_mb() {
    local total
    total="$(df -Pm / 2>/dev/null | awk 'NR == 2 { print $2 }')"
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    REPLY_JD_DEF=$((total * 5 / 100))
    [ "$REPLY_JD_DEF" -lt 100 ] && REPLY_JD_DEF=100
    [ "$REPLY_JD_DEF" -gt 1000 ] && REPLY_JD_DEF=1000
    return 0
}

status_journald() {
    local cap=''
    if [ -f "$JOURNALD_DROPIN" ]; then
        cap="$(sed -nE 's/^[[:space:]]*SystemMaxUse=([^[:space:]]+).*/\1/p' "$JOURNALD_DROPIN" | tail -n1)"
    fi
    _jd_usage
    local used=''
    [ -n "$REPLY_JD_USED" ] && used=" · ${REPLY_JD_USED}"
    if [ -n "$cap" ]; then
        st "$GREEN" "✓ лимит ${cap}${used}" "✓ cap ${cap}${used}"; return 0
    fi
    st "$DIM" "○ не задан${used}" "○ not set${used}"; return 1
}

# Реальный рестарт и сжатие возможны только под systemd: в контейнере
# journald нет, и писать «перезапущен» было бы враньём
_jd_restart() {
    if [ ! -d /run/systemd/system ]; then
        log_warn_t "systemd не запущен (контейнер?) — journald не перезапущен, лимит применится при его старте" \
"systemd is not running (a container?) — journald was not restarted, the cap applies when it starts"
        return 1
    fi
    if ! systemctl restart systemd-journald; then
        log_error_t "Не удалось перезапустить systemd-journald" "Could not restart systemd-journald"
        return 1
    fi
    return 0
}

apply_journald() {
    _jd_default_mb
    local mb
    mb="$(ask_value_t "Лимит журнала systemd, МБ?" "systemd journal cap, MB?" "${JOURNAL_MAX_BULK:-$REPLY_JD_DEF}")"
    [[ "$mb" =~ ^[0-9]+$ ]] || mb="$REPLY_JD_DEF"
    mb=$((10#$mb))
    if [ "$mb" -lt 50 ]; then
        log_warn_t "Меньше 50 МБ journald не удержит — ставлю 50" \
"journald cannot work in under 50 MB — using 50"
        mb=50
    fi

    mkdir -p /etc/systemd/journald.conf.d
    write_file "$JOURNALD_DROPIN" <<EOF
[Journal]
SystemMaxUse=${mb}M
EOF
    log_success_t "Лимит журнала: ${mb} МБ" "Journal cap: ${mb} MB"

    _jd_usage
    [ -n "$REPLY_JD_USED" ] && log_info_t "Сейчас журнал занимает ${REPLY_JD_USED}" "The journal currently takes ${REPLY_JD_USED}"
    _jd_restart || return 1
    # vacuum удаляет файлы; в сухом прогоне run_logged только печатает команду
    # (журнал не трогается), поэтому отдельного условия не нужно
    run_logged "journalctl --vacuum-size" journalctl "--vacuum-size=${mb}M" || return 1
    _jd_usage
    [ -n "$REPLY_JD_USED" ] && log_info_t "После сжатия: ${REPLY_JD_USED}" "After trimming: ${REPLY_JD_USED}"
    return 0
}

disable_journald() {
    if [ ! -f "$JOURNALD_DROPIN" ]; then
        log_info_t "Лимит не задан — нечего убирать" "No cap is set — nothing to remove"
        return 0
    fi
    ask_yn_t "Убрать лимит журнала и вернуть умолчания systemd?" "Remove the journal cap and go back to the systemd defaults?" N || return 0
    remove_file "$JOURNALD_DROPIN"
    # пустой каталог не оставляем: rmdir не тронет непустой
    [ "$USFC_DRY_RUN" = true ] || rmdir /etc/systemd/journald.conf.d 2>/dev/null
    log_success_t "Лимит убран" "Cap removed"
    _jd_restart
    return 0
}
