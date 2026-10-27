#!/usr/bin/env bash
# Файрвол 5.0: разбор портов, ping через before.rules, блок Docker в
# after.rules и разбор `usfc firewall`.
#
# До 5.0 пункт открывал только TCP-порты, которые слушались в момент
# включения (UDP — WireGuard, Hysteria — отрезался), ping не выключался, а
# порты Docker-контейнеров жили мимо UFW. Здесь правки проверяются на
# эталонных файлах пакета ufw (tests/fixtures/ufw, ufw 0.36.2 из 24.04):
# результат совпадает со схемой, повтор ничего не меняет, обратная правка
# возвращает файл байт-в-байт. Сам ufw не вызывается.
set -uo pipefail
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$(cd "$(dirname "$0")" && pwd)/fixtures/ufw"
export UFW_DIR="$TMP/ufw"
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"
# shellcheck disable=SC2034  # читается в write_file
USFC_DRY_RUN=false
# shellcheck disable=SC2034  # читается в log_*
USFC_NO_COLOR=true
backup_file() { :; }        # снимки проверяет test_backup.sh
ufw_active() { return 1; }  # без reload
docker() { :; }             # опубликованных портов нет

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }
fresh() { rm -rf "$UFW_DIR"; cp -r "$FIX" "$UFW_DIR"; }

echo "разбор портов"
port() {
    local in="$1" want="$2"
    if fw_parse_ports "$in"; then
        [ "$want" = "$REPLY_FW_PORTS" ] && ok "«$in» → $want" || bad "«$in» → «$REPLY_FW_PORTS», ждали «$want»"
    else
        [ "$want" = ERR ] && ok "«$in» — ошибка" || bad "«$in»: ошибка «$REPLY_FW_ERR», ждали «$want»"
    fi
}
port "443"                       "443/tcp"
port "80,443"                    "80/tcp 443/tcp"
port "80, 443 51820/udp"         "80/tcp 443/tcp 51820/udp"
port "1000:2000/tcp"             "1000:2000/tcp"
port "443,443/tcp"               "443/tcp"
port "443/tcp,443/udp"           "443/tcp 443/udp"
port "080"                       "80/tcp"
port "0"                         ERR
port "65536"                     ERR
port "2000:1000"                 ERR
port "443/sctp"                  ERR
port "http"                      ERR
port "443;reboot"                ERR

echo "адрес --from"
for a in 10.0.0.5 10.0.0.0/8 2001:db8::1 2001:db8::/32; do
    fw_valid_from "$a" && ok "$a" || bad "$a отвергнут"
done
for a in 'any' '10.0.0.5;id' '-1' ''; do
    fw_valid_from "$a" && bad "«$a» принят" || ok "«$a» отвергнут"
done

echo "ping: before.rules по схеме пользователя"
fresh
# Ожидание собрано независимо от awk: в блоках ICMP для INPUT и FORWARD
# ACCEPT → DROP, и строка source-quench в конце блока INPUT
want4="$TMP/want4"
awk -v sq="$FW_PING_SQ" '
    /^# ok icmp codes for INPUT$/  { sec = 1 }
    /^# ok icmp code for FORWARD$/ { sec = 2 }
    sec && /^$/ { if (sec == 1) print sq; sec = 0 }
    sec && /^-A / { sub(/ACCEPT$/, "DROP") }
    { print }' "$FIX/before.rules" > "$want4"
fw_ping_state; [ "$REPLY_FW_PING" = on ] && ok "исходно: on" || bad "исходно: $REPLY_FW_PING"
fw_ping_set off >/dev/null 2>&1 || bad "fw_ping_set off вернул ошибку"
cmp -s "$UFW_DIR/before.rules" "$want4" && ok "before.rules = схема" \
    || { bad "before.rules не совпал со схемой"; diff "$want4" "$UFW_DIR/before.rules" | head -20; }
[ "$(diff "$FIX/before.rules" "$UFW_DIR/before.rules" | grep -c -- '^> .*-j DROP$')" -eq 9 ] \
    && ok "9 новых строк DROP (4 INPUT + 4 FORWARD + source-quench)" || bad "новых строк DROP не 9"
