# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# usfc export — файл ответов по текущему серверу
# ═══════════════════════════════════════════════════════════════
# Настроил одну ноду руками через меню — получил файл, которым следующая
# настраивается одной командой. Ответы читаются из СОСТОЯНИЯ системы, а не из
# истории запусков: истории у usfc нет, а состояние правдиво и после ручных
# правок.
#
# Секреты не выгружаются никогда: CF_TOKEN остаётся закомментированным
# ключом без значения. Имя хоста у каждой ноды своё — тоже комментарий.
# Только чтение: export, как и аудит, ничего не меняет.

# export_answer <КЛЮЧ> — значение ключа по текущему состоянию → REPLY_EXPORT.
# Код 1 — по системе ответ не определить, ключ не выгружается
REPLY_EXPORT=''
export_answer() {
    local f v
    REPLY_EXPORT=''
    case "$1" in
        SWAP_MB)
            [ -f /swapfile ] || return 1
            v="$(stat -c %s /swapfile 2>/dev/null)" || return 1
            REPLY_EXPORT="$((v / 1024 / 1024))" ;;
        ZRAM_PERCENT)
            f=/etc/default/zramswap
            [ -f "$f" ] || return 1
            v="$(sed -n 's/^[[:space:]]*PERCENT=["'\'']\{0,1\}\([0-9]\{1,\}\).*/\1/p' "$f" | tail -n 1)"
            [ -n "$v" ] || return 1
            REPLY_EXPORT="$v" ;;
        SYSCTL)
            [ -f /etc/sysctl.d/99-zram.conf ] && REPLY_EXPORT=Y || REPLY_EXPORT=N ;;
        NGINX_AUTOSTART|DOCKER_AUTOSTART)
            v=nginx; [ "$1" = DOCKER_AUTOSTART ] && v=docker
            command -v "$v" >/dev/null 2>&1 || return 1
            systemctl is-enabled "$v" >/dev/null 2>&1 && REPLY_EXPORT=Y || REPLY_EXPORT=N ;;
        CERTBOT_CF)
            pkg_installed certbot || return 1
            pkg_installed python3-certbot-dns-cloudflare && REPLY_EXPORT=Y || REPLY_EXPORT=N ;;
        CERTBOT_TLS)
            pkg_installed certbot || return 1
            [ -f /etc/letsencrypt/options-ssl-nginx.conf ] && REPLY_EXPORT=Y || REPLY_EXPORT=N ;;
        UFW)
            ufw_active || return 1
            REPLY_EXPORT=Y ;;
        UFW_ALLOW)
            ufw_active || return 1
            export_ufw_ports
            [ -n "$REPLY_EXPORT" ] || return 1 ;;
        UFW_PING)
            ufw_active || return 1
            fw_ping_state
            case "$REPLY_FW_PING" in on) REPLY_EXPORT=Y ;; off) REPLY_EXPORT=N ;; *) return 1 ;; esac ;;
        UFW_DOCKER)
            ufw_active && command -v docker >/dev/null 2>&1 || return 1
            fw_docker_on && REPLY_EXPORT=Y || REPLY_EXPORT=N ;;
        TIMEZONE)
            v="$(timedatectl show -p Timezone --value 2>/dev/null)"
            [ -n "$v" ] || v="$(cat /etc/timezone 2>/dev/null)"
            valid_timezone "$v" || return 1
            REPLY_EXPORT="$v" ;;
        JOURNAL_MAX_MB)
            f=/etc/systemd/journald.conf.d/usfc.conf
            [ -f "$f" ] || return 1
            v="$(sed -n 's/^[[:space:]]*SystemMaxUse=\([0-9]\{1,\}\)M.*/\1/p' "$f" | tail -n 1)"
            [ -n "$v" ] || return 1
            REPLY_EXPORT="$v" ;;
        MOTD_CLEAN)
            # список выключенного пишет только «да» на этот вопрос
            [ -f /etc/update-motd.d/01-usfc ] || return 1
            [ -f /etc/usfc/motd-disabled ] && REPLY_EXPORT=Y || REPLY_EXPORT=N ;;
        STARSHIP_PRESET|STARSHIP_PROD)
            # маркер первой строки нашего starship.toml: preset=… prod=…
            v="$(grep -m1 '^# usfc:starship ' "${TARGET_HOME}/.config/starship.toml" 2>/dev/null)" || return 1
            if [ "$1" = STARSHIP_PRESET ]; then
                [[ "$v" =~ preset=([a-z]+) ]] || return 1
            else
                [[ "$v" =~ prod=([YN]) ]] || return 1
            fi
            REPLY_EXPORT="${BASH_REMATCH[1]}" ;;
        LAZYDOCKER)
            command -v docker >/dev/null 2>&1 || return 1
            command -v lazydocker >/dev/null 2>&1 && REPLY_EXPORT=Y || REPLY_EXPORT=N ;;
        *) return 1 ;;
    esac
    return 0
}

