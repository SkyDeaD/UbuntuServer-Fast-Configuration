# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: TCP BBR ─────────────────────────────────────────────────────
usfc_item bbr система "TCP BBR" \
    "быстрее и ровнее TCP на каналах с потерями" \
    "TCP BBR" \
    "faster, steadier TCP on lossy links"
usfc_item_toggle bbr

usfc_item_full bbr "Включает алгоритм управления перегрузкой TCP BBR вместе с очередью fq.

Стандартный cubic воспринимает любую потерю пакета как перегрузку и
сбрасывает скорость; BBR ориентируется на измеренную пропускную способность
и задержку, поэтому на международных и мобильных каналах (обычная VPS) отдача
заметно ровнее. Особенно полезно для прокси, VPN и раздачи файлов.

Настройка пишется в /etc/sysctl.d/60-usfc-bbr.conf, модуль tcp_bbr
подгружается при загрузке (/etc/modules-load.d/usfc-bbr.conf). Работает только
если ядро умеет BBR; контейнеры делят ядро с хозяином и настроить его не могут." \
"Turns on the BBR TCP congestion control together with the fq queue.

The default cubic treats every lost packet as congestion and slows down; BBR
works from measured bandwidth and delay, so throughput on international and
mobile links (the usual VPS case) is noticeably steadier. Most useful for
proxies, VPNs and file serving.

The setting goes to /etc/sysctl.d/60-usfc-bbr.conf, and the tcp_bbr module is
loaded at boot (/etc/modules-load.d/usfc-bbr.conf). It only works when the
kernel supports BBR; containers share the host kernel and cannot change it."

usfc_item_rollback bbr "sudo rm -f /etc/sysctl.d/60-usfc-bbr.conf /etc/modules-load.d/usfc-bbr.conf
     sudo sysctl -w net.ipv4.tcp_congestion_control=cubic" \
"sudo rm -f /etc/sysctl.d/60-usfc-bbr.conf /etc/modules-load.d/usfc-bbr.conf
     sudo sysctl -w net.ipv4.tcp_congestion_control=cubic"

BBR_SYSCTL=/etc/sysctl.d/60-usfc-bbr.conf
BBR_MODLOAD=/etc/modules-load.d/usfc-bbr.conf

# → REPLY_BBR_KERNEL: ok | container | stale | absent. Как zram_module_state:
# bbr уже в списке доступных (вкомпилирован или модуль загружен) либо модуль
# лежит на диске и его можно подгрузить
REPLY_BBR_KERNEL=''
bbr_kernel_state() {
    local avail=''
    # контейнер — ПЕРВЫМ: в LXC список доступных алгоритмов — ядра хозяина и
    # содержит bbr, но sysctl net.core.default_qdisc из контейнера даёт EPERM,
    # и пункт писал бы файлы впустую, а потом падал на sysctl -p
    if systemd-detect-virt --container --quiet 2>/dev/null; then REPLY_BBR_KERNEL=container; return 0; fi
    avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
    if [[ " ${avail} " == *" bbr "* ]]; then REPLY_BBR_KERNEL=ok; return 0; fi
    if modinfo tcp_bbr >/dev/null 2>&1; then REPLY_BBR_KERNEL=ok; return 0; fi
    if [ ! -d "${USFC_MODULES_DIR:-/lib/modules}/$(uname -r)" ]; then REPLY_BBR_KERNEL=stale; return 0; fi
    REPLY_BBR_KERNEL=absent
    return 0
}

status_bbr() {
    local cc qd
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    qd="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    if [ "$cc" = bbr ]; then
        st "$GREEN" "✓ bbr + ${qd:-?}" "✓ bbr + ${qd:-?}"; return 0
    fi
    st "$DIM" "○ ${cc:-?}" "○ ${cc:-?}"; return 1
}

apply_bbr() {
    bbr_kernel_state
    case "$REPLY_BBR_KERNEL" in
        container)
            log_warn_t "Машина работает в контейнере: ядро общее с хозяином, BBR тут не включить" \
"This machine runs in a container: the kernel is shared with the host, BBR cannot be enabled here"
            return 1 ;;
        stale)
            log_warn_t "Ядро обновлено, а машина работает на старом ($(uname -r)) — каталога модулей для него нет" \
