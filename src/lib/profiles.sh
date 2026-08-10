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
    log_info "Готовые профили:"
    for name in minimal web dockerhost secure; do
        printf '    %b%-8s%b %s\n' "$BOLD" "$name" "$NC" "${USFC_PROFILES[$name]}"
    done
    echo ""
    log_info "Пункты можно перечислить и вручную: ${BOLD}--apply docker,nginx,ufw${NC}"
    log_info "Все id: ${DIM}${ITEM_IDS[*]}${NC}"
}

# resolve_items <спецификация> → REPLY_ITEM_NUMS (номера пунктов).
# Принимает: all, имя профиля, список id и/или номеров через запятую/пробел.
REPLY_ITEM_NUMS=()
resolve_items() {
    local spec="$1" tok num i
    local -a tokens=() expanded=()
    REPLY_ITEM_NUMS=()

    # Профили раскрываются ПОТОКЕННО, а не для всей строки целиком: иначе
    # `--apply web,ufw` разбирался бы как список id, и про валидный профиль
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
                log_error "Нет пункта с номером ${tok} (всего ${#ITEM_IDS[@]})"
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
            log_error "Неизвестный пункт или профиль: ${tok}"
            log_info "Доступные id: ${ITEM_IDS[*]}"
            log_info "Профили: ${!USFC_PROFILES[*]}"
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

    [ "${#REPLY_ITEM_NUMS[@]}" -gt 0 ] || { log_error "Пустой список пунктов"; return 1; }
    return 0
}

# Файл ответов. Формат — KEY=значение, без исполнения: конфиг не должен
# уметь запускать команды, иначе `--config` из непроверенного места
# превращается в дыру. Поэтому разбираем построчно, а не source.
load_config() {
    local file="$1" line key val
    if [ ! -r "$file" ]; then
        log_error "Конфиг не читается: ${file}"
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        key="${line%%=*}"
        val="${line#*=}"
        val="${val%\"}"; val="${val#\"}"
        case "$key" in
            ITEMS)             USFC_APPLY_SPEC="$val" ;;
            NGINX_AUTOSTART)   NGINX_AUTOSTART="$val" ;;
            DOCKER_AUTOSTART)  DOCKER_AUTOSTART="$val" ;;
            ZRAM_PERCENT)      ZRAM_BULK_PERCENT="$val" ;;
            SWAP_MB)           SWAP_BULK_MB="$val" ;;
            CERTBOT_CF)        CERTBOT_CF_BULK="$val" ;;
            CF_TOKEN)          CF_TOKEN_BULK="$val" ;;
            *)
                log_warn "Непонятный ключ в ${file}: ${key}"
                ;;
        esac
    done < "$file"
    return 0
}

# Имя профиля не должно совпадать с id пункта. Совпадение было: профиль
# «docker» перебивал одноимённый пункт, и `--apply docker` разворачивался
# в восемь пунктов вместо одного — молча и совсем не туда. Проверяем здесь,
# чтобы следующий профиль не наступил на те же грабли.
usfc_check_profile_names() {
    local name id bad=0
    for name in "${!USFC_PROFILES[@]}"; do
        for id in "${ITEM_IDS[@]}"; do
            if [ "$name" = "$id" ]; then
                echo "usfc: имя профиля '${name}' совпадает с id пункта" >&2
                bad=1
            fi
        done
    done
    return "$bad"
}
