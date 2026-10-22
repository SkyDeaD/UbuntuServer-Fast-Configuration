# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# Профили и конфигурация неинтерактивного запуска
# ═══════════════════════════════════════════════════════════════
# Профиль — это именованный набор пунктов под роль сервера. Ничего, кроме
# списка id, в нём нет: ответы на вопросы приезжают отдельно, через
# --config или переменные окружения. Так профиль остаётся читаемым, а не
# превращается во вторую конфигурацию.
#
# Идентификаторы, а не номера: номера пунктов меняются при добавлении
# нового, id — нет. На этом уже обжигались подсказки вида «пункт 12».
declare -A USFC_PROFILES=(
    [minimal]="basepkgs cli unattended"
    [web]="basepkgs cli docker nginx certbot fail2ban unattended zram ufw"
    [dockerhost]="basepkgs cli docker dockerlog fail2ban unattended zram ufw"
    [secure]="basepkgs fail2ban unattended sshhardening ufw"
)

profile_list() {
    local name
    echo ""
    log_info_t "Готовые профили:" \
"Available profiles:"
    for name in minimal web dockerhost secure; do
        printf '    %b%-8s%b %s\n' "$BOLD" "$name" "$NC" "${USFC_PROFILES[$name]}"
    done
    echo ""
    log_info_t "Пункты можно перечислить и вручную: ${BOLD}usfc apply docker,nginx,ufw${NC}" \
"Items can also be listed by hand: ${BOLD}usfc apply docker,nginx,ufw${NC}"
    log_info_t "Все id: ${DIM}${ITEM_IDS[*]}${NC}" \
"All ids: ${DIM}${ITEM_IDS[*]}${NC}"
}

# resolve_items <спецификация> → REPLY_ITEM_NUMS (номера пунктов).
# Принимает: all, имя профиля, список id и/или номеров через запятую/пробел.
REPLY_ITEM_NUMS=()
resolve_items() {
    local spec="$1" tok num i
    local -a tokens=() expanded=()
    REPLY_ITEM_NUMS=()

    # Профили раскрываются ПОТОКЕННО, а не для всей строки целиком: иначе
    # `usfc apply web,ufw` разбирался бы как список id, и про валидный профиль
    # web сообщалось бы «неизвестный пункт» — то есть ровно наоборот
    IFS=', ' read -ra tokens <<< "$spec"
    for tok in "${tokens[@]}"; do
        [ -z "$tok" ] && continue
        case "$tok" in
            all) expanded+=("${ITEM_IDS[@]}") ;;
            *)
                if [ -n "${USFC_PROFILES[$tok]:-}" ]; then
                    # shellcheck disable=SC2206  # список id, разбить по пробелам и надо
                    expanded+=(${USFC_PROFILES[$tok]})
                else
                    expanded+=("$tok")
                fi
                ;;
        esac
    done

    for tok in "${expanded[@]}"; do
        [ -z "$tok" ] && continue
        if [[ "$tok" =~ ^[0-9]+$ ]]; then
            if [ "$tok" -lt 1 ] || [ "$tok" -gt "${#ITEM_IDS[@]}" ]; then
                log_error_t "Нет пункта с номером ${tok} (всего ${#ITEM_IDS[@]})" \
"No item number ${tok} (there are ${#ITEM_IDS[@]})"
                return 1
            fi
            REPLY_ITEM_NUMS+=("$tok")
            continue
        fi
        num=""
        for i in "${!ITEM_IDS[@]}"; do
            [ "${ITEM_IDS[$i]}" = "$tok" ] && { num=$((i + 1)); break; }
        done
        if [ -z "$num" ]; then
            log_error_t "Неизвестный пункт или профиль: ${tok}" \
"Unknown item or profile: ${tok}"
            log_info_t "Доступные id: ${ITEM_IDS[*]}" \
"Available ids: ${ITEM_IDS[*]}"
            log_info_t "Профили: ${!USFC_PROFILES[*]}" \
