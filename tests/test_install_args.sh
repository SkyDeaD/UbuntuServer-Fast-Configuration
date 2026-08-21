#!/usr/bin/env bash
# Аргументы установщика: что он берёт себе, что передаёт дальше и когда
# открывает меню.
#
# До 4.2.0 install.sh падал с `exit 2` на любом незнакомом аргументе, поэтому
# `curl … | sudo bash -s -- --apply web` не начинал установку вовсе, а финальный
# `exec setup.sh </dev/tty` без терминала валился с «No such device or address»,
# то есть установка в cloud-init заканчивалась ошибкой на последнем шаге.
# Тестов на install.sh не было ни одного.
#
# Сеть не нужна: curl подменён шимом в PATH, который раздаёт файлы из фикстуры,
# а setup.sh в фикстуре — заглушка, печатающая полученные аргументы.
set -uo pipefail

# install.sh от не-root отказывается работать — это его первая проверка.
# Без явного отказа тест «проваливался» бы с невнятным списком, как это
# и случилось на раннере GitHub, где пользователь не root.
if [ "$(id -u)" -ne 0 ]; then
    echo "нужен root: install.sh проверяет это первой строкой. Запусти в контейнере" >&2
    exit 2
fi

INSTALLER="${1:-install.sh}"
[ -f "$INSTALLER" ] || { echo "не найден $INSTALLER" >&2; exit 2; }
INSTALLER="$(cd "$(dirname "$INSTALLER")" && pwd)/$(basename "$INSTALLER")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: нет «$3»" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: есть лишнее «$3»" ;; *) ok "$1" ;; esac; }

# ── фикстура: то, что «лежит в репозитории» ──────────────────────────────────
mkdir -p "$TMP/fixture/lib"
cat > "$TMP/fixture/setup.sh" <<'STUB'
#!/bin/bash
echo "SETUP-ARGS: $*"
if [ -t 0 ]; then echo "SETUP-STDIN: терминал"; else echo "SETUP-STDIN: не терминал"; fi
STUB
chmod +x "$TMP/fixture/setup.sh"
echo "9.9.9" > "$TMP/fixture/VERSION"
printf 'lib/fake.sh\n' > "$TMP/fixture/MODULES"
echo '# заглушка модуля' > "$TMP/fixture/lib/fake.sh"

# ── шим curl: отдаёт файл из фикстуры вместо сети ────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'SHIM'
#!/bin/bash
url=""; out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
echo "$url" >> "$USFC_TEST_URLS"
rel="${url##*/src/}"
[ -f "${USFC_TEST_FIXTURE}/${rel}" ] || exit 22
cat "${USFC_TEST_FIXTURE}/${rel}" > "$out"
SHIM
chmod +x "$TMP/bin/curl"

export USFC_TEST_FIXTURE="$TMP/fixture"
export PATH="$TMP/bin:$PATH"

# run <аргументы...> → OUT, RC. Каждый прогон в свой каталог установки
run() {
    rm -rf "$TMP/opt" "$TMP/urls"; : > "$TMP/urls"
    export USFC_TEST_URLS="$TMP/urls"
    OUT="$(USFC_INSTALL_DIR="$TMP/opt" bash "$INSTALLER" "$@" 2>&1)"; RC=$?
    URLS="$(cat "$TMP/urls")"
}

# ── 1. аргументы доезжают до setup.sh, меню не открывается ───────────────────
echo "аргументы форвардятся"
run --apply web
has   "setup.sh получил аргументы"  "$OUT" "SETUP-ARGS: --apply web"
hasnt "меню не открывалось"         "$OUT" "Терминала нет"
[ "$RC" -eq 0 ] && ok "код возврата 0" || bad "код возврата $RC"

# ── 2. --branch забирает себе установщик ─────────────────────────────────────
echo ""
echo "--branch не уезжает вниз"
run --branch dev --apply zram --yes
has   "setup.sh получил только своё" "$OUT"  "SETUP-ARGS: --apply zram --yes"
has   "ветка попала в URL"           "$URLS" "/dev/src/"
hasnt "ветка не уехала в setup.sh"   "$OUT"  "--branch"

# ── 3. явный разделитель отдаёт вниз даже наши флаги ─────────────────────────
echo ""
echo "разделитель --"
run -- --branch собственная-ветка
has "после -- всё уходит вниз" "$OUT"  "SETUP-ARGS: --branch собственная-ветка"
has "ветка установщика осталась main" "$URLS" "/main/src/"

# ── 4. без аргументов и без терминала: не падаем, а отчитываемся ─────────────
# Ровно тот случай, который ломался: в контейнере /dev/tty существует,
# а открыть его нельзя, поэтому проверять надо попыткой открытия
echo ""
echo "без аргументов и без терминала"
if { : </dev/tty; } 2>/dev/null; then
    echo "  ⚠ терминал доступен — проверку пропускаю (нужен запуск без tty)"
else
    run
    has   "сказано, что меню не открывается" "$OUT" "Терминала нет"
    has   "подсказана команда запуска"       "$OUT" "sudo usfc"
    hasnt "setup.sh не запускался"           "$OUT" "SETUP-ARGS"
    [ "$RC" -eq 0 ] && ok "код возврата 0, а не ошибка" || bad "код возврата $RC"
fi

# ── 5. установка реально разложила файлы ─────────────────────────────────────
echo ""
echo "файлы на месте"
run --apply web
[ -x "$TMP/opt/setup.sh" ]   && ok "setup.sh установлен"      || bad "нет setup.sh"
[ -f "$TMP/opt/VERSION" ]    && ok "VERSION установлен"       || bad "нет VERSION"
[ -f "$TMP/opt/lib/fake.sh" ] && ok "модуль из манифеста установлен" || bad "нет модуля"

# ── 6. --help объясняет, что остальные флаги уходят в usfc ───────────────────
echo ""
echo "справка"
run --help
has "справка упоминает передачу вниз" "$OUT" "usfc"
has "есть пример с --apply"           "$OUT" "--apply"
[ "$RC" -eq 0 ] && ok "код возврата 0" || bad "код возврата $RC"

echo ""
[ "$fail" -eq 0 ] && echo "аргументы установщика: все проверки пройдены" \
                  || echo "аргументы установщика: ЕСТЬ ПРОВАЛЫ"
exit "$fail"
