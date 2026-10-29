#!/bin/bash
# usfc — быстрая установка
# Использование: curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh | sudo bash && source ~/.bashrc
# "&& source ~/.bashrc" — не косметика: это выполняется уже в ТВОЕЙ оболочке
# (в отличие от того, что делает изнутри сам скрипт), поэтому реально
# подхватывает новые алиасы/промпт сразу после первой установки
set -uo pipefail

REPO="SkyDeaD/UbuntuServer-Fast-Configuration"
# Переменной, а не константой: так путь подменяет tests/test_install_args.sh
# и не трогает при этом настоящий /opt
INSTALL_DIR="${USFC_INSTALL_DIR:-/opt/vps-setup}"
BRANCH="${USFC_BRANCH:-main}"

# Всё, что не наше, уезжает в setup.sh. Раньше здесь стоял `exit 2` на любой
# незнакомый аргумент, и `curl … | sudo bash -s -- --apply web` падал, не начав
# установку: поставить с аргументами было нельзя в принципе — только поставить
# без них, дождаться меню, выйти и запустить usfc заново.
# Язык справки — по всем аргументам сразу: в цикле ниже на -h видны только
# те, что после него, и `--lang en -h` давал русскую справку
HELP_LANG="${USFC_LANG:-ru}"
_prev=''
for _a in "$@"; do
    case "$_a" in --lang=en) HELP_LANG=en ;; --lang=ru) HELP_LANG=ru ;; esac
    [ "$_prev" = --lang ] && case "$_a" in en|ru) HELP_LANG="$_a" ;; esac
    _prev="$_a"
done
unset _a _prev

REST=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -b|--branch)
            [ -n "${2:-}" ] || { echo "--branch требует имя ветки" >&2; exit 2; }
            BRANCH="$2"; shift 2 ;;
        --branch=*) BRANCH="${1#*=}"; shift ;;
        -h|--help)
            if [ "$HELP_LANG" = en ]; then
                echo "Usage: install.sh [--branch <branch>] [usfc command and options...]"
                echo ""
                echo "  --branch <branch>  install from that branch (main by default)"
                echo ""
                echo "Everything else goes to the installed usfc. With a command, the menu"
                echo "does not open and no terminal is needed (cloud-init). Full list: usfc help"
                echo "  curl -fsSL .../install.sh | sudo bash -s -- apply web --yes"
                echo "  curl -fsSL .../install.sh | sudo bash -s -- apply docker,zram,ufw --swap 2048 --ufw"
                echo "  curl -fsSL .../install.sh | sudo bash -s -- audit"
            else
                echo "Использование: install.sh [--branch <ветка>] [команда usfc и опции...]"
                echo ""
                echo "  --branch <ветка>  ставить из указанной ветки (по умолчанию main)"
                echo ""
                echo "Остальное передаётся установленному usfc. С командой меню не открывается"
                echo "и терминал не нужен (cloud-init). Полный список — usfc help. Примеры:"
                echo "  curl -fsSL .../install.sh | sudo bash -s -- apply web --yes"
                echo "  curl -fsSL .../install.sh | sudo bash -s -- apply docker,zram,ufw --swap 2048 --ufw"
                echo "  curl -fsSL .../install.sh | sudo bash -s -- audit"
            fi
            exit 0 ;;
        # Явный разделитель: всё после него — аргументы usfc, даже если совпадают
        # с нашими. Нужен, чтобы можно было передать вниз собственный --branch
        --) shift; while [ "$#" -gt 0 ]; do REST+=("$1"); shift; done ;;
        *) REST+=("$1"); shift ;;
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

