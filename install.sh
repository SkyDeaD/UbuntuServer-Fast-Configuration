#!/bin/bash
# usfc — быстрая установка
# Использование: curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh | sudo bash && source ~/.bashrc
# "&& source ~/.bashrc" — не косметика: это выполняется уже в ТВОЕЙ оболочке
# (в отличие от того, что делает изнутри сам скрипт), поэтому реально
# подхватывает новые алиасы/промпт сразу после первой установки
set -uo pipefail

REPO="SkyDeaD/UbuntuServer-Fast-Configuration"
INSTALL_DIR="/opt/vps-setup"
BRANCH="${USFC_BRANCH:-main}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        -b|--branch)
            [ -n "${2:-}" ] || { echo "--branch требует имя ветки" >&2; exit 2; }
            BRANCH="$2"; shift 2 ;;
        --branch=*) BRANCH="${1#*=}"; shift ;;
        -h|--help)
            echo "Использование: install.sh [--branch <ветка>]"
            echo "  --branch  ставить из указанной ветки (по умолчанию main)"
            exit 0 ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
done

RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}/src"

if [ "$(id -u)" -ne 0 ]; then
    echo "Запустите от root: curl -fsSL .../install.sh | sudo bash && source ~/.bashrc" >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "  curl не найден, ставлю..."
    apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq curl >/dev/null 2>&1
    command -v curl >/dev/null 2>&1 || { echo "  Не удалось поставить curl" >&2; exit 1; }
fi

# ── Загрузка ─────────────────────────────────────────────────────────────────
# Ставим в отдельный каталог и переносим на место одним движением в конце.
# Иначе оборванная на середине установка оставила бы половину модулей —
# то есть точку входа, которая грузит несуществующие файлы.
STAGE="$(mktemp -d)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

fetch() {  # fetch <хвост пути> <куда>
    local rel="$1" dest="$2" tmp
    tmp="$(mktemp)" || return 1
    if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 30 "${RAW}/${rel}" -o "$tmp" 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    case "$rel" in
        *.sh) bash -n "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; } ;;
    esac
    mkdir -p "$(dirname "$dest")" && mv "$tmp" "$dest"
}

echo ""
echo "  usfc — установка"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[ "$BRANCH" != "main" ] && echo "  Ветка: ${BRANCH}"
echo ""

for f in setup.sh VERSION MODULES; do
    if ! fetch "$f" "${STAGE}/${f}"; then
        echo "  Не удалось скачать ${f}. Проверьте сеть и доступность github.com" >&2
        exit 1
    fi
done

# Список модулей — из скачанного манифеста, а не зашитый здесь: иначе
# установщик разойдётся с репозиторием при первом же добавлении модуля
MODULES=()
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    MODULES+=("$line")
done < "${STAGE}/MODULES"

if [ "${#MODULES[@]}" -eq 0 ]; then
    echo "  Пустой список модулей — установка прервана" >&2
    exit 1
fi

echo "  Скачивание модулей..."
i=0
for m in "${MODULES[@]}"; do
    i=$((i + 1))
    printf '  [%2d/%2d] %-28s' "$i" "${#MODULES[@]}" "$m"
    if fetch "$m" "${STAGE}/${m}"; then
        printf '✓\n'
    else
        printf '✗\n'
        echo "  Не удалось скачать ${m}. Ничего не установлено." >&2
        exit 1
    fi
done
echo "  Все ${#MODULES[@]} на месте и проверены."

# ── Установка на место ───────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
OLD_LIB=""
if [ -d "${INSTALL_DIR}/lib" ]; then
    OLD_LIB="${INSTALL_DIR}/lib.old.$$"
    mv "${INSTALL_DIR}/lib" "$OLD_LIB"
fi
mv "${STAGE}/lib"      "${INSTALL_DIR}/lib"
mv "${STAGE}/setup.sh" "${INSTALL_DIR}/setup.sh"
mv "${STAGE}/VERSION"  "${INSTALL_DIR}/VERSION"
mv "${STAGE}/MODULES"  "${INSTALL_DIR}/MODULES"
chmod +x "${INSTALL_DIR}/setup.sh"
[ -n "$OLD_LIB" ] && rm -rf "$OLD_LIB"

ln -sf "${INSTALL_DIR}/setup.sh" /usr/local/bin/usfc

echo "  usfc $(cat "${INSTALL_DIR}/VERSION") установлен"
echo ""

# Запускаем меню с вводом от терминала: при `curl | bash` stdin занят пайпом,
# и без этого первый же вопрос молча проскочил бы.
#
# Перенаправление вешается ТОЛЬКО на запускаемую команду. Делать
# `exec < /dev/tty` для текущей оболочки нельзя: при `curl | bash` сам скрипт
# читается из stdin, и подмена stdin заставляет bash дочитывать оставшиеся
# команды с терминала. Установка при этом молча зависает, не дойдя до строки
# ниже, — ровно это и случилось в 4.0.0.
exec "${INSTALL_DIR}/setup.sh" </dev/tty