cp "$UFW_DIR/before.rules" "$TMP/off4"; cp "$UFW_DIR/before6.rules" "$TMP/off6"
fw_ping_state; [ "$REPLY_FW_PING" = off ] && ok "состояние: off" || bad "состояние: $REPLY_FW_PING"
fw_ping_set off >/dev/null 2>&1
cmp -s "$UFW_DIR/before.rules" "$TMP/off4" && cmp -s "$UFW_DIR/before6.rules" "$TMP/off6" \
    && ok "повтор off ничего не меняет" || bad "повтор off изменил файлы"

echo "ping: before6.rules — только echo-request"
d6="$(diff "$FIX/before6.rules" "$UFW_DIR/before6.rules" | grep '^[<>]')"
if [ "$d6" = "< -A ufw6-before-input -p icmpv6 --icmpv6-type echo-request -j ACCEPT
> -A ufw6-before-input -p icmpv6 --icmpv6-type echo-request -j DROP" ]; then
    ok "изменилась ровно одна строка"
else
    bad "before6.rules: лишние изменения"; printf '%s\n' "$d6" | head -10
fi

echo "ping on возвращает исходник байт-в-байт"
fw_ping_set on >/dev/null 2>&1 || bad "fw_ping_set on вернул ошибку"
cmp -s "$UFW_DIR/before.rules" "$FIX/before.rules" && ok "before.rules" || bad "before.rules отличается"
cmp -s "$UFW_DIR/before6.rules" "$FIX/before6.rules" && ok "before6.rules" || bad "before6.rules отличается"
fw_ping_state; [ "$REPLY_FW_PING" = on ] && ok "состояние: on" || bad "состояние: $REPLY_FW_PING"

echo "ping: чужой файл не трогаем"
fresh
printf '*filter\nCOMMIT\n' > "$UFW_DIR/before.rules"
cp "$UFW_DIR/before.rules" "$TMP/alien"
fw_ping_set off >/dev/null 2>&1 && bad "ошибки нет" || ok "ошибка"
cmp -s "$UFW_DIR/before.rules" "$TMP/alien" && ok "файл не изменён" || bad "файл изменён"
fresh
sed -i.bak 's/--icmp-type time-exceeded -j ACCEPT/--icmp-type time-exceeded -j DROP/' "$UFW_DIR/before.rules"
fw_ping_state; [ "$REPLY_FW_PING" = mixed ] && ok "правленный руками — mixed" || bad "правленный руками: $REPLY_FW_PING"

echo "Docker: блок в after.rules"
fresh
fw_docker_on && bad "исходно включён" || ok "исходно выключен"
fw_docker_set on >/dev/null 2>&1 || bad "fw_docker_set on вернул ошибку"
fw_docker_on && ok "включён" || bad "не включён"
[ "$(tail -n 1 "$UFW_DIR/after.rules")" = "$FW_DOCKER_END" ] && ok "блок в конце файла" || bad "блок не в конце"
cp "$UFW_DIR/after.rules" "$TMP/dock"
fw_docker_set on >/dev/null 2>&1
cmp -s "$UFW_DIR/after.rules" "$TMP/dock" && ok "повтор on ничего не меняет" || bad "повтор on изменил файл"
fw_docker_set off >/dev/null 2>&1 || bad "fw_docker_set off вернул ошибку"
cmp -s "$UFW_DIR/after.rules" "$FIX/after.rules" && ok "off возвращает исходник байт-в-байт" \
    || { bad "after.rules отличается"; diff "$FIX/after.rules" "$UFW_DIR/after.rules" | head; }

echo "Docker: правило маршрута — на адрес контейнера"
# два контейнера с одним внутренним портом: сайт 8080→80 и админка 9000→80
docker() {
    case "$1" in
        ps)      printf 'site 0.0.0.0:8080->80/tcp, [::]:8080->80/tcp\nadmin 0.0.0.0:9000->80/tcp\n' ;;
        inspect) case "${*: -1}" in site) echo "172.17.0.2 " ;; admin) echo "172.17.0.3 " ;; esac ;;
    esac
}
ROUTES="$TMP/routes"; : > "$ROUTES"
saved_fw_ufw="$(declare -f _fw_ufw)"
_fw_ufw() { printf '%s\n' "$*" >> "$ROUTES"; }
ufw()     { printf 'DEL %s\n' "$*" >> "$ROUTES"; }
fw_docker_route allow '' 8080/tcp >/dev/null 2>&1
same_route="$(cat "$ROUTES")"
[ "$same_route" = "route allow proto tcp from any to 172.17.0.2 port 80" ] \
    && ok "--allow 8080 открывает только сайт" || bad "правила: $(tr '\n' '|' < "$ROUTES")"
