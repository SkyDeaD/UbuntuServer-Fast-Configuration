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
expect "--config= с пустым значением"     2 "" "требует значение"    -- apply web --config=
expect "--swap= с пустым значением"       2 "" "требует значение"    -- apply web --swap=
expect "--swap не глотает --yes"          2 "" "требует значение"    -- apply web --swap --yes
expect "--set без ="                      2 "" "КЛЮЧ=значение"       -- apply web --set SWAP_MB
expect "--set с неизвестным ключом"       2 "" "неизвестный ключ"    -- apply web --set FOO=1
expect "--set с секретом CF_TOKEN"        2 "" "секрет"              -- apply certbot --set CF_TOKEN=abc
expect "--set с секретом TG_TOKEN"        2 "" "секрет"              -- apply notify --set TG_TOKEN=1:a
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
expect "--tg-chat с минусом — значение"   0 "apply|notify||false|false|false|TG_CHAT=-1001234567890" "" -- apply notify --tg-chat -1001234567890
expect "минус не делает опцию значением"  2 "" "требует значение"    -- apply notify --tg-chat --yes
expect "--no- у флага со значением — нет" 2 "" "неизвестная опция" -- apply zram --no-swap
expect "--ufw=Y — понятная ошибка"         2 "" "--ufw не принимает значение: пишите --ufw или --no-ufw" -- apply zram --ufw=Y
expect "--sysctl=yes — понятная ошибка"   2 "" "--sysctl не принимает значение" -- apply zram --sysctl=yes
expect "--no-ufw=1 — понятная ошибка"     2 "" "--no-ufw не принимает значение" -- apply zram --no-ufw=1
expect "--ufw=Y по-английски"             2 "" "--ufw takes no value: write --ufw or --no-ufw" -- --lang en apply zram --ufw=Y
expect "--swap=2048 не задет (не yn)"     0 "" "" -- apply zram --swap=2048

echo ""
echo "справка и версия"
expect "version"                          0 "" "$VERSION"  -- version
expect "-V"                               0 "" "$VERSION"  -- -V
expect "help"                             0 "" "Команды:"  -- help
expect "help apply печатает флаги из таблицы" 0 "" "--swap" -- help apply
expect "apply --help — справка по apply"  0 "" "--docker-restart" -- apply --help
expect "help apply firewall — лишний аргумент" 2 "" "help: лишний аргумент" -- help apply firewall
expect "help apply firewall по-английски" 2 "" "help: unexpected argument" -- --lang en help apply firewall
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
for u in HTTP://example.com/x Http://example.com/x hTTp://example.com/x; do
    r="$( USFC_CONFIG_FILE="$u"; fetch_config() { echo "FETCH $1"; return 1; }; apply_cli_answers 2>&1; echo "rc=$?" )"
    [[ "$r" == *rc=2* && "$r" != *FETCH* ]] && ok "${u%%:*}:// отвергается без скачивания" || bad "${u%%:*}:// не отвергнут: $r"
done
# HTTPS в любом регистре — это https: в curl уходит схема в нижнем регистре,
# остальной адрес (путь, токен в query) не меняется
for u in HTTPS://Example.com/Path?T=aBc Https://Example.com/Path?T=aBc https://Example.com/Path?T=aBc; do
    r="$( USFC_CONFIG_FILE="$u"; fetch_config() { echo "FETCH $1"; return 1; }; apply_cli_answers 2>&1 )"
    [[ "$r" == *"FETCH https://Example.com/Path?T=aBc"* ]] && ok "${u%%:*}:// качается как https" || bad "${u%%:*}:// передан как: $r"
