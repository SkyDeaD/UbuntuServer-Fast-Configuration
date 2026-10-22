#!/usr/bin/env bash
# unattended-upgrades: окно автоперезагрузки (файл 52usfc-reboot).
#
# Подменяем внешние точки — write_file, remove_file, apt-config, ensure_pkg,
# systemctl, pkg_installed, — а логику вопросов и разбора времени гоняем
# настоящую. Запись отмечаем ФАЙЛАМИ: write_file стоит в правой части
# конвейера/heredoc, и присваивание из подоболочки не дожило бы до проверки.
# shellcheck disable=SC2034  # BULK_MODE, REPLY_TEXT, *_BULK читаются кодом пункта по имени
set -uo pipefail
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# shellcheck disable=SC2034  # читается внутри src/lib/items/unattended.sh
UA_REBOOT_FILE="$TMP/52usfc-reboot"

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: ожидалось «$2», получено «$3»"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1: нет «$2» в «$3»" ;; esac; }

write_file()  { cat > "$1"; echo "$1" >> "$TMP/wrote"; }
remove_file() { [ -e "$1" ] || return 0; rm -f "$1"; echo "$1" >> "$TMP/removed"; }
ensure_pkg()  { return 0; }
systemctl()   { return 0; }
pkg_installed() { return 0; }
# apt-config: периодика берётся из флага ENABLED, окно — из реального файла
ENABLED=1
apt-config() {
    [ "$ENABLED" = 1 ] && echo 'APT::Periodic::Unattended-Upgrade "1";'
    [ -s "$UA_REBOOT_FILE" ] && sed 's|^//.*||; /^$/d' "$UA_REBOOT_FILE"
    return 0
}
QUESTIONS=""
# ответы на вопросы задаём переменными: ANS_ENABLE, ANS_USERS
ANS_ENABLE=Y; ANS_USERS=N
ask_yn_t() {
    QUESTIONS="${QUESTIONS}|$1"
    case "$1" in
        Включить*) [ "$ANS_ENABLE" = Y ] ;;
        Перезагружать*) [ "$ANS_USERS" = Y ] ;;
        *) [ "${3:-Y}" = Y ] ;;
    esac
}
TIME_REPLIES=()   # очередь ответов на вопрос про время
# shellcheck disable=SC2034  # REPLY_TEXT читается кодом пункта
ask_text_t() {
    QUESTIONS="${QUESTIONS}|time"
    REPLY_TEXT="${3:-}"
    if [ "${#TIME_REPLIES[@]}" -gt 0 ]; then REPLY_TEXT="${TIME_REPLIES[0]}"; TIME_REPLIES=("${TIME_REPLIES[@]:1}"); fi
}

# shellcheck disable=SC2034  # BULK_MODE читается кодом пункта
reset() {  # reset — чистый стенд: нет нашего файла, нет ответов
    rm -f "$TMP/wrote" "$TMP/removed" "$UA_REBOOT_FILE"
    QUESTIONS=""; ENABLED=1; ANS_ENABLE=Y; ANS_USERS=N; TIME_REPLIES=()
    BULK_MODE=false
    reset_bulk_answers
}
wrote()   { [ -s "$TMP/wrote" ]; }
removed() { [ -s "$TMP/removed" ]; }
conf()    { cat "$UA_REBOOT_FILE" 2>/dev/null; }

echo "меню: время вводит человек"
reset; TIME_REPLIES=(4:00)
apply_unattended >/dev/null 2>&1
has "4:00 → 04:00 в файле"      'Automatic-Reboot-Time "04:00";' "$(conf)"
has "перезагрузка включена"     'Automatic-Reboot "true";'       "$(conf)"
has "по умолчанию без вошедших" 'WithUsers "false";'             "$(conf)"

reset; TIME_REPLIES=(03:30); ANS_USERS=Y
apply_unattended >/dev/null 2>&1
has "with-users Y → true" 'WithUsers "true";' "$(conf)"
has "03:30 как есть"      'Time "03:30";'     "$(conf)"

echo ""
echo "off убирает наш файл"
reset; TIME_REPLIES=(04:00); apply_unattended >/dev/null 2>&1
TIME_REPLIES=(off); : > "$TMP/removed"; : > "$TMP/wrote"
apply_unattended >/dev/null 2>&1
removed && ok "remove_file вызван" || bad "remove_file не вызван"
[ -e "$UA_REBOOT_FILE" ] && bad "файл остался" || ok "файла нет"
reset; TIME_REPLIES=(off); apply_unattended >/dev/null 2>&1
removed && bad "удаляли несуществующий" || ok "нет файла — нечего удалять"

