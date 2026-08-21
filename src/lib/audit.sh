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

# Машинный вывод. Находки копятся в параллельных массивах, а печатаются одним
# куском в audit_emit_json: печатать по ходу нельзя — до последней проверки
# неизвестны итоговые счётчики, а они идут в шапке документа.
# Присваивание =() обязательно: без него set -u роняет первое же ${#x[@]}
USFC_AUDIT_JSON=false
AUDIT_J_ID=(); AUDIT_J_SECTION=(); AUDIT_J_LEVEL=()
AUDIT_J_TEXT=(); AUDIT_J_HINT=(); AUDIT_J_VALUE=(); AUDIT_J_UNIT=()
AUDIT_SECTION=""

# _audit_line <id> <уровень> <текст> [подсказка]
#
# Единственная воронка отчёта — поэтому машинный вывод врезается сюда, а не
# в каждую проверку. id идёт ЯВНЫМ аргументом, а не «липкой» переменной:
# забытую переменную следующая находка молча унаследовала бы, и потребитель
# JSON получил бы чужой ключ, ничего не заметив.
_audit_line() {
    local id="$1" lvl="$2" text="$3" hint="${4:-}"
    case "$lvl" in
        ok)   AUDIT_OK=$((AUDIT_OK + 1)) ;;
        warn) AUDIT_WARN=$((AUDIT_WARN + 1)) ;;
        crit) AUDIT_CRIT=$((AUDIT_CRIT + 1)) ;;
    esac
    if [ "$USFC_AUDIT_JSON" = true ]; then
        AUDIT_J_ID+=("$id");        AUDIT_J_SECTION+=("$AUDIT_SECTION")
        AUDIT_J_LEVEL+=("$lvl");    AUDIT_J_TEXT+=("$text")
        AUDIT_J_HINT+=("$hint");    AUDIT_J_VALUE+=("${REPLY_AUDIT_VALUE:-}")
        AUDIT_J_UNIT+=("${REPLY_AUDIT_UNIT:-}")
        REPLY_AUDIT_VALUE=''; REPLY_AUDIT_UNIT=''
        return 0
    fi
    REPLY_AUDIT_VALUE=''; REPLY_AUDIT_UNIT=''
    case "$lvl" in
        ok)   printf '  %b✓%b %s\n' "$GREEN" "$NC" "$text" ;;
        warn) printf '  %b!%b %s\n' "$YELLOW" "$NC" "$text" ;;
        crit) printf '  %b✗%b %s\n' "$RED" "$NC" "$text" ;;
    esac
    [ -n "$hint" ] && printf '      %b%s%b\n' "$DIM" "$hint" "$NC"
    return 0
}

# Числовое значение находки — необязательное. Ставится ПЕРЕД вызовом и
# потребляется первым же _audit_line, чтобы не протечь в следующую находку
REPLY_AUDIT_VALUE=''
REPLY_AUDIT_UNIT=''
audit_value() { REPLY_AUDIT_VALUE="$1"; REPLY_AUDIT_UNIT="$2"; }

# _audit_t <id> <уровень> <ru> <en> [подсказка-ru] [подсказка-en]
# Обёртка над _audit_line: аудит — самый «текстовый» экран, и без неё каждая
# строка обрастала бы четырьмя вызовами t()
_audit_t() {
    local id="$1" lvl="$2" ru="$3" en="$4" hru="${5:-}" hen="${6:-}"
    local text hint=""
    t "$ru" "$en"; text="$REPLY_T"
    if [ -n "$hru" ]; then t "$hru" "$hen"; hint="$REPLY_T"; fi
    _audit_line "$id" "$lvl" "$text" "$hint"
}

_audit_section() { echo ""; echo -e "  ${BOLD}${1}${NC}"; }
# _audit_section_t <машинный ключ> <ru> <en>. Ключ нужен машинному выводу:
# отображаемое имя там было бы бесполезно, оно меняется вместе с языком
_audit_section_t() {
    AUDIT_SECTION="$1"
    [ "$USFC_AUDIT_JSON" = true ] && return 0
    t "$2" "$3"; _audit_section "$REPLY_T"
}

