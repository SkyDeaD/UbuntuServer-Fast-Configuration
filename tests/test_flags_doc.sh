#!/usr/bin/env bash
# Справочник команд docs/CLI*.md не должен разъезжаться с кодом.
#
# Документация врёт молча: добавил флаг — забыл описать, убрал — забыл вычеркнуть.
# Ни один прогон скрипта этого не заметит, а человек, который по справочнику
# собирает команду, упрётся в «неизвестная опция» или не найдёт нужного флага.
#
# Источники правды: USFC_COMMANDS, ветки case в parse_args, таблица
# USFC_ANSWER_KEYS (флаги ответов, у «да/нет» — ещё и --no-…) и install.sh.
# Сверяем в обе стороны и на обоих языках.
set -uo pipefail

SETUP="${1:-src/setup.sh}"
INST="${2:-install.sh}"
ROOT="$(dirname "$INST")"
CLI="$(dirname "$SETUP")/lib/cli.sh"

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }

# ветки case вида `--dry-run)` или `-y|--yes)` внутри указанной функции
# (пустое имя — во всём файле)
case_flags() {
    awk -v fn="$2" 'BEGIN { on = (fn == "") }
        fn != "" && $0 ~ "^" fn "\\(\\)" { on = 1 }
        fn != "" && on && /^}/ { on = 0 }
        on' "$1" \
        | grep -oE '^[[:space:]]+(--?[a-zA-Z][a-zA-Z-]*(=\*)?(\|--?[a-zA-Z][a-zA-Z-]*(=\*)?)*)\)' \
        | tr -d ' )' | tr '|' '\n' | sed 's/=\*$//' | grep -E '^--[a-z]' | sort -u
}

# shellcheck disable=SC2016  # $-выражения раскрываются во внутренней оболочке
table="$(USFC_SOURCE_ONLY=1 bash -c 'source "$1"
    echo "CMDS $USFC_COMMANDS"
    for row in "${USFC_ANSWER_KEYS[@]}"; do
        IFS="|" read -r _ _ ty fl _ <<< "$row"
        [ -n "$fl" ] || continue
        echo "$fl"; [ "$ty" = yn ] && echo "--no-${fl#--}"
    done
    echo "--set"' _ "$SETUP")" || { echo "не загрузился $SETUP" >&2; exit 2; }

commands="$(printf '%s\n' "$table" | sed -n 's/^CMDS //p' | tr ' ' '\n' | grep .)"
flags="$( { printf '%s\n' "$table" | grep -E '^--'; case_flags "$CLI" parse_args; case_flags "$INST" '' ; } | sort -u)"
legacy="$(case_flags "$CLI" _cli_old_form)"
[ -n "$commands" ] && [ -n "$flags" ] || { echo "не нашёл ни команд, ни флагов — разбор сломался" >&2; exit 2; }

for doc in "$ROOT/docs/CLI.md" "$ROOT/docs/CLI.en.md"; do
    name="docs/$(basename "$doc")"
    [ -f "$doc" ] || { bad "нет файла $name"; continue; }

    missing=""
    while IFS= read -r c; do
        grep -qE -- "\`usfc $c( |\`)" "$doc" || missing="${missing}${missing:+, }${c}"
    done <<< "$commands"
    [ -z "$missing" ] && ok "$name: описаны все $(grep -c . <<< "$commands") команд" \
        || bad "$name: не описаны команды — ${missing}"

    missing=""
    while IFS= read -r f; do
        grep -qE -- "\`${f}( |=|\`)" "$doc" || missing="${missing}${missing:+, }${f}"
    done <<< "$flags"
    [ -z "$missing" ] && ok "$name: описаны все $(grep -c . <<< "$flags") флагов" \
        || bad "$name: не описаны флаги — ${missing}"

    # обратная сторона: описанного флага может не быть в коде. Старые формы
    # 4.x упоминать можно — разбор их узнаёт и подсказывает новую строку
    extra=""
    while IFS= read -r f; do
        grep -qxF -- "$f" <<< "$flags" || grep -qxF -- "$f" <<< "$legacy" \
            || extra="${extra}${extra:+, }${f}"
    done < <(grep -oE '`--[a-z][a-z-]+' "$doc" | tr -d '`' | sort -u)
    [ -z "$extra" ] && ok "$name: выдуманных флагов нет" || bad "$name: описаны несуществующие флаги — ${extra}"
done

echo ""
[ "$fail" -eq 0 ] && echo "справочник команд: сходится с кодом" || echo "справочник команд: РАСХОЖДЕНИЯ"
exit "$fail"