echo ""
echo "неверное время в меню переспрашивается"
reset; TIME_REPLIES=(25:99 ерунда 05:15)
apply_unattended >/dev/null 2>&1
has "третья попытка принята" 'Time "05:15";' "$(conf)"
reset; TIME_REPLIES=(x y z)
apply_unattended >/dev/null 2>&1
[ -e "$UA_REBOOT_FILE" ] && bad "после трёх ошибок записан наш файл" || ok "после трёх ошибок — off, наш файл не пишем"

echo ""
echo "пакетный режим"
reset; BULK_MODE=true; REBOOT_TIME_BULK=02:30
apply_unattended >/dev/null 2>&1
has "время из REBOOT_TIME_BULK" 'Time "02:30";' "$(conf)"
has "вошедшие без ответа → дефолт N" 'WithUsers "false";' "$(conf)"
reset; BULK_MODE=true; REBOOT_TIME_BULK=02:30; REBOOT_WITH_USERS_BULK=Y
apply_unattended >/dev/null 2>&1
has "REBOOT_WITH_USERS_BULK=Y → true" 'WithUsers "true";' "$(conf)"
reset; BULK_MODE=true; REBOOT_TIME_BULK=02:30; REBOOT_WITH_USERS_BULK=N; ANS_USERS=Y
apply_unattended >/dev/null 2>&1
has "REBOOT_WITH_USERS_BULK=N сильнее дефолта" 'WithUsers "false";' "$(conf)"
reset; BULK_MODE=true; REBOOT_TIME_BULK=off
apply_unattended >/dev/null 2>&1
[ -e "$UA_REBOOT_FILE" ] && bad "off в пакете записал наш файл" || ok "REBOOT_TIME_BULK=off → файла нет"

echo ""
echo "повторный запуск на уже включённом"
reset; BULK_MODE=true; REBOOT_TIME_BULK=01:00
apply_unattended >/dev/null 2>&1
has "время сменилось" 'Time "01:00";' "$(conf)"
case "$QUESTIONS" in *Включить*) bad "переспросили «включить?»" ;; *) ok "«включить?» не задавали" ;; esac
grep -q 20auto-upgrades "$TMP/wrote" 2>/dev/null && bad "20auto-upgrades переписан" || ok "20auto-upgrades не трогали"

echo ""
echo "предзапрос"
reset; TIME_REPLIES=(04:00); ANS_USERS=Y
preask_unattended >/dev/null 2>&1
is "время → REBOOT_TIME_BULK" 04:00 "$REBOOT_TIME_BULK"
is "вошедшие → REBOOT_WITH_USERS_BULK" Y "$REBOOT_WITH_USERS_BULK"
reset; TIME_REPLIES=(off)
preask_unattended >/dev/null 2>&1
is "off → второй вопрос не нужен" "" "$REBOOT_WITH_USERS_BULK"
reset; REBOOT_TIME_BULK=03:00; REBOOT_WITH_USERS_BULK=N
preask_unattended >/dev/null 2>&1
case "$QUESTIONS" in "") ok "всё задано флагами — не спрашиваем" ;; *) bad "лишний вопрос: $QUESTIONS" ;; esac

echo ""
echo "статус"
reset; TIME_REPLIES=(04:00); apply_unattended >/dev/null 2>&1
has "✓ включено · ребут 04:00" "ребут 04:00" "$(status_unattended)"
reset
case "$(status_unattended)" in *ребут*) bad "ребут показан без файла" ;; *) ok "без файла — просто «включено»" ;; esac

echo ""
echo "выключение"
reset; TIME_REPLIES=(04:00); apply_unattended >/dev/null 2>&1
ask_yn_t() { return 0; }
disable_unattended >/dev/null 2>&1
[ -e "$UA_REBOOT_FILE" ] && bad "disable оставил 52usfc-reboot" || ok "disable удалил 52usfc-reboot"

echo ""
[ "$fail" -eq 0 ] && echo "unattended: все проверки пройдены" || echo "unattended: ЕСТЬ ПРОВАЛЫ"
exit "$fail"
