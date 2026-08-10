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
подождать несколько минут. Скрипт это учитывает и ждёт освобождения." \
"Installs security updates by itself, without your involvement.

The main argument for it is simple: a server nobody updates becomes
vulnerable through no fault of the software, just because a patch was
published and never applied.

Note that unattended-upgrades holds the dpkg lock while it works — that is
exactly why every apt call in this script waits for the lock instead of
failing instantly."


usfc_item_rollback unattended "sudo apt purge unattended-upgrades
     sudo rm -f /etc/apt/apt.conf.d/20auto-upgrades
     # security-обновления перестанут ставиться сами — придётся apt upgrade руками" \
"sudo apt purge unattended-upgrades
     sudo rm -f /etc/apt/apt.conf.d/20auto-upgrades
     # security updates stop installing themselves — you will need apt upgrade by hand"

status_unattended() {
    if [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
        st "$GREEN" "✓ включено" "✓ enabled"; return 0
    else
        st "$DIM" "○ выключено" "○ disabled"; return 1
    fi
}

apply_unattended() {
    if ! ask_yn_t "Включить автообновление security-патчей?" "Enable automatic security updates?"; then return; fi
    ensure_pkg "unattended-upgrades" unattended-upgrades || return 1
    write_file /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    systemctl enable --now unattended-upgrades >/dev/null
    log_success_t "unattended-upgrades включён" \
"unattended-upgrades enabled"
}

disable_unattended() {
    if ask_yn_t "Выключить unattended-upgrades?" "Disable unattended-upgrades?" N; then
        printf 'APT::Periodic::Update-Package-Lists "0";\nAPT::Periodic::Unattended-Upgrade "0";\n' | write_file /etc/apt/apt.conf.d/20auto-upgrades
        systemctl disable unattended-upgrades &>/dev/null || true
        log_success_t "unattended-upgrades выключен" \
"unattended-upgrades disabled"
    fi
}