done
r="$( USFC_CONFIG_FILE="HTTPS://Example.com/Path?T=aBc"; fetch_config() { return 1; }; apply_cli_answers 2>&1 )"
[[ "$r" != *aBc* ]] && ok "секрет из URL в лог не попал" || bad "URL с секретом в выводе"

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
echo "usfc export"
# Состояние сервера подменено: ufw и certbot применены, токен в памяти есть
ex="$(
    refresh_statuses() { :; }
    item_applied() { case "$1" in ufw|certbot) return 0 ;; esac; return 1; }
    ufw_active() { return 0; }
    pkg_installed() { return 0; }
    # shellcheck disable=SC2034  # подмены читает export_cmd
    fw_ping_state() { REPLY_FW_PING=off; }
    hostname() { echo node-1; }
    ufw() { printf '%s\n' 'Status: active' '' 'To   Action  From' '--   ------  ----' \
        "${SSH_PORT}/tcp   ALLOW   Anywhere" '443   ALLOW   Anywhere' '51820/udp   ALLOW   Anywhere' \
        '9000/tcp   ALLOW   10.0.0.0/8' '443 (v6)   ALLOW   Anywhere (v6)'; }
    # shellcheck disable=SC2034
    CF_TOKEN_BULK=секретный-токен-123
    export_cmd 2>"$TMP/export-err"   # в файл уходит только stdout, как у `usfc export > файл`
)"
! grep -F "секретный-токен-123" "$TMP/export-err" >/dev/null && [[ "$ex" != *"секретный-токен-123"* ]] && [[ "$ex" == *"# CF_TOKEN="* ]] \
    && ok "токен Cloudflare не выгружается, ключ закомментирован" || bad "токен в выводе export"
[[ "$ex" == *$'\nITEMS=certbot,ufw\n'* ]] && ok "ITEMS — применённые пункты в порядке меню" || bad "ITEMS: $(grep '^ITEMS' <<< "$ex")"
[[ "$ex" == *'UFW_ALLOW="443/tcp 51820/udp"'* ]] && ok "порты без SSH, v6-дублей и правил «для адреса»" || bad "UFW_ALLOW: $(grep '^UFW_ALLOW' <<< "$ex")"
[[ "$ex" == *"9000/tcp ← 10.0.0.0/8"* ]] && ok "правило для адреса — комментарием" || bad "правило для адреса потерялось"
grep -E '^(SWAP_MB|ZRAM_PERCENT|SYSCTL|TIMEZONE|HOSTNAME)=' <<< "$ex" >/dev/null \
    && bad "выгружены ответы пунктов не из ITEMS" || ok "ответы только для пунктов из ITEMS"

# файл export и его однострочная команда принимаются и дают одно состояние
printf '%s\n' "$ex" > "$cfg"
# shellcheck disable=SC2034  # читается в apply_cli_answers
via_cfg="$( USFC_CONFIG_FILE="$cfg"; apply_cli_answers >"$TMP/cfg-err" 2>&1; echo "rc=$? $USFC_APPLY_SPEC|$UFW_BULK|$UFW_ALLOW_BULK|$UFW_PING_BULK|$CERTBOT_CF_BULK|$CERTBOT_TLS_BULK" )"
line="$(sed -n 's/^#     apply //p' "$cfg")"
# shellcheck disable=SC2086  # строка команды делится на аргументы, как в shell
via_flags="$( parse_args apply ${line} >/dev/null 2>&1; apply_cli_answers >/dev/null 2>&1
    check_cli_answer_items certbot ufw >/dev/null 2>&1 || echo "items-fail"
    echo "rc=0 $USFC_APPLY_SPEC|$UFW_BULK|$UFW_ALLOW_BULK|$UFW_PING_BULK|$CERTBOT_CF_BULK|$CERTBOT_TLS_BULK" )"
[[ "$via_cfg" == rc=0* ]] && [ "$via_cfg" = "$via_flags" ] && ok "файл export и его команда дают одни ответы" \
    || { bad "файл: «$via_cfg», команда: «$via_flags»"; sed 's/^/      /' "$TMP/cfg-err"; sed 's/^/      | /' "$cfg"; }

echo ""
echo "проверка скачанного обновления перед заменой"
# usfc_stage_loads смотрит не на код возврата source, а на то, что код
# реально загрузился: модуль, ломающий загрузку посреди файла, отсеивается
stg="$(mktemp -d)"
cp -R "$(dirname "${1:-src/setup.sh}")/." "$stg/"
usfc_stage_loads "$stg/setup.sh" && ok "целая версия загружается" || bad "целая версия отвергнута"
last_mod="$(grep -v '^[[:space:]]*\(#\|$\)' "$stg/MODULES" | tail -1)"
cp "$stg/$last_mod" "$stg/keep.sh"
printf '\nunset -f main\ntrue\n' >> "$stg/$last_mod"
usfc_stage_loads "$stg/setup.sh" && bad "версия без main принята" || ok "без main — отвергнута, хотя source вернул 0"
cp "$stg/keep.sh" "$stg/$last_mod"
printf '\nexit 0\n' >> "$stg/$(grep -v '^[[:space:]]*\(#\|$\)' "$stg/MODULES" | head -1)"
usfc_stage_loads "$stg/setup.sh" && bad "exit 0 в первом модуле принят" || ok "exit 0 посреди загрузки — отвергнута"
rm -rf "$stg"