# ── Место на диске и inode ────────────────────────────────────────────────────
audit_disk() {
    local use inodes
    use="$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
    inodes="$(df -Pi / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
    [[ "$use" =~ ^[0-9]+$ ]] || use=0
    [[ "$inodes" =~ ^[0-9]+$ ]] || inodes=0

    audit_value "$use" percent
    if   [ "$use" -ge 90 ]; then _audit_t disk.usage crit "Диск / занят на ${use}%" "Disk / is ${use}% full" "Кончится место — встанут и apt, и логи, и базы" "When it fills up, apt, logs and databases all stop"
    elif [ "$use" -ge 75 ]; then audit_value "$use" percent; _audit_t disk.usage warn "Диск / занят на ${use}%" "Disk / is ${use}% full" "Посмотреть, что съело: ncdu /" "See what ate it: ncdu /"
    else                          audit_value "$use" percent; _audit_t disk.usage ok "Диск / занят на ${use}%" "Disk / is ${use}% full"
    fi

    # inode кончаются раньше места там, где много мелких файлов, и ошибка
    # при этом выглядит как «нет места» при свободных гигабайтах
    audit_value "$inodes" percent
    if   [ "$inodes" -ge 90 ]; then _audit_t disk.inodes crit "Inode на / израсходованы на ${inodes}%" "Inodes on / are ${inodes}% used" "Место может быть, а файл не создастся" "There may be free space, yet no new file can be created"
    elif [ "$inodes" -ge 75 ]; then audit_value "$inodes" percent; _audit_t disk.inodes warn "Inode на / израсходованы на ${inodes}%" "Inodes on / are ${inodes}% used"
    else                             audit_value "$inodes" percent; _audit_t disk.inodes ok "Inode на / израсходованы на ${inodes}%" "Inodes on / are ${inodes}% used"
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
        audit_value "$avail_mb" mb
        _audit_t mem.available warn "Свободно памяти: ${avail_mb} из ${ram_mb} МБ" "Free memory: ${avail_mb} of ${ram_mb} MB" "Меньше 10% — следующая нагрузка упрётся в OOM" "Under 10% — the next spike will hit the OOM killer"
    else
        audit_value "$avail_mb" mb
        _audit_t mem.available ok "Свободно памяти: ${avail_mb} из ${ram_mb} МБ" "Free memory: ${avail_mb} of ${ram_mb} MB"
    fi

    if [ "$SWAP_ACTIVE" = true ] || [ "$ZRAM_ACTIVE" = true ]; then
        # НЕ ${ZRAM_ACTIVE:+ (zram)}: эта подстановка срабатывает на любую
        # непустую строку, а там лежит слово «false». Пометка (zram) стояла
        # всегда — в том числе на машине, где zram выключен или сломан
        local kind=""
        [ "$ZRAM_ACTIVE" = true ] && kind=" (zram)"
        _audit_t swap.present ok "Подкачка есть${kind}" "Swap is present${kind}"
    else
        _audit_t swap.present warn "Подкачки нет совсем" "No swap at all" "Пик нагрузки убьёт процесс вместо того, чтобы притормозить. Пункт $(item_number zram)" "A load spike kills a process instead of slowing down. Item $(item_number zram)"
    fi

    audit_zram
}

