#!/usr/bin/env bash
# Замер отрисовки меню: сколько занимает один кадр show_menu.
# Аргументы: <путь_к_setup.sh> <число_кадров>
set -uo pipefail
SETUP="$1"; N="${2:-10}"
USFC_SOURCE_ONLY=1; export USFC_SOURCE_ONLY
# shellcheck disable=SC1090
source "$SETUP"

# первый кадр греет кэши (dpkg, statuses) — меряем и его, и установившийся режим
t0=$(date +%s%N)
show_menu >/dev/null 2>&1
t1=$(date +%s%N)
for ((i = 0; i < N; i++)); do
    show_menu >/dev/null 2>&1
done
t2=$(date +%s%N)

first_ms=$(( (t1 - t0) / 1000000 ))
rest_ms=$(( (t2 - t1) / 1000000 / N ))
printf 'пунктов в меню: %s\n' "${#ITEM_IDS[@]}"
printf 'первый кадр   : %s мс\n' "$first_ms"
printf 'следующие     : %s мс/кадр (среднее по %s)\n' "$rest_ms" "$N"