"Profiles: ${!USFC_PROFILES[*]}"
            return 1
        fi
        REPLY_ITEM_NUMS+=("$num")
    done

    # Профили пересекаются (basepkgs есть почти в каждом), да и руками легко
    # написать пункт дважды. Дубли убираем, порядок — как в меню: применять
    # пункты вразнобой значило бы, например, ставить Docker до базовых пакетов
    local -a uniq=()
    for i in "${!ITEM_IDS[@]}"; do
        num=$((i + 1))
        case " ${REPLY_ITEM_NUMS[*]} " in
            *" $num "*) uniq+=("$num") ;;
        esac
    done
    REPLY_ITEM_NUMS=("${uniq[@]}")

    [ "${#REPLY_ITEM_NUMS[@]}" -gt 0 ] || { log_error_t "Пустой список пунктов" \
"Empty item list"; return 1; }
    return 0
}

# ═══════════════════════════════════════════════════════════════
# Ответы на вопросы пунктов: файл ответов и флаги `usfc apply`
# ═══════════════════════════════════════════════════════════════
# Одна таблица — источник для ВСЕГО: разбора `--config`, флагов `apply`,
# справки `usfc help apply` и сверки документации (tests/test_flags_doc.sh).
# До 5.0 ключи жили в case внутри load_config, флагов не было вовсе, а
# справка перечисляла ключи руками — и уже разошлась с кодом (SYSCTL в ней
# не было).
#
# Поля: КЛЮЧ|переменная|тип|флаг|пункт|описание ru|описание en
#   тип: yn — да/нет (флаг --x даёт Y, --no-x даёт N); int — целое ≥ 0;
#        pct — процент 1..400; secret — только в файле (в командной строке
#        его увидел бы любой через ps)
#   пункт — id, к которому ответ относится: флаг для пункта, которого нет в
#        списке apply, — ошибка, а не тихое игнорирование
USFC_ANSWER_KEYS=(   # i18n-ok: английская пара — последнее поле каждой строки
    "SWAP_MB|SWAP_BULK_MB|int|--swap|zram|размер резервного swap-файла, МБ|backup swap file size, MB"
    "ZRAM_PERCENT|ZRAM_BULK_PERCENT|pct|--zram|zram|размер zram, % от RAM|zram size, % of RAM"
    "ZRAM_RECONF|ZRAM_RECONF_BULK|yn|--zram-reconfigure|zram|перенастроить zram, настроенный вручную|reconfigure a hand-tuned zram"
    "SYSCTL|SYSCTL_BULK|yn|--sysctl|zram|swappiness=80, vfs_cache_pressure=50|swappiness=80, vfs_cache_pressure=50"
    "NGINX_AUTOSTART|NGINX_AUTOSTART|yn|--nginx-autostart|nginx|запустить nginx и включить автозапуск|start nginx and enable autostart"
    "DOCKER_AUTOSTART|DOCKER_AUTOSTART|yn|--docker-autostart|docker|запустить Docker и включить автозапуск|start Docker and enable autostart"
    "DOCKER_RESTART|DOCKER_RESTART_BULK|yn|--docker-restart|dockerlog|перезапустить Docker под лимит логов (перезапустит контейнеры)|restart Docker for the log limit (restarts containers)"
    "CERTBOT_CF|CERTBOT_CF_BULK|yn|--certbot-cf|certbot|плагин Cloudflare (wildcard)|Cloudflare plugin (wildcard)"
    "CF_TOKEN|CF_TOKEN_BULK|secret||certbot|API-токен Cloudflare (Zone:DNS:Edit)|Cloudflare API token (Zone:DNS:Edit)"
    "CERTBOT_TLS|CERTBOT_TLS_BULK|yn|--certbot-tls|certbot|TLS-заготовки в /etc/letsencrypt|TLS boilerplate in /etc/letsencrypt"
    "UFW|UFW_BULK|yn|--ufw|ufw|включить UFW|enable UFW"
    "UFW_ALLOW|UFW_ALLOW_BULK|ports|--allow|ufw|открыть порты: 443,51820/udp,1000:2000/tcp|open ports: 443,51820/udp,1000:2000/tcp"
    "UFW_FROM|UFW_FROM_BULK|addr|--from|ufw|открывать их только для этого IP/подсети|open them only to this IP/subnet"
    "UFW_PING|UFW_PING_BULK|yn|--ping|ufw|отвечать на ping (--no-ping — не отвечать)|reply to ping (--no-ping — do not)"
    "UFW_DOCKER|UFW_DOCKER_BULK|yn|--docker-firewall|ufw|подчинить порты Docker-контейнеров UFW|put Docker container ports behind UFW"
)