# ── zram: включён, но не работает ─────────────────────────────────────────────
# Отдельно от строки про подкачку, потому что одно другое маскирует: на машине
# с рабочим swap-файлом и падающим zram аудит бодро писал «подкачка есть»
# и молчал о том, что половина настройки не работает.
#
# Молчим на машинах, где zram не включали: сообщать «zram не настроен» — работа
# пункта меню, а не аудита. Аудит говорит только о том, что сломано.
audit_zram() {
    if [ "$ZRAM_ACTIVE" = true ]; then
        _audit_t zram.running ok "zram работает" "zram is running"
        audit_sysctl
        return 0
    fi
    systemctl is-enabled zramswap.service >/dev/null 2>&1 || return 0

    zram_module_state
    case "$REPLY_ZRAM_MOD" in
        container)
            _audit_t zram.running warn "zram включён, но не работает: машина в контейнере" \
                          "zram is enabled but not running: this machine is a container" \
                          "Ядро общее с хозяином, модуль туда не загрузить. Выключить: systemctl disable --now zramswap" \
                          "The kernel is shared with the host, the module cannot be loaded. Turn it off: systemctl disable --now zramswap" ;;
        stale)
            _audit_t zram.running warn "zram включён, но не работает: ядро обновлено без перезагрузки" \
                          "zram is enabled but not running: the kernel was upgraded without a reboot" \
                          "Каталога модулей для $(uname -r) больше нет — нужна перезагрузка" \
                          "The module directory for $(uname -r) is gone — a reboot is needed" ;;
        absent)
            _audit_t zram.running warn "zram включён, но не работает: модуля ядра нет" \
                          "zram is enabled but not running: the kernel module is missing" \
                          "Служба падает при каждой загрузке. Пункт $(item_number zram) доставит недостающий пакет" \
                          "The service fails on every boot. Item $(item_number zram) will pull in the missing package" ;;
        *)
            _audit_t zram.running warn "zram включён, но устройство не поднято" \
                          "zram is enabled but no device is up" \
                          "Причина в журнале: journalctl -u zramswap -n 20 --no-pager" \
                          "The reason is in the journal: journalctl -u zramswap -n 20 --no-pager" ;;
    esac
}

# Рекомендованные значения под zram. Спрашиваются пунктом и легко остаются
# неприменёнными: до 4.2.0 в пакетном прогоне вопрос вообще не показывался.
# В статус пункта это не входит осознанно — иначе у отказавшегося пункт
# навсегда застрял бы в «настроено частично». Проверяем только когда zram
# реально работает: без него совет про swappiness — шум.
audit_sysctl() {
    local sw vfs
    sw="$(cat "${USFC_PROC_VM}"/swappiness 2>/dev/null)"
    vfs="$(cat "${USFC_PROC_VM}"/vfs_cache_pressure 2>/dev/null)"
    [[ "$sw" =~ ^[0-9]+$ ]] && [[ "$vfs" =~ ^[0-9]+$ ]] || return 0
    if [ "$sw" = 80 ] && [ "$vfs" = 50 ]; then
        _audit_t vm.tunables ok "sysctl под zram: swappiness=${sw}, vfs_cache_pressure=${vfs}" \
                    "sysctl for zram: swappiness=${sw}, vfs_cache_pressure=${vfs}"
    else
        _audit_t vm.tunables warn "sysctl не под zram: swappiness=${sw}, vfs_cache_pressure=${vfs}" \
                      "sysctl not tuned for zram: swappiness=${sw}, vfs_cache_pressure=${vfs}" \
                      "Рекомендуется 80 и 50 — своп в памяти быстрый. Пункт $(item_number zram)" \
                      "80 and 50 are recommended — swap in RAM is fast. Item $(item_number zram)"
    fi
}

