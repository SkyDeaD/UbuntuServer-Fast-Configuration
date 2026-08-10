#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  vps-setup — команда: usfc
#  Menu-driven: CLI tools + Docker + zram/swap + fastfetch + starship
#  + hardening (fail2ban, unattended-upgrades, docker log rotation,
#    tmux, SSH key-only hardening (self-testing), UFW)
#  + self-update on every run
#  https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration
# ═══════════════════════════════════════════════════════════════
set -uo pipefail
# ПРИМЕЧАНИЕ: сознательно без -e — это интерактивное меню, которое
# живёт много действий подряд; одна упавшая подкоманда не должна
# убивать всю сессию, только то конкретное действие.

# Ассоциативные массивы (кэши пакетов/статусов/рамок) — bash 4+.
# Ubuntu везде даёт bash 5, но если скрипт запустили через `sh setup.sh`
# или на экзотике, лучше сказать это прямо, чем сыпать «declare -A: invalid option»
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "Нужен bash 4 или новее. Запуск: bash $0" >&2
    exit 1
fi

# ═══════════════════════════════════════════════════════════════
# ЛОВУШКА: `... | grep -q` под set -o pipefail
# ═══════════════════════════════════════════════════════════════
# grep -q выходит на ПЕРВОМ совпадении и закрывает канал. Продюсер (locale -a,
# apt-cache, ufw status) получает SIGPIPE и умирает с кодом 141, а pipefail
# делает 141 статусом ВСЕГО пайплайна. Условие `if producer | grep -q ...`
# оказывается ложным ровно тогда, когда совпадение НАШЛОСЬ, а вывод длинный —
# то есть на настоящем сервере, но не в коротком тесте.
#
# Именно на этом гонялся фолбэк Docker: проверка «есть ли пакеты под наш
# codename» была ложной ВСЕГДА, и на каждой машине печаталось «У Docker пока
# нет пакетов под 'noble' — переключаюсь на noble».
#
# Поэтому в условиях grep идёт БЕЗ -q, с выводом в /dev/null: обычный grep
# дочитывает ввод до конца, SIGPIPE не возникает. Проверено обоими способами.
# Регрессия на это есть в tests/test_layout.sh — она запрещает `| grep -q`
# во всём файле.

# C.UTF-8 встроена в glibc и не требует locale-gen — в отличие от ru_RU.UTF-8/en_US.UTF-8,
# которые на свежих VPS-образах часто объявлены, но не собраны. Именно из-за такого
# полусломанного locale раньше приходилось считать длину строк через python3: ${#s} мерил
# байты вместо символов, а tr резал многобайтовый "─" на мусор. Фиксируем окружение один
# раз здесь — и вся отрисовка живёт на чистом bash.
if [ -z "${USFC_KEEP_LOCALE:-}" ] && locale -a 2>/dev/null | grep -iE '^C\.utf-?8$' >/dev/null; then
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8
fi

# Считает ли ${#s} символы (а не байты) — определяем один раз, дальше это
# горячий путь отрисовки меню, там не до проверок
_probe='─'
# shellcheck disable=SC2034  # читается в lib/layout.sh: visible_len и truncate_colored
if [ "${#_probe}" -eq 1 ]; then CHARLEN_NATIVE=true; else CHARLEN_NATIVE=false; fi
unset _probe

# Откуда качаются обновления и модули. Переопределяется переменной окружения:
# без этого механизм обновления невозможно проверить до того, как изменения
# окажутся в main, — а проверять его надо именно до, потому что чинить
# сломанное обновление уже нечем.
REPO_RAW_BASE="${USFC_REPO_RAW_BASE:-https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/src}"

# ═══════════════════════════════════════════════════════════════
# Загрузка модулей
# ═══════════════════════════════════════════════════════════════
# Этот файл — точка входа и загрузчик; логика лежит в lib/.
#
# Имя setup.sh менять НЕЛЬЗЯ: установленные версии обновляются через
# `curl .../src/setup.sh`, и переименование оставило бы их с 404 навсегда.
#
# Порядок в MODULES = порядок выполнения, и он повторяет порядок кусков
# прежнего однофайлового setup.sh. Поэтому дробление не меняет поведения.
#
# Всё в этом блоке НЕ должно зависеть от модулей: их ещё нет. Ни log_info,
# ни цветов, ни run_logged здесь использовать нельзя.
# BASH_SOURCE, а не $0: тесты подключают этот файл через `source`, и тогда $0 —
# это тестовый скрипт, а модули лежат рядом с setup.sh. BASH_SOURCE[0] указывает
# на сам файл в обоих случаях. (В lib/ident.sh SCRIPT_PATH намеренно остаётся
# на $0 — там он нужен именно как «кого запустили», для самозамены.)
USFC_ROOT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")"
USFC_MANIFEST="${USFC_ROOT}/MODULES"
USFC_INSTALL_URL="https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh"

