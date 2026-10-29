#!/usr/bin/env bash
# Аргументы установщика: что он берёт себе, что передаёт дальше и когда
# открывает меню.
#
# До 4.2.0 install.sh падал с `exit 2` на любом незнакомом аргументе, поэтому
# `curl … | sudo bash -s -- --apply web` (в 5.0 — `apply web`) не начинал установку вовсе, а финальный
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
printf 'lib/fake.sh\nlib/profiles.sh\n' > "$TMP/fixture/MODULES"
echo '# заглушка модуля' > "$TMP/fixture/lib/fake.sh"
# мини-таблица ответов: install.sh берёт из неё список флагов со значением
cat > "$TMP/fixture/lib/profiles.sh" <<'PROF'
USFC_ANSWER_KEYS=(
    "HOSTNAME|HOSTNAME_BULK|host|--hostname|hostname|имя|name"
    "TIMEZONE|TIMEZONE_BULK|tz|--timezone|hostname|пояс|zone"
    "UFW|UFW_BULK|yn|--ufw|ufw|включить|enable"
    "TG_CHAT|TG_CHAT_BULK|chat|--tg-chat|notify|кому|to"
)
PROF

# ── шим curl: отдаёт файл из фикстуры вместо сети ────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'SHIM'
#!/bin/bash
# Понимает и один файл, и пачку «url -o путь url -o путь…» с --parallel.
# USFC_TEST_NOPARALLEL=1 — curl без --parallel (отказ, как у старого curl);
# USFC_TEST_SKIP=<хвост> — в пачке этот файл не приходит
urls=(); outs=(); par=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) outs+=("$2"); shift 2 ;;
        --parallel) par=1; shift ;;
        http*) urls+=("$1"); shift ;;
        *) shift ;;
    esac
done
echo "CALL ${#urls[@]} parallel=${par}" >> "${USFC_TEST_URLS}.calls"
[ "$par" = 1 ] && [ -n "${USFC_TEST_NOPARALLEL:-}" ] && exit 2
rc=0
for i in "${!urls[@]}"; do
    url="${urls[$i]}"; out="${outs[$i]}"
    echo "$url" >> "$USFC_TEST_URLS"
    rel="${url##*/src/}"
    if [ "$par" = 1 ] && [ "$rel" = "${USFC_TEST_SKIP:-}" ]; then rc=22; continue; fi
    [ -f "${USFC_TEST_FIXTURE}/${rel}" ] || { rc=22; continue; }
    cat "${USFC_TEST_FIXTURE}/${rel}" > "$out"
done
exit "$rc"
SHIM
chmod +x "$TMP/bin/curl"

export USFC_TEST_FIXTURE="$TMP/fixture"
export PATH="$TMP/bin:$PATH"

# run <аргументы...> → OUT, RC. Каждый прогон в свой каталог установки
run() {
    rm -rf "$TMP/opt" "$TMP/urls" "$TMP/urls.calls"; : > "$TMP/urls"
    export USFC_TEST_URLS="$TMP/urls"
    OUT="$(USFC_INSTALL_DIR="$TMP/opt" bash "$INSTALLER" "$@" 2>&1)"; RC=$?
    URLS="$(cat "$TMP/urls")"
}

# ── 1. аргументы доезжают до setup.sh, меню не открывается ───────────────────
echo "аргументы форвардятся"
run apply web
has   "setup.sh получил аргументы"  "$OUT" "SETUP-ARGS: apply web"
hasnt "меню не открывалось"         "$OUT" "Терминала нет"
[ "$RC" -eq 0 ] && ok "код возврата 0" || bad "код возврата $RC"

# ── 2. --branch забирает себе установщик ─────────────────────────────────────
echo ""
echo "--branch не уезжает вниз"
run --branch dev apply zram --yes
has   "setup.sh получил только своё" "$OUT"  "SETUP-ARGS: apply zram --yes"
has   "ветка попала в URL"           "$URLS" "/dev/src/"
hasnt "ветка не уехала в setup.sh"   "$OUT"  "--branch"