echo ""
echo "обновление: модули пачкой, недостающее — по одному"
fm="$(mktemp -d)"
mkdir -p "$fm/remote/lib"
echo 'a=1' > "$fm/remote/lib/a.sh"; echo 'b=1' > "$fm/remote/lib/b.sh"; echo 'c=1' > "$fm/remote/lib/c.sh"
fm_run() {  # fm_run <режим curl> — REPLY: код, вызовы curl, вызовы usfc_fetch_to
    (
        rm -rf "$fm/st" "$fm/log"; mkdir -p "$fm/st"
        # shellcheck disable=SC2034  # читается в usfc_fetch_many
        REPO_RAW_BASE="https://example.invalid/src"; MODE="$1"
        curl() {
            local a urls=() outs=() par=0 i rel
            while [ "$#" -gt 0 ]; do
                case "$1" in -o) outs+=("$2"); shift 2 ;; --parallel) par=1; shift ;; https*) urls+=("$1"); shift ;; *) shift ;; esac
            done
            echo "curl ${#urls[@]} par=$par" >> "$fm/log"
            [ "$MODE" = old ] && [ "$par" = 1 ] && return 2
            for i in "${!urls[@]}"; do
                rel="${urls[$i]##*/src/}"
                case "$MODE" in skip|dead) [ "$rel" = lib/b.sh ] && continue ;; esac
                if [ "$MODE" = broken ] && [ "$rel" = lib/c.sh ]; then echo 'if then' > "${outs[$i]}"; continue; fi
                cp "$fm/remote/$rel" "${outs[$i]}"
            done
        }
        usfc_fetch_to() { echo "one $1" >> "$fm/log"; [ "$MODE" = dead ] && [ "$1" = lib/b.sh ] && return 1; cp "$fm/remote/$1" "$2"; }
        usfc_fetch_many "$fm/st" lib/a.sh lib/b.sh lib/c.sh; rc=$?
        echo "rc=$rc failed=${REPLY_FETCH_FAILED}" >> "$fm/log"
        ok_files=1
        [ "$rc" -eq 0 ] && for f in a b c; do cmp -s "$fm/st/lib/$f.sh" "$fm/remote/lib/$f.sh" || ok_files=0; done
        echo "files=$ok_files parts=$(find "$fm/st" -name '*.part' | wc -l)" >> "$fm/log"
    )
    cat "$fm/log"
}
out="$(fm_run normal)"
[[ "$out" == *"curl 3 par=1"* && "$out" != *"one "* && "$out" == *"rc=0"* && "$out" == *"files=1 parts=0"* ]] \
    && ok "все три одним curl --parallel" || bad "пачка: $out"
out="$(fm_run old)"
[[ "$out" == *"one lib/a.sh"* && "$out" == *"one lib/c.sh"* && "$out" == *"rc=0"* && "$out" == *"files=1"* ]] \
    && ok "curl без --parallel: все по одному" || bad "старый curl: $out"
out="$(fm_run skip)"
[[ "$out" == *"one lib/b.sh"* && "$out" != *"one lib/a.sh"* && "$out" == *"rc=0"* && "$out" == *"files=1"* ]] \
    && ok "не пришедший файл докачан, остальные нет" || bad "докачка: $out"
out="$(fm_run broken)"
[[ "$out" == *"one lib/c.sh"* && "$out" == *"rc=0"* && "$out" == *"files=1 parts=0"* ]] \
    && ok "битый в пачке перекачан по одному" || bad "битый: $out"
out="$(fm_run dead)"
[[ "$out" == *"rc=1 failed=lib/b.sh"* ]] && ok "сбой назван: lib/b.sh" || bad "сбой: $out"
rm -rf "$fm"

