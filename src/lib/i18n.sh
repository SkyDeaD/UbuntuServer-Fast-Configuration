# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# Язык интерфейса
# ═══════════════════════════════════════════════════════════════
# Перевод живёт РЯДОМ С ВЫЗОВОМ, а не в таблице ключей:
#
#     log_info_t "Пользователь: X" "User: X"
#
# Таблица ключей выглядит аккуратнее, но на практике расходится: строку
# правят в одном месте, ключ забывают в другом, и половина сообщений
# застревает в прошлой формулировке. Здесь оба варианта видно одновременно,
# и забыть второй невозможно — он в тех же кавычках.
#
# Ни одного форка: t() пишет в REPLY_T по тому же соглашению, что и остальная
# разметка. Отрисовка меню стоит 15 мс, и подстановка $(...) на каждую строку
# вернула бы нас к секундам, от которых уходили.
#
# ЯЗЫК ПО УМОЛЧАНИЮ — РУССКИЙ, и это осознанно. Определять его по локали
# нельзя: bootstrap форсирует LC_ALL=C.UTF-8, а на серверах и без того обычно
# стоит C или en_US — все нынешние пользователи разом получили бы английский
# интерфейс без спроса. Английский включается явно: --lang en или USFC_LANG=en.
# Выбор языка запоминается в файле рядом с установкой. Он переживает
# обновление: апдейтер подменяет setup.sh, VERSION, MODULES и каталог lib,
# а посторонние файлы не трогает.
USFC_LANG_FILE="${USFC_ROOT:-/opt/vps-setup}/lang"

# Приоритет: явный --lang / USFC_LANG → сохранённый выбор → русский.
# Флаг одноразовый и НЕ сохраняется: одноразовый запуск на чужом языке
# не должен молча переучивать инструмент. Запоминается только выбор
# из меню и ответ при первом запуске.
USFC_LANG_EXPLICIT=false
if [ -n "${USFC_LANG:-}" ]; then
    USFC_LANG_EXPLICIT=true
else
    # Инициализация обязательна, а не косметика: без неё под set -u падает
    # первый же case по $USFC_LANG, когда файла выбора ещё нет
    USFC_LANG=""
    # Существование проверяем ОТДЕЛЬНО: `< несуществующий` ругается сам shell,
    # ещё до запуска tr, и 2>/dev/null на команде это сообщение не глушит
    if [ -s "$USFC_LANG_FILE" ]; then
        USFC_LANG="$(tr -d '[:space:]' < "$USFC_LANG_FILE" 2>/dev/null)"
    fi
fi
case "$USFC_LANG" in
    ru|en) ;;
    *)     USFC_LANG=ru ;;
esac

# Был ли выбор сделан осознанно — от этого зависит, спрашивать ли при старте
usfc_lang_saved() { [ -s "$USFC_LANG_FILE" ]; }

# Есть ли кому отвечать. Условие спрашивается и вопросом о языке, и мастером
# первого запуска; разъехавшись, они дали бы зависание на чтении с /dev/tty
usfc_interactive() { [ -t 0 ] && [ -e /dev/tty ]; }

usfc_lang_save() {
    [ -n "${USFC_SOURCE_ONLY:-}" ] && return 0
    printf '%s\n' "$1" > "$USFC_LANG_FILE" 2>/dev/null || {
        echo "  Не удалось сохранить выбор языка в ${USFC_LANG_FILE}" >&2  # i18n-ok: пара строкой ниже
        echo "  Could not save the language choice to ${USFC_LANG_FILE}" >&2
        return 1
    }
}

# Список языков. Двуязычный по необходимости: при первом запуске ещё
# неизвестно, какой язык человек понимает, и спросить на одном — значит
# половине пользователей показать непонятное.
#
# Один и тот же список и при первом запуске, и при смене из меню: разведи их
# по двум функциям — и они разойдутся при первой же правке.
#
# _usfc_lang_options <помечать ли текущий>
_usfc_lang_options() {
    local cur_ru='' cur_en=''
    if [ "$1" = true ]; then
        t "(сейчас)" "(current)"
        case "$USFC_LANG" in
            ru) cur_ru="  ${DIM}${REPLY_T}${NC}" ;;
            en) cur_en="  ${DIM}${REPLY_T}${NC}" ;;
        esac
    fi
    echo ""
    # i18n-ok: список языков намеренно двуязычен — на этом шаге ещё неизвестно,
    # какой из них человек понимает
    echo -e "  ${BOLD}Язык интерфейса${NC}  ${DIM}/${NC}  ${BOLD}Interface language${NC}"  # i18n-ok
    echo -e "    ${CYAN}${BOLD}1${NC}) Русский${cur_ru}"   # i18n-ok: название языка на нём самом
    echo -e "    ${CYAN}${BOLD}2${NC}) English${cur_en}"
    echo ""
}

