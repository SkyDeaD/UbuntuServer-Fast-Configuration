# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

ask_yn() {
    local question="${1:-}" default="${2:-Y}" reply prompt
    if [ "$BULK_MODE" = true ]; then
        [ "$default" = "Y" ] && return 0 || return 1
    fi
    if [ "$default" = "Y" ]; then prompt="[Y/n]"; else prompt="[y/N]"; fi
    echo -en "  ${BOLD}${question}${NC} ${DIM}${prompt}:${NC} "
    read -r reply </dev/tty
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

# ask_value question default — как ask_yn, но для чисел; печатает результат
# в stdout (нужно вызывать через командную подстановку), весь интерактив — в stderr
ask_value() {
    local question="${1:-}" default="${2:-}" reply
    if [ "$BULK_MODE" = true ]; then
        echo "$default"
        return
    fi
    echo -en "  ${BOLD}${question}${NC} ${DIM}[${default}]:${NC} " >&2
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