"The kernel was upgraded but the machine still runs the old one ($(uname -r)) — its module directory is gone"
            log_info_t "Перезагрузите сервер и прогоните пункт ещё раз" "Reboot the server and run this item again"
            return 1 ;;
        absent)
            log_error_t "Ядро $(uname -r) не поддерживает BBR (нет модуля tcp_bbr)" \
"Kernel $(uname -r) has no BBR support (no tcp_bbr module)"
            return 1 ;;
    esac

    # Свой файл не побеждает файл с большим номером: если кто-то уже задал
    # алгоритм в другом месте, после перезагрузки там может оказаться не bbr
    local other
    other="$(grep -lE '^[[:space:]]*net\.ipv4\.tcp_congestion_control' /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null | grep -vxF "$BBR_SYSCTL")"
    if [ -n "$other" ]; then
        log_warn_t "Алгоритм перегрузки уже задан в: $(echo "$other" | tr '\n' ' ')— проверь, что там не перебивает bbr" \
"The congestion control is also set in: $(echo "$other" | tr '\n' ' ')— check that nothing there overrides bbr"
    fi

    ask_yn_t "Включить TCP BBR (+ очередь fq)?" "Enable TCP BBR (+ the fq queue)?" Y || return 0

    write_file "$BBR_SYSCTL" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    write_file "$BBR_MODLOAD" <<'EOF'
tcp_bbr
EOF
    # без модуля sysctl на списке доступных алгоритмов отвергнет bbr
    modprobe tcp_bbr 2>/dev/null
    if ! sysctl -p "$BBR_SYSCTL" >/dev/null; then
        log_error_t "sysctl не принял настройки BBR" "sysctl rejected the BBR settings"
        return 1
    fi
    [ "$USFC_DRY_RUN" = true ] && return 0
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != bbr ]; then
        log_error_t "BBR не включился: алгоритм так и не стал bbr" "BBR did not turn on: the algorithm is still not bbr"
        return 1
    fi
    log_success_t "TCP BBR включён" "TCP BBR is on"
    log_info_t "Очередь fq применится к интерфейсам, которые поднимутся заново (после перезагрузки); BBR при этом работает уже сейчас" \
"The fq queue applies to interfaces brought up again (after a reboot); BBR itself works right now"
}

disable_bbr() {
    if [ ! -e "$BBR_SYSCTL" ] && [ ! -e "$BBR_MODLOAD" ] \
        && [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != bbr ]; then
        log_info_t "BBR не включён — нечего отключать" "BBR is not on — nothing to turn off"
        return 0
    fi
    ask_yn_t "Отключить BBR и вернуть cubic?" "Turn BBR off and go back to cubic?" N || return 0
    remove_file "$BBR_SYSCTL"
    remove_file "$BBR_MODLOAD"

    local avail algo=cubic
    avail="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
    [[ " ${avail} " == *" cubic "* ]] || algo=reno
    sysctl -w "net.ipv4.tcp_congestion_control=${algo}" >/dev/null
    log_success_t "Алгоритм перегрузки: ${algo}" "Congestion control: ${algo}"

    # Очередь по умолчанию системы берём из её же конфигов: в Ubuntu это
    # fq_codel (/etc/sysctl.d/10-bufferbloat.conf из procps). В Debian
    # значения в конфигах нет — там действует умолчание ядра, и угадывать его
    # не будем
    local q
    q="$(cat /usr/lib/sysctl.d/*.conf /etc/sysctl.d/*.conf /etc/sysctl.conf 2>/dev/null \
        | sed -nE 's/^[-[:space:]]*net\.core\.default_qdisc[[:space:]]*=[[:space:]]*([A-Za-z0-9_]+).*/\1/p' | tail -n1)"
    if [ -n "$q" ]; then
        sysctl -w "net.core.default_qdisc=${q}" >/dev/null
        log_success_t "Очередь по умолчанию: ${q}" "Default queue: ${q}"
    else
        log_info_t "В конфигах системы очередь по умолчанию не задана — после перезагрузки вернётся умолчание ядра (сейчас остаётся fq, он безвреден)" \
"The system configs set no default queue — the kernel default returns after a reboot (fq stays for now, it is harmless)"
    fi
}
