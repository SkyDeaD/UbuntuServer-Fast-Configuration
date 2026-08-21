#!/usr/bin/env bash
# Мастер первого запуска: разбор ответа, существование профилей, отсев пунктов.
#
# Интерактив здесь не нужен: разбор ответа вынесен в wizard_parse отдельной
# функцией ровно для того, чтобы его можно было проверить без терминала —
# так же, как _usfc_lang_parse у вопроса о языке.
set -uo pipefail
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: ожидалось «$2», получено «$3»"; fi; }

echo "wizard_parse"
for pair in "1:minimal" "2:web" "3:dockerhost" "4:secure" \
            "m:minimal" "w:web" "d:dockerhost" "s:secure" \
            "minimal:minimal" "web:web" "dockerhost:dockerhost" "secure:secure" \
            "WEB:web" "Веб:web" "защита:secure" \
            "5:" ":" "мусор:" "0:" "99:"; do
    ans="${pair%%:*}"; want="${pair#*:}"
    wizard_parse "$ans"
    is "«${ans:-<пусто>}» → ${want:-меню}" "$want" "$REPLY_WIZARD_PROFILE"
done

echo ""
echo "профили, которые называет мастер"
# Ловит переименование профиля: мастер молча предлагал бы несуществующий
for name in minimal web dockerhost secure; do
    if [ -n "${USFC_PROFILES[$name]:-}" ]; then ok "профиль ${name} существует"
    else bad "профиль ${name} назван мастером, но его нет в USFC_PROFILES"; fi
    if resolve_items "$name" >/dev/null 2>&1 && [ "${#REPLY_ITEM_NUMS[@]}" -gt 0 ]; then
        ok "  разворачивается в ${#REPLY_ITEM_NUMS[@]} пункт(ов)"
    else
        bad "  ${name} не разворачивается в пункты"
    fi
done

echo ""
echo "filter_pending"
# Ничего не применено: всё в очередь, кроме sshhardening
for id in "${ITEM_IDS[@]}"; do STATUS_RC[$id]=1; done
# shellcheck disable=SC2034  # читаются функциями из statecache.sh
STATUS_DIRTY=false
resolve_items all >/dev/null 2>&1
filter_pending "${REPLY_ITEM_NUMS[@]}"
is "ничего не применено → в очереди все, кроме одного" \
   "$(( ${#ITEM_IDS[@]} - 1 ))" "${#REPLY_PENDING[@]}"
case " ${REPLY_SKIPPED[*]} " in
    *" sshhardening "*) ok "sshhardening всегда в пропущенных" ;;
    *) bad "sshhardening не попал в пропущенные" ;;
esac

# Всё применено: очередь пуста
# shellcheck disable=SC2034
for id in "${ITEM_IDS[@]}"; do STATUS_RC[$id]=0; done
filter_pending "${REPLY_ITEM_NUMS[@]}"
is "всё применено → очередь пуста" 0 "${#REPLY_PENDING[@]}"
is "и всё ушло в «уже применено»" "$(( ${#ITEM_IDS[@]} - 1 ))" "${#REPLY_ALREADY[@]}"

echo ""
[ "$fail" -eq 0 ] && echo "мастер: все проверки пройдены" || echo "мастер: ЕСТЬ ПРОВАЛЫ"
exit "$fail"
