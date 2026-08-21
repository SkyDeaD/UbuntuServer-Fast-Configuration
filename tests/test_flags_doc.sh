#!/usr/bin/env bash
# Справочник флагов в README не должен разъезжаться с кодом.
#
# Документация врёт молча: добавил флаг — забыл описать, убрал — забыл вычеркнуть.
# Ни один прогон скрипта этого не заметит, а человек, который по README собирает
# команду, упрётся в «Unknown option» или не найдёт нужного флага вовсе.
#
# Сверяем в обе стороны и на обоих языках.
set -uo pipefail

SRC="${1:-src/lib/cli.sh}"
INST="${2:-install.sh}"
ROOT="$(dirname "$INST")"

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }

# Флаги, которые код реально разбирает: ветки case вида `--apply|-a)`
flags_of() {
    grep -oE '^[[:space:]]+(--?[a-zA-Z][a-zA-Z-]*(\|--?[a-zA-Z][a-zA-Z-]*)*)\)' "$1" \
        | tr -d ' )' | tr '|' '\n' | sed 's/\*$//' | sort -u
}

real="$(flags_of "$SRC"; flags_of "$INST")"
[ -n "$real" ] || { echo "не нашёл ни одного флага в коде — разбор сломался" >&2; exit 2; }

for doc in "$ROOT/README.md" "$ROOT/README.en.md"; do
    [ -f "$doc" ] || { bad "нет файла $doc"; continue; }
    missing=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        grep -qF -- "\`$f\`" "$doc" || missing="${missing}${missing:+, }${f}"
    done <<< "$real"
    if [ -n "$missing" ]; then
        bad "$(basename "$doc"): не описаны флаги — ${missing}"
    else
        ok "$(basename "$doc"): описаны все $(printf '%s\n' "$real" | grep -c .) флага"
    fi

    # обратная сторона: описанного флага может не быть в коде
    extra=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        printf '%s\n' "$real" | grep -qxF -- "$f" || extra="${extra}${extra:+, }${f}"
    done < <(grep -oE '`--[a-z][a-z-]+`' "$doc" | tr -d '`' | sort -u)
    if [ -n "$extra" ]; then
        bad "$(basename "$doc"): описаны несуществующие флаги — ${extra}"
    else
        ok "$(basename "$doc"): выдуманных флагов нет"
    fi
done

echo ""
[ "$fail" -eq 0 ] && echo "справочник флагов: сходится с кодом" || echo "справочник флагов: РАСХОЖДЕНИЯ"
exit "$fail"