: > "$ROUTES"
fw_docker_route delete '' 9000/tcp >/dev/null 2>&1
[ "$(cat "$ROUTES")" = "DEL route delete allow proto tcp from any to 172.17.0.3 port 80" ] \
    && ok "--deny 9000 снимает правило только админки" || bad "удаление: $(tr '\n' '|' < "$ROUTES")"
: > "$ROUTES"
fw_docker_route allow '' 5432/tcp >/dev/null 2>&1
[ ! -s "$ROUTES" ] && ok "порт без контейнера — правила маршрута нет" || bad "лишнее правило: $(tr '\n' '|' < "$ROUTES")"
docker() { :; }
unset -f ufw
eval "$saved_fw_ufw"

echo "«-» в вопросе о портах — только SSH"
saved_listen="$(declare -f fw_listening)"
saved_ask="$(declare -f ask_text_t)"
# shellcheck disable=SC2034
fw_listening() { REPLY_FW_LISTEN=$'80/tcp nginx\n5432/tcp postgres'; }
# shellcheck disable=SC2034
ask_text_t() { REPLY_TEXT="$FAKE_ANSWER"; }
# shellcheck disable=SC2034
SSH_PORT=22
reset_bulk_answers
FAKE_ANSWER=-
_ufw_ask_ports >/dev/null 2>&1
_ufw_proposed
[ -z "$REPLY_FW_PORTS" ] && [ -z "$UFW_ALLOW_BULK" ] \
    && ok "«-» — список пуст, слушающие порты не подставляются" || bad "«-» дал «${REPLY_FW_PORTS}»"
FAKE_ANSWER=443
_ufw_ask_ports >/dev/null 2>&1
_ufw_proposed
[ "$REPLY_FW_PORTS" = 443/tcp ] && ok "ответ после «-» снова работает" || bad "после «-»: «${REPLY_FW_PORTS}»"
reset_bulk_answers
_ufw_proposed
[ "$REPLY_FW_PORTS" = "80/tcp 5432/tcp" ] && ok "без ответа — предложены слушающие порты" || bad "без ответа: «${REPLY_FW_PORTS}»"
eval "$saved_listen"
eval "$saved_ask"

echo "разбор usfc firewall"
# fa <аргументы> — разбор и применение ответов в подоболочке, как в main:
# порты и адрес проверяет answer_set, ошибка — код 2.
# Вывод «код|ACTION|VALUE|DENY|ALLOW|FROM|PING»
fa() {
    local out rc
    out="$(
        parse_args "$@" >/dev/null 2>&1 || exit $?
        apply_cli_answers >/dev/null 2>&1 || exit $?
        printf '%s|%s|%s|%s|%s|%s' "$FW_CMD_ACTION" "$FW_CMD_VALUE" "$FW_CMD_DENY" \
            "$UFW_ALLOW_BULK" "$UFW_FROM_BULK" "$UFW_PING_BULK"
    )"; rc=$?
    printf '%s|%s' "$rc" "$out"
}
cli() {
    local name="$1" want="$2" got; shift 2
    got="$(fa "$@")"
    [ "$got" = "$want" ] && ok "$name" || bad "$name: «$got», ждали «$want»"
}
cli "firewall — сводка"            "0||||||"                              firewall
cli "ping off"                     "0|ping|off||||"                       firewall ping off
cli "docker on"                    "0|docker|on||||"                      firewall docker on
cli "--allow и --from"             "0||||443/tcp 51820/udp|10.0.0.5|"     firewall --allow 443,51820/udp --from 10.0.0.5
cli "--deny"                       "0|||8080/tcp|||"                      firewall --deny 8080
cli "--no-ping"                    "0||||||N"                             firewall --no-ping
cli "apply с --allow и --no-ping"  "0||||443/tcp 51820/udp||N"            apply ufw --allow 443,51820/udp --no-ping
cli "ping без on/off — ошибка"     "2|"                                   firewall ping
cli "ping maybe — ошибка"          "2|"                                   firewall ping maybe
cli "лишнее слово — ошибка"        "2|"                                   firewall reload
cli "--allow мусор — ошибка"       "2|"                                   firewall --allow http
cli "--from мусор — ошибка"        "2|"                                   firewall --allow 80 --from 'x;id'
cli "--deny мусор — ошибка"        "2|"                                   firewall --deny http
cli "--deny вне firewall — ошибка" "2|"                                   apply ufw --deny 80

