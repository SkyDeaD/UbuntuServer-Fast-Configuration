# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# Считаем всё разом и держим до ближайшего действия, которое реально что-то меняет.
declare -A STATUS_TEXT=() STATUS_RC=()
STATUS_DIRTY=true

invalidate_statuses() { STATUS_DIRTY=true; }

refresh_statuses() {
    [ "$STATUS_DIRTY" = false ] && return 0
    local id out rc
    for id in "${ITEM_IDS[@]}"; do
        out="$("status_${id}")"; rc=$?
        STATUS_TEXT[$id]="$out"
        STATUS_RC[$id]="$rc"
    done
    STATUS_DIRTY=false
}

# код возврата status_<id> из кэша — замена россыпи `status_"$id" >/dev/null; [ $? ... ]`
item_applied() {
    refresh_statuses
    [ "${STATUS_RC[${1}]:-1}" -eq 0 ]
}

# Короткий маркер состояния пункта → REPLY_MARKER (для узкой колонки в справке).
# Символ берём из уже посчитанного STATUS_TEXT — там он и так первый («✓», «○»,
# «!», «—»), — а цвет по STATUS_RC. Так второго источника истины не заводим:
# что показывает меню, то же увидит и справка.
REPLY_MARKER=''
status_marker() {
    local id="${1:-}" ch
    refresh_statuses
    strip_ansi "${STATUS_TEXT[$id]:-}"
    if [ "$CHARLEN_NATIVE" = true ]; then
        ch="${REPLY_PLAIN:0:1}"
    else
        # при небитом locale срез идёт по БАЙТАМ, и от «✓» остался бы огрызок:
        # берём ведущий байт вместе со всеми его континуационными
        local s="$REPLY_PLAIN" n=1
        while [ "$n" -lt "${#s}" ] && [[ "${s:n:1}" == [$'\x80'-$'\xbf'] ]]; do
            n=$((n + 1))
        done
        ch="${s:0:n}"
    fi
    [ -z "$ch" ] && ch='?'
    if [ "${STATUS_RC[$id]:-1}" -eq 0 ]; then
        REPLY_MARKER="${GREEN}${ch}${NC}"
    else
        REPLY_MARKER="${DIM}${ch}${NC}"
    fi
}

REPLY_COLOR=''
section_color_for() {
    case "${1:-}" in
        система)  REPLY_COLOR="$YELLOW" ;;
        база)     REPLY_COLOR="$CYAN" ;;
        сервисы)  REPLY_COLOR="$BLUE" ;;
        защита)   REPLY_COLOR="$MAGENTA" ;;
        *)        REPLY_COLOR="$NC" ;;
    esac
}
