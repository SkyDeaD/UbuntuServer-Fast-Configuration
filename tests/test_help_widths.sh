#!/usr/bin/env bash
# Рамка экрана справки обязана совпадать с TERM_W на любой ширине —
# та же проверка, что уже есть для таблицы меню.
set -uo pipefail
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"

# show_item_help сама зовёт refresh_term_width и перетёрла бы заданную ширину
refresh_term_width() { :; }

# Подставляем заведомо известные статусы, чтобы ширина не зависела от того,
# что реально установлено на машине, где гоняются тесты.
# shellcheck disable=SC2034  # всё это читается внутри функций из setup.sh
for id in "${ITEM_IDS[@]}"; do
    STATUS_TEXT[$id]="○ не установлен"
    STATUS_RC[$id]=1
done
# shellcheck disable=SC2034
STATUS_DIRTY=false

fail=0
for tw in 58 78 98 118; do
    # shellcheck disable=SC2034  # читается внутри show_item_help
    TERM_W=$tw
    bad=0
    while IFS= read -r line; do
        case "$line" in
            *'│'*|*'╭'*|*'╰'*|*'├'*)
                s="${line#  }"
                visible_len "$s"
                if [ "$REPLY_LEN" -ne "$tw" ]; then
                    bad=$((bad + 1))
                    [ "$bad" -le 2 ] && printf '    %s симв. вместо %s: %.60s\n' "$REPLY_LEN" "$tw" "$s"
                fi
                ;;
        esac
    done < <(printf '\n' | show_item_help 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
    if [ "$bad" -eq 0 ]; then
        printf 'TERM_W=%-4s рамка справки ровная\n' "$tw"
    else
        printf 'TERM_W=%-4s КРИВЫХ СТРОК %s\n' "$tw" "$bad"
        fail=1
    fi
done
exit "$fail"
