# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: fail2ban ─────────────────────────────────────────
usfc_item fail2ban защита "fail2ban" \
    "банит перебор паролей по SSH" \
    "fail2ban" \
    "bans SSH password guessing"
usfc_item_toggle fail2ban

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
    systemctl is-active fail2ban &>/dev/null \
        && { st "$GREEN" "✓ запущен" "✓ running"; return 0; } \
        || { st "$DIM" "○ не запущен" "○ not running"; return 1; }
}

apply_fail2ban() {
    if ! ask_yn_t "Установить fail2ban?" "Install fail2ban?"; then return; fi
    ensure_pkg "fail2ban" fail2ban || return 1
    write_file /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    systemctl enable --now fail2ban >/dev/null
    log_success_t "fail2ban установлен и настроен на порт ${SSH_PORT}" \
"fail2ban installed and watching port ${SSH_PORT}"
}

disable_fail2ban() {
    ask_yn_t "Остановить и выключить fail2ban?" "Stop and disable fail2ban?" N && { systemctl disable --now fail2ban &>/dev/null; log_success_t "fail2ban выключен" \
"fail2ban disabled"; }
}
