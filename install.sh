#!/bin/bash
# vps-setup — быстрая установка
# Использование: curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh | sudo bash && source ~/.bashrc
# "&& source ~/.bashrc" — не косметика: это выполняется уже в ТВОЕЙ оболочке
# (в отличие от того, что делает изнутри сам скрипт), поэтому реально
# подхватывает новые алиасы/промпт сразу после первой установки
set -e

REPO_RAW_BASE="https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/src"
INSTALL_DIR="/opt/vps-setup"

if [ "$(id -u)" -ne 0 ]; then
    echo "Запустите от root: curl -fsSL .../install.sh | sudo bash && source ~/.bashrc" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
curl -fsSL "${REPO_RAW_BASE}/setup.sh" -o "${INSTALL_DIR}/setup.sh"
chmod +x "${INSTALL_DIR}/setup.sh"
curl -fsSL "${REPO_RAW_BASE}/VERSION" -o "${INSTALL_DIR}/VERSION" || true
ln -sf "${INSTALL_DIR}/setup.sh" /usr/local/bin/usfc

echo "usfc установлен и готов к работе"
# Запускаем основной скрипт с stdin от терминала (нужно для интерактивных шагов, если появятся)
exec "${INSTALL_DIR}/setup.sh" </dev/tty