# ── Упавшие юниты ─────────────────────────────────────────────────────────────
audit_units() {
    local failed n=0
    failed="$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
    # НЕ через `grep -c . || echo 0`: на пустом вводе grep печатает 0 И выходит
    # с кодом 1, поэтому || дописывает второй ноль. Получается «0\n0», и
    # дальше [ -eq ] падает с «integer expected»
    [ -n "$failed" ] && n="$(printf '%s\n' "$failed" | wc -l | tr -d ' ')"
    if [ "$n" -eq 0 ]; then
        audit_value 0 count
        _audit_t units.failed ok "Упавших systemd-юнитов нет" "No failed systemd units"
    else
        audit_value "$n" count
        _audit_t units.failed crit "Упавших юнитов: ${n}" "Failed units: ${n}" "$(printf '%s' "$failed" | tr '\n' ' ')" "$(printf '%s' "$failed" | tr '\n' ' ')"
        # Раньше здесь печаталась вторая находка и тут же откручивался счётчик.
        # В машинном выводе это дало бы фантомную запись и расхождение
        # len(findings) с суммой счётчиков
        if [ "$USFC_AUDIT_JSON" != true ]; then
            t "Подробности: systemctl --failed" "Details: systemctl --failed"
            printf '      %b%s%b\n' "$DIM" "$REPLY_T" "$NC"
        fi
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
        _audit_t ports.public ok "Наружу ничего не слушает" "Nothing is listening on public interfaces"
        return 0
    fi

    if ! command -v ufw >/dev/null 2>&1 || ! ufw status 2>/dev/null | grep 'Status: active' >/dev/null; then
        _audit_t ports.public warn "Порты наружу: ${ports}" "Public ports: ${ports}" "Файрвол выключен — доступны все. Пункт $(item_number ufw)" "The firewall is off, so all of them are reachable. Item $(item_number ufw)"
        return 0
    fi

    local rules unlisted=""
    rules="$(ufw status 2>/dev/null)"
    for p in $listening; do
        printf '%s' "$rules" | grep -E "(^|[^0-9])${p}(/|[^0-9]|$)" >/dev/null || unlisted="${unlisted}${p} "
    done
    if [ -z "$unlisted" ]; then
        _audit_t ports.firewalled ok "Все открытые порты (${ports}) есть в правилах UFW" "Every open port (${ports}) has a UFW rule"
    else
        # Не «дыра»: UFW их и так режет. Но расхождение стоит увидеть —
        # обычно это сервис, который подняли уже после настройки файрвола
        _audit_t ports.firewalled warn "Слушают, но правил в UFW нет: ${unlisted}" "Listening without a UFW rule: ${unlisted}" "Снаружи закрыты. Если нужны — sudo ufw allow <порт>/tcp" "Blocked from outside. If you need them: sudo ufw allow <port>/tcp"
    fi
}

# ── SSH ───────────────────────────────────────────────────────────────────────
audit_ssh() {
    local out pa rl
    out="$(sshd -T 2>/dev/null)" || { _audit_t ssh.config warn "Не удалось прочитать конфиг sshd" "Could not read the sshd config"; return 0; }
    pa="$(printf '%s' "$out"  | awk '/^passwordauthentication /{print $2}')"
    rl="$(printf '%s' "$out"  | awk '/^permitrootlogin /{print $2}')"

    [ "$pa" = "no" ] \
        && _audit_t ssh.password_auth ok "Вход по паролю выключен" "Password login is disabled" \
        || _audit_t ssh.password_auth warn "Вход по паролю разрешён" "Password login is allowed" "Перебор по SSH идёт круглосуточно. Пункт $(item_number sshhardening)" "SSH brute-forcing runs around the clock. Item $(item_number sshhardening)"

    case "$rl" in
        no|prohibit-password|forced-commands-only)
            _audit_t ssh.root_login ok "Root-логин: ${rl}" "Root login: ${rl}" ;;
        *)
            _audit_t ssh.root_login warn "Root-логин разрешён (${rl:-?})" "Root login is allowed (${rl:-?})" "Пункт $(item_number sshhardening)" "Item $(item_number sshhardening)" ;;
    esac

    if systemctl is-active fail2ban >/dev/null 2>&1; then
        _audit_t ssh.fail2ban ok "fail2ban работает" "fail2ban is running"
    else
        _audit_t ssh.fail2ban warn "fail2ban не работает" "fail2ban is not running" "Пункт $(item_number fail2ban)" "Item $(item_number fail2ban)"
    fi
}