echo "дефолт вопроса про ping"
saved_state="$(declare -f fw_ping_state)"
# shellcheck disable=SC2034
fw_ping_state() { REPLY_FW_PING="$FAKE_PING"; }
for pair in on:Y off:N mixed:N unknown:Y; do
    FAKE_PING="${pair%%:*}"
    _ufw_ping_default
    [ "$REPLY_T" = "${pair#*:}" ] && ok "ping ${FAKE_PING} → ${REPLY_T}" || bad "ping ${FAKE_PING}: «${REPLY_T}», ждали ${pair#*:}"
done
eval "$saved_state"

echo "--from без --allow"
saved_active="$(declare -f ufw_active)"
saved_show="$(declare -f _ufw_show_listening)"
saved_pkg="$(declare -f ensure_pkg)"
ufw_active() { return 1; }
_ufw_show_listening() { :; }
ensure_pkg() { echo REACHED; return 1; }
reset_bulk_answers
# shellcheck disable=SC2034
BULK_MODE=true
# shellcheck disable=SC2034
UFW_BULK=Y
# shellcheck disable=SC2034
UFW_FROM_BULK=10.0.0.5
out="$(apply_ufw 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && [[ "$out" != *REACHED* ]] && ok "--from без --allow — отказ до включения UFW" || bad "--from без --allow: код ${rc}"
# shellcheck disable=SC2034
UFW_SSH_ONLY_BULK=Y
out="$(apply_ufw 2>&1)"
[[ "$out" == *REACHED* ]] && ok "--from при ответе «только SSH» не мешает" || bad "«только SSH» с --from остановлен"
reset_bulk_answers
# shellcheck disable=SC2034
BULK_MODE=false
eval "$saved_active"
eval "$saved_show"
eval "$saved_pkg"

echo "аудит: профиль OpenSSH — это правило для 22/tcp"
saved_listen="$(declare -f fw_listening)"
saved_active="$(declare -f ufw_active)"
saved_audit="$(declare -f _audit_t)"
saved_pingst="$(declare -f fw_ping_state)"
saved_pub="$(declare -f fw_docker_published)"
# shellcheck disable=SC2034
fw_listening() { REPLY_FW_LISTEN=$'22/tcp sshd\n443/tcp nginx'; }
ufw_active() { return 0; }
ufw() { printf 'Status: active\n\nTo Action From\n-- ------ ----\nOpenSSH ALLOW Anywhere\n443/tcp ALLOW Anywhere\n'; }
# shellcheck disable=SC2034
fw_ping_state() { REPLY_FW_PING=on; }
# shellcheck disable=SC2034
fw_docker_published() { REPLY_FW_DOCKER=''; }
_audit_t() { echo "$1 $2"; }
out="$(audit_ports 2>&1)"
[[ "$out" == *"ports.firewalled ok"* ]] && ok "22/tcp под профилем OpenSSH не считается «без правила»" || bad "аудит: $out"
unset -f ufw
eval "$saved_listen"
eval "$saved_active"
eval "$saved_audit"
eval "$saved_pingst"
eval "$saved_pub"

if [ "$fail" -eq 0 ]; then echo "OK"; else echo "ЕСТЬ ОШИБКИ"; fi
exit "$fail"
