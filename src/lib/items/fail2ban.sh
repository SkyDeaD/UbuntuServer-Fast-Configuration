# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: fail2ban ─────────────────────────────────────────
usfc_item fail2ban защита "fail2ban" \
    "банит перебор паролей по SSH" \
    "fail2ban" \
    "bans SSH password guessing"
usfc_item_toggle fail2ban

FAIL2BAN_DROPIN="${FAIL2BAN_DROPIN:-/etc/fail2ban/jail.d/usfc-sshd.local}"

usfc_item_full fail2ban "Банит IP после нескольких неудачных попыток входа по SSH — защита от перебора
паролей.

Настраивается на реальный SSH-порт сервера, а не на захардкоженный 22." \
"Bans IP addresses that keep failing SSH authentication. Brute-forcing a
public server runs around the clock, and even with password login disabled
it fills the logs.

Configured for the actual SSH port, which the script reads from sshd -T
rather than assuming 22."


usfc_item_rollback fail2ban "sudo apt purge fail2ban
     sudo rm -rf /etc/fail2ban
     # заблокированные IP сбросятся вместе с базой в /var/lib/fail2ban" \
"sudo apt purge fail2ban
     sudo rm -rf /etc/fail2ban
     # banned IPs are lost together with the database in /var/lib/fail2ban"

status_fail2ban() {
    if ! systemctl is-active fail2ban &>/dev/null; then
        st "$DIM" "○ не запущен" "○ not running"; return 1
    fi
    # Сверяем порт нашего jail [sshd] с текущим SSH-портом: если порт сменили
    # в обход usfc, fail2ban молча продолжил бы сторожить старый
    if [ -f "$FAIL2BAN_DROPIN" ]; then
        local f2b_port='' port_ok=false p
        f2b_port="$(awk '
            /^[[:space:]]*\[/ { insec = ($0 ~ /^[[:space:]]*\[sshd\]/); next }
            insec && /^[[:space:]]*port[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); p = $0
            }
            END { print p }' "$FAIL2BAN_DROPIN" 2>/dev/null)"
        if [ -n "$f2b_port" ]; then
            for p in ${f2b_port//,/ }; do
                if [ "$p" = "$SSH_PORT" ] || [[ " ${SSHD_PORTS:-} " == *" ${p} "* ]]; then
                    port_ok=true; break
                fi
            done
            if [ "$port_ok" = false ]; then
                st "$YELLOW" "! запущен (порт ${f2b_port} ≠ SSH ${SSH_PORT})" \
                             "! running (port ${f2b_port} ≠ SSH ${SSH_PORT})"; return 1
            fi
        fi
    fi
    if command -v fail2ban-client >/dev/null 2>&1 \
       && fail2ban-client status >/dev/null 2>&1 \
       && ! fail2ban-client status sshd >/dev/null 2>&1; then
        st "$YELLOW" "! запущен (jail sshd не активен)" \
                     "! running (sshd jail inactive)"; return 1
    fi
    st "$GREEN" "✓ запущен" "✓ running"; return 0
}

apply_fail2ban() {
    if ! ask_yn_t "Установить fail2ban?" "Install fail2ban?"; then return; fi
    # python3-systemd на Debian 12 только в Recommends, а журнал нужен (ниже)
    ensure_pkg "fail2ban" fail2ban python3-systemd || return 1
    # Свой файл в jail.d, а не jail.local: тот принадлежит человеку (свои jail,
    # ignoreip, banaction), и раньше мы перезаписывали его целиком. jail.d/*.local
    # читается после jail.local — проверено fail2ban-client -d, — поэтому
    # перекрываем только [sshd], и все его ключи задаём сами.
    #
    # backend = systemd: на Debian 12 нет /var/log/auth.log (rsyslog не стоит),
    # а пакет журнал для sshd не включает — jail не находил лога и fail2ban не
    # стартовал. Юнит называется ssh.service (Debian/Ubuntu) или sshd.service,
    # процесс сеанса в OpenSSH 10 — sshd-session; «+» в journalmatch — это «или»
    write_file "$FAIL2BAN_DROPIN" <<EOF
# usfc: SSH brute-force jail. Put your own changes in jail.local or another jail.d file
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd + _COMM=sshd-session
maxretry = 5
findtime = 10m
bantime = 1h
bantime.increment = true
EOF
    if [ "$USFC_DRY_RUN" != true ] && ! fail2ban-client -t >/dev/null 2>&1; then
        remove_file "$FAIL2BAN_DROPIN"
        log_error_t "fail2ban отверг конфиг — файл убран. Проверка: fail2ban-client -t" \
"fail2ban rejected the config — file removed. Check: fail2ban-client -t"
        return 1
    fi
    # restart, а не enable --now: postinst уже запустил сервис со старым
    # конфигом, и --now на активном юните его не перечитывает — до
    # перезагрузки jail сторожил бы порт по умолчанию
    if ! systemctl enable fail2ban >/dev/null 2>&1 || ! systemctl restart fail2ban >/dev/null 2>&1; then
        log_error_t "fail2ban не запустился — подробности: journalctl -u fail2ban" \
"fail2ban did not start — details: journalctl -u fail2ban"
        return 1
    fi
    log_success_t "fail2ban установлен и настроен на порт ${SSH_PORT}" \
"fail2ban installed and watching port ${SSH_PORT}"
}

disable_fail2ban() {
    ask_yn_t "Остановить и выключить fail2ban?" "Stop and disable fail2ban?" N && { systemctl disable --now fail2ban &>/dev/null; log_success_t "fail2ban выключен" \
"fail2ban disabled"; }
}

