# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: unattended-upgrades ─────────────────────────────────────────
usfc_item unattended защита "unattended-upgrades" \
    "сам ставит security-обновления системы"
usfc_item_toggle unattended

usfc_item_full unattended "Сам ставит security-обновления системы, без твоего участия.

Полезно и одновременно коварно: именно unattended-upgrades держит блокировку
dpkg на только что загруженном сервере, из-за чего установка пакетов может
подождать несколько минут. Скрипт это учитывает и ждёт освобождения."


usfc_item_rollback unattended "sudo apt purge unattended-upgrades
     sudo rm -f /etc/apt/apt.conf.d/20auto-upgrades
     # security-обновления перестанут ставиться сами — придётся apt upgrade руками"

status_unattended() {
    if [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
        echo -e "${GREEN}✓ включено${NC}"; return 0
    else
        echo -e "${DIM}○ выключено${NC}"; return 1
    fi
}

apply_unattended() {
    if ! ask_yn "Включить автообновление security-патчей?"; then return; fi
    ensure_pkg "unattended-upgrades" unattended-upgrades || return 1
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    systemctl enable --now unattended-upgrades >/dev/null
    log_success "unattended-upgrades включён"
}

disable_unattended() {
    if ask_yn "Выключить unattended-upgrades?" N; then
        printf 'APT::Periodic::Update-Package-Lists "0";\nAPT::Periodic::Unattended-Upgrade "0";\n' > /etc/apt/apt.conf.d/20auto-upgrades
        systemctl disable unattended-upgrades &>/dev/null || true
        log_success "unattended-upgrades выключен"
    fi
}
