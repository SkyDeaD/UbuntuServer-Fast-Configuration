# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# Аудит: что с сервером прямо сейчас
# ═══════════════════════════════════════════════════════════════
# Инструмент умел настраивать, но никогда не отвечал на вопрос «как оно
# живёт». Аудит только ЧИТАЕТ: ни одной изменяющей команды здесь нет и быть
# не должно — это его главное свойство, на нём держится доверие к нему.
#
# Почти всё собирается из уже написанного: status_*, read_swap_state,
# разбор sshd -T, детект занятых портов из пункта UFW.

# Каждая проверка кладёт строку в отчёт с одним из трёх уровней.
AUDIT_OK=0
AUDIT_WARN=0
AUDIT_CRIT=0

_audit_line() {  # <уровень> <текст> [подсказка]
    local lvl="$1" text="$2" hint="${3:-}"
    case "$lvl" in
        ok)   printf '  %b✓%b %s\n' "$GREEN" "$NC" "$text";  AUDIT_OK=$((AUDIT_OK + 1)) ;;
        warn) printf '  %b!%b %s\n' "$YELLOW" "$NC" "$text"; AUDIT_WARN=$((AUDIT_WARN + 1)) ;;
        crit) printf '  %b✗%b %s\n' "$RED" "$NC" "$text";    AUDIT_CRIT=$((AUDIT_CRIT + 1)) ;;
    esac
    [ -n "$hint" ] && printf '      %b%s%b\n' "$DIM" "$hint" "$NC"
    return 0
}

_audit_section() { echo ""; echo -e "  ${BOLD}${1}${NC}"; }

# ── Место на диске и inode ────────────────────────────────────────────────────
audit_disk() {
    local use inodes
    use="$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
    inodes="$(df -Pi / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
    [[ "$use" =~ ^[0-9]+$ ]] || use=0
    [[ "$inodes" =~ ^[0-9]+$ ]] || inodes=0

    if   [ "$use" -ge 90 ]; then _audit_line crit "Диск / занят на ${use}%" "Кончится место — встанут и apt, и логи, и базы"
    elif [ "$use" -ge 75 ]; then _audit_line warn "Диск / занят на ${use}%" "Посмотреть, что съело: ncdu /"
    else                          _audit_line ok   "Диск / занят на ${use}%"
    fi

    # inode кончаются раньше места там, где много мелких файлов, и ошибка
    # при этом выглядит как «нет места» при свободных гигабайтах
    if   [ "$inodes" -ge 90 ]; then _audit_line crit "Inode на / израсходованы на ${inodes}%" "Место может быть, а файл не создастся"
    elif [ "$inodes" -ge 75 ]; then _audit_line warn "Inode на / израсходованы на ${inodes}%"
    else                             _audit_line ok   "Inode на / израсходованы на ${inodes}%"
    fi
}

# ── Память и своп ─────────────────────────────────────────────────────────────
audit_memory() {
    read_swap_state
    local ram_mb avail_mb
    ram_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    avail_mb="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    [[ "$ram_mb" =~ ^[0-9]+$ ]] || ram_mb=0
    [[ "$avail_mb" =~ ^[0-9]+$ ]] || avail_mb=0

    if [ "$ram_mb" -gt 0 ] && [ "$((avail_mb * 100 / ram_mb))" -lt 10 ]; then
        _audit_line warn "Свободно памяти: ${avail_mb} из ${ram_mb} МБ" "Меньше 10% — следующая нагрузка упрётся в OOM"
    else
        _audit_line ok "Свободно памяти: ${avail_mb} из ${ram_mb} МБ"
    fi

    if [ "$SWAP_ACTIVE" = true ] || [ "$ZRAM_ACTIVE" = true ]; then
        _audit_line ok "Подкачка есть${ZRAM_ACTIVE:+ (zram)}"
    else
        _audit_line warn "Подкачки нет совсем" "Пик нагрузки убьёт процесс вместо того, чтобы притормозить. Пункт $(item_number zram)"
    fi
}

# ── Упавшие юниты ─────────────────────────────────────────────────────────────
audit_units() {
    local failed n
    failed="$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
    n="$(printf '%s' "$failed" | grep -c . 2>/dev/null || echo 0)"
    if [ "$n" -eq 0 ]; then
        _audit_line ok "Упавших systemd-юнитов нет"
    else
        _audit_line crit "Упавших юнитов: ${n}" "$(printf '%s' "$failed" | tr '\n' ' ')"
        _audit_line warn "Подробности: systemctl --failed" ""
        AUDIT_WARN=$((AUDIT_WARN - 1))   # это подсказка, а не отдельная находка
    fi
}