# ── Обновления и перезагрузка ─────────────────────────────────────────────────
audit_updates() {
    local sec
    # apt-get -s: имитация, ничего не ставит — аудиту менять систему нельзя
    sec="$(apt-get -s upgrade 2>/dev/null | grep -ci '^Inst .*security' || true)"
    [[ "$sec" =~ ^[0-9]+$ ]] || sec=0
    if [ "$sec" -gt 0 ]; then
        _audit_t updates.security warn "Не установлено security-обновлений: ${sec}" "Pending security updates: ${sec}" "sudo apt update && sudo apt upgrade" "sudo apt update && sudo apt upgrade"
    else
        _audit_t updates.security ok "Security-обновления установлены" "Security updates are up to date"
    fi

    if systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then
        _audit_t updates.unattended ok "unattended-upgrades включён" "unattended-upgrades is enabled"
    else
        _audit_t updates.unattended warn "unattended-upgrades выключен" "unattended-upgrades is disabled" "Пункт $(item_number unattended)" "Item $(item_number unattended)"
    fi

    if [ -f /var/run/reboot-required ]; then
        _audit_t updates.reboot_required warn "Нужна перезагрузка" "Reboot required" "$(cat /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ' | cut -c1-70)" "$(cat /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ' | cut -c1-70)"
    else
        _audit_t updates.reboot_required ok "Перезагрузка не требуется" "No reboot required"
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
        if   [ "$days" -lt 0 ];  then _audit_t cert.expiry crit "Сертификат ${name} просрочен" "Certificate ${name} has expired"
        elif [ "$days" -lt 14 ]; then _audit_t cert.expiry crit "Сертификат ${name}: осталось ${days} дн." "Certificate ${name}: ${days} days left" "Автопродление, похоже, не работает: systemctl status certbot.timer" "Auto-renewal looks broken: systemctl status certbot.timer"
        elif [ "$days" -lt 30 ]; then _audit_t cert.expiry warn "Сертификат ${name}: осталось ${days} дн." "Certificate ${name}: ${days} days left"
        else                          _audit_t cert.expiry ok "Сертификат ${name}: осталось ${days} дн." "Certificate ${name}: ${days} days left"
        fi
    done
}

# Список проверок — в одном месте. Человеческий экран и машинный вывод зовут
# его оба: заведи два экземпляра, и они разъедутся на первой же новой проверке.
run_audit_checks() {
    AUDIT_OK=0; AUDIT_WARN=0; AUDIT_CRIT=0
    AUDIT_J_ID=(); AUDIT_J_SECTION=(); AUDIT_J_LEVEL=()
    AUDIT_J_TEXT=(); AUDIT_J_HINT=(); AUDIT_J_VALUE=(); AUDIT_J_UNIT=()

    _audit_section_t resources "Ресурсы" "Resources";        audit_disk; audit_memory
    _audit_section_t services  "Сервисы" "Services";         audit_units
    _audit_section_t network   "Сеть" "Network";             audit_ports
    _audit_section_t access    "Доступ" "Access";            audit_ssh
    _audit_section_t updates   "Обновления" "Updates";       audit_updates
    if [ -d /etc/letsencrypt/live ]; then
        _audit_section_t certs "Сертификаты" "Certificates"; audit_certs
    fi
}

show_audit() {
    refresh_term_width
    show_header
    t "Аудит сервера" "Server audit"; local _title="$REPLY_T"
    t "— только чтение, ничего не меняется" "— read-only, nothing is changed"
    echo -e "  ${BOLD}${_title}${NC} ${DIM}${REPLY_T}${NC}"
    run_audit_checks

    echo ""
    hr
    # «3 замечаний» и «1 важных» — согласование по-русски требует трёх форм.
    # Двоеточие обходит проблему и читается не хуже
    t "Итог:" "Summary:";      local _sum="$REPLY_T"
    t "в норме"  "healthy";    local _ok="$REPLY_T"
    t "замечаний" "warnings";  local _wn="$REPLY_T"
    t "важных"   "critical";   local _cr="$REPLY_T"
    printf '  %b%s%b  %s: %b%d%b   %s: %b%d%b   %s: %b%d%b\n' \
        "$BOLD" "$_sum" "$NC" "$_ok" "$GREEN" "$AUDIT_OK" "$NC" "$_wn" "$YELLOW" "$AUDIT_WARN" "$NC" "$_cr" "$RED" "$AUDIT_CRIT" "$NC"
    echo ""
    return 0
}

