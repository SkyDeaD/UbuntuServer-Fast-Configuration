#!/usr/bin/env bash
# Гоняет НАСТОЯЩИЕ функции отрисовки (show_menu, show_item_help) и меряет их
# вывод. Формулы ширин здесь намеренно не повторяются: второй источник истины
# разъехался бы с первым и «проходил» бы, ничего не проверяя.
#
# Проверяется два инварианта:
#   1. рамка ровно в TERM_W символов на любой строке и любой ширине;
#   2. колонки выровнены — номера пунктов по правому краю (1..9 и 10..14
#      в одну линию), метка ⇄ в своём столбике, а не приклеена к названию.
set -uo pipefail
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"

# show_menu/show_item_help сами зовут refresh_term_width и перетёрли бы заданную
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

# render <menu|help> — вывод экрана без ANSI. Пустая строка на stdin нужна
# show_item_help: она ждёт номер пункта и по Enter выходит
render() {
    case "$1" in
        menu) show_menu 2>/dev/null ;;
        help) printf '\n' | show_item_help 2>/dev/null ;;
        aliases) printf '\n' | show_aliases_help 2>/dev/null ;;
    esac | sed 's/\x1b\[[0-9;]*m//g'
}

fail=0

# Английский и русский дают разную длину строк, и рамка едет там, где
# по-русски всё влезало. Поэтому обе раскладки меряются одним и тем же тестом.
LANGS="${USFC_TEST_LANGS:-ru en}"

# ── 1. ширина рамки ───────────────────────────────────────────────────────────
for USFC_LANG in $LANGS; do
usfc_registry_apply_lang
for screen in menu help aliases; do
    for tw in 58 78 98 118; do
        # shellcheck disable=SC2034  # читается внутри функций отрисовки
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
        done < <(render "$screen")
        if [ "$bad" -eq 0 ]; then
            printf '%-2s %-5s TERM_W=%-4s рамка ровная\n' "$USFC_LANG" "$screen" "$tw"
        else
            printf '%-2s %-5s TERM_W=%-4s КРИВЫХ СТРОК %s\n' "$USFC_LANG" "$screen" "$tw" "$bad"
            fail=1
        fi
    done
done
done

# ── 2. выравнивание колонок ───────────────────────────────────────────────────
# uniq_count <список чисел через пробел> → сколько различных значений
uniq_count() {
    local n seen='' c=0
    for n in $1; do
        case " $seen " in *" $n "*) continue ;; esac
        seen="$seen $n"; c=$((c + 1))
    done
    printf '%s' "$c"
}

