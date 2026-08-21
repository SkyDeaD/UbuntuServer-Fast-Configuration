# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# Мастер первого запуска
# ═══════════════════════════════════════════════════════════════
# Четырнадцать пунктов и четыре профиля — это много для человека, который
# видит инструмент впервые. Мастер задаёт ОДИН вопрос («для чего сервер?»)
# и разворачивает ответ в готовый профиль. Отказаться можно всегда: любой
# исход возвращает управление в обычное меню, никаких exit отсюда нет.
#
# Показывается ровно один раз — признаком служит файл выбора языка рядом
# с установкой. Отдельный файл-признак пришлось бы держать с ним в синхроне
# руками, а это ровно тот класс расхождений, от которого уходили в реестре.

# Ответ → REPLY_WIZARD_PROFILE (имя профиля либо пусто «выберу сам»).
# Отдельной функцией, как _usfc_lang_parse: так её проверяет тест, не поднимая
# интерактив.
REPLY_WIZARD_PROFILE=''
wizard_parse() {
    # i18n-ok: разбор ВВОДА, а не вывод — русские синонимы здесь для того,
    # чтобы «веб» и «защита» тоже принимались
    case "${1,,}" in
        1|m|minimal|минимум)      REPLY_WIZARD_PROFILE=minimal ;;    # i18n-ok: ввод
        2|w|web|веб)              REPLY_WIZARD_PROFILE=web ;;        # i18n-ok: ввод
        3|d|docker|dockerhost)    REPLY_WIZARD_PROFILE=dockerhost ;;
        4|s|secure|защита)        REPLY_WIZARD_PROFILE=secure ;;     # i18n-ok: ввод
        *)                        REPLY_WIZARD_PROFILE='' ;;
    esac
}

# Одна строка варианта: номер, название и СОСТАВ из самой USFC_PROFILES —
# дублировать состав текстом нельзя, он разъедется с профилем при первой правке
_wizard_option() {
    local num="$1" name="$2" ru="$3" en="$4"
    t "$ru" "$en"
    printf '    %b%s%b) %-11s %b%s%b\n' \
        "$CYAN$BOLD" "$num" "$NC" "$REPLY_T" "$DIM" "${USFC_PROFILES[$name]}" "$NC"
}

usfc_wizard() {
    show_header
    t "Для чего этот сервер?" "What is this server for?"
    echo -e "  ${BOLD}${REPLY_T}${NC}"
    t "Выбор ни к чему не обязывает: всё то же есть в меню, и отказаться можно на следующем шаге." \
      "Nothing is set in stone: the same items are in the menu, and you can back out on the next step."
    echo -e "  ${DIM}${REPLY_T}${NC}"
    echo ""
    _wizard_option 1 minimal    "минимум"    "minimal"
    _wizard_option 2 web        "веб-сервер" "web server"
    _wizard_option 3 dockerhost "docker-хост" "docker host"
    _wizard_option 4 secure     "защита"     "security"
    t "выберу сам в меню" "I will pick from the menu"
    printf '    %b5%b) %s\n' "$CYAN$BOLD" "$NC" "$REPLY_T"
    echo ""

    local choice
    t "Выбор" "Choice"
    echo -en "  ${BOLD}${REPLY_T}${NC} ${DIM}[5]:${NC} "
    read -r choice </dev/tty
    wizard_parse "$choice"
    if [ -z "$REPLY_WIZARD_PROFILE" ]; then
        log_info_t "Открываю меню" "Opening the menu"
        return 0
    fi

    resolve_items "$REPLY_WIZARD_PROFILE" || return 0
    filter_pending "${REPLY_ITEM_NUMS[@]}"

    # Про пропущенное говорим до того, как человек согласится: молчаливый
    # пропуск пункта в первом же прогоне читается как поломка
    local id
    for id in "${REPLY_SKIPPED[@]+"${REPLY_SKIPPED[@]}"}"; do
        log_info_t "Пункт «${id}» требует отдельного подтверждения — настройте его из меню" \
"Item \"${id}\" needs explicit confirmation — set it up from the menu"
    done
    if [ "${#REPLY_PENDING[@]}" -eq 0 ]; then
        log_success_t "Всё из этого профиля уже настроено" \
"Everything in this profile is already set up"
        return 0
    fi

    echo ""
    log_info_t "Будет применено:" "Will be applied:"
    local n
    for n in "${REPLY_PENDING[@]}"; do
        printf '      %s\n' "${ITEM_TITLES[$((n - 1))]}"
    done
    echo ""
    if ! ask_yn_t "Применить эти ${#REPLY_PENDING[@]} пунктов сейчас?" \
                  "Apply these ${#REPLY_PENDING[@]} items now?"; then
        log_info_t "Ок, открываю меню" "Fine, opening the menu"
        return 0
    fi

    local -a ids=()
    for n in "${REPLY_PENDING[@]}"; do ids+=("${ITEM_IDS[$((n - 1))]}"); done
    preask_bulk_answers "${ids[@]}"
    run_items "${REPLY_PENDING[@]}"
    reset_bulk_answers
    pause
    return 0
}
