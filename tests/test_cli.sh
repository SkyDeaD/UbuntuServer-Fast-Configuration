#!/usr/bin/env bash
# Командная строка 5.0: команды, опции, ответы и их приоритет.
#
# До 5.0 режимы были флагами с негласным приоритетом (`--audit --apply web`
# молча выполнял только аудит), флаги со значением глотали следующий флаг,
# `--config` вне --apply молча игнорировался, а ITEMS= из файла перебивал
# командную строку. Здесь — таблица «аргументы → что решил разбор и с каким
# кодом», плюс то, что флаги и файл ответов дают одно и то же состояние.
set -uo pipefail
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"
# shellcheck disable=SC2034  # читается в log_*
USFC_NO_COLOR=true

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }

# pa <аргументы...> — разбор в подоболочке: OUT (stdout+stderr), RC, и
# состояние в виде «CMD|SPEC|STAMP|DRY|YES|JSON|ответы флагов»
pa() {
    OUT="$(
        parse_args "$@" 2>&1
        local k a=''
        for k in $(printf '%s\n' "${!USFC_FLAG_ANS[@]}" | sort); do a="${a}${k}=${USFC_FLAG_ANS[$k]} "; done
        printf '\n@@%s|%s|%s|%s|%s|%s|%s\n' "$USFC_CMD" "$USFC_APPLY_SPEC" "$USFC_RESTORE_STAMP" \
            "$USFC_DRY_RUN" "$USFC_ASSUME_YES" "$USFC_AUDIT_JSON" "${a% }"
    )"
    RC=$?
    STATE="$(printf '%s\n' "$OUT" | sed -n 's/^@@//p')"
}
# expect <имя> <код> <ожидаемое состояние или ''> [подстрока в выводе] -- <аргументы>
expect() {
    local name="$1" rc="$2" state="$3" text="$4"; shift 5
    pa "$@"
    if [ "$RC" -ne "$rc" ]; then bad "$name: код $RC, ждали $rc — $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"; return; fi
    if [ -n "$state" ] && [ "$STATE" != "$state" ]; then bad "$name: состояние «$STATE», ждали «$state»"; return; fi
    if [ -n "$text" ] && [[ "$OUT" != *"$text"* ]]; then bad "$name: в выводе нет «$text»"; return; fi
    ok "$name"
}

echo "команды"
expect "без аргументов — меню"            0 "|||false|false|false|" "" --
expect "apply web"                        0 "apply|web||false|false|false|" "" -- apply web
expect "apply: несколько слов склеиваются" 0 "apply|web,bbr,ufw||false|false|false|" "" -- apply web,bbr ufw
expect "audit --json"                     0 "audit|||false|false|true|" "" -- audit --json
expect "restore с меткой и --yes"         0 "restore||20260101-000000-1|false|true|false|" "" -- restore 20260101-000000-1 --yes
expect "--dry-run без команды — меню"     0 "|||true|false|false|" "" -- --dry-run
expect "глобальные опции до команды"      0 "apply|web||true|false|false|" "" -- --verbose --no-update apply web --dry-run

echo ""
echo "ошибки разбора — код 2 и объяснение"
expect "неизвестная команда"              2 "" "неизвестная команда" -- frobnicate
expect "apply без пунктов"                2 "" "что применять"       -- apply
expect "лишний аргумент у audit"          2 "" "лишний аргумент"     -- audit extra
expect "--json вне audit"                 2 "" "--json"              -- list --json
expect "--json без команды"               2 "" "работает только с командой" -- --json
expect "--dry-run у audit"                2 "" "не относится"        -- audit --dry-run
expect "--config вне apply"               2 "" "--config"            -- audit --config /x
expect "неизвестная опция"                2 "" "неизвестная опция"   -- apply web --frobnicate
expect "--lang без значения"              2 "" "требует значение"    -- --lang
expect "--lang не глотает следующий флаг" 2 "" "требует значение"    -- --lang --verbose
expect "--lang de"                        2 "" "ru или en"           -- --lang de
expect "--swap без значения"              2 "" "требует значение"    -- apply web --swap
expect "--swap не глотает --yes"          2 "" "требует значение"    -- apply web --swap --yes
expect "--set без ="                      2 "" "КЛЮЧ=значение"       -- apply web --set SWAP_MB
expect "--set с неизвестным ключом"       2 "" "неизвестный ключ"    -- apply web --set FOO=1
expect "restore без метки и без терминала" 2 "" "метку снимка"       -- restore </dev/null

echo ""
echo "старые формы 4.x — ошибка с готовой новой строкой"
expect "--apply web --dry-run"            2 "" "usfc apply web --dry-run" -- --apply web --dry-run
expect "--apply=all"                      2 "" "usfc apply all"           -- --apply=all
expect "--audit --json"                   2 "" "usfc audit --json"        -- --audit --json
expect "--list"                           2 "" "usfc list"                -- --list
expect "--restore метка --yes"            2 "" "usfc restore 20260101-000000-1 --yes" -- --restore 20260101-000000-1 --yes
expect "--audit --apply web больше не молча audit" 2 "" "в 5.0"   -- --audit --apply web