# fetch_many <каталог> <хвост пути>... — все файлы одним curl --parallel:
# по curl на файл — это TLS-рукопожатие на каждый, 47 модулей шли ~25 с.
# Что не пришло этим заходом (старый curl без --parallel, сбой отдельного
# файла), докачивается по одному через fetch. FETCH_FAILED — первый
# файл, который так и не удалось получить
FETCH_FAILED=""
fetch_many() {
    local dir="$1" rel args=()
    shift
    for rel in "$@"; do
        mkdir -p "$(dirname "${dir}/${rel}")" || { FETCH_FAILED="$rel"; return 1; }
        args+=("${RAW}/${rel}" -o "${dir}/${rel}.part")
    done
    # Общий код возврата не годится — судим по каждому файлу: curl печатает
    # код завершения на каждую передачу, принимаем только с кодом 0. Обрыв
    # ровно на границе команд bash -n не заметил бы
    local done_ok
    done_ok="$(curl -fsSL --parallel --parallel-max 8 --remove-on-error \
        --retry 3 --retry-delay 2 --max-time 30 \
        -w '%{exitcode} %{filename_effective}\n' "${args[@]}" 2>/dev/null)"
    for rel in "$@"; do
        case $'\n'"${done_ok}"$'\n' in
            *$'\n'"0 ${dir}/${rel}.part"$'\n'*) ;;
            *) rm -f "${dir}/${rel}.part" ;;
        esac
        if [ -s "${dir}/${rel}.part" ]; then
            case "$rel" in
                *.sh) bash -n "${dir}/${rel}.part" 2>/dev/null || rm -f "${dir}/${rel}.part" ;;
            esac
        fi
        if [ -s "${dir}/${rel}.part" ] && mv "${dir}/${rel}.part" "${dir}/${rel}"; then
            continue
        fi
        rm -f "${dir}/${rel}.part"
        fetch "$rel" "${dir}/${rel}" || { FETCH_FAILED="$rel"; return 1; }
    done
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
    # строка манифеста становится путём на диске — только lib/….sh
    case "$line" in
        *..*|*[!A-Za-z0-9_./-]*) ;;
        lib/*.sh) MODULES+=("$line"); continue ;;
    esac
    echo "  В манифесте недопустимая строка «${line}» — установка прервана" >&2
    exit 1
done < "${STAGE}/MODULES"

if [ "${#MODULES[@]}" -eq 0 ]; then
    echo "  Пустой список модулей — установка прервана" >&2
    exit 1
fi

printf '  Скачивание модулей (%d)... ' "${#MODULES[@]}"
if fetch_many "$STAGE" "${MODULES[@]}"; then
    printf '✓\n'
else
    printf '✗\n'
    echo "  Не удалось скачать ${FETCH_FAILED}. Ничего не установлено." >&2
    exit 1
fi
echo "  Все ${#MODULES[@]} на месте и проверены."

# ── Установка на место ───────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
OLD_LIB=""
# Прежние setup.sh, MODULES и VERSION сохраняются рядом с old lib: при сбое
# возвращаются все четыре вещи, иначе новый setup.sh остался бы с чужим lib
OLD_FILES="${INSTALL_DIR}/files.old.$$"
rm -rf "$OLD_FILES"
mkdir -p "$OLD_FILES" || { echo "  Не удалось создать ${OLD_FILES}" >&2; exit 1; }
for f in setup.sh MODULES VERSION; do
    if [ -f "${INSTALL_DIR}/${f}" ] && ! cp -p "${INSTALL_DIR}/${f}" "${OLD_FILES}/${f}"; then
        echo "  Не удалось сохранить ${f}" >&2; rm -rf "$OLD_FILES"; exit 1
    fi
done
if [ -d "${INSTALL_DIR}/lib" ]; then
    OLD_LIB="${INSTALL_DIR}/lib.old.$$"
    mv "${INSTALL_DIR}/lib" "$OLD_LIB" || { echo "  Не удалось освободить ${INSTALL_DIR}/lib" >&2; rm -rf "$OLD_FILES"; exit 1; }
fi
# старое удаляется только после полного успеха, иначе возвращается всё
if ! { mv "${STAGE}/lib" "${INSTALL_DIR}/lib" && mv "${STAGE}/setup.sh" "${INSTALL_DIR}/setup.sh" \
       && mv "${STAGE}/VERSION" "${INSTALL_DIR}/VERSION" && mv "${STAGE}/MODULES" "${INSTALL_DIR}/MODULES"; }; then
    echo "  Не удалось разложить файлы в ${INSTALL_DIR}" >&2
    rm -rf "${INSTALL_DIR:?}/lib"
    [ -n "$OLD_LIB" ] && mv "$OLD_LIB" "${INSTALL_DIR}/lib"
    # cp, а не mv: сбоить мог именно mv. Файла, которого не было, не будет и после
    for f in setup.sh MODULES VERSION; do
        if [ -f "${OLD_FILES}/${f}" ]; then cp -p "${OLD_FILES}/${f}" "${INSTALL_DIR}/${f}"; else rm -f "${INSTALL_DIR:?}/${f}"; fi
    done
    rm -rf "$OLD_FILES"
    exit 1
fi
chmod +x "${INSTALL_DIR}/setup.sh"
[ -n "$OLD_LIB" ] && rm -rf "$OLD_LIB"
rm -rf "$OLD_FILES"

ln -sf "${INSTALL_DIR}/setup.sh" /usr/local/bin/usfc

echo "  usfc $(cat "${INSTALL_DIR}/VERSION") установлен"
echo ""

# Три ветки вместо одной.
#
# 1. Есть аргументы — значит человек уже сказал, чего хочет, и меню открывать
#    незачем. Терминал такому запуску не нужен: это и есть путь для cloud-init.
# 2. Аргументов нет, терминал есть — обычная установка, открываем меню. Ввод
#    берём от терминала: при `curl | bash` stdin занят пайпом, и без этого
#    первый же вопрос молча проскочил бы. Перенаправление вешается ТОЛЬКО
#    на запускаемую команду: `exec < /dev/tty` для текущей оболочки заставляет
#    bash дочитывать оставшиеся команды с терминала — ровно это и повесило
#    установку в 4.0.0.
# 3. Ни аргументов, ни терминала — раньше здесь безусловно шёл `</dev/tty`
#    и установка падала на последнем шаге с «No such device or address»,
#    хотя файлы уже разложены. Теперь честно отчитываемся и выходим нулём.
#
# Терминал проверяем ПОПЫТКОЙ ОТКРЫТЬ, а не `[ -e /dev/tty ]`: в контейнере
# файл существует, а открытие не удаётся. Редирект берём в группу — иначе
# bash печатает «/dev/tty: No such device or address» мимо 2>/dev/null,
# потому что об ошибке редиректа отчитывается сам шелл, а не команда.
#
# «Есть аргументы» — это есть КОМАНДА (apply, audit…). Одни модификаторы
# (`--lang en`, `--verbose`) означают меню, и раньше оно открывалось без
# терминала — то есть зависало или падало на первом вопросе.
# Команда — первое слово, не являющееся опцией и не являющееся значением
# опции. Раньше имя искалось среди ВСЕХ аргументов, и значение флага
# (`--hostname list`, `--timezone help`) принималось за команду. Любое первое
# слово считаем командой (неверную назовёт сам usfc кодом 2 — в cloud-init это
# лучше тихого «терминала нет»). Значения берут --lang, --config, --set, --deny
# и все не-yn флаги ответов: их список читаем из таблицы только что
# установленной версии (lib/profiles.sh), чтобы не держать второй список здесь
VALUE_OPTS=" --lang --config --set --deny "
if [ -f "${INSTALL_DIR}/lib/profiles.sh" ]; then
    while IFS='|' read -r _k _v _ty _fl _; do
        [ -n "$_fl" ] && [ "$_ty" != yn ] && VALUE_OPTS="${VALUE_OPTS}${_fl} "
    done < <(sed -n 's/^    "\([A-Z_]*|[A-Za-z_]*|[a-z]*|.*\)"[[:space:]]*$/\1/p' "${INSTALL_DIR}/lib/profiles.sh")
fi
HAS_CMD=false
_skip=false
for a in "${REST[@]+"${REST[@]}"}"; do
    if [ "$_skip" = true ]; then _skip=false; continue; fi
    case "$a" in
        -V|--version) HAS_CMD=true; break ;;
        -*=*) ;;
        -*) case "$VALUE_OPTS" in *" ${a} "*) _skip=true ;; esac ;;
        *) HAS_CMD=true; break ;;
    esac
done
if [ "$HAS_CMD" = true ]; then
    exec "${INSTALL_DIR}/setup.sh" "${REST[@]}"
elif { : </dev/tty; } 2>/dev/null; then
    exec "${INSTALL_DIR}/setup.sh" "${REST[@]+"${REST[@]}"}" </dev/tty
else
    echo "  Терминала нет — меню не открываю. / No terminal — not opening the menu."
    echo "  Меню / Menu:              sudo usfc"
    echo "  Без меню / Without menu:  sudo usfc apply web"
    exit 0
fi
