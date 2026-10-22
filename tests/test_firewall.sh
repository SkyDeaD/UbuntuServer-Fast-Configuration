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

if [ "$fail" -eq 0 ]; then echo "OK"; else echo "ЕСТЬ ОШИБКИ"; fi
exit "$fail"