echo ""
echo "флаги ответов"
expect "--swap 2048"                      0 "apply|zram||false|false|false|SWAP_MB=2048" "" -- apply zram --swap 2048
expect "--swap=2048"                      0 "apply|zram||false|false|false|SWAP_MB=2048" "" -- apply zram --swap=2048
expect "--sysctl / --no-sysctl"           0 "apply|zram||false|false|false|SYSCTL=N" "" -- apply zram --no-sysctl
expect "--ufw даёт Y"                     0 "apply|ufw||false|false|false|UFW=Y" "" -- apply ufw --ufw
expect "--set KEY=VALUE"                  0 "apply|ufw||false|false|false|UFW=yes" "" -- apply ufw --set UFW=yes
expect "--no- у флага со значением — нет" 2 "" "неизвестная опция" -- apply zram --no-swap

echo ""
echo "справка и версия"
expect "version"                          0 "" "$VERSION"  -- version
expect "-V"                               0 "" "$VERSION"  -- -V
expect "help"                             0 "" "Команды:"  -- help
expect "help apply печатает флаги из таблицы" 0 "" "--swap" -- help apply
expect "apply --help — справка по apply"  0 "" "--docker-restart" -- apply --help
expect "help по неизвестной команде"      2 "" "нет справки" -- help frobnicate
expect "--lang en переводит ошибки"       2 "" "unknown command" -- --lang en frobnicate

echo ""
echo "файл ответов и флаги: флаг > файл > дефолт"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cfg="$TMP/node.conf"
printf '# узел\nITEMS=web\nSWAP_MB=1024\nSYSCTL=yes\nUFW="n"\n' > "$cfg"
r="$(
    USFC_APPLY_SPEC=docker; USFC_CONFIG_FILE="$cfg"
    USFC_FLAG_ANS=([SWAP_MB]=2048)
    apply_cli_answers >/dev/null 2>&1; echo "rc=$? spec=${USFC_APPLY_SPEC} swap=${SWAP_BULK_MB} sysctl=${SYSCTL_BULK} ufw=${UFW_BULK}"
)"
[ "$r" = "rc=0 spec=docker swap=2048 sysctl=Y ufw=N" ] && ok "флаг сильнее файла, CLI-пункты сильнее ITEMS, yes/n нормализованы" || bad "получили: $r"

r="$( USFC_APPLY_SPEC=''; USFC_CONFIG_FILE="$cfg"; apply_cli_answers >/dev/null 2>&1; echo "spec=${USFC_APPLY_SPEC}" )"
[ "$r" = "spec=web" ] && ok "ITEMS из файла — когда пункты не заданы" || bad "получили: $r"

printf 'SWAP_MB=lots\n' > "$cfg"
( USFC_CONFIG_FILE="$cfg"; apply_cli_answers >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "мусор в значении — ошибка" || bad "мусор в значении прошёл"
printf 'UWF=Y\n' > "$cfg"
out="$( USFC_CONFIG_FILE="$cfg"; apply_cli_answers 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && [[ "$out" == *"неизвестный ключ UWF"* ]] && ok "опечатка в ключе — ошибка с номером строки" || bad "опечатка прошла (rc=$rc)"
printf 'SWAP_MB 1024\n' > "$cfg"
( USFC_CONFIG_FILE="$cfg"; apply_cli_answers >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "строка без = — ошибка" || bad "строка без = прошла"
( USFC_CONFIG_FILE="http://example.com/x"; apply_cli_answers >/dev/null 2>&1 ); [ $? -eq 2 ] && ok "http:// отвергается — только https" || bad "http принят"

# флаги и файл дают ОДНО состояние
printf 'SWAP_MB=1536\nZRAM_PERCENT=60\nSYSCTL=N\nNGINX_AUTOSTART=Y\nCERTBOT_TLS=Y\nUFW=Y\n' > "$cfg"
via_cfg="$( USFC_CONFIG_FILE="$cfg"; apply_cli_answers >/dev/null 2>&1
    echo "$SWAP_BULK_MB $ZRAM_BULK_PERCENT $SYSCTL_BULK $NGINX_AUTOSTART $CERTBOT_TLS_BULK $UFW_BULK" )"
via_flags="$(
    parse_args apply web,zram --swap 1536 --zram 60 --no-sysctl --nginx-autostart --certbot-tls --ufw >/dev/null 2>&1
    apply_cli_answers >/dev/null 2>&1
    echo "$SWAP_BULK_MB $ZRAM_BULK_PERCENT $SYSCTL_BULK $NGINX_AUTOSTART $CERTBOT_TLS_BULK $UFW_BULK" )"
[ "$via_cfg" = "$via_flags" ] && [ "$via_cfg" = "1536 60 N Y Y Y" ] && ok "флаги и --config дают одинаковые ответы" \
    || bad "файл: «$via_cfg», флаги: «$via_flags»"

echo ""
echo "флаг для невыбранного пункта"
r="$(
    parse_args apply docker --swap 2048 >/dev/null 2>&1
    apply_cli_answers >/dev/null 2>&1
    check_cli_answer_items docker 2>&1; echo "rc=$?"
)"
[[ "$r" == *"rc=1"* && "$r" == *"zram"* ]] && ok "--swap без zram — ошибка с именем пункта" || bad "получили: $r"
r="$(
    printf 'SWAP_MB=2048\n' > "$cfg"
    # shellcheck disable=SC2034  # читается в apply_cli_answers
    USFC_CONFIG_FILE="$cfg"; apply_cli_answers >/dev/null 2>&1
    check_cli_answer_items docker >/dev/null 2>&1; echo "rc=$?"
)"
[ "$r" = "rc=0" ] && ok "тот же ключ из общего файла ответов — норма" || bad "получили: $r"

echo ""
[ "$fail" -eq 0 ] && echo "командная строка: все проверки пройдены" || echo "командная строка: ЕСТЬ ОШИБКИ"
exit "$fail"