# ── Порты наружу против правил файрвола ───────────────────────────────────────
audit_ports() {
    local listening ports p
    # только то, что слушает НЕ на localhost: 127.0.0.1 и ::1 наружу не смотрят
    listening="$(ss -ltnH 2>/dev/null | awk '{print $4}' \
        | grep -vE '^(127\.|\[::1\])' | sed 's/.*://' | sort -un)"
    ports="$(printf '%s' "$listening" | tr '\n' ' ')"
    if [ -z "${ports// /}" ]; then
        _audit_line ok "Наружу ничего не слушает"
        return 0
    fi

    if ! command -v ufw >/dev/null 2>&1 || ! ufw status 2>/dev/null | grep 'Status: active' >/dev/null; then
        _audit_line warn "Порты наружу: ${ports}" "Файрвол выключен — доступны все. Пункт $(item_number ufw)"
        return 0
    fi

    local rules unlisted=""
    rules="$(ufw status 2>/dev/null)"
    for p in $listening; do
        printf '%s' "$rules" | grep -E "(^|[^0-9])${p}(/|[^0-9]|$)" >/dev/null || unlisted="${unlisted}${p} "
    done
    if [ -z "$unlisted" ]; then
        _audit_line ok "Все открытые порты (${ports}) есть в правилах UFW"
    else
        # Не «дыра»: UFW их и так режет. Но расхождение стоит увидеть —
        # обычно это сервис, который подняли уже после настройки файрвола
        _audit_line warn "Слушают, но правил в UFW нет: ${unlisted}" "Снаружи закрыты. Если нужны — sudo ufw allow <порт>/tcp"
    fi
}

# ── SSH ───────────────────────────────────────────────────────────────────────
audit_ssh() {
    local out pa rl
    out="$(sshd -T 2>/dev/null)" || { _audit_line warn "Не удалось прочитать конфиг sshd"; return 0; }
    pa="$(printf '%s' "$out"  | awk '/^passwordauthentication /{print $2}')"
    rl="$(printf '%s' "$out"  | awk '/^permitrootlogin /{print $2}')"

    [ "$pa" = "no" ] \
        && _audit_line ok   "Вход по паролю выключен" \
        || _audit_line warn "Вход по паролю разрешён" "Перебор по SSH идёт круглосуточно. Пункт $(item_number sshhardening)"

    case "$rl" in
        no|prohibit-password|forced-commands-only)
            _audit_line ok "Root-логин: ${rl}" ;;
        *)
            _audit_line warn "Root-логин разрешён (${rl:-?})" "Пункт $(item_number sshhardening)" ;;
    esac

    if systemctl is-active fail2ban >/dev/null 2>&1; then
        _audit_line ok "fail2ban работает"
    else
        _audit_line warn "fail2ban не работает" "Пункт $(item_number fail2ban)"
    fi
}

# ── Обновления и перезагрузка ─────────────────────────────────────────────────
audit_updates() {
    local sec
    # apt-get -s: имитация, ничего не ставит — аудиту менять систему нельзя
    sec="$(apt-get -s upgrade 2>/dev/null | grep -ci '^Inst .*security' || true)"
    [[ "$sec" =~ ^[0-9]+$ ]] || sec=0
    if [ "$sec" -gt 0 ]; then
        _audit_line warn "Не установлено security-обновлений: ${sec}" "sudo apt update && sudo apt upgrade"
    else
        _audit_line ok "Security-обновления установлены"
    fi

    if systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then
        _audit_line ok "unattended-upgrades включён"
    else
        _audit_line warn "unattended-upgrades выключен" "Пункт $(item_number unattended)"
    fi

    if [ -f /var/run/reboot-required ]; then
        _audit_line warn "Нужна перезагрузка" "$(cat /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ' | cut -c1-70)"
    else
        _audit_line ok "Перезагрузка не требуется"
    fi
}

# ── Сертификаты ───────────────────────────────────────────────────────────────
audit_certs() {
    local live=/etc/letsencrypt/live d cert name days end
    [ -d "$live" ] || return 0
    for d in "$live"/*/; do
        [ -d "$d" ] || continue
        cert="${d}cert.pem"
        [ -f "$cert" ] || continue
        name="$(basename "$d")"
        end="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)"
        [ -n "$end" ] || continue
        days=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
        if   [ "$days" -lt 0 ];  then _audit_line crit "Сертификат ${name} просрочен"
        elif [ "$days" -lt 14 ]; then _audit_line crit "Сертификат ${name}: осталось ${days} дн." "Автопродление, похоже, не работает: systemctl status certbot.timer"
        elif [ "$days" -lt 30 ]; then _audit_line warn "Сертификат ${name}: осталось ${days} дн."
        else                          _audit_line ok   "Сертификат ${name}: осталось ${days} дн."
        fi
    done
}

show_audit() {
    refresh_term_width
    show_header
    echo -e "  ${BOLD}Аудит сервера${NC} ${DIM}— только чтение, ничего не меняется${NC}"
    AUDIT_OK=0; AUDIT_WARN=0; AUDIT_CRIT=0

    _audit_section "Ресурсы";     audit_disk; audit_memory
    _audit_section "Сервисы";     audit_units
    _audit_section "Сеть";        audit_ports
    _audit_section "Доступ";      audit_ssh
    _audit_section "Обновления";  audit_updates
    if [ -d /etc/letsencrypt/live ]; then
        _audit_section "Сертификаты"; audit_certs
    fi

    echo ""
    hr
    printf '  %bИтог:%b %b%d в норме%b   %b%d замечаний%b   %b%d важных%b\n' \
        "$BOLD" "$NC" "$GREEN" "$AUDIT_OK" "$NC" "$YELLOW" "$AUDIT_WARN" "$NC" "$RED" "$AUDIT_CRIT" "$NC"
    echo ""
    return 0
}
