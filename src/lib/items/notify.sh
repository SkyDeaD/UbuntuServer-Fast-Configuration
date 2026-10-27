# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: уведомления в Telegram ──────────────────────────────────────
usfc_item notify защита "Уведомления в Telegram" \
    "вход по SSH, баны fail2ban, нужна перезагрузка" \
    "Telegram alerts" \
    "SSH logins, fail2ban bans, reboot required"
usfc_item_toggle notify
usfc_item_reconf notify

usfc_item_full notify "Шлёт в Telegram три вида сообщений (набор выбирается):
  ssh    — вход по SSH: пользователь, откуда, когда (pam_exec в /etc/pam.d/sshd);
  ban    — бан от fail2ban (отдельный action в /etc/fail2ban/action.d);
  reboot — нужна перезагрузка после обновлений (systemd-таймер раз в сутки,
           сообщение один раз на набор пакетов).

Нужен бот: @BotFather → /newbot → токен. chat_id usfc умеет найти сам: напиши
боту любое сообщение, и он возьмёт последний чат из getUpdates.

Токен лежит только в /etc/usfc/notify.conf (права 600, root) и нигде больше:
не в логе usfc, не в аргументах команд (curl читает адрес с токеном из
stdin, ps его не видит), не в usfc export. Копия для отката лежит в каталоге
снимков с правами 700. Отправляет скрипт /usr/local/sbin/usfc-notify — он
самодостаточный и работает без usfc; вход по SSH он не задерживает (отправка
уходит в фон), а правка PAM — только optional, сбой скрипта вход не ломает.
Повторный выбор пункта — перенастройка: токен можно оставить прежним." \
"Sends three kinds of Telegram messages (you pick the set):
  ssh    — an SSH login: user, source, time (pam_exec in /etc/pam.d/sshd);
  ban    — a fail2ban ban (a dedicated action in /etc/fail2ban/action.d);
  reboot — a reboot is needed after updates (a daily systemd timer, one
           message per set of packages).

You need a bot: @BotFather → /newbot → a token. usfc can find the chat_id
itself: send the bot any message and it takes the latest chat from getUpdates.

The token lives only in /etc/usfc/notify.conf (mode 600, root) and nowhere
else: not in the usfc log, not in command arguments (curl reads the URL with
the token from stdin, so ps cannot see it), not in usfc export. The rollback
copy sits in the snapshot directory, mode 700. Messages are sent by
/usr/local/sbin/usfc-notify — self-contained, works without usfc. It never
delays an SSH login (sending goes to the background), and the PAM line is
optional only, so a failing script cannot break logins.
Choosing the item again reconfigures it: the token may stay as it is."

usfc_item_rollback notify "sudo sed -i '/usfc-notify/d' /etc/pam.d/sshd
     sudo rm -f /etc/fail2ban/action.d/usfc-telegram.conf /etc/fail2ban/jail.d/usfc-notify.local
     sudo systemctl disable --now usfc-notify-reboot.timer
     sudo rm -f /etc/systemd/system/usfc-notify-reboot.{timer,service}
     sudo systemctl daemon-reload; sudo systemctl restart fail2ban
     sudo rm -f /usr/local/sbin/usfc-notify /usr/local/sbin/usfc-notify-ssh /usr/local/sbin/usfc-notify-reboot
     sudo rm -f /etc/usfc/notify.conf   # здесь токен бота" \
"sudo sed -i '/usfc-notify/d' /etc/pam.d/sshd
     sudo rm -f /etc/fail2ban/action.d/usfc-telegram.conf /etc/fail2ban/jail.d/usfc-notify.local
     sudo systemctl disable --now usfc-notify-reboot.timer
     sudo rm -f /etc/systemd/system/usfc-notify-reboot.{timer,service}
     sudo systemctl daemon-reload; sudo systemctl restart fail2ban
     sudo rm -f /usr/local/sbin/usfc-notify /usr/local/sbin/usfc-notify-ssh /usr/local/sbin/usfc-notify-reboot
     sudo rm -f /etc/usfc/notify.conf   # the bot token is in here"

NOTIFY_CONF=/etc/usfc/notify.conf
NOTIFY_BIN=/usr/local/sbin/usfc-notify
NOTIFY_SSH_BIN=/usr/local/sbin/usfc-notify-ssh
NOTIFY_REBOOT_BIN=/usr/local/sbin/usfc-notify-reboot
NOTIFY_PAM=/etc/pam.d/sshd
NOTIFY_PAM_MARK='# usfc-notify (ssh login alert)'
NOTIFY_ACTION=/etc/fail2ban/action.d/usfc-telegram.conf
NOTIFY_JAIL=/etc/fail2ban/jail.d/usfc-notify.local
NOTIFY_UNIT_DIR=/etc/systemd/system
NOTIFY_TIMER_NAME=usfc-notify-reboot.timer
NOTIFY_SERVICE_NAME=usfc-notify-reboot.service
NOTIFY_ALL_EVENTS="ssh,ban,reboot"

