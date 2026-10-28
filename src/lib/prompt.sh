# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ui_prompt <вопрос> [подсказка] — единый вид приглашения для всех вопросов:
# «› вопрос [подсказка]:». Раньше у меню, ask_yn, ask_value и мастера было
# по своему оформлению, и глаз не находил, где именно ждут ввода
ui_prompt() {
    local hint=''
    [ -n "${2:-}" ] && hint=" ${DIM}[${2}]${NC}"
    echo -en "  ${CYAN}›${NC} ${BOLD}${1}${NC}${hint}${DIM}:${NC} "
}

ask_yn() {
    local question="${1:-}" default="${2:-Y}" reply prompt
    # --yes действует ТОЛЬКО в `usfc apply`, и это не перестраховка.
    # Из 62 вопросов 24 имеют защитный дефолт «нет», и среди них удаление
    # самого usfc, гейт неподдерживаемой ОС, остановка nginx и Docker,
    # выключение unattended-upgrades. Глобальный «да на всё» превратил бы
    # usfc --yes в команду, которая сносит скрипт и гасит сервисы за один
    # заход. В неинтерактивном прогоне эти ветки недостижимы по построению:
    # уже применённые пункты run_noninteractive пропускает, удаление живёт
    # только в меню, а гейт ОС срабатывает раньше всего.
    if [ "${USFC_ASSUME_YES:-false}" = true ] && { [ "${USFC_CMD:-}" = apply ] || [ "${USFC_CMD:-}" = firewall ]; }; then
        return 0
    fi
    if [ "$BULK_MODE" = true ]; then
        [ "$default" = "Y" ] && return 0 || return 1
    fi
    if [ "$default" = "Y" ]; then prompt="Y/n"; else prompt="y/N"; fi
    ui_prompt "$question" "$prompt"
    read -r reply </dev/tty
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

# ask_bulk_yn <переменная> <ru> <en> [дефолт] — вопрос, на который в пакетном
# режиме отвечают ЗАРАНЕЕ (preask_<id>, файл ответов, флаг). Заготовленный
# ответ Y/N сильнее всего; без него — обычный ask_yn, то есть в пакете дефолт.
#
# Это и есть лекарство от «раздел целиком применяется не так, как пункт
# руками»: раньше вопрос внутри apply_* в пакетном режиме молча становился
# своим дефолтом, даже когда ответ на него уже спросили заранее
ask_bulk_yn() {
    local var="$1" ans
    ans="${!var:-}"
    case "$ans" in
        Y) return 0 ;;
        N) return 1 ;;
    esac
    ask_yn_t "$2" "$3" "${4:-Y}"
}

# ask_text <вопрос> [дефолт] → REPLY_TEXT — строка как есть (список портов,
# адрес). Проверяет вызывающий: у каждого поля своя грамматика
REPLY_TEXT=''
ask_text() {
    local question="${1:-}" default="${2:-}" reply
    REPLY_TEXT="$default"
    [ "$BULK_MODE" = true ] && return 0
    ui_prompt "$question" "$default"
    read -r reply </dev/tty || return 0
    REPLY_TEXT="${reply:-$default}"
}

# ask_value question default — как ask_yn, но для чисел; печатает результат
# в stdout (нужно вызывать через командную подстановку), весь интерактив — в stderr
ask_value() {
    local question="${1:-}" default="${2:-}" reply
    if [ "$BULK_MODE" = true ]; then
        echo "$default"
        return
    fi
    ui_prompt "$question" "$default" >&2
    read -r reply </dev/tty
    reply="${reply:-$default}"
    if ! [[ "$reply" =~ ^[0-9]+$ ]]; then
        log_warn_t "Не похоже на число — использую значение по умолчанию (${default})" \
"Does not look like a number — using the default (${default})"
        reply="$default"
    fi
    echo "$reply"
}

# ── Шапка ─────────────────────────────────────────────────────────────────────
# Шрифт ANSI Shadow, буквы вплотную. В 2.6.5 здесь была разрядка ради
# «покрупнее» — вышло хуже: промежутки читались как четыре отдельные буквы,
# а не как слово. Крупнее без разрежения даёт только смена шрифта (mono12 —
# +1 строка, bigmono12 — вдвое выше), но за это платит высота экрана, а
