#!/usr/bin/env bash
# Карточка входа (пункт motd): скрипт, который usfc кладёт в /etc/update-motd.d.
#
# Ставить его в систему здесь не нужно — тест root не требует. Проверяем
# сам сгенерированный скрипт: запускаем под `bash -u` в двух локалях и на двух
# языках и смотрим три вещи, на которых карточка ломается в жизни:
#   • код возврата и stderr — pam_motd молча выкидывает скрипт с ошибкой, а
#     «unbound variable» под set -u на другом сервере легко не заметить;
#   • одинаковая видимая ширина всех строк рамки — съехавшая рамка выглядит
#     хуже, чем её отсутствие; в C-локали ${#s} считает байты, а не символы,
#     и именно там расчёт ширины ломается первым;
#   • время работы — скрипт исполняется при КАЖДОМ входе по SSH.
# Нужен python3: ширину в символах считаем им, а не тем же bash, что в карточке.
set -uo pipefail
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"

# shellcheck disable=SC2034  # читается в write_file / log_*
USFC_DRY_RUN=false
# shellcheck disable=SC2034
USFC_NO_COLOR=true
backup_file() { :; }    # снимки проверяет test_backup.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }

if ! command -v python3 >/dev/null 2>&1; then
    echo "  ✗ нужен python3 для подсчёта ширины"; exit 1
fi

# Максимальная ширина — из задания: узкий терминал 80 колонок, запас на отступ
MAX_WIDTH=78
# Бюджет времени: в задании 100 мс; на медленном CI даём запас, но не десятки
# раз — иначе проверка теряет смысл
MAX_MS=300

# widths <файл вывода> → "<мин> <макс> <число строк рамки>"
widths() {
    python3 -I - "$1" <<'PY'
import re, sys
raw = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
raw = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', raw)
frame = [l for l in raw.split('\n') if l[:1] in ('╭', '│', '╰', '+', '|')]
if not frame:
    print('0 0 0')
else:
    w = [len(l) for l in frame]
    print(min(w), max(w), len(frame))
PY
}

for lang in ru en; do
    # shellcheck disable=SC2034  # читает t() из src/lib/i18n.sh при генерации
    USFC_LANG="$lang"
    card="$TMP/card-$lang.sh"
    motd_card_script > "$card"

    echo ""
    echo "карточка [$lang]"
    if bash -n "$card" 2>"$TMP/syn"; then ok "bash -n"; else bad "bash -n: $(cat "$TMP/syn")"; fi

    for loc in C C.UTF-8; do
        out="$TMP/out-$lang-$loc"; err="$TMP/err-$lang-$loc"
        env -i PATH="$PATH" HOME="$TMP" LC_ALL="$loc" TERM=xterm bash -u "$card" >"$out" 2>"$err"
        rc=$?
        [ "$rc" -eq 0 ] && ok "$loc: код возврата 0" || bad "$loc: код возврата $rc"
        if [ -s "$err" ]; then bad "$loc: stderr не пуст: $(head -n3 "$err")"; else ok "$loc: stderr пуст"; fi

        read -r wmin wmax wn < <(widths "$out")
        if [ "$wn" -lt 3 ]; then
            bad "$loc: рамка не найдена (строк: $wn)"
        elif [ "$wmin" -ne "$wmax" ]; then
            bad "$loc: ширина строк рамки разная: от $wmin до $wmax"
        elif [ "$wmax" -gt "$MAX_WIDTH" ]; then
            bad "$loc: ширина $wmax > $MAX_WIDTH"
        else
            ok "$loc: $wn строк рамки, везде $wmax колонок"
        fi
    done

    # без переменных локали вовсе — Unicode-рамка, а не ASCII
    env -i PATH="$PATH" HOME="$TMP" TERM=xterm bash -u "$card" >"$TMP/out-noloc" 2>&1
    grep -F '╭' "$TMP/out-noloc" >/dev/null && ok "без локали: Unicode-рамка" || bad "без локали: рамка ASCII"

    # язык зашит при установке: в английской карточке нет кириллицы
    if [ "$lang" = en ]; then
        if LC_ALL=C.UTF-8 grep -P '[\x{0400}-\x{04FF}]' "$TMP/out-en-C.UTF-8" >/dev/null 2>&1; then
            bad "en: в английской карточке есть кириллица"
        else ok "en: кириллицы нет"; fi
    fi