# ── Чтение конфига ──────────────────────────────────────────────────────────
# Парсим построчно, а не через source: конфиг — данные, не код.
# → REPLY_NF_CHAT, REPLY_NF_EVENTS, REPLY_NF_HAS (1 — токен в файле есть);
#   REPLY_NF_TOKEN заполняется только при keep — иначе секрет зря не выносим
#   в переменную (status_ дёргается при каждой отрисовке меню)
REPLY_NF_TOKEN=''; REPLY_NF_CHAT=''; REPLY_NF_EVENTS=''; REPLY_NF_HAS=0
_notify_read_conf() {
    local nf_file="$1" nf_keep="${2:-}" nf_k nf_v
    REPLY_NF_TOKEN=''; REPLY_NF_CHAT=''; REPLY_NF_EVENTS=''; REPLY_NF_HAS=0
    [ -r "$nf_file" ] || return 1
    while IFS='=' read -r nf_k nf_v || [ -n "$nf_k" ]; do
        case "$nf_k" in
            TG_TOKEN) [ -n "$nf_v" ] && REPLY_NF_HAS=1
                      [ -n "$nf_keep" ] && REPLY_NF_TOKEN="$nf_v" ;;
            TG_CHAT)  REPLY_NF_CHAT="$nf_v" ;;
            EVENTS)   REPLY_NF_EVENTS="$nf_v" ;;
        esac
    done < "$nf_file"
    return 0
}

# ── Генераторы содержимого ──────────────────────────────────────────────────
# Все печатают текст в stdout и ничего не пишут на диск: тест вызывает их
# без root. Подписи запекаются в момент генерации (язык фиксируется при
# установке), чтобы сами скрипты были самодостаточными. Одинарных кавычек
# в запекаемых текстах нет.
_notify_bake() { printf "%s='%s'\n" "$1" "$REPLY_T"; }

# usfc-notify [--bg] "текст": отправка в Telegram.
# Токен уходит в curl через stdin (--config -): в argv его нет, ps не увидит.
# Без конфига выходим с 1 и сообщением: тихий «успех» скрыл бы, что
# уведомления не работают. Вызывающие (PAM-обёртка, fail2ban) к сбою
# отправки терпимы — ни один не должен из-за него ломаться.
# --bg: сразу вернуть управление, отправку увести в фон; сбой — в журнал
# (logger). Для fail2ban, чьё действие иначе ждало бы сеть до 10 с.
notify_send_script() {
    local nf_conf="${1:-$NOTIFY_CONF}"
    printf '%s\n' '#!/bin/bash'
    t "# Создано usfc (пункт «Уведомления в Telegram»). Не редактируйте: usfc перезапишет файл." \
"# Created by usfc (item \"Telegram alerts\"). Do not edit: usfc will overwrite it."
    printf '%s\n' "$REPLY_T"
    printf '%s\n' "# usage: usfc-notify [--bg] \"text\""
    printf "CONF='%s'\n" "$nf_conf"
    t "usfc-notify: нет конфига или в нём пусто:" "usfc-notify: no config or it is empty:"; _notify_bake L_NOCONF
    t "usfc-notify: не найден curl" "usfc-notify: curl not found"; _notify_bake L_NOCURL
    t "usfc-notify: Telegram ответил:" "usfc-notify: Telegram answered:"; _notify_bake L_FAIL
    cat <<'EOS'
bg=0
if [ "${1:-}" = --bg ]; then bg=1; shift; fi
if [ "$#" -lt 1 ]; then echo 'usage: usfc-notify [--bg] "text"' >&2; exit 2; fi
if [ "$bg" = 1 ]; then
    setsid bash -c 'out="$("$0" "$@" 2>&1)" || { command -v logger >/dev/null 2>&1 && logger -t usfc-notify -- "$out"; }' \
        "$0" "$@" </dev/null >/dev/null 2>&1 &
    exit 0
fi
TOKEN=''; CHAT=''
if [ -r "$CONF" ]; then
    while IFS='=' read -r k v || [ -n "$k" ]; do
        case "$k" in TG_TOKEN) TOKEN="$v" ;; TG_CHAT) CHAT="$v" ;; esac
    done < "$CONF"
fi
if [ -z "$TOKEN" ] || [ -z "$CHAT" ]; then echo "$L_NOCONF $CONF" >&2; exit 1; fi
if ! command -v curl >/dev/null 2>&1; then echo "$L_NOCURL" >&2; exit 1; fi
msg="[$(uname -n)] $1"
msg="${msg:0:4000}"
resp="$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TOKEN" \
    | curl -sS --connect-timeout 5 --max-time 10 --config - \
        --data-urlencode "chat_id=${CHAT}" --data-urlencode "text=${msg}" 2>&1)"
if [[ "$resp" == *'"ok":true'* ]]; then exit 0; fi
resp="${resp//"$TOKEN"/***}"
echo "$L_FAIL ${resp:0:300}" >&2
exit 1
EOS
}

# Обёртка для pam_exec: ВСЕГДА выходит 0 и сразу. Реагирует только на
# открытие сеанса; отправка уходит в фон, чтобы таймаут сети не держал вход.
notify_ssh_script() {
    local nf_bin="${1:-$NOTIFY_BIN}"
    printf '%s\n' '#!/bin/bash'
    t "# Создано usfc (пункт «Уведомления в Telegram»). Не редактируйте: usfc перезапишет файл." \
"# Created by usfc (item \"Telegram alerts\"). Do not edit: usfc will overwrite it."
    printf '%s\n' "$REPLY_T"
    printf "BIN='%s'\n" "$nf_bin"
    t "SSH: вход" "SSH login"; _notify_bake L_LOGIN
    t "локально" "local"; _notify_bake L_LOCAL
    cat <<'EOS'
[ "${PAM_TYPE:-}" = open_session ] || exit 0
[ -x "$BIN" ] || exit 0
user="${PAM_USER:-?}"
from="${PAM_RHOST:-}"
[ -n "$from" ] || from="$L_LOCAL"
"$BIN" --bg "${L_LOGIN}: ${user:0:60} <- ${from:0:100}, $(date '+%F %T %Z')" </dev/null >/dev/null 2>&1
exit 0
EOS
}

