# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# Реестр пунктов меню
# ═══════════════════════════════════════════════════════════════
# Раньше пункт был размазан по шести параллельным массивам, которые
# приходилось держать синхронными руками (в CI была отдельная проверка длин).
# Теперь каждый файл lib/items/*.sh регистрирует себя сам, а массивы ниже
# собираются из этих вызовов — рассинхронизировать больше нечего.
#
# Массивы сохранены как есть: их читают show_menu, show_item_help,
# item_number и режим A. Меняется только способ их наполнения.
#
# Порядок пунктов в меню = порядок модулей items/* в src/MODULES.
ITEM_IDS=()
ITEM_TITLES=()
ITEM_SECTIONS=()
ITEM_SHORT=()
ITEM_FULL=()
ROLLBACK_NOTES=()
DISABLE_SUPPORTED=()

# usfc_item <id> <раздел> <название> <краткое> [англ. название] [англ. краткое]
# Английские варианты необязательны: пока их нет, показывается русский —
# это лучше пустой ячейки в таблице, и видно, что ещё не переведено.
usfc_item() {
    ITEM_IDS+=("$1")
    ITEM_SECTIONS+=("$2")
    if [ "$USFC_LANG" = en ]; then
        ITEM_TITLES+=("${5:-$3}")
        ITEM_SHORT+=("${6:-$4}")
    else
        ITEM_TITLES+=("$3")
        ITEM_SHORT+=("$4")
    fi
    ITEM_FULL+=("")
    ROLLBACK_NOTES+=("")
}

# Названия разделов. Раздел хранится по-русски (он же ключ для букв C/B/S/P),
# а показывается на языке интерфейса
section_label() {
    case "${1}" in
        система) t "система" "system"  ;;
        база)    t "база"    "base"    ;;
        сервисы) t "сервисы" "services";;
        защита)  t "защита"  "security";;
        *)       REPLY_T="$1" ;;
    esac
}

# Индекс пункта → REPLY_ITEM_IDX. Отдельно от item_number: тому нужен
# человеческий номер с единицы, а здесь нужен индекс массива
REPLY_ITEM_IDX=-1
_usfc_item_idx() {
    local i
    REPLY_ITEM_IDX=-1
    for i in "${!ITEM_IDS[@]}"; do
        [ "${ITEM_IDS[$i]}" = "$1" ] && { REPLY_ITEM_IDX="$i"; return 0; }
    done
    echo "usfc_item: пункт '$1' не зарегистрирован" >&2
    return 1
}

# Полное описание для экрана справки
usfc_item_full() {
    _usfc_item_idx "$1" || return 1
    ITEM_FULL[$REPLY_ITEM_IDX]="$2"
}

# Команды «удалить совсем» для экрана справки
usfc_item_rollback() {
    _usfc_item_idx "$1" || return 1
    ROLLBACK_NOTES[$REPLY_ITEM_IDX]="$2"
}

# Пункт умеет выключаться повторным выбором (метка ⇄ в таблице)
usfc_item_toggle() {
    DISABLE_SUPPORTED+=("$1")
}

# Буквы разделов. Раньше раскрытие B/S/P было зашито числами прямо в main()
# ("B) valid+=(1 2 3 4)"), и любой новый пункт молча ломал его. Теперь это
# единственный источник истины, а номера выводятся из ITEM_SECTIONS.
SECTION_NAMES=(система база сервисы защита)
SECTION_LETTERS=(C B S P)

# item_number <id> → номер пункта в меню. Нужен сообщениям вида «настройте
# отдельно пунктом N»: захардкоженные там числа разъезжались с меню при каждом
# добавлении пункта, причём молча
item_number() {
    local id="${1:-}" i
    for i in "${!ITEM_IDS[@]}"; do
        [ "${ITEM_IDS[$i]}" = "$id" ] && { printf '%s' "$((i + 1))"; return 0; }
    done
    printf '?'
    return 1
}

# expand_section_letter <буква> → номера пунктов этого раздела (через пробел)
REPLY_SECTION_ITEMS=''

expand_section_letter() {
    local letter="${1:-}" i sec want=''
    for i in "${!SECTION_LETTERS[@]}"; do
        [ "${SECTION_LETTERS[$i]}" = "$letter" ] && { want="${SECTION_NAMES[$i]}"; break; }
    done
    REPLY_SECTION_ITEMS=''
    [ -z "$want" ] && return 1
    for i in "${!ITEM_SECTIONS[@]}"; do
        sec="${ITEM_SECTIONS[$i]}"
        [ "$sec" = "$want" ] && REPLY_SECTION_ITEMS="${REPLY_SECTION_ITEMS}${REPLY_SECTION_ITEMS:+ }$((i + 1))"
    done
    return 0
}

item_supports_disable() {
    local id="${1:-}" d
    for d in "${DISABLE_SUPPORTED[@]}"; do [ "$d" = "$id" ] && return 0; done
    return 1
}