# ── 3. явный разделитель отдаёт вниз даже наши флаги ─────────────────────────
echo ""
echo "разделитель --"
run -- apply --branch собственная-ветка
has "после -- всё уходит вниз" "$OUT"  "SETUP-ARGS: apply --branch собственная-ветка"
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

# ── 4б. одни модификаторы — это меню, а без терминала меню не открыть ────────
# До 5.0 `… -s -- --lang en` уходил в setup.sh без терминала и зависал на
# первом вопросе меню
echo ""
echo "только модификаторы и без терминала"
if { : </dev/tty; } 2>/dev/null; then
    echo "  ⚠ терминал доступен — проверку пропускаю (нужен запуск без tty)"
else
    run --lang en
    has   "сказано, что меню не открывается" "$OUT" "Терминала нет"
    hasnt "setup.sh не запускался"           "$OUT" "SETUP-ARGS"
fi

# ── 4в. значение флага — не команда ──────────────────────────────────────────
# Раньше имя команды искалось среди всех аргументов: `--hostname list` считалось
# командой list, и меню без терминала не отсекалось
echo ""
echo "значение флага не принимается за команду"
run apply basepkgs --hostname list --yes
has   "команда после apply, значение list внутри" "$OUT" "SETUP-ARGS: apply basepkgs --hostname list --yes"
hasnt "меню не открывалось" "$OUT" "Терминала нет"
run --lang en apply web
has   "общий флаг до команды" "$OUT" "SETUP-ARGS: --lang en apply web"
run --hostname node-1 apply web
has   "флаг ответа со значением до команды" "$OUT" "SETUP-ARGS: --hostname node-1 apply web"
run --ufw list
has   "yn-флаг не берёт значение: list — команда" "$OUT" "SETUP-ARGS: --ufw list"
run --tg-chat -1001234567890 audit
has   "отрицательное значение пропущено, audit — команда" "$OUT" "SETUP-ARGS: --tg-chat -1001234567890 audit"
if { : </dev/tty; } 2>/dev/null; then
    echo "  ⚠ терминал доступен — проверку пропускаю (нужен запуск без tty)"
else
    run --hostname list
    has   "--hostname list без команды — это меню" "$OUT" "Терминала нет"
    hasnt "setup.sh не запускался" "$OUT" "SETUP-ARGS"
    run --timezone help --lang en
    has   "--timezone help без команды — это меню" "$OUT" "Терминала нет"
    hasnt "setup.sh не запускался (help)" "$OUT" "SETUP-ARGS"
    run --config list
    has   "--config list без команды — это меню" "$OUT" "Терминала нет"
fi

# ── 4г. сбой при раскладке файлов возвращает старую установку целиком ────────
echo ""
echo "сбой раскладки: старые файлы возвращены"
cat > "$TMP/bin/mv" <<'MVSHIM'
#!/bin/bash
# падает только на переносе в каталог установки, чтобы не ломать fetch
if [ -n "${USFC_TEST_FAILMV:-}" ] && [ "${*: -1}" = "$USFC_TEST_FAILMV" ]; then exit 1; fi
exec /bin/mv "$@"
MVSHIM
chmod +x "$TMP/bin/mv"
rm -rf "$TMP/opt"; mkdir -p "$TMP/opt/lib"
echo OLD-SETUP > "$TMP/opt/setup.sh"; echo OLD-MODULES > "$TMP/opt/MODULES"
echo 1.0.0 > "$TMP/opt/VERSION"; echo OLD-LIB > "$TMP/opt/lib/a.sh"
: > "$TMP/urls"; export USFC_TEST_URLS="$TMP/urls"
OUT="$(USFC_TEST_FAILMV="$TMP/opt/MODULES" USFC_INSTALL_DIR="$TMP/opt" bash "$INSTALLER" apply web 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok "установка завершилась ошибкой" || bad "код возврата $RC"
state="$(cat "$TMP/opt/setup.sh") $(cat "$TMP/opt/MODULES") $(cat "$TMP/opt/VERSION") $(cat "$TMP/opt/lib/a.sh" 2>/dev/null)"
[ "$state" = "OLD-SETUP OLD-MODULES 1.0.0 OLD-LIB" ] && ok "setup.sh, MODULES, VERSION и lib прежние" || bad "состояние: «$state»"
[ -n "$(find "$TMP/opt" -maxdepth 1 -name '*.old*')" ] && bad "остались *.old" || ok "служебных *.old не осталось"
rm -f "$TMP/bin/mv"