# Таймер-сервис: если нужна перезагрузка — сообщить один раз на набор пакетов.
# Метка — в /run (tmpfs), после перезагрузки сама пропадает.
notify_reboot_script() {
    local nf_bin="${1:-$NOTIFY_BIN}" nf_req="${2:-/var/run/reboot-required}" nf_state="${3:-/run/usfc-notify-reboot}"
    printf '%s\n' '#!/bin/bash'
    t "# Создано usfc (пункт «Уведомления в Telegram»). Не редактируйте: usfc перезапишет файл." \
"# Created by usfc (item \"Telegram alerts\"). Do not edit: usfc will overwrite it."
    printf '%s\n' "$REPLY_T"
    printf "BIN='%s'\nREQ='%s'\nSTATE='%s'\n" "$nf_bin" "$nf_req" "$nf_state"
    t "нужна перезагрузка" "reboot required"; _notify_bake L_REBOOT
    cat <<'EOS'
[ -e "$REQ" ] || exit 0
pk=''
if [ -r "${REQ}.pkgs" ]; then pk="$(sort -u "${REQ}.pkgs" | head -n 10 | tr '\n' ' ')"; fi
sig="$(printf '%s' "$pk" | cksum)"
[ "$(cat "$STATE" 2>/dev/null)" = "$sig" ] && exit 0
msg="$L_REBOOT"
[ -n "$pk" ] && msg="${msg}: ${pk}"
"$BIN" "$msg" || exit 1
printf '%s\n' "$sig" > "$STATE"
exit 0
EOS
}

# Действие fail2ban. Текст фиксируется языком на момент настройки.
# Через --bg: ожидание сети не должно тормозить остальные действия бана
notify_action_conf() {
    local nf_bin="${1:-$NOTIFY_BIN}"
    printf '%s\n' "# usfc: Telegram alert on ban. Used by jail.d/usfc-notify.local"
    printf '%s\n' "[Definition]"
    printf '%s\n' "actionstart ="
    printf '%s\n' "actionstop ="
    printf '%s\n' "actioncheck ="
    t "fail2ban: бан <ip> (<name>)" "fail2ban: ban <ip> (<name>)"
    printf 'actionban = %s --bg "%s"\n' "$nf_bin" "$REPLY_T"
    printf '%s\n' "actionunban ="
}

# Подключает действие к jail [sshd]. Ключ action заменяет, а не дополняет —
# поэтому перед записью проверяется чужой action (см. _notify_foreign_action)
notify_jail_conf() {
    printf '%s\n' "# usfc: Telegram alert on SSH bans. Remove via usfc (item Telegram alerts)"
    printf '%s\n' "[sshd]"
    printf '%s\n' "action = %(action_)s"
    printf '%s\n' "         usfc-telegram"
}

notify_timer_unit() {
    printf '%s\n' "[Unit]"
    printf '%s\n' "Description=usfc: daily check whether a reboot is required"
    printf '%s\n' ""
    printf '%s\n' "[Timer]"
    printf '%s\n' "OnCalendar=daily"
    printf '%s\n' "RandomizedDelaySec=1h"
    printf '%s\n' "Persistent=true"
    printf '%s\n' ""
    printf '%s\n' "[Install]"
    printf '%s\n' "WantedBy=timers.target"
}

notify_service_unit() {
    local nf_bin="${1:-$NOTIFY_REBOOT_BIN}"
    printf '%s\n' "[Unit]"
    printf '%s\n' "Description=usfc: send a Telegram alert if a reboot is required"
    printf '%s\n' ""
    printf '%s\n' "[Service]"
    printf '%s\n' "Type=oneshot"
    printf '%s\n' "ExecStart=${nf_bin}"
}

# ── Правка /etc/pam.d/sshd ──────────────────────────────────────────────────
notify_pam_line() { printf 'session optional pam_exec.so quiet %s' "${1:-$NOTIFY_SSH_BIN}"; }

# _notify_file_has_line <файл> <строка> — построчное сравнение целиком, без grep
_notify_file_has_line() {
    local nf_l
    [ -r "$1" ] || return 1
    while IFS= read -r nf_l || [ -n "$nf_l" ]; do
        [ "$nf_l" = "$2" ] && return 0
    done < "$1"
    return 1
}

# notify_pam_add <файл> [обёртка] — идемпотентно дописать маркер и строку.
# Только session optional: сбой обёртки (нет файла, ненулевой код) на вход
# не влияет — результат optional-модуля учитывается, лишь когда он в стеке один
notify_pam_add() {
    local nf_f="$1" nf_line
    nf_line="$(notify_pam_line "${2:-}")"
    _notify_file_has_line "$nf_f" "$NOTIFY_PAM_MARK" && return 0
    {
        # файл без завершающего перевода строки: иначе наша метка склеится с его последней строкой
        if [ -s "$nf_f" ] && [ -n "$(tail -c1 "$nf_f")" ]; then printf '\n'; fi
        printf '%s\n%s\n' "$NOTIFY_PAM_MARK" "$nf_line"
    } | append_file "$nf_f"
}