# ── Машинный вывод ────────────────────────────────────────────────────────────
# jq здесь нельзя: --audit обязан работать на свежем сервере, ДО того как
# поставили базовые пакеты. Поэтому экранируем сами.
#
# strip_ansi берём готовый из lib/layout.sh — он снимает оба вида цветовых
# кодов, и настоящий \x1b[, и буквальный текст \033[, который попадает в строки
# из переменных вроде $BOLD. Цветам в JSON делать нечего.
REPLY_JSON=''
_json_esc() {
    strip_ansi "${1-}"
    local s="$REPLY_PLAIN"
    # Обратный слэш ПЕРВЫМ: иначе следующие замены экранировали бы уже
    # собственный вывод и получилось бы \\" вместо \"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    REPLY_JSON="$s"
}

# audit_emit_json — весь отчёт одним документом в stdout.
#
# text и hint остаются на языке интерфейса: машиночитаем здесь id, а текст
# читает человек, открывший файл. Поэтому набор (id, level) обязан совпадать
# на обоих языках — это проверяется тестом.
audit_emit_json() {
    USFC_AUDIT_JSON=true
    run_audit_checks
    local i n="${#AUDIT_J_ID[@]}" total=$((AUDIT_OK + AUDIT_WARN + AUDIT_CRIT))

    printf '{\n'
    _json_esc "${VERSION:-}";        printf '  "usfc": "%s",\n'    "$REPLY_JSON"
    _json_esc "$(date -Is 2>/dev/null)"; printf '  "generated_at": "%s",\n' "$REPLY_JSON"
    _json_esc "$(hostname 2>/dev/null)"; printf '  "host": "%s",\n' "$REPLY_JSON"
    _json_esc "${OS_PRETTY:-}";      printf '  "os": "%s",\n'      "$REPLY_JSON"
    _json_esc "${USFC_LANG:-ru}";    printf '  "lang": "%s",\n'    "$REPLY_JSON"
    printf '  "summary": { "ok": %d, "warn": %d, "crit": %d, "total": %d },\n' \
        "$AUDIT_OK" "$AUDIT_WARN" "$AUDIT_CRIT" "$total"
    printf '  "findings": [\n'
    for ((i = 0; i < n; i++)); do
        printf '    {'
        _json_esc "${AUDIT_J_ID[$i]}";      printf '"id": "%s", '      "$REPLY_JSON"
        _json_esc "${AUDIT_J_SECTION[$i]}"; printf '"section": "%s", ' "$REPLY_JSON"
        _json_esc "${AUDIT_J_LEVEL[$i]}";   printf '"level": "%s", '   "$REPLY_JSON"
        _json_esc "${AUDIT_J_TEXT[$i]}";    printf '"text": "%s"'      "$REPLY_JSON"
        if [ -n "${AUDIT_J_HINT[$i]}" ]; then
            _json_esc "${AUDIT_J_HINT[$i]}"; printf ', "hint": "%s"' "$REPLY_JSON"
        fi
        # value и unit — только когда число действительно есть. Потребитель
        # проверяет наличие ключа, а не сравнивает с выдуманным -1
        if [ -n "${AUDIT_J_VALUE[$i]}" ]; then
            printf ', "value": %s' "${AUDIT_J_VALUE[$i]}"
            _json_esc "${AUDIT_J_UNIT[$i]}"; printf ', "unit": "%s"' "$REPLY_JSON"
        fi
        if [ "$i" -lt "$((n - 1))" ]; then printf '},\n'; else printf '}\n'; fi
    done
    printf '  ]\n}\n'
}