# export_ufw_ports → REPLY_EXPORT: «443/tcp 51820/udp» — разрешения «отовсюду»
# без SSH (его apply разрешает сам). Правила для отдельных адресов в общий
# список не годятся: UFW_FROM у файла один на все порты — их печатаем
# комментарием, чтобы не потерялись молча
REPLY_EXPORT_FROM=''
export_ufw_ports() {
    local line p act from list='' addrs=''
    REPLY_EXPORT=''; REPLY_EXPORT_FROM=''
    while read -r line; do
        [[ "$line" == *"(v6)"* ]] && continue
        read -r p act from _ <<< "$line"
        [ "$act" = ALLOW ] || continue
        [[ "$p" =~ ^[0-9]+(:[0-9]+)?(/(tcp|udp))?$ ]] || continue
        [[ "$p" == */* ]] || p="${p}/tcp"
        [ "$p" = "${SSH_PORT}/tcp" ] && continue
        if [ "$from" = Anywhere ]; then
            [[ " $list " == *" $p "* ]] || list="${list}${list:+ }${p}"
        else
            addrs="${addrs}${addrs:+, }${p} ← ${from}"
        fi
    done < <(ufw status 2>/dev/null)
    REPLY_EXPORT="$list"
    REPLY_EXPORT_FROM="$addrs"
}

# Значение для файла: с пробелами — в кавычках (load_config их снимает)
_export_quote() {
    case "$1" in *[[:space:]]*) printf '"%s"' "$1" ;; *) printf '%s' "$1" ;; esac
}

export_cmd() {
    refresh_statuses
    local id items='' row k ty fl it ru en cmd='' line
    for id in "${ITEM_IDS[@]}"; do
        item_applied "$id" && items="${items}${items:+,}${id}"
    done

    local host
    host="$(hostname 2>/dev/null)"
    t "# usfc export — ответы по серверу ${host}, $(date '+%Y-%m-%d'), usfc ${VERSION}" \
"# usfc export — answers taken from server ${host}, $(date '+%Y-%m-%d'), usfc ${VERSION}"
    printf '%s\n' "$REPLY_T"
    t "# Применить на другом сервере: usfc apply --config <этот файл> --yes" \
"# Apply on another server: usfc apply --config <this file> --yes"
    printf '%s\n#\n' "$REPLY_T"
    if [ -n "$items" ]; then
        printf 'ITEMS=%s\n' "$items"
    else
        t "# ITEMS= — на этом сервере ещё ничего не применено" "# ITEMS= — nothing has been applied on this server yet"
        printf '%s\n' "$REPLY_T"
    fi

    for row in "${USFC_ANSWER_KEYS[@]}"; do
        IFS='|' read -r k _ ty fl it ru en <<< "$row"
        if [ "$USFC_LANG" = en ]; then line="$en"; else line="$ru"; fi
        case "$k" in
            CF_TOKEN)
                # секрет: ключ — да, значение — никогда
                printf '# %s=\t\t# %s\n' "$k" "$line"; continue ;;
            HOSTNAME)
                t "у каждой ноды своё" "each node has its own"
                printf '# %s=%s\t# %s\n' "$k" "$(hostname 2>/dev/null)" "$REPLY_T"; continue ;;
        esac
        # ответ к пункту, которого нет в ITEMS, не нужен, а флаг без своего
        # пункта apply отвергает (exit 2) — однострочная команда бы упала
        [[ ",${items}," == *",${it},"* ]] || continue
        export_answer "$k" || continue
        printf '%s=%s\n' "$k" "$(_export_quote "$REPLY_EXPORT")"
        # та же настройка флагом — для однострочной команды
        [ -n "$fl" ] || continue
        case "$ty" in
            yn) if [ "$REPLY_EXPORT" = Y ]; then cmd="${cmd} ${fl}"; else cmd="${cmd} --no-${fl#--}"; fi ;;
            ports) cmd="${cmd} ${fl} ${REPLY_EXPORT// /,}" ;;
            *) cmd="${cmd} ${fl} ${REPLY_EXPORT}" ;;
        esac
    done
    if [ -n "$REPLY_EXPORT_FROM" ]; then
        t "# Разрешения для отдельных адресов (в файл ответов не входят): ${REPLY_EXPORT_FROM}" \
"# Rules for specific addresses (not part of the answers file): ${REPLY_EXPORT_FROM}"
        printf '%s\n' "$REPLY_T"
    fi

    [ -n "$items" ] || return 0
    t "# То же одной командой на свежем сервере:" "# The same as one command on a fresh server:"
    printf '#\n%s\n' "$REPLY_T"
    printf '#   curl -fsSL %s/install.sh | sudo bash -s -- \\\n#     apply %s%s --yes\n' \
        "${REPO_RAW_BASE%/src}" "$items" "$cmd"
}
