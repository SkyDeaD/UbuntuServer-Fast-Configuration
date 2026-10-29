#!/usr/bin/env bash
# Карточка входа (пункт motd): скрипт, который usfc кладёт в /etc/update-motd.d.
#
# Ставить его в систему здесь не нужно — тест root не требует. Проверяем
# сам сгенерированный скрипт: запускаем под `bash -u` в двух локалях и на двух
# языках и смотрим три вещи, на которых карточка ломается в жизни:
#   • код возврата и stderr — pam_motd молча выкидывает скрипт с ошибкой, а
#     «unbound variable» под set -u на другом сервере легко не заметить;
#   • ширина: ни одна строка не шире 78 колонок (терминал 80), в C-локали
#     ${#s} считает байты, а не символы, и именно там расчёт ломается первым;
#   • крупные буквы имени: есть в UTF-8, нет в C-локали и для длинного имени;
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

# widths <файл вывода> → "<макс. ширина> <непустых строк> <строк с полублоками>"
widths() {
    python3 -I - "$1" <<'PY'
import re, sys
raw = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
raw = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', raw)
lines = [l for l in raw.split('\n') if l.strip()]
big = [l for l in lines if re.search('[▀▄█]', l)]
print(max([len(l) for l in lines] or [0]), len(lines), len(big))
PY
}

# card_as <имя> <файл карточки> <локаль> → вывод карточки с подменённым именем
card_as() {
    echo "$1" > "$TMP/hn"
    sed "s|/proc/sys/kernel/hostname|$TMP/hn|" "$2" > "$TMP/card-host.sh"
    env -i PATH="$PATH" HOME="$TMP" LC_ALL="$3" TERM=xterm bash -u "$TMP/card-host.sh" 2>&1
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

        read -r wmax wn wbig < <(widths "$out")
        if [ "$wn" -lt 5 ]; then
            bad "$loc: карточка почти пустая (строк: $wn)"
        elif [ "$wmax" -gt "$MAX_WIDTH" ]; then
            bad "$loc: ширина $wmax > $MAX_WIDTH"
        else
            ok "$loc: $wn строк, самая широкая $wmax колонок"
        fi
        grep -F 'usfc-motd-card: ' "$card" >/dev/null && ok "метка версии карточки в скрипте" || bad "нет метки версии"
    done

    # без переменных локали вовсе — Unicode-рамка, а не ASCII
    env -i PATH="$PATH" HOME="$TMP" TERM=xterm bash -u "$card" >"$TMP/out-noloc" 2>&1
    grep -F '▰' "$TMP/out-noloc" >/dev/null && ok "без локали: Unicode-полоски" || bad "без локали: полоски ASCII"

    # крупное имя: в UTF-8 — две строки полублоков, в C и для длинного — нет
    card_as srv-01 "$card" C.UTF-8 > "$TMP/o-big"
    read -r wmax _ wbig < <(widths "$TMP/o-big")
    [ "$wbig" -eq 2 ] && ok "имя крупными буквами (2 строки)" || bad "крупного имени нет: строк с полублоками $wbig"
    card_as srv-01 "$card" C > "$TMP/o-c"
    read -r _ _ wbig < <(widths "$TMP/o-c")
    { [ "$wbig" -eq 0 ] && grep -F 'srv-01' "$TMP/o-c" >/dev/null; } && ok "C-локаль: имя обычным текстом" || bad "C-локаль: полублоков $wbig"
    long=very-long-hostname-for-test-node-1
    card_as "$long" "$card" C.UTF-8 > "$TMP/o-long"
    read -r wmax _ wbig < <(widths "$TMP/o-long")
    { [ "$wbig" -eq 0 ] && grep -F "$long" "$TMP/o-long" >/dev/null && [ "$wmax" -le "$MAX_WIDTH" ]; } \
        && ok "длинное имя — обычным текстом" || bad "длинное имя: полублоков $wbig, ширина $wmax"
    card_as 'Prod_DB.01' "$card" C.UTF-8 > "$TMP/o-mix"
    read -r wmax _ wbig < <(widths "$TMP/o-mix")
    [ "$wbig" -eq 2 ] && [ "$wmax" -le "$MAX_WIDTH" ] && ok "заглавные, точка, _ и цифры — крупно" || bad "смешанное имя: $wbig/$wmax"
    # IPv6 до 39 символов: строка с аптаймом переносится, а не вылезает
    sed -e "s|^\[ -n \"\$IP\" \] .*|IP=2001:0db8:85a3:0000:0000:8a2e:0370:7334|" -e "s|/proc/uptime|$TMP/up|" "$card" > "$TMP/card-v6.sh"
    echo '1100000.00 1.00' > "$TMP/up"
    env -i PATH="$PATH" HOME="$TMP" LC_ALL=C.UTF-8 bash -u "$TMP/card-v6.sh" > "$TMP/o-v6" 2>&1; rc=$?
    read -r wmax _ _ < <(widths "$TMP/o-v6")
    { [ "$rc" -eq 0 ] && grep -F '2001:0db8' "$TMP/o-v6" >/dev/null && [ "$wmax" -le "$MAX_WIDTH" ]; } \
        && ok "длинный IPv6: ширина $wmax" || bad "IPv6: rc=$rc ширина $wmax"
    for odd in 'host+1' 'a@b' 'x*y' 'q[1]' 'имя'; do
        card_as "$odd" "$card" C.UTF-8 > "$TMP/o-odd"; rc=$?
        read -r _ _ wbig < <(widths "$TMP/o-odd")
        { [ "$rc" -eq 0 ] && [ "$wbig" -eq 0 ] && ! grep -F 'unbound' "$TMP/o-odd" >/dev/null; } \
            && ok "«${odd}» — обычным текстом" || bad "«${odd}»: rc=$rc полублоков $wbig"
    done

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
echo "статус: карточка старой версии — устаревшая, повторный выбор её обновит"
printf '#!/bin/bash\n# Created by usfc (item "Login greeting"), card version 1.\n' > "$MOTD_FILE"
chmod 755 "$MOTD_FILE"
out="$(status_motd 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && [[ "$out" == *"!"* ]]; } && ok "v1: «!» и код 1 — выбор применит заново" || bad "v1: rc=$rc «$out»"
motd_card_script > "$MOTD_FILE"
out="$(status_motd 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [[ "$out" == *"✓"* ]]; } && ok "текущая: «✓» и код 0" || bad "текущая: rc=$rc «$out»"
chmod 644 "$MOTD_FILE"
status_motd >/dev/null 2>&1 && bad "неисполняемая считается установленной" || ok "без +x — не установлена"
rm -f "$MOTD_FILE"

echo ""
[ "$fail" -eq 0 ] && echo "карточка входа: все проверки пройдены" || echo "карточка входа: ЕСТЬ ОШИБКИ"
exit "$fail"