# notify_pam_remove <файл> [обёртка] — убрать ровно то, что добавили
notify_pam_remove() {
    local nf_f="$1" nf_line nf_tmp nf_rc
    nf_line="$(notify_pam_line "${2:-}")"
    _notify_file_has_line "$nf_f" "$NOTIFY_PAM_MARK" || return 0
    nf_tmp="$(mktemp)" || return 1
    awk -v m="$NOTIFY_PAM_MARK" -v l="$nf_line" '$0 != m && $0 != l' "$nf_f" > "$nf_tmp"
    write_file "$nf_f" < "$nf_tmp"; nf_rc=$?
    rm -f "$nf_tmp"
    return "$nf_rc"
}

# ── Состояние ───────────────────────────────────────────────────────────────
# _notify_part_ok <ssh|ban|reboot> — часть установлена. Только файлы и
# симлинк: status_ идёт на каждую отрисовку меню, systemctl там дорог
_notify_part_ok() {
    case "$1" in
        ssh)    [ -x "$NOTIFY_SSH_BIN" ] && _notify_file_has_line "$NOTIFY_PAM" "$NOTIFY_PAM_MARK" ;;
        ban)    [ -f "$NOTIFY_ACTION" ] && [ -f "$NOTIFY_JAIL" ] ;;
        reboot) [ -x "$NOTIFY_REBOOT_BIN" ] && [ -f "${NOTIFY_UNIT_DIR}/${NOTIFY_TIMER_NAME}" ] \
                    && [ -e "${NOTIFY_UNIT_DIR}/timers.target.wants/${NOTIFY_TIMER_NAME}" ] ;;
        *) return 1 ;;
    esac
}