# _answer_row <поле> <значение> — найти строку таблицы → REPLY_ANS_ROW
# (поля в REPLY_ANS_KEY, _VAR, _TYPE, _FLAG, _ITEM)
REPLY_ANS_KEY=''; REPLY_ANS_VAR=''; REPLY_ANS_TYPE=''; REPLY_ANS_FLAG=''; REPLY_ANS_ITEM=''
_answer_row() {
    local field="$1" want="$2" row k v ty fl it
    for row in "${USFC_ANSWER_KEYS[@]}"; do
        IFS='|' read -r k v ty fl it _ <<< "$row"
        case "$field" in
            key)  [ "$k" = "$want" ] || continue ;;
            flag) [ -n "$fl" ] && [ "$fl" = "$want" ] || continue ;;
        esac
        REPLY_ANS_KEY="$k"; REPLY_ANS_VAR="$v"; REPLY_ANS_TYPE="$ty"; REPLY_ANS_FLAG="$fl"; REPLY_ANS_ITEM="$it"
        return 0
    done
    return 1
}

# answer_normalize <тип> <значение> → REPLY_ANS. 1 — значение не подходит.
# «y», «yes», «да» раньше молча значили «не Y», то есть «нет»
REPLY_ANS=''
answer_normalize() {
    local ty="$1" v="$2"
    REPLY_ANS=''
    case "$ty" in
        yn)
            case "${v,,}" in
                y|yes|true|on|1|да|д) REPLY_ANS=Y ;;     # i18n-ok: принимаемые ответы, не текст
                n|no|false|off|0|нет|н) REPLY_ANS=N ;;  # i18n-ok: принимаемые ответы, не текст
                *) return 1 ;;
            esac ;;
        int) [[ "$v" =~ ^[0-9]+$ ]] || return 1; REPLY_ANS="$v" ;;
        pct) [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 400 ] || return 1; REPLY_ANS="$v" ;;
        ports) fw_parse_ports "$v" && [ -n "$REPLY_FW_PORTS" ] || return 1; REPLY_ANS="$REPLY_FW_PORTS" ;;
        addr)  fw_valid_from "$v" || return 1; REPLY_ANS="$v" ;;
        *)   [ -n "$v" ] || return 1; REPLY_ANS="$v" ;;
    esac
}

# answer_set <КЛЮЧ> <значение> <откуда> — проверить и записать. Откуда
# пришло, запоминаем: флаг для невыбранного пункта — ошибка, а тот же ключ
# в общем на все ноды файле ответов — норма
declare -A USFC_ANS_SRC=()
answer_set() {
    local key="$1" val="$2" src="$3"
    _answer_row key "$key" || return 2
    if ! answer_normalize "$REPLY_ANS_TYPE" "$val"; then
        case "$REPLY_ANS_TYPE" in
            yn)  t "${key}: ожидается Y или N, а не «${val}»" "${key}: expected Y or N, not \"${val}\"" ;;
            int) t "${key}: ожидается целое число, а не «${val}»" "${key}: expected a whole number, not \"${val}\"" ;;
            pct) t "${key}: ожидается процент 1..400, а не «${val}»" "${key}: expected a percentage 1..400, not \"${val}\"" ;;
            ports) if [ -n "$REPLY_FW_ERR" ]; then REPLY_T="${key}: ${REPLY_FW_ERR}"
                   else t "${key}: пустой список портов" "${key}: empty port list"; fi ;;
            addr) t "${key}: ожидается IP или подсеть (1.2.3.4, 10.0.0.0/8), а не «${val}»" "${key}: expected an IP or a subnet (1.2.3.4, 10.0.0.0/8), not \"${val}\"" ;;
            *)   t "${key}: пустое значение" "${key}: empty value" ;;
        esac
        log_error "$REPLY_T"
        return 1
    fi
    printf -v "$REPLY_ANS_VAR" '%s' "$REPLY_ANS"
    USFC_ANS_SRC[$key]="$src"
}