# ── 5. установка реально разложила файлы ─────────────────────────────────────
echo ""
echo "файлы на месте"
run apply web
[ -x "$TMP/opt/setup.sh" ]   && ok "setup.sh установлен"      || bad "нет setup.sh"
[ -f "$TMP/opt/VERSION" ]    && ok "VERSION установлен"       || bad "нет VERSION"
[ -f "$TMP/opt/lib/fake.sh" ] && ok "модуль из манифеста установлен" || bad "нет модуля"

# ── 5б. модули одним curl --parallel, без него — по одному ───────────────────
echo ""
echo "параллельная загрузка"
run apply web
calls="$(cat "$TMP/urls.calls")"
has "модули пачкой с --parallel" "$calls" "CALL 2 parallel=1"
[ "$(grep -c 'parallel=1' "$TMP/urls.calls")" -eq 1 ] && ok "пачка — один вызов curl" || bad "вызовов с --parallel: $(grep -c 'parallel=1' "$TMP/urls.calls")"
hasnt "строки на каждый модуль нет" "$OUT" "[ 1/"
has   "итог одной строкой" "$OUT" "Скачивание модулей (2)... ✓"
OUT="$(USFC_TEST_NOPARALLEL=1 bash -c 'rm -rf "$1/opt"; USFC_INSTALL_DIR="$1/opt" bash "$2" apply web' _ "$TMP" "$INSTALLER" 2>&1)"; RC=$?
{ [ "$RC" -eq 0 ] && [ -f "$TMP/opt/lib/fake.sh" ] && [ -f "$TMP/opt/lib/profiles.sh" ]; } \
    && ok "curl без --parallel: докачано по одному" || bad "без --parallel: rc=$RC $OUT"
OUT="$(USFC_TEST_SKIP=lib/fake.sh bash -c 'rm -rf "$1/opt"; USFC_INSTALL_DIR="$1/opt" bash "$2" apply web' _ "$TMP" "$INSTALLER" 2>&1)"; RC=$?
{ [ "$RC" -eq 0 ] && [ -f "$TMP/opt/lib/fake.sh" ]; } && ok "файл, не пришедший в пачке, докачан" || bad "докачка: rc=$RC $OUT"
mv "$TMP/fixture/lib/fake.sh" "$TMP/fake.bak"
run apply web
{ [ "$RC" -eq 1 ] && [[ "$OUT" == *"Не удалось скачать lib/fake.sh"* ]]; } && ok "ошибка называет модуль" || bad "ошибка: rc=$RC $OUT"
[ -f "$TMP/opt/setup.sh" ] && bad "при сбое что-то установлено" || ok "при сбое ничего не установлено"
mv "$TMP/fake.bak" "$TMP/fixture/lib/fake.sh"
printf 'if then\n' > "$TMP/fixture/lib/fake.sh"
run apply web
[ "$RC" -eq 1 ] && ok "битый синтаксис отвергнут" || bad "битый модуль принят: rc=$RC"
echo '# заглушка модуля' > "$TMP/fixture/lib/fake.sh"

# ── 6. --help объясняет, что остальные флаги уходят в usfc ───────────────────
echo ""
echo "справка"
run --help
has "справка упоминает передачу вниз" "$OUT" "usfc"
has "есть пример с командой apply"    "$OUT" "apply web"
[ "$RC" -eq 0 ] && ok "код возврата 0" || bad "код возврата $RC"
for args in "--help --lang en" "--lang en --help" "--lang=en -h"; do
    # shellcheck disable=SC2086  # слова аргументов разделяются намеренно
    run $args
    has "справка по-английски: ${args}" "$OUT" "Usage: install.sh"
done

echo ""
[ "$fail" -eq 0 ] && echo "аргументы установщика: все проверки пройдены" \
                  || echo "аргументы установщика: ЕСТЬ ПРОВАЛЫ"
exit "$fail"