status_notify() {
    local nf_e nf_miss='' nf_any=false
    for nf_e in ssh ban reboot; do _notify_part_ok "$nf_e" && nf_any=true; done
    _notify_read_conf "$NOTIFY_CONF"
    if [ "$REPLY_NF_HAS" != 1 ] || [ -z "$REPLY_NF_CHAT" ]; then
        if [ "$nf_any" = true ]; then
            st "$YELLOW" "! части без конфига" "! parts without a config"; return 1
        fi
        st "$DIM" "○ не настроено" "○ not configured"; return 1
    fi
    [ -x "$NOTIFY_BIN" ] || nf_miss="usfc-notify"
    for nf_e in ${REPLY_NF_EVENTS//,/ }; do
        _notify_part_ok "$nf_e" || nf_miss="${nf_miss}${nf_miss:+,}${nf_e}"
    done
    if [ -n "$nf_miss" ]; then
        st "$YELLOW" "! Telegram · нет: ${nf_miss}" "! Telegram · missing: ${nf_miss}"; return 1
    fi
    st "$GREEN" "✓ Telegram · ${REPLY_NF_EVENTS:-—}" "✓ Telegram · ${REPLY_NF_EVENTS:-—}"; return 0
}

# ── Запись конфига с токеном ────────────────────────────────────────────────
# Файл не должен быть читаем другим ни на мгновение: у уже существующего
# права сужаются ДО записи, новый создаётся при umask 077 (в подоболочке —
# чтобы маска не утекла на остаток прогона). Копию для отката write_file
# делает cp -p в каталог снимков с правами 700, так что секрет не расширяется.
_notify_write_conf() {
    local nf_tok="$1" nf_chat="$2" nf_ev="$3"
    mkdir -p "$(dirname "$NOTIFY_CONF")"
    [ -e "$NOTIFY_CONF" ] && chmod 600 "$NOTIFY_CONF"
    ( umask 077
      printf '%s\n' "# usfc: Telegram alerts. Mode 600: holds the bot token. Edit via usfc."
      printf 'TG_TOKEN=%s\nTG_CHAT=%s\nEVENTS=%s\n' "$nf_tok" "$nf_chat" "$nf_ev"
    ) | ( umask 077; write_file "$NOTIFY_CONF" ) || return 1
    chmod 600 "$NOTIFY_CONF" && chown root:root "$NOTIFY_CONF" 2>/dev/null
    return 0
}

# _notify_write_exec <путь> <функция-генератор> [аргументы] — скрипт, 755
_notify_write_exec() {
    local nf_path="$1"; shift
    mkdir -p "$(dirname "$nf_path")"
    "$@" | write_file "$nf_path" || return 1
    chmod 755 "$nf_path"
}

# ── Вопросы ─────────────────────────────────────────────────────────────────
NOTIFY_TOKEN_RE='^[0-9]+:[A-Za-z0-9_-]+$'

# Telegram API: токен — позиционный аргумент функции (в argv процесса он не
# попадает), адрес идёт в curl через stdin
# _notify_api <токен> <метод> [аргументы curl] → stdout ответ
_notify_api() {
    printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$1" "$2" \
        | curl -sS --connect-timeout 5 --max-time 15 --config - "${@:3}" 2>&1
}

# _notify_ask_token [текущий] → REPLY_NOTIFY_TOKEN. 0 — есть токен;
# 2 — пусто и текущего нет; 1 — ввод не годится
REPLY_NOTIFY_TOKEN=''
_notify_ask_token() {
    local nf_cur="${1:-}" nf_tries=0 nf_p nf_h
    REPLY_NOTIFY_TOKEN=''
    while [ "$nf_tries" -lt 3 ]; do
        nf_tries=$((nf_tries + 1))
        t "Токен бота (@BotFather)" "Bot token (@BotFather)"; nf_p="$REPLY_T"
        if [ -n "$nf_cur" ]; then
            t "Enter — оставить текущий, ввод скрыт" "Enter keeps the current one, input hidden"
        else
            t "ввод скрыт" "input hidden"
        fi
        nf_h="$REPLY_T"
        ui_prompt "$nf_p" "$nf_h"
        read -rs REPLY_NOTIFY_TOKEN </dev/tty || { echo ""; REPLY_NOTIFY_TOKEN=''; return 1; }
        echo ""
        if [ -z "$REPLY_NOTIFY_TOKEN" ]; then
            [ -n "$nf_cur" ] && { REPLY_NOTIFY_TOKEN="$nf_cur"; return 0; }
            return 2
        fi
        if [[ "$REPLY_NOTIFY_TOKEN" =~ $NOTIFY_TOKEN_RE ]]; then return 0; fi
        log_warn_t "Токен выглядит иначе: ожидается 123456:ABC… (цифры, двоеточие, буквы)" \
"The token looks wrong: expected 123456:ABC… (digits, a colon, letters)"
    done
    REPLY_NOTIFY_TOKEN=''
    return 1
}

# _notify_find_chat <токен> → REPLY_NOTIFY_CHAT. Без jq: берём последний
# "chat":{"id":N из ответа getUpdates (offset=-1 — только последнее событие)
REPLY_NOTIFY_CHAT=''
_notify_find_chat() {
    local nf_resp nf_id
    REPLY_NOTIFY_CHAT=''
    log_info_t "Напиши своему боту в Telegram любое сообщение (для группы — добавь бота и напиши там), потом нажми Enter" \
"Send your bot any message in Telegram (for a group, add the bot and write there), then press Enter"
    read -r _ </dev/tty || return 1
    nf_resp="$(_notify_api "$1" getUpdates -d offset=-1)"
    if [[ "$nf_resp" != *'"ok":true'* ]]; then
        nf_resp="${nf_resp//"$1"/***}"
        if [[ "$nf_resp" =~ \"description\":\"([^\"]*)\" ]]; then nf_resp="${BASH_REMATCH[1]}"; fi
        log_error_t "Telegram не отдал обновления: ${nf_resp:0:200}" \
"Telegram returned no updates: ${nf_resp:0:200}"
        return 1
    fi
    if [[ "$nf_resp" =~ \"chat\":\{\"id\":(-?[0-9]+) ]]; then
        nf_id="${BASH_REMATCH[1]}"
        # регулярка жадная по порядку, а нужен последний чат: при offset=-1 он единственный
        if ask_yn_t "Найден чат ${nf_id}. Использовать?" "Found chat ${nf_id}. Use it?" Y; then
            REPLY_NOTIFY_CHAT="$nf_id"; return 0
        fi
        return 1
    fi
    log_warn_t "Новых сообщений боту нет — напиши ему и повтори" \
"The bot has no new messages — write to it and try again"
    return 1
}

# _notify_ask_chat <токен> [текущий] → REPLY_NOTIFY_CHAT
_notify_ask_chat() {
    local nf_tries=0 nf_v
    REPLY_NOTIFY_CHAT=''
    while [ "$nf_tries" -lt 3 ]; do
        nf_tries=$((nf_tries + 1))
        ask_text_t "chat_id получателя (Enter без значения — найти автоматически)" \
"Recipient chat_id (empty Enter — find it automatically)" "${2:-}"
        nf_v="${REPLY_TEXT// /}"
        if [ -z "$nf_v" ]; then
            _notify_find_chat "$1" && return 0
            continue
        fi
        if answer_normalize chat "$nf_v"; then REPLY_NOTIFY_CHAT="$REPLY_ANS"; return 0; fi
        log_warn_t "chat_id — число (123456, -100…) или @канал" \
"chat_id is a number (123456, -100…) or @channel"
    done
    return 1
}

# _notify_ask_events <дефолт> → REPLY_NOTIFY_EV
REPLY_NOTIFY_EV=''
_notify_ask_events() {
    local nf_tries=0
    REPLY_NOTIFY_EV=''
    while [ "$nf_tries" -lt 3 ]; do
        nf_tries=$((nf_tries + 1))
        ask_text_t "О чём сообщать: ssh (вход), ban (fail2ban), reboot (нужна перезагрузка)?" \
"What to report: ssh (logins), ban (fail2ban), reboot (reboot needed)?" "${1:-$NOTIFY_ALL_EVENTS}"
        if valid_notify_events "$REPLY_TEXT"; then REPLY_NOTIFY_EV="$REPLY_NOTIFY_EVENTS"; return 0; fi
        log_warn_t "Допустимо: ssh, ban, reboot через запятую" "Allowed: ssh, ban, reboot, comma-separated"
    done
    return 1
}

# Пакет: всё нужное спрашиваем заранее. Пусто вместо токена — пропустить пункт
preask_notify() {
    local nf_ct nf_cc nf_ce nf_rc
    _notify_read_conf "$NOTIFY_CONF" keep
    nf_ct="$REPLY_NF_TOKEN"; nf_cc="$REPLY_NF_CHAT"; nf_ce="$REPLY_NF_EVENTS"
    REPLY_NF_TOKEN=''
    if [ -z "$TG_TOKEN_BULK" ] && [ -z "$nf_ct" ]; then
        echo ""
        log_info_t "Уведомления в Telegram: нужен токен бота от @BotFather. Пустой ввод — пропустить пункт" \
"Telegram alerts need a bot token from @BotFather. Empty input skips the item"
        _notify_ask_token ""; nf_rc=$?
        if [ "$nf_rc" -eq 0 ]; then TG_TOKEN_BULK="$REPLY_NOTIFY_TOKEN"; fi
        REPLY_NOTIFY_TOKEN=''
    fi
    if [ -n "$TG_TOKEN_BULK$nf_ct" ]; then
        if [ -z "$TG_CHAT_BULK" ] && [ -z "$nf_cc" ]; then
            _notify_ask_chat "${TG_TOKEN_BULK:-$nf_ct}" && TG_CHAT_BULK="$REPLY_NOTIFY_CHAT"
        fi
        if [ -z "$NOTIFY_EVENTS_BULK" ]; then
            _notify_ask_events "${nf_ce:-$NOTIFY_ALL_EVENTS}" && NOTIFY_EVENTS_BULK="$REPLY_NOTIFY_EV"
        fi
    fi
    nf_ct=''
    return 0
}

# ── Установка частей ────────────────────────────────────────────────────────
# Каждая _notify_install_* возвращает 0 — установлено; 2 — пропущено из-за
# отсутствия зависимости (это предупреждение, не ошибка); 1 — сбой

_notify_install_ssh() {
    if [ ! -f "$NOTIFY_PAM" ]; then
        log_warn_t "Нет ${NOTIFY_PAM} (openssh-server не установлен?) — вход по SSH не отслеживаю" \
"No ${NOTIFY_PAM} (openssh-server missing?) — SSH logins are not tracked"
        return 2
    fi
    if command -v sshd >/dev/null 2>&1 && [ "$USFC_DRY_RUN" != true ]; then
        case "$(sshd -T 2>/dev/null | awk '$1 == "usepam" { print $2 }')" in
            no) log_warn_t "В sshd выключен UsePAM — вход по SSH уведомление не вызовет" \
"sshd has UsePAM disabled — SSH logins will not trigger the alert" ;;
        esac
    fi
    # обёртка должна лежать на месте ДО строки в PAM
    _notify_write_exec "$NOTIFY_SSH_BIN" notify_ssh_script "$NOTIFY_BIN" || return 1
    notify_pam_add "$NOTIFY_PAM" "$NOTIFY_SSH_BIN" || return 1
    log_success_t "Вход по SSH: строка pam_exec добавлена в ${NOTIFY_PAM}" \
"SSH logins: pam_exec line added to ${NOTIFY_PAM}"
}

# Чужой action в [sshd] или [DEFAULT] (кроме нашего файла): наш ключ action
# его заменил бы, и, например, письма fail2ban молча пропали бы
_notify_foreign_action() {
    local nf_f
    for nf_f in /etc/fail2ban/jail.local /etc/fail2ban/jail.d/*.local /etc/fail2ban/jail.d/*.conf; do
        [ -f "$nf_f" ] || continue
        [ "$nf_f" = "$NOTIFY_JAIL" ] && continue
        awk '/^[[:space:]]*\[/ { s = $0; gsub(/[[:space:]]/, "", s) }
             (s == "[sshd]" || s == "[DEFAULT]") && /^[[:space:]]*action[[:space:]]*=/ { f = 1 }
             END { exit !f }' "$nf_f" && { REPLY_T="$nf_f"; return 0; }
    done
    return 1
}

_notify_install_ban() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        log_warn_t "fail2ban не установлен — баны не отслеживаю. Поставь fail2ban и запусти пункт ещё раз" \
"fail2ban is not installed — bans are not tracked. Install fail2ban and run the item again"
        return 2
    fi
    if _notify_foreign_action; then
        log_warn_t "В ${REPLY_T} уже задан action для sshd — свой не навязываю. Добавь к нему usfc-telegram вручную" \
"${REPLY_T} already sets an action for sshd — not overriding it. Add usfc-telegram to it by hand"
        return 2
    fi
    _notify_write_exec "$NOTIFY_BIN" notify_send_script || return 1
    write_file "$NOTIFY_ACTION" < <(notify_action_conf "$NOTIFY_BIN") || return 1
    write_file "$NOTIFY_JAIL" < <(notify_jail_conf) || return 1
    if [ "$USFC_DRY_RUN" != true ] && ! fail2ban-client -t >/dev/null 2>&1; then
        remove_file "$NOTIFY_ACTION"; remove_file "$NOTIFY_JAIL"
        log_error_t "fail2ban отверг конфиг — файлы уведомления убраны. Проверка: fail2ban-client -t" \
"fail2ban rejected the config — alert files removed. Check: fail2ban-client -t"
        return 1
    fi
    if systemctl is-active fail2ban >/dev/null 2>&1; then
        if ! systemctl restart fail2ban >/dev/null 2>&1; then
            log_error_t "fail2ban не перезапустился — подробности: journalctl -u fail2ban" \
"fail2ban did not restart — details: journalctl -u fail2ban"
            return 1
        fi
    fi
    log_success_t "Баны fail2ban: действие usfc-telegram подключено к jail sshd" \
"fail2ban bans: the usfc-telegram action is attached to the sshd jail"
}

_notify_install_reboot() {
    if [ ! -d /run/systemd/system ] && [ "$USFC_DRY_RUN" != true ]; then
        log_warn_t "systemd не запущен (контейнер?) — таймер проверки перезагрузки не ставлю" \
"systemd is not running (a container?) — the reboot check timer is not installed"
        return 2
    fi
    _notify_write_exec "$NOTIFY_REBOOT_BIN" notify_reboot_script "$NOTIFY_BIN" || return 1
    write_file "${NOTIFY_UNIT_DIR}/${NOTIFY_SERVICE_NAME}" < <(notify_service_unit "$NOTIFY_REBOOT_BIN") || return 1
    write_file "${NOTIFY_UNIT_DIR}/${NOTIFY_TIMER_NAME}" < <(notify_timer_unit) || return 1
    chmod 644 "${NOTIFY_UNIT_DIR}/${NOTIFY_SERVICE_NAME}" "${NOTIFY_UNIT_DIR}/${NOTIFY_TIMER_NAME}"
    if ! systemctl daemon-reload || ! systemctl enable --now "$NOTIFY_TIMER_NAME" >/dev/null 2>&1; then
        log_error_t "Не удалось включить ${NOTIFY_TIMER_NAME}" "Could not enable ${NOTIFY_TIMER_NAME}"
        return 1
    fi
    log_success_t "Перезагрузка: таймер ${NOTIFY_TIMER_NAME} включён (раз в сутки)" \
"Reboot: ${NOTIFY_TIMER_NAME} enabled (daily)"
}

apply_notify() {
    local nf_tok nf_chat nf_ev nf_cur_t nf_cur_c nf_cur_e nf_e nf_rc nf_done='' nf_failed=false nf_out nf_msg nf_dry=false
    [ "$USFC_DRY_RUN" = true ] && nf_dry=true

    _notify_read_conf "$NOTIFY_CONF" keep
    nf_cur_t="$REPLY_NF_TOKEN"; nf_cur_c="$REPLY_NF_CHAT"; nf_cur_e="$REPLY_NF_EVENTS"
    REPLY_NF_TOKEN=''
    nf_tok="$TG_TOKEN_BULK"; nf_chat="$TG_CHAT_BULK"; nf_ev="$NOTIFY_EVENTS_BULK"
    # токен живёт один прогон (как CF_TOKEN_BULK у certbot)
    TG_TOKEN_BULK=''

    if [ "$nf_dry" = true ]; then
        # ничего не спрашиваем и не отправляем; значения-заглушки не уходят никуда, кроме строки dry-run
        [ -n "$nf_tok" ] || nf_tok="${nf_cur_t:-000000:dry-run}"
        [ -n "$nf_chat" ] || nf_chat="${nf_cur_c:-0}"
        [ -n "$nf_ev" ] || nf_ev="${nf_cur_e:-$NOTIFY_ALL_EVENTS}"
    elif [ "$BULK_MODE" = true ]; then
        [ -n "$nf_tok" ] || nf_tok="$nf_cur_t"
        [ -n "$nf_chat" ] || nf_chat="$nf_cur_c"
        [ -n "$nf_ev" ] || nf_ev="${nf_cur_e:-$NOTIFY_ALL_EVENTS}"
        if [ -z "$nf_tok" ] || [ -z "$nf_chat" ]; then
            log_error_t "Уведомления в Telegram пропущены: не задан токен бота (TG_TOKEN в файле ответов) или chat_id (--tg-chat / TG_CHAT)" \
"Telegram alerts skipped: no bot token (TG_TOKEN in the answers file) or chat_id (--tg-chat / TG_CHAT)"
            nf_tok=''; nf_cur_t=''
            return 1
        fi
        if ! [[ "$nf_tok" =~ $NOTIFY_TOKEN_RE ]]; then
            log_error_t "Токен Telegram выглядит неверно (ожидается 123456:ABC…) — пункт пропущен" \
"The Telegram token looks wrong (expected 123456:ABC…) — item skipped"
            nf_tok=''; nf_cur_t=''
            return 1
        fi
    else
        _notify_ask_token "$nf_cur_t"; nf_rc=$?
        if [ "$nf_rc" -ne 0 ]; then
            [ "$nf_rc" -eq 2 ] && log_error_t "Пустой токен — ничего не настроено" "Empty token — nothing configured"
            REPLY_NOTIFY_TOKEN=''; nf_cur_t=''
            return 1
        fi
        nf_tok="$REPLY_NOTIFY_TOKEN"; REPLY_NOTIFY_TOKEN=''
        if [ -z "$nf_chat" ]; then
            if ! _notify_ask_chat "$nf_tok" "$nf_cur_c"; then
                log_error_t "chat_id не задан — ничего не настроено" "No chat_id — nothing configured"
                nf_tok=''; nf_cur_t=''
                return 1
            fi
            nf_chat="$REPLY_NOTIFY_CHAT"
        fi
        if [ -z "$nf_ev" ]; then
            _notify_ask_events "${nf_cur_e:-$NOTIFY_ALL_EVENTS}" || { nf_tok=''; nf_cur_t=''; return 1; }
            nf_ev="$REPLY_NOTIFY_EV"
        fi
    fi
    nf_cur_t=''

    if ! [[ "$nf_tok" =~ $NOTIFY_TOKEN_RE ]]; then
        log_error_t "Токен Telegram выглядит неверно (ожидается 123456:ABC…)" \
"The Telegram token looks wrong (expected 123456:ABC…)"
        nf_tok=''; return 1
    fi
    valid_notify_events "$nf_ev" || nf_ev="$NOTIFY_ALL_EVENTS"
    nf_ev="$REPLY_NOTIFY_EVENTS"

    if ! command -v curl >/dev/null 2>&1; then
        ensure_pkg "curl" curl || { nf_tok=''; return 1; }
    fi

    # 1. конфиг и отправитель; 2. проверка доставки; 3. хуки
    _notify_write_conf "$nf_tok" "$nf_chat" "$nf_ev" || { nf_tok=''; log_error_t "Не удалось записать ${NOTIFY_CONF}" "Could not write ${NOTIFY_CONF}"; return 1; }
    nf_tok=''
    _notify_write_exec "$NOTIFY_BIN" notify_send_script || return 1
    log_success_t "Настройки сохранены: ${NOTIFY_CONF} (права 600)" "Settings saved: ${NOTIFY_CONF} (mode 600)"

    if [ "$nf_dry" != true ]; then
        t "usfc: уведомления настроены" "usfc: alerts are set up"; nf_msg="$REPLY_T"
        if ! nf_out="$("$NOTIFY_BIN" "$nf_msg" 2>&1)"; then
            log_error_t "Telegram не принял тестовое сообщение. ${nf_out}" \
"Telegram did not accept the test message. ${nf_out}"
            log_info_t "Проверь: токен; chat_id (боту надо сначала написать /start); доступ к api.telegram.org. Настройки сохранены — запусти пункт ещё раз" \
"Check: the token; the chat_id (message the bot /start first); access to api.telegram.org. Settings are saved — run the item again"
            return 1
        fi
        log_success_t "Тестовое сообщение доставлено" "The test message was delivered"
    fi

    for nf_e in ${nf_ev//,/ }; do
        case "$nf_e" in
            ssh)    _notify_install_ssh ;;
            ban)    _notify_install_ban ;;
            reboot) _notify_install_reboot ;;
        esac
        nf_rc=$?
        case "$nf_rc" in
            0) nf_done="${nf_done}${nf_done:+,}${nf_e}" ;;
            2) ;;
            *) nf_failed=true ;;
        esac
    done
    # в конфиге остаются только реально подключённые события, иначе статус врал бы
    if [ "$nf_done" != "$nf_ev" ] && [ "$nf_dry" != true ]; then
        _notify_read_conf "$NOTIFY_CONF" keep
        nf_tok="$REPLY_NF_TOKEN"; REPLY_NF_TOKEN=''
        _notify_write_conf "$nf_tok" "$nf_chat" "${nf_done:-$nf_ev}"
        nf_tok=''
        [ -z "$nf_done" ] && log_warn_t "Ни одно событие не подключено — отправитель готов, но слать нечему" \
"No event is attached — the sender is ready, but nothing triggers it"
    fi
    [ "$nf_failed" = true ] && return 1
    log_success_t "Уведомления в Telegram: ${nf_done:-$nf_ev}" "Telegram alerts: ${nf_done:-$nf_ev}"
    return 0
}

disable_notify() {
    local nf_any=false nf_e
    for nf_e in ssh ban reboot; do _notify_part_ok "$nf_e" && nf_any=true; done
    [ -e "$NOTIFY_CONF" ] || [ -e "$NOTIFY_BIN" ] && nf_any=true
    if [ "$nf_any" != true ]; then
        log_info_t "Уведомления не настроены — нечего убирать" "Alerts are not set up — nothing to remove"
        return 0
    fi
    ask_yn_t "Убрать уведомления в Telegram (вход по SSH, баны, таймер, скрипты и конфиг с токеном)?" \
"Remove Telegram alerts (SSH logins, bans, timer, scripts and the config with the token)?" N || return 0

    notify_pam_remove "$NOTIFY_PAM" "$NOTIFY_SSH_BIN"
    if [ -e "$NOTIFY_ACTION" ] || [ -e "$NOTIFY_JAIL" ]; then
        remove_file "$NOTIFY_ACTION"; remove_file "$NOTIFY_JAIL"
        systemctl is-active fail2ban >/dev/null 2>&1 && systemctl restart fail2ban >/dev/null 2>&1
    fi
    if [ -e "${NOTIFY_UNIT_DIR}/${NOTIFY_TIMER_NAME}" ]; then
        systemctl disable --now "$NOTIFY_TIMER_NAME" >/dev/null 2>&1
        remove_file "${NOTIFY_UNIT_DIR}/${NOTIFY_TIMER_NAME}"
        remove_file "${NOTIFY_UNIT_DIR}/${NOTIFY_SERVICE_NAME}"
        systemctl daemon-reload >/dev/null 2>&1
    fi
    remove_file "$NOTIFY_SSH_BIN"
    remove_file "$NOTIFY_REBOOT_BIN"
    remove_file "$NOTIFY_BIN"
    remove_file "$NOTIFY_CONF"
    [ "$USFC_DRY_RUN" = true ] || rmdir "$(dirname "$NOTIFY_CONF")" 2>/dev/null
    log_success_t "Уведомления убраны. Копия конфига с токеном осталась в снимке отката (права 700)" \
"Alerts removed. A copy of the config with the token remains in the rollback snapshot (mode 700)"
    return 0
}