# Файл ответов. Формат — KEY=значение, без исполнения: конфиг не должен
# уметь запускать команды, иначе `--config` из непроверенного места
# превращается в дыру. Поэтому разбираем построчно, а не source.
#
# Неизвестный ключ — ОШИБКА, а не предупреждение: опечатка `UWF=Y` иначе
# молча оставляла бы сервер без файрвола
load_config() {
    local file="$1" line key val n=0 bad=0
    if [ ! -r "$file" ]; then
        log_error_t "Файл ответов не читается: ${file}" \
"Cannot read the answers file: ${file}"
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        if [[ "$line" != *=* ]]; then
            log_error_t "${file}:${n}: нет «=» — ожидается КЛЮЧ=значение" \
"${file}:${n}: no \"=\" — expected KEY=value"
            bad=1; continue
        fi
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        val="${line#*=}"
        val="${val#"${val%%[![:space:]]*}"}"
        case "$val" in \"*\") val="${val#\"}"; val="${val%\"}" ;; \'*\') val="${val#\'}"; val="${val%\'}" ;; esac
        if [ "$key" = ITEMS ]; then
            # командная строка сильнее файла: ITEMS — только если пункты не заданы
            [ -n "$USFC_APPLY_SPEC" ] || USFC_APPLY_SPEC="$val"
            continue
        fi
        answer_set "$key" "$val" config
        case $? in
            0) ;;
            2) log_error_t "${file}:${n}: неизвестный ключ ${key}" \
"${file}:${n}: unknown key ${key}"
               bad=1 ;;
            *) bad=1 ;;
        esac
    done < "$file"
    return "$bad"
}

# fetch_config <https://…> → REPLY_CONFIG_PATH (временный файл).
# Только https: файл ответов может нести токен, и отдавать его по
# открытому каналу нельзя. Сам URL в лог не пишем — в нём бывает секрет
REPLY_CONFIG_PATH=''
fetch_config() {
    local url="$1" tmp
    tmp="$(mktemp)" || return 1
    chmod 600 "$tmp"
    if ! curl -fsSL --proto '=https' --max-time 20 --retry 2 "$url" -o "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        log_error_t "Не удалось скачать файл ответов (нужен https и доступный адрес)" \
"Could not download the answers file (it must be https and reachable)"
        return 1
    fi
    REPLY_CONFIG_PATH="$tmp"
}

# Имя профиля не должно совпадать с id пункта. Совпадение было: профиль
# «docker» перебивал одноимённый пункт, и `usfc apply docker` разворачивался
# в восемь пунктов вместо одного — молча и совсем не туда. Проверяем здесь,
# чтобы следующий профиль не наступил на те же грабли.
usfc_check_profile_names() {
    local name id bad=0
    for name in "${!USFC_PROFILES[@]}"; do
        for id in "${ITEM_IDS[@]}"; do
            if [ "$name" = "$id" ]; then
                echo "usfc: имя профиля '${name}' совпадает с id пункта" >&2   # i18n-ok: проверка для CI
                bad=1
            fi
        done
    done
    return "$bad"
}

# filter_pending <номера...> — что из них реально надо применять.
# Раскладывает по трём массивам: REPLY_PENDING, REPLY_ALREADY, REPLY_SKIPPED.
#
# Вынесено из run_noninteractive, потому что тот же отсев нужен мастеру первого
# запуска. Второй экземпляр этой логики означал бы, что мастер однажды начнёт
# выключать уже применённое — ровно тот баг, который чинили в 4.0.0.
REPLY_PENDING=()
REPLY_ALREADY=()
REPLY_SKIPPED=()
filter_pending() {
    REPLY_PENDING=(); REPLY_ALREADY=(); REPLY_SKIPPED=()
    local n id
    for n in "$@"; do
        id="${ITEM_IDS[$((n - 1))]}"
        # SSH hardening умеет закрыть доступ к серверу и потому всегда требует
        # явного подтверждения. Молча пропускать его тоже нельзя — скажем прямо
        if [ "$id" = "sshhardening" ]; then
            REPLY_SKIPPED+=("$id")
            continue
        fi
        # Уже применённое пропускаем. Это не оптимизация, а вопрос смысла:
        # в меню повторный выбор ⇄-пункта означает «переключить», и без этой
        # проверки автоматический прогон ВЫКЛЮЧАЛ бы то, что просили включить
        # Исключение — ufw с явными портами, ping или Docker (fw_has_answers)
        if item_applied "$id" && ! { [ "$id" = ufw ] && fw_has_answers; }; then
            REPLY_ALREADY+=("$id")
            continue
        fi
        REPLY_PENDING+=("$n")
    done
}