# Ответ → REPLY_LANG (ru|en), либо пусто, если не разобрали
REPLY_LANG=''
_usfc_lang_parse() {
    case "$1" in
        1|r|R|ru|RU|Ru|рус|русский|Русский) REPLY_LANG=ru ;;  # i18n-ok: разбор ВВОДА, не вывод
        2|e|E|en|EN|En|english|English)     REPLY_LANG=en ;;
        *)                                  REPLY_LANG='' ;;
    esac
}

# Вопрос при первом запуске: пустой ответ и мусор дают русский — на этом шаге
# отменять нечего, язык нужен прямо сейчас.
usfc_ask_language() {
    _usfc_lang_options false
    local choice
    echo -en "  ${BOLD}Выбор / Choice${NC} ${DIM}[1]:${NC} "   # i18n-ok: двуязычный по замыслу
    read -r choice </dev/tty
    _usfc_lang_parse "$choice"
    USFC_LANG="${REPLY_LANG:-ru}"
    usfc_lang_save "$USFC_LANG"
    echo ""
    t "Язык сохранён. Сменить потом — клавиша L в меню." \
      "Language saved. Change it later with the L key in the menu."
    log_info "$REPLY_T"
}

# Смена языка из меню.
#
# Раньше это был слепой тумблер: брал «противоположный» язык, сохранял и сразу
# exec-ал. Ни вопроса, ни сообщения — а сообщение и не помогло бы, exec
# перерисовывает экран, и любой вывод перед ним мгновенно исчезает. Нажал —
# и гадаешь, что произошло. Плюс «противоположный» перестанет иметь смысл
# на третьем языке. Поэтому здесь тот же список, что при первом запуске,
# только с пометкой текущего выбора и с отменой по Enter.
#
# Перезапускаем себя, а не правим переменные на лету: названия и описания
# пунктов складываются в массивы при загрузке модулей (usfc_item), и смена
# языка без пересборки реестра обновила бы половину экрана. exec заодно
# гарантирует, что от прежнего языка ничего не осталось.
usfc_switch_language() {
    _usfc_lang_options true
    local choice
    t "Enter — отмена" "Enter to cancel"
    echo -en "  ${BOLD}Выбор / Choice${NC} ${DIM}[${REPLY_T}]:${NC} "   # i18n-ok: двуязычный по замыслу
    read -r choice </dev/tty

    if [ -z "$choice" ]; then
        t "Отменено, язык не менялся" "Cancelled, language unchanged"
        log_info "$REPLY_T"
        return 0
    fi
    _usfc_lang_parse "$choice"
    if [ -z "$REPLY_LANG" ]; then
        t "Не понял ответ «${choice}» — язык не менялся" \
          "Did not understand ${choice} — language unchanged"
        log_warn "$REPLY_T"
        return 0
    fi
    if [ "$REPLY_LANG" = "$USFC_LANG" ]; then
        t "Этот язык уже выбран" "That language is already selected"
        log_info "$REPLY_T"
        return 0
    fi

    usfc_lang_save "$REPLY_LANG" || return 0
    # --no-update: обновление уже проверялось на этом запуске, второй раз
    # спрашивать про него при простой смене языка незачем
    USFC_LANG="$REPLY_LANG" USFC_NO_UPDATE=1 exec "$SCRIPT_PATH"
}

REPLY_T=''
t() {
    if [ "$USFC_LANG" = en ]; then REPLY_T="$2"; else REPLY_T="$1"; fi
}

# Языковые варианты логгеров и вопросов. Имена с суффиксом _t, чтобы
# непереведённые вызовы были видны глазом и грепом: `grep -c 'log_info "'`
# показывает, сколько ещё осталось.
log_info_t()    { t "$1" "$2"; log_info    "$REPLY_T"; }
log_success_t() { t "$1" "$2"; log_success "$REPLY_T"; }
log_warn_t()    { t "$1" "$2"; log_warn    "$REPLY_T"; }
log_error_t()   { t "$1" "$2"; log_error   "$REPLY_T"; }

# ask_yn_t <ru> <en> [дефолт]
ask_yn_t()      { t "$1" "$2"; ask_yn "$REPLY_T" "${3:-Y}"; }
# ask_value_t <ru> <en> <дефолт>
ask_value_t()   { t "$1" "$2"; ask_value "$REPLY_T" "$3"; }

# st <цвет> <ru> <en> — строка статуса пункта.
# Статусы печатаются десятками и всегда одной формой «цвет + текст + сброс»,
# так что отдельная функция короче, чем t() плюс echo в каждом месте.
st() { local c="$1"; t "$2" "$3"; echo -e "${c}${REPLY_T}${NC}"; }