done

echo ""
echo "время"
start=$(date +%s%N 2>/dev/null || echo 0)
for _ in 1 2 3 4 5; do
    env -i PATH="$PATH" HOME="$TMP" LC_ALL=C.UTF-8 bash -u "$TMP/card-ru.sh" >/dev/null 2>&1
done
end=$(date +%s%N 2>/dev/null || echo 0)
if [ "$start" = 0 ] || [ "$end" = 0 ]; then
    ok "время не измерено (нет date +%N)"
else
    ms=$(( (end - start) / 5000000 ))
    [ "$ms" -le "$MAX_MS" ] && ok "в среднем ${ms} мс (порог ${MAX_MS})" || bad "в среднем ${ms} мс > ${MAX_MS}"
fi

echo ""
echo "выключение и возврат стандартного приветствия (во временном каталоге)"
MOTD_DIR="$TMP/motd.d"; MOTD_FILE="$MOTD_DIR/01-usfc"
MOTD_STATE="$TMP/usfc/motd-disabled"; MOTD_ORIG="$TMP/usfc/motd.orig"; MOTD_STATIC="$TMP/motd"
mkdir -p "$MOTD_DIR" "$TMP/pkg"
printf '#!/bin/sh\n' > "$TMP/pkg/landscape.wrapper"; chmod 755 "$TMP/pkg/landscape.wrapper"
printf '#!/bin/sh\n' > "$MOTD_DIR/00-header"; chmod 755 "$MOTD_DIR/00-header"
ln -s "$TMP/pkg/landscape.wrapper" "$MOTD_DIR/50-landscape-sysinfo"
printf 'старое приветствие\n' > "$MOTD_STATIC"
motd_scan
_motd_silence
[ -x "$TMP/pkg/landscape.wrapper" ] && ok "цель симлинка сохранила +x" || bad "у файла пакета снят +x"
[ ! -e "$MOTD_DIR/50-landscape-sysinfo" ] && [ ! -L "$MOTD_DIR/50-landscape-sysinfo" ] && ok "сама ссылка убрана" || bad "ссылка на месте"
[ ! -x "$MOTD_DIR/00-header" ] && ok "обычному скрипту снят +x" || bad "00-header всё ещё исполняемый"
grep -F "L	$TMP/pkg/landscape.wrapper	$MOTD_DIR/50-landscape-sysinfo" "$MOTD_STATE" >/dev/null && ok "ссылка записана в состояние" || bad "в состоянии нет ссылки"

: > "$MOTD_FILE"
ask_yn_t() { return 1; }
disable_motd >/dev/null 2>&1
[ -e "$MOTD_FILE" ] && ok "ответ «нет» — карточка на месте" || bad "карточка удалена без подтверждения"
ask_yn_t() { return 0; }
disable_motd >/dev/null 2>&1
[ ! -e "$MOTD_FILE" ] && ok "ответ «да» — карточка удалена" || bad "карточка не удалена"
{ [ -L "$MOTD_DIR/50-landscape-sysinfo" ] && [ "$(readlink "$MOTD_DIR/50-landscape-sysinfo")" = "$TMP/pkg/landscape.wrapper" ]; } \
    && ok "disable вернул ссылку на прежнюю цель" || bad "ссылка не вернулась"
[ -x "$MOTD_DIR/00-header" ] && ok "disable вернул +x обычному скрипту" || bad "+x не возвращён"
grep -F 'старое приветствие' "$MOTD_STATIC" >/dev/null && ok "/etc/motd возвращён" || bad "/etc/motd не возвращён"

# устаревший motd.orig (откат оставил, /etc/motd потом изменили) обновляется
rm -f "$MOTD_STATE"
printf 'УСТАРЕВШЕЕ\n' > "$MOTD_ORIG"
printf 'свежий motd\n' > "$MOTD_STATIC"
motd_scan; _motd_silence
grep -F 'свежий motd' "$MOTD_ORIG" >/dev/null && ok "устаревший motd.orig перезаписан" || bad "motd.orig остался старым: $(cat "$MOTD_ORIG")"
unset -f ask_yn_t

echo ""
[ "$fail" -eq 0 ] && echo "карточка входа: все проверки пройдены" || echo "карточка входа: ЕСТЬ ОШИБКИ"
exit "$fail"
