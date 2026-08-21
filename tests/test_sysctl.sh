#!/usr/bin/env bash
# vm.swappiness / vm.vfs_cache_pressure: применяются ли рекомендованные значения.
#
# Пользовательская жалоба была ровно про это: при массовом применении пунктов
# настройки не применялись. Причина — строка
#     [ "$cur_sw" != "60" ] || [ "$cur_vfs" != "100" ] && sysctl_default=N
# разбиралась как (A || B) && C, поэтому «да» выпадало ТОЛЬКО на нетронутой
# машине ровно с 60/100; а ask_yn в пакетном режиме при дефолте «нет» молча
# возвращает «нет», не показав вопрос.
set -uo pipefail
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/vm"
# shellcheck disable=SC2034  # читается внутри zram_apply_sysctl и audit_sysctl
USFC_PROC_VM="$TMP/vm"

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: ожидалось «$2», получено «$3»"; fi; }

vm() { echo "$1" > "$TMP/vm/swappiness"; echo "$2" > "$TMP/vm/vfs_cache_pressure"; }

# Заглушки внешних действий: записан ли файл и звали ли sysctl
# Факт записи отмечаем ФАЙЛОМ, а не переменной: write_file зовут через
# конвейер (`printf ... | write_file`), а правая часть конвейера — подоболочка,
# и присваивание из неё до проверок бы не дожило
write_file() { echo "$1" >> "$TMP/wrote"; cat >/dev/null; }
sysctl()     { :; }
ANSWERED=""
ask_yn_t()   { ANSWERED="${3:-Y}"; [ "${3:-Y}" = Y ]; }
WROTE=false

run() {  # run <swappiness> <vfs> [SYSCTL_BULK] → WROTE, ANSWERED
    vm "$1" "$2"
    SYSCTL_BULK="${3:-}"
    rm -f "$TMP/wrote"; ANSWERED=""
    zram_apply_sysctl >/dev/null 2>&1
    if [ -s "$TMP/wrote" ]; then WROTE=true; else WROTE=false; fi
}

echo "предзаданный ответ из предзапроса"
run 10 50 Y;  is "SYSCTL_BULK=Y → применили"          true  "$WROTE"
run 10 50 Y;  is "и вопроса не задавали"              ""    "$ANSWERED"
run 60 100 N; is "SYSCTL_BULK=N → не применили"       false "$WROTE"

echo ""
echo "ответа нет — считаем дефолт сами"
run 60 100;   is "заводские 60/100 → спросили с дефолтом Y" "Y" "$ANSWERED"
run 60 100;   is "и применили"                              true "$WROTE"
run 10 100;   is "одно отклонение → всё ещё Y"              "Y" "$ANSWERED"
run 60 50;    is "другое отклонение → всё ещё Y"            "Y" "$ANSWERED"
run 10 50;    is "оба не заводские → дефолт N"              "N" "$ANSWERED"
run '?' '?';  is "значения не прочитались → дефолт N"       "N" "$ANSWERED"

echo ""
echo "уже настроено"
run 80 50;    is "80/50 → ничего не пишем"  false "$WROTE"
run 80 50;    is "и не спрашиваем"          ""    "$ANSWERED"

echo ""
echo "проводка ответа"
SYSCTL_BULK=Y; reset_bulk_answers
is "reset_bulk_answers гасит SYSCTL_BULK" "" "$SYSCTL_BULK"
printf 'ITEMS=zram\nSYSCTL=N\n' > "$TMP/conf"
load_config "$TMP/conf" >/dev/null 2>&1
is "ключ SYSCTL из файла ответов принят" "N" "$SYSCTL_BULK"

echo ""
[ "$fail" -eq 0 ] && echo "sysctl: все проверки пройдены" || echo "sysctl: ЕСТЬ ПРОВАЛЫ"
exit "$fail"
