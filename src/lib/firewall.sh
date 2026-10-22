# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
#
# Файрвол: общая логика пункта «UFW» и команды `usfc firewall`. Две копии
# разбора портов и правки before.rules разъехались бы при первой же правке.
#
# До 5.0 пункт брал только TCP-порты, которые слушались в момент включения:
# WireGuard и Hysteria (UDP) отрезались, свой порт не задать, ответ на ping
# не выключить, а порты Docker-контейнеров UFW не подчинялись вовсе.

# Каталог правил — переменная ради теста: tests/test_firewall.sh правит
# эталонные файлы пакета ufw в tests/fixtures/ufw, а не /etc
UFW_DIR="${UFW_DIR:-/etc/ufw}"

# ── Порты ────────────────────────────────────────────────────────────────────
# fw_parse_ports <спецификация...> → REPLY_FW_PORTS («80/tcp 51820/udp …»)
# или REPLY_FW_ERR и код 1. Принимает «80», «443/tcp», «51820/udp»,
# «1000:2000/tcp» через запятые и пробелы. Без протокола — tcp: так пишут
# порты веб-сервисов, а UDP почти всегда указывают явно (VPN)
REPLY_FW_PORTS=''; REPLY_FW_ERR=''
fw_parse_ports() {
    local spec w lo hi proto p out=' '
    REPLY_FW_PORTS=''; REPLY_FW_ERR=''
    spec="$*"; spec="${spec//,/ }"
    for w in $spec; do
        if ! [[ "$w" =~ ^([0-9]+)(:([0-9]+))?(/(tcp|udp))?$ ]]; then
            t "«${w}» — не порт. Примеры: 443, 51820/udp, 1000:2000/tcp" "\"${w}\" is not a port. Examples: 443, 51820/udp, 1000:2000/tcp"
            REPLY_FW_ERR="$REPLY_T"; return 1
        fi
        lo=$((10#${BASH_REMATCH[1]})); hi="${BASH_REMATCH[3]}"; proto="${BASH_REMATCH[5]:-tcp}"
        [ -n "$hi" ] && hi=$((10#$hi))
        if [ "$lo" -lt 1 ] || [ "$lo" -gt 65535 ] || { [ -n "$hi" ] && { [ "$hi" -gt 65535 ] || [ "$hi" -le "$lo" ]; }; }; then
            t "«${w}» — порт вне 1..65535 или диапазон наоборот" "\"${w}\" is outside 1..65535 or the range is reversed"
            REPLY_FW_ERR="$REPLY_T"; return 1
        fi
        p="${lo}${hi:+:${hi}}/${proto}"
        [[ "$out" == *" $p "* ]] || out="${out}${p} "
    done
    out="${out# }"; REPLY_FW_PORTS="${out% }"
    return 0
}

# fw_valid_from <адрес> — IPv4/IPv6 с маской или без. Только форма: ufw
# сам откажет на 300.1.1.1, а нам важно не пустить в его аргументы мусор
fw_valid_from() {
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] && return 0
    [[ "$1" =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*(/[0-9]{1,3})?$ ]] && return 0
    return 1
}

# fw_listening → REPLY_FW_LISTEN: строки «порт/протокол процесс», TCP и UDP,
# только наружу. Локальные адреса (127.*, ::1, ::ffff:127.*, link-local, %lo)
# снаружи недостижимы. 68/udp и 546/udp — клиенты DHCP: они слушают ответ
# сервера, а не принимают подключения, и открывать их незачем
REPLY_FW_LISTEN=''
fw_listening() {
    REPLY_FW_LISTEN="$(ss -tulpnH 2>/dev/null | awk '
        { proto = $1; addr = $5; port = addr; sub(/.*:/, "", port)
          host = addr; sub(/:[^:]*$/, "", host)
          if (host ~ /^(127\.|\[::1\]|\[::ffff:127\.|\[fe80|fe80)/ || host ~ /%lo$/) next
          if (proto == "udp" && (port == 68 || port == 546)) next
          key = port "/" proto
          if (key in seen) next
          seen[key] = 1
          proc = ""
          if (match($0, /users:\(\("[^"]+"/)) proc = substr($0, RSTART + 9, RLENGTH - 10)
          print key " " proc }' | sort -t/ -k1,1n)"
}

ufw_active() {
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep "Status: active" >/dev/null
}

# _fw_ufw <аргументы ufw…> — вызов с проверкой кода: ошибка ufw видна
# человеку, а не только в логе. До 5.0 код `ufw allow` не проверялся вовсе
_fw_ufw() {
    local out rc
    out="$(ufw "$@" 2>&1)"; rc=$?
    printf '\n--- %s $ ufw %s\n%s\n' "$(date '+%F %T')" "$*" "$out" >> "${USFC_LOG:-/dev/null}" 2>/dev/null
    if [ "$rc" -ne 0 ]; then
        log_error "ufw $*: ${out##*$'\n'}"
        return "$rc"
    fi
    [ "$USFC_DRY_RUN" = true ] && printf '%s\n' "$out"
    return 0
}

# fw_has_answers — заданы ли явные порты, ping или Docker (--allow,
# --no-ping, UFW_ALLOW…). На включённом UFW это новые правила, а не повторное
# включение: filter_pending не отсеивает такой пункт как «уже применённый», а
# process_item не уводит его в disable_ufw
fw_has_answers() {
    [ -n "${UFW_ALLOW_BULK}${UFW_PING_BULK}${UFW_DOCKER_BULK}" ]
}

# fw_allow <откуда|''> <порт/протокол…> — разрешить порты (снаружи или с
# одного адреса). При включённой связке с Docker — ещё и маршрут к
# контейнерам (см. fw_docker_route)
fw_allow() {
    local from="$1" p rc=0; shift
    for p in "$@"; do
        if [ -z "$from" ]; then
            _fw_ufw allow "$p" || rc=1
        else
            _fw_ufw allow from "$from" to any port "${p%/*}" proto "${p#*/}" || rc=1
        fi
        fw_docker_on && { fw_docker_route allow "$from" "$p" || rc=1; }
    done
    return "$rc"
}

# fw_deny <откуда|''> <порт/протокол…> — убрать разрешение. SSH-порт не
# закрываем никогда: так отрезают себе доступ к серверу одной командой
fw_deny() {
    local from="$1" p rc=0 out; shift
    for p in "$@"; do
        if [ "${p%/*}" = "$SSH_PORT" ] && [ "${p#*/}" = tcp ]; then
            log_error_t "${p} — порт SSH, его не закрываю: оборвётся доступ к серверу" \
"${p} is the SSH port, not closing it: it would cut off access to the server"
            rc=1; continue
        fi
        if [ -z "$from" ]; then
            out="$(ufw delete allow "$p" 2>&1)" || rc=1
        else
            out="$(ufw delete allow from "$from" to any port "${p%/*}" proto "${p#*/}" 2>&1)" || rc=1
        fi
        # несуществующее правило ufw «удаляет» с кодом 0 — скажем прямо
        if [[ "$out" == *non-existent* ]]; then
            log_warn_t "${p}: такого разрешения не было" "${p}: there was no such rule"
        elif [ "$USFC_DRY_RUN" = true ]; then
            printf '%s\n' "$out"
        elif [ "$rc" -eq 0 ]; then
            log_success_t "${p}: разрешение снято" "${p}: rule removed"
        fi
        fw_docker_on && fw_docker_route delete "$from" "$p" >/dev/null 2>&1
    done
    return "$rc"
}

# fw_enable <откуда|''> <порт/протокол…> — включить UFW с этими портами.
# Порядок важен: сначала SSH (если он не встал — дальше не идём, иначе
# `enable` закроет и его), потом явные политики, потом остальное, и только
# потом enable. Политики раньше не задавались: на сервере с изменённым
# /etc/default/ufw «включённый файрвол» мог ничего не закрывать
fw_enable() {
    local from="$1"; shift
    if ! _fw_ufw allow "${SSH_PORT}/tcp"; then
        log_error_t "Не удалось разрешить SSH-порт ${SSH_PORT} — UFW не включаю" \
"Could not allow the SSH port ${SSH_PORT} — not enabling UFW"
        return 1
    fi
    _fw_ufw default deny incoming && _fw_ufw default allow outgoing || return 1
    local rc=0
    [ "$#" -gt 0 ] && { fw_allow "$from" "$@" || rc=1; }
    _fw_ufw --force enable || return 1
    return "$rc"
}

# ── Ответ на ping ────────────────────────────────────────────────────────────
# Схема пользователя: в before.rules в блоках «# ok icmp codes for INPUT» и
# «# ok icmp code for FORWARD» ACCEPT → DROP, и в конец INPUT строка про
# source-quench. Ответы на наши же соединения (RELATED — в том числе
# «фрагментация нужна» для PMTU) пропускает правило conntrack выше этих
# блоков, так что исходящие соединения не ломаются.
#
# IPv6: только echo-request. Остальной ICMPv6 трогать нельзя — на нём
# держится обнаружение соседей (NDP), без него IPv6 просто перестаёт работать
FW_PING_SQ='-A ufw-before-input -p icmp --icmp-type source-quench -j DROP'

# fw_ping_transform <on|off> <v4|v6> — фильтр stdin → stdout. Код 3 — нужные
# блоки не найдены (файл не от ufw или переписан руками)
fw_ping_transform() {
    awk -v mode="$1" -v fam="$2" -v sq="$FW_PING_SQ" '
        function flip(s) {
            if (mode == "off") sub(/-j ACCEPT$/, "-j DROP", s)
            else               sub(/-j DROP$/, "-j ACCEPT", s)
            return s
        }
        fam == "v6" {
            if ($0 ~ /^-A ufw6-before-input -p icmpv6 --icmpv6-type echo-request -j (ACCEPT|DROP)$/) { found = 1; $0 = flip($0) }
            print; next
        }
        /^# ok icmp codes for INPUT$/  { sec = "in";  found = 1; print; next }
        /^# ok icmp code for FORWARD$/ { sec = "fwd"; print; next }
        sec != "" && /^[[:space:]]*$/ {
            if (sec == "in" && mode == "off" && !sq_seen) print sq
            sec = ""; print; next
        }
        sec == "in" && $0 == sq { sq_seen = 1; if (mode == "on") next; print; next }
        sec != "" && /^-A ufw-before-(input|forward) -p icmp / { print flip($0); next }
        { print }
        END {
            if (sec == "in" && mode == "off" && !sq_seen) print sq
            if (!found) exit 3
        }'
}

# _fw_rules_files — пары «семейство файл» тех, что есть
_fw_ping_files() {
    [ -f "$UFW_DIR/before.rules" ]  && echo "v4 $UFW_DIR/before.rules"
    [ -f "$UFW_DIR/before6.rules" ] && echo "v6 $UFW_DIR/before6.rules"
}

# fw_ping_state → REPLY_FW_PING: on | off | mixed | unknown. Состояние —
# это «файл уже совпадает с результатом правки»: так on/off определяются
# ровно той же логикой, что их ставит, и не разъедутся с ней
REPLY_FW_PING=''
fw_ping_state() {
    local fam f st='' cur on off
    REPLY_FW_PING=unknown
    while read -r fam f; do
        cur="$(cat "$f")" || return 1
        on="$(fw_ping_transform on "$fam" < "$f")" || return 1
        off="$(fw_ping_transform off "$fam" < "$f")" || return 1
        if [ "$cur" = "$off" ] && [ "$cur" != "$on" ]; then cur=off
        elif [ "$cur" = "$on" ]; then cur=on
        else cur=mixed; fi
        if [ -z "$st" ]; then st="$cur"; elif [ "$st" != "$cur" ]; then st=mixed; fi
    done < <(_fw_ping_files)
    [ -n "$st" ] && REPLY_FW_PING="$st"
    return 0
}

# fw_ping_set <on|off> — правка before.rules/before6.rules через write_file
# (снимок для `usfc restore`, сухой прогон), только если что-то меняется.
# Потом reload: без него правка ждала бы перезагрузки
fw_ping_set() {
    local mode="$1" fam f tmp changed=false rc=0
    while read -r fam f; do
        tmp="$(mktemp)" || return 1
        if ! fw_ping_transform "$mode" "$fam" < "$f" > "$tmp"; then
            rm -f "$tmp"
            log_error_t "${f}: не нашёл блоков ICMP — файл не похож на стандартный от ufw, не трогаю" \
"${f}: ICMP sections not found — the file does not look like ufw's stock one, leaving it alone"
            rc=1; continue
        fi
        if ! cmp -s "$tmp" "$f"; then
            write_file "$f" < "$tmp" || rc=1
            changed=true
        fi
        rm -f "$tmp"
    done < <(_fw_ping_files)
    if [ "$changed" = true ] && ufw_active; then _fw_ufw reload || rc=1; fi
    if [ "$rc" -eq 0 ]; then
        if [ "$mode" = off ]; then
            log_success_t "Ответ на ping выключен" "Ping replies disabled"
        else
            log_success_t "Ответ на ping включён" "Ping replies enabled"
        fi
    fi
    return "$rc"
}

# ── Docker ───────────────────────────────────────────────────────────────────
# Docker публикует порты через nat-таблицу, и пакеты к контейнерам уходят в
# FORWARD мимо INPUT, где живут правила UFW: `-p 8080:80` открыт всему миру
# при включённом файрволе. Так прямо сказано в документации Docker («Docker
# and ufw»). Лекарство — схема ufw-docker (github.com/chaifeng/ufw-docker):
# блок в after.rules заворачивает цепочку DOCKER-USER в правила
# `ufw route`, и снаружи к контейнеру проходит только разрешённое.
#
# Ограничения схемы (сверено с документацией Docker 28/29):
#   • только iptables-бэкенд Docker. В экспериментальном nftables-бэкенде
#     (29.0+, firewall-backend: nftables) цепочки DOCKER-USER нет;
#   • только IPv4: для after6.rules ufw-docker своего блока не публикует;
#   • правило маршрута пишется на порт КОНТЕЙНЕРА: для `-p 8080:80` это 80.
FW_DOCKER_BEGIN='# BEGIN UFW AND DOCKER'
FW_DOCKER_END='# END UFW AND DOCKER'
fw_docker_block() {
    cat <<'EOF'
# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward

-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -m conntrack --ctstate INVALID -j DROP
-A DOCKER-USER -i docker0 -o docker0 -j ACCEPT

-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16

-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 192.168.0.0/16

-A DOCKER-USER -j RETURN

-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

COMMIT
# END UFW AND DOCKER
EOF
}

fw_docker_on() {
    [ -f "$UFW_DIR/after.rules" ] && grep -qxF "$FW_DOCKER_BEGIN" "$UFW_DIR/after.rules"
}

# Docker с nftables-бэкендом: DOCKER-USER нет, схема не сработает
fw_docker_nftables() {
    [ -f /etc/docker/daemon.json ] && grep -E '"firewall-backend"[[:space:]]*:[[:space:]]*"nftables"' /etc/docker/daemon.json >/dev/null
}

# fw_docker_published → REPLY_FW_DOCKER: строки «хост-порт/протокол
# порт-контейнера имя» по запущенным контейнерам
REPLY_FW_DOCKER=''
fw_docker_published() {
    REPLY_FW_DOCKER=''
    command -v docker >/dev/null 2>&1 || return 0
    REPLY_FW_DOCKER="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | awk '
        { name = $1
          for (i = 2; i <= NF; i++) {
              s = $i; sub(/,$/, "", s)
              if (s !~ /->/) continue
              split(s, a, "->"); hp = a[1]; sub(/.*:/, "", hp); cp = a[2]
              split(cp, b, "/"); key = hp "/" b[2] " " b[1] " " name
              if (!(key in seen)) { seen[key] = 1; print key }
          } }')"
}

# fw_docker_route <allow|delete> <откуда|''> <порт/протокол> — правило
# маршрута к контейнерам. Если порт опубликован с другим номером внутри
# (8080→80), правило пишется на порт контейнера: DOCKER-USER видит пакет
# уже после DNAT
fw_docker_route() {
    local act="$1" from="${2:-any}" p="$3" ports="${3%/*}" proto="${3#*/}" hp rest cp
    fw_docker_published
    while read -r hp cp rest; do
        [ "$hp" = "$p" ] && [ "$cp" != "$ports" ] && ports="$ports $cp"
    done <<< "$REPLY_FW_DOCKER"
    local rc=0 n
    for n in $ports; do
        if [ "$act" = delete ]; then
            ufw route delete allow proto "$proto" from "$from" to any port "$n" >/dev/null 2>&1
        else
            _fw_ufw route allow proto "$proto" from "$from" to any port "$n" || rc=1
        fi
    done
    return "$rc"
}

# fw_docker_sync — после включения связки: опубликованным портам, которые
# уже разрешены в UFW, — правило маршрута; остальные назвать, они закроются.
# `ufw show added` читает правила и у выключенного UFW
fw_docker_sync() {
    local added hp cp name closed='' rc=0
    fw_docker_published
    [ -n "$REPLY_FW_DOCKER" ] || return 0
    added="$(ufw show added 2>/dev/null)"
    while read -r hp cp name; do
        [ -n "$hp" ] || continue
        if grep -xE "ufw allow (${hp}|${hp%/*})" <<< "$added" >/dev/null; then
            fw_docker_route allow '' "$hp" || rc=1
        else
            closed="${closed} ${hp}(${name})"
        fi
    done <<< "$REPLY_FW_DOCKER"
    if [ -n "$closed" ]; then
        log_warn_t "Теперь закрыты снаружи:${closed}. Открыть: usfc firewall --allow <порт>" "Now closed from outside:${closed}. To open: usfc firewall --allow <port>"
    fi
    return "$rc"
}

# fw_docker_set <on|off> — добавить или убрать блок в after.rules
fw_docker_set() {
    local mode="$1" f="$UFW_DIR/after.rules" tmp rc
    [ -f "$f" ] || { log_error_t "Нет ${f} — ufw не установлен?" "No ${f} — is ufw installed?"; return 1; }
    if [ "$mode" = on ]; then
        fw_docker_on && return 0
        if fw_docker_nftables; then
            log_error_t "Docker работает на nftables-бэкенде: цепочки DOCKER-USER там нет, подчинить его UFW так нельзя" \
"Docker runs on the nftables backend: it has no DOCKER-USER chain, so it cannot be put behind UFW this way"
            return 1
        fi
        # через временный файл: `{ cat f; …; } | write_file f` гонится —
        # write_file обрезает f раньше, чем cat успевает его прочитать
        tmp="$(mktemp)" || return 1
        { cat "$f"; echo ""; fw_docker_block; } > "$tmp"
        write_file "$f" < "$tmp"; rc=$?
        rm -f "$tmp"
        [ "$rc" -eq 0 ] || return 1
    else
        fw_docker_on || return 0
        tmp="$(mktemp)" || return 1
        # вместе с блоком уходит пустая строка, которую добавили перед ним
        awk -v b="$FW_DOCKER_BEGIN" -v e="$FW_DOCKER_END" '
            $0 == b { skip = 1; if (held) held = 0; next }
            skip { if ($0 == e) skip = 0; next }
            { if (held) print ""; held = 0
              if ($0 == "") { held = 1; next }
              print }
            END { if (held) print "" }' "$f" > "$tmp"
        write_file "$f" < "$tmp"; rc=$?
        rm -f "$tmp"
        [ "$rc" -eq 0 ] || return 1
    fi
    if [ "$mode" = on ]; then fw_docker_sync || return 1; fi
    if ufw_active; then _fw_ufw reload || return 1; fi
    if [ "$mode" = on ]; then
        log_success_t "Docker подчинён UFW: снаружи к контейнерам — только разрешённые порты" \
"Docker is behind UFW now: only allowed ports reach the containers from outside"
        log_info_t "Если правила не подхватились — перезагрузите сервер (так советует и ufw-docker)" \
"If the rules did not take effect, reboot the server (ufw-docker advises the same)"
    else
        log_success_t "Связка Docker и UFW снята: опубликованные порты контейнеров снова открыты всем" \
"Docker is no longer behind UFW: published container ports are open to everyone again"
    fi
}

# ── Сводка ───────────────────────────────────────────────────────────────────
fw_show_status() {
    if ! command -v ufw >/dev/null 2>&1; then
        log_info_t "UFW не установлен" "UFW is not installed"; return 0
    fi
    ufw status verbose 2>/dev/null | sed 's/^/      /'
    fw_ping_state
    case "$REPLY_FW_PING" in
        on)    t "отвечает" "replies" ;;
        off)   t "не отвечает" "does not reply" ;;
        mixed) t "частично (before.rules правили руками?)" "partly (before.rules edited by hand?)" ;;
        *)     t "неизвестно" "unknown" ;;
    esac
    log_info_t "Ping: ${REPLY_T}" "Ping: ${REPLY_T}"
    if command -v docker >/dev/null 2>&1; then
        if fw_docker_on; then t "подчинён UFW" "behind UFW"; else t "мимо UFW — опубликованные порты открыты всем" "bypasses UFW — published ports are open to everyone"; fi
        log_info_t "Docker: ${REPLY_T}" "Docker: ${REPLY_T}"
    fi
}

# ── Команда `usfc firewall` ──────────────────────────────────────────────────
# Без аргументов — сводка. Порты, ping и Docker — те же ключи ответов, что
# у пункта ufw (UFW_ALLOW, UFW_FROM, UFW_PING, UFW_DOCKER): флаги у `apply`
# и у `firewall` одинаковые
FW_CMD_ACTION=''      # ping|docker — позиционное «usfc firewall ping off»
FW_CMD_VALUE=''
FW_CMD_DENY=''
firewall_cmd() {
    apply_cli_answers || return 2
    local from="${UFW_FROM_BULK:-}"
    if [ -z "$UFW_ALLOW_BULK$FW_CMD_DENY$UFW_PING_BULK$UFW_DOCKER_BULK$FW_CMD_ACTION" ]; then
        fw_show_status; return 0
    fi
    [ "$FW_CMD_ACTION" = ping ]   && { [ "$FW_CMD_VALUE" = on ] && UFW_PING_BULK=Y || UFW_PING_BULK=N; }
    [ "$FW_CMD_ACTION" = docker ] && { [ "$FW_CMD_VALUE" = on ] && UFW_DOCKER_BULK=Y || UFW_DOCKER_BULK=N; }

    ensure_pkg "UFW" ufw || return 1
    local rc=0
    if [ -n "$UFW_ALLOW_BULK" ]; then
        fw_parse_ports "$UFW_ALLOW_BULK" || { log_error "$REPLY_FW_ERR"; return 2; }
        local -a ports
        read -ra ports <<< "$REPLY_FW_PORTS"
        if ufw_active; then
            fw_allow "$from" "${ports[@]}" || rc=1
        else
            # включение файрвола — то самое действие, которое рвёт VPN и
            # прокси, поэтому у терминала спрашиваем; --yes и скрипт — нет
            if usfc_interactive && [ "$USFC_ASSUME_YES" != true ]; then
                log_warn_t "UFW выключен. Включение закроет всё, кроме SSH (${SSH_PORT}) и ${REPLY_FW_PORTS}" \
"UFW is off. Enabling it closes everything except SSH (${SSH_PORT}) and ${REPLY_FW_PORTS}"
                ask_yn_t "Включить UFW?" "Enable UFW?" N || return 1
            fi
            fw_enable "$from" "${ports[@]}" || rc=1
        fi
        [ "$rc" -eq 0 ] && log_success_t "Открыты: ${ports[*]}${from:+ (← ${from})}" "Opened: ${ports[*]}${from:+ (← ${from})}"
    fi
    if [ -n "$FW_CMD_DENY" ]; then
        fw_parse_ports "$FW_CMD_DENY" || { log_error "$REPLY_FW_ERR"; return 2; }
        local -a dports
        read -ra dports <<< "$REPLY_FW_PORTS"
        fw_deny "$from" "${dports[@]}" || rc=1
    fi
    case "$UFW_PING_BULK" in Y) fw_ping_set on || rc=1 ;; N) fw_ping_set off || rc=1 ;; esac
    case "$UFW_DOCKER_BULK" in Y) fw_docker_set on || rc=1 ;; N) fw_docker_set off || rc=1 ;; esac
    reset_bulk_answers
    return "$rc"
}