USFC_MODULES=()
usfc_read_manifest() {
    USFC_MODULES=()
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        USFC_MODULES+=("$line")
    done < "${1}"
}

# Скачать один модуль во временный файл, проверить синтаксис, положить на место.
# Через временный — чтобы оборванная закачка не оставила обрубок на месте
# рабочего файла.
usfc_bootstrap_fetch() {
    local rel="$1" tmp
    tmp="$(mktemp)" || return 1
    if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 30 \
            "${REPO_RAW_BASE}/${rel}" -o "$tmp" 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    mkdir -p "$(dirname "${USFC_ROOT}/${rel}")"
    mv "$tmp" "${USFC_ROOT}/${rel}" && chmod 644 "${USFC_ROOT}/${rel}"
}

if [ ! -f "$USFC_MANIFEST" ]; then
    # Манифеста нет — значит пришли с однофайловой установки: прежний апдейтер
    # заменил setup.sh и про MODULES не знал. Тянем манифест сами.
    if [ -n "${USFC_SOURCE_ONLY:-}" ]; then
        echo "Не найден ${USFC_MANIFEST}" >&2; exit 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        echo "Структура установки обновилась, нужен root: sudo usfc" >&2; exit 1
    fi
    echo ""
    echo "  Структура обновилась — доношу список модулей..."
    _tmp_manifest="$(mktemp)"
    if ! curl -fsSL --retry 3 --max-time 30 "${REPO_RAW_BASE}/MODULES" -o "$_tmp_manifest" 2>/dev/null \
       || [ ! -s "$_tmp_manifest" ]; then
        rm -f "$_tmp_manifest"
        echo "  Не удалось получить список модулей. Переустановите:" >&2
        echo "  curl -fsSL ${USFC_INSTALL_URL} | sudo bash" >&2
        exit 1
    fi
    mv "$_tmp_manifest" "$USFC_MANIFEST"
    unset _tmp_manifest
fi

usfc_read_manifest "$USFC_MANIFEST"

# Чего не хватает на диске
_usfc_missing=()
for _usfc_m in "${USFC_MODULES[@]}"; do
    [ -f "${USFC_ROOT}/${_usfc_m}" ] || _usfc_missing+=("$_usfc_m")
done

if [ "${#_usfc_missing[@]}" -gt 0 ]; then
    if [ -n "${USFC_SOURCE_ONLY:-}" ]; then
        echo "Нет модулей: ${_usfc_missing[*]}" >&2; exit 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        echo "Не хватает модулей, дозагрузка требует root: sudo usfc" >&2; exit 1
    fi
    echo "  Докачиваю модули (${#_usfc_missing[@]} шт.)"
    _usfc_i=0
    for _usfc_m in "${_usfc_missing[@]}"; do
        _usfc_i=$((_usfc_i + 1))
        printf '  [%2d/%2d] %s' "$_usfc_i" "${#_usfc_missing[@]}" "$_usfc_m"
        if usfc_bootstrap_fetch "$_usfc_m"; then
            printf '  ok\n'
        else
            printf '  ОШИБКА\n'
            echo "  Переустановите: curl -fsSL ${USFC_INSTALL_URL} | sudo bash" >&2
            exit 1
        fi
    done
    echo "  Готово."
    unset _usfc_i
fi
unset _usfc_missing

# ВАЖНО: статус `source` — это статус ПОСЛЕДНЕЙ команды в файле, а не признак
# успешной загрузки. Проверять его нельзя: lib/ident.sh, например, кончается на
# `[ -z "$VERSION" ] && VERSION="0.0.0"`, и на нормальной установке (версия
# непустая) это ложь — то есть статус 1 у совершенно исправного модуля.
# Ровно на этом падал `usfc --version` после установки, хотя все 32 модуля
# лежали на месте.
#
# Целостность гарантируется иначе: файл существует (проверено выше), а его
# синтаксис проверен `bash -n` при скачивании — и установщиком, и обновлением.
for _usfc_m in "${USFC_MODULES[@]}"; do
    if [ ! -r "${USFC_ROOT}/${_usfc_m}" ]; then
        echo "Модуль недоступен для чтения: ${_usfc_m}" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "${USFC_ROOT}/${_usfc_m}"
done
unset _usfc_m

# USFC_SOURCE_ONLY=1 — загрузить функции, не запуская меню. Нужно тестам,
# заодно защищает от случайного `source setup.sh`
if [ -z "${USFC_SOURCE_ONLY:-}" ]; then
    parse_args "$@"
    main
fi