for USFC_LANG in $LANGS; do
usfc_registry_apply_lang
for screen in menu help; do
    for tw in 58 78 98 118; do
        # shellcheck disable=SC2034
        TERM_W=$tw
        idx_ends='' mark_cols='' rows=0 marks=0
        while IFS= read -r line; do
            s="${line#  }"
            [ "${s:0:1}" = '│' ] || continue
            rest="${s#│}"; cell="${rest%%│*}"
            # только строки пунктов: в ячейке номера ровно число и пробелы.
            # Отсекает и подзаголовки разделов, и легенду (там тоже есть цифры)
            [[ "$cell" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || continue
            rows=$((rows + 1))
            # правый край номера = длина ячейки без хвостовых пробелов
            trimmed="${cell%"${cell##*[![:space:]]}"}"
            visible_len "$trimmed"; idx_ends="${idx_ends} ${REPLY_LEN}"
            if [[ "$s" == *⇄* ]]; then
                marks=$((marks + 1))
                pre="${s%%⇄*}"; visible_len "$pre"; mark_cols="${mark_cols} ${REPLY_LEN}"
            fi
        done < <(render "$screen")

        # 14 пунктов и 7 помеченных — если разбор поехал, дальше мерить нечего
        if [ "$rows" -ne "${#ITEM_IDS[@]}" ]; then
            printf '%-5s TERM_W=%-4s разобрано строк: %s, ожидалось %s\n' \
                "$screen" "$tw" "$rows" "${#ITEM_IDS[@]}"
            fail=1; continue
        fi
        if [ "$marks" -ne "${#DISABLE_SUPPORTED[@]}" ]; then
            printf '%-5s TERM_W=%-4s меток ⇄: %s, ожидалось %s\n' \
                "$screen" "$tw" "$marks" "${#DISABLE_SUPPORTED[@]}"
            fail=1; continue
        fi

        n_idx="$(uniq_count "$idx_ends")"
        n_mark="$(uniq_count "$mark_cols")"
        if [ "$n_idx" -eq 1 ] && [ "$n_mark" -eq 1 ]; then
            printf '%-2s %-5s TERM_W=%-4s номера и ⇄ выровнены\n' "$USFC_LANG" "$screen" "$tw"
        else
            [ "$n_idx" -ne 1 ] && printf '%-2s %-5s TERM_W=%-4s номера вразнобой:%s\n' "$USFC_LANG" "$screen" "$tw" "$idx_ends"
            [ "$n_mark" -ne 1 ] && printf '%-2s %-5s TERM_W=%-4s метка ⇄ вразнобой:%s\n' "$USFC_LANG" "$screen" "$tw" "$mark_cols"
            fail=1
        fi
    done
done
done

# ── 3. прогресс-бар в шапке (build_progress) ──────────────────────────────────
# На всех ширинах и обоих языках строка версии + прогресс-бара не должна
# вылезать за TERM_W (проверяем с done=10 из всех пунктов)
for USFC_LANG in $LANGS; do
    usfc_registry_apply_lang
    for i in "${!ITEM_IDS[@]}"; do
        id="${ITEM_IDS[$i]}"
        if [ "$i" -lt 10 ]; then STATUS_RC[$id]=0; else STATUS_RC[$id]=1; fi
    done
    for tw in 58 78 98 118; do
        # shellcheck disable=SC2034
        TERM_W=$tw
        build_progress
        pad_title "USFC v${VERSION} by SkyDeaD" 32
        full_line="  ${REPLY_PAD}  ${REPLY_PROGRESS}"
        visible_len "$full_line"; full_w="$REPLY_LEN"
        visible_len "$REPLY_PROGRESS"; prog_w="$REPLY_LEN"; prog_plain="$REPLY_PLAIN"
        if [ -n "$REPLY_PROGRESS" ] && [[ "$prog_plain" == *"10"*"${#ITEM_IDS[@]}"* ]] \
           && [ "$prog_w" -le "$tw" ] && [ "$full_w" -le "$tw" ]; then
            printf '%-2s prog  TERM_W=%-4s ширина %s/%s <= %s\n' "$USFC_LANG" "$tw" "$prog_w" "$full_w" "$tw"
        else
            printf '%-2s prog  TERM_W=%-4s ПЕРЕПОЛНЕНИЕ или пустой вывод: prog=%s full=%s (> %s): %s\n' \
                "$USFC_LANG" "$tw" "$prog_w" "$full_w" "$tw" "$prog_plain"
            fail=1
        fi
    done
done

# ── 4. рамка итогов прогона (show_summary) при заголовке 26+ символов ─────────
# Регрессия на pad_title +1: при длине названия ровно name_w (26) и больше
# pad_title добавлял лишний пробел и сдвигал правую рамку на 1 символ.
for USFC_LANG in $LANGS; do
    usfc_registry_apply_lang
    summary_reset
    # shellcheck disable=SC2034  # читаются внутри show_summary
    SUMMARY_TITLES=(
        "Короткий пункт"
        "Ровно двадцать шесть симв!"
        "Очень длинное название пункта длиннее двадцати шести символов"
    )
    # shellcheck disable=SC2034
    SUMMARY_RESULTS=("✓ готово" "— пропущено" "✗ ошибка")
    # shellcheck disable=SC2034
    SUMMARY_TIMES=("1s" "0s" "12s")
    # shellcheck disable=SC2034
    SUMMARY_WHY=("" "требует подтверждения отдельно" "")
    for tw in 58 78 98 118; do
        # shellcheck disable=SC2034
        TERM_W=$tw
        widths='' frame_rows=0 max_w=0
        while IFS= read -r line; do
            case "$line" in
                *'│'*|*'╭'*|*'╰'*|*'├'*)
                    s="${line#  }"
                    visible_len "$s"
                    widths="${widths} ${REPLY_LEN}"
                    [ "$REPLY_LEN" -gt "$max_w" ] && max_w="$REPLY_LEN"
                    frame_rows=$((frame_rows + 1))
                    ;;
            esac
        done < <(show_summary 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
        n_w="$(uniq_count "$widths")"
        if [ "$frame_rows" -eq 5 ] && [ "$n_w" -eq 1 ] && [ "$max_w" -le "$tw" ]; then
            printf '%-2s summ  TERM_W=%-4s рамка ровная (%s симв.)\n' "$USFC_LANG" "$tw" "$max_w"
        else
            printf '%-2s summ  TERM_W=%-4s КРИВАЯ РАМКА (строк=%s, ширин=%s:%s)\n' \
                "$USFC_LANG" "$tw" "$frame_rows" "$n_w" "$widths"
            fail=1
        fi
    done
done
summary_reset

# ── 5. цвет маркера «!» в status_marker ───────────────────────────────────────
# При STATUS_RC=1 и тексте, начинающемся с «!», маркер обязан краситься
# в $YELLOW, а не в тусклый $DIM (как «○»). В подоболочке включаем реальные
# ANSI-коды: без терминала core.sh обнуляет цвета, и проверка стала бы пустой.
marker_out="$(
    # shellcheck disable=SC2034  # читаются в status_marker
    YELLOW='\033[0;33m'; GREEN='\033[0;32m'; DIM='\033[2m'; NC='\033[0m'
    # shellcheck disable=SC2034
    STATUS_DIRTY=false
    id="${ITEM_IDS[0]}"
    STATUS_RC[$id]=1
    STATUS_TEXT[$id]="${YELLOW}! настроено частично${NC}"
    status_marker "$id"
    [ "$REPLY_MARKER" = "${YELLOW}!${NC}" ] || { printf 'warn-colored=%q\n' "$REPLY_MARKER"; exit 1; }

    STATUS_TEXT[$id]="! требует внимания"
    status_marker "$id"
    [ "$REPLY_MARKER" = "${YELLOW}!${NC}" ] || { printf 'warn-plain=%q\n' "$REPLY_MARKER"; exit 1; }

    STATUS_TEXT[$id]="○ не настроено"
    status_marker "$id"
    [ "$REPLY_MARKER" = "${DIM}○${NC}" ] || { printf 'unapplied=%q\n' "$REPLY_MARKER"; exit 1; }

    # shellcheck disable=SC2034
    STATUS_RC[$id]=0
    # shellcheck disable=SC2034
    STATUS_TEXT[$id]="${GREEN}✓ настроено${NC}"
    status_marker "$id"
    [ "$REPLY_MARKER" = "${GREEN}✓${NC}" ] || { printf 'applied=%q\n' "$REPLY_MARKER"; exit 1; }
    echo ok
)"
if [ "$marker_out" = ok ]; then
    printf 'status_marker: ! → YELLOW, ○ → DIM, ✓ → GREEN\n'
else
    printf 'status_marker: ОШИБКА (%s)\n' "$marker_out"
    fail=1
fi

exit "$fail"