echo ""
echo "обновление: сбой на середине замены возвращает всё"
# Падает mv MODULES из staging: к этому моменту lib и setup.sh уже новые. Откат обязан
# вернуть все четыре вещи, а не один lib (смешанная установка)
ur="$(mktemp -d)"
mkroot() {  # mkroot — свежий корень со старой установкой и «скачанной» новой
    rm -rf "${ur:?}"/*; mkdir -p "$ur/root/lib" "$ur/remote/lib"
    echo OLD-SETUP > "$ur/root/setup.sh"; echo OLD-MODULES > "$ur/root/MODULES"
    echo 1.0.0 > "$ur/root/VERSION"; echo OLD-LIB > "$ur/root/lib/a.sh"
    echo NEW-SETUP > "$ur/remote/setup.sh"; printf 'lib/a.sh\n' > "$ur/remote/MODULES"
    echo 2.0.0 > "$ur/remote/VERSION"; echo NEW-LIB > "$ur/remote/lib/a.sh"
}
run_update() {  # run_update <паттерн цели mv, на которой падать или ''>
    (
        # shellcheck disable=SC2034  # читаются в install_update
        SCRIPT_PATH="$ur/root/setup.sh"
        # shellcheck disable=SC2034
        USFC_ROOT="$ur/root"; VERSION=1.0.0; FAIL_MV="$1"
        usfc_fetch_to() { mkdir -p "$(dirname "$2")"; cp "$ur/remote/$1" "$2"; }
        curl() { return 2; }    # пачка не приходит — модули идут через usfc_fetch_to
        usfc_stage_loads() { return 0; }
        mv() { [ -n "$FAIL_MV" ] && [[ "${*: -2:1}" == *"/.usfc-stage${FAIL_MV}" ]] && return 1; command mv "$@"; }
        install_update 2.0.0 >/dev/null 2>&1
    )
}
snap() { echo "$(cat "$ur/root/setup.sh") $(cat "$ur/root/MODULES") $(cat "$ur/root/VERSION") $(cat "$ur/root/lib/a.sh")"; }
mkroot; run_update ''; rc=$?
[ "$rc" -eq 0 ] || bad "контроль: install_update вернул $rc"
[ -e "$ur/root/MODULES" ] && [ "$(cat "$ur/root/MODULES")" = "lib/a.sh" ] && [ "$(snap)" = "NEW-SETUP lib/a.sh 2.0.0 NEW-LIB" ] \
    && ok "успех: setup.sh, MODULES, VERSION и lib новые" || bad "успех: $(snap)"
[ -n "$(find "$ur/root" -maxdepth 1 -name '*.old*')" ] && bad "после успеха остались *.old" || ok "после успеха *.old убраны"
for tgt in /MODULES /VERSION /setup.sh; do
    mkroot; run_update "$tgt"; rc=$?
    [ "$rc" -eq 1 ] && [ "$(snap)" = "OLD-SETUP OLD-MODULES 1.0.0 OLD-LIB" ] \
        && ok "сбой mv ${tgt#/}: возвращены setup.sh, MODULES, VERSION и lib" || bad "сбой mv ${tgt#/}: rc=$rc, состояние «$(snap)»"
    [ -n "$(find "$ur/root" -maxdepth 1 -name '*.old*')" ] && bad "после отката остались *.old" || ok "после отката *.old убраны"
done
mkroot; run_update /lib; rc=$?
[ "$rc" -eq 1 ] && [ "$(snap)" = "OLD-SETUP OLD-MODULES 1.0.0 OLD-LIB" ] && ok "сбой mv lib: установка прежняя" || bad "сбой mv lib: rc=$rc «$(snap)»"
rm -rf "$ur"

echo ""
echo "сухой прогон: hostnamectl наружу только читает"
fb="$(mktemp -d)"
printf '#!/bin/sh\necho "REAL $*"\n' > "$fb/hostnamectl"
command chmod +x "$fb/hostnamectl"
hn() { ( PATH="$fb:$PATH"; USFC_DRY_RUN=true; dry_run_enable; hostnamectl "$@" ) 2>&1; }
for args in "" "status" "hostname" "--static" "--static hostname"; do
    # shellcheck disable=SC2086  # слова аргументов разделяются намеренно
    case "$(hn $args)" in *REAL*) ok "чтение пропущено: «${args}»" ;; *) bad "чтение перехвачено: «${args}»" ;; esac
done
for args in "set-hostname x" "hostname node-1" "--static set-hostname x" "--pretty Node"; do
    # shellcheck disable=SC2086
    case "$(hn $args)" in *REAL*) bad "запись ушла наружу: «${args}»" ;; *) ok "запись перехвачена: «${args}»" ;; esac
done
rm -rf "$fb"

echo ""
[ "$fail" -eq 0 ] && echo "командная строка: все проверки пройдены" || echo "командная строка: ЕСТЬ ОШИБКИ"
exit "$fail"
