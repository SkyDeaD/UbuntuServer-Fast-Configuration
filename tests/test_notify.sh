#!/usr/bin/env bash
# Уведомления в Telegram (пункт notify): сгенерированные скрипты и правка PAM.
#
# Root не нужен. curl подменяется скриптом в PATH, который пишет argv и stdin
# в файлы. Проверяем то, на чём такая вещь ломается в жизни:
#   • токен не попадает в argv (ps видит всех) и не попадает в сообщения об ошибках;
#   • PAM-обёртка выходит 0 мгновенно, даже когда curl висит, и не реагирует
#     на закрытие сеанса — иначе сетевой таймаут задержал бы вход по SSH;
#   • правка /etc/pam.d/sshd идемпотентна и обратима байт-в-байт;
#   • конфиг с токеном получает права 600 и не меняет umask процесса.
set -uo pipefail
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"
# shellcheck disable=SC2034  # читается в write_file / log_*
USFC_DRY_RUN=false
# shellcheck disable=SC2034
USFC_NO_COLOR=true
backup_file() { :; }    # снимки проверяет test_backup.sh

TMP="$(mktemp -d)"
FAKE="$TMP/fake"; mkdir -p "$FAKE" "$TMP/bin"
cleanup() {
    if [ -s "$FAKE/pids" ]; then while read -r p; do kill "$p" 2>/dev/null; done < "$FAKE/pids"; fi
    rm -rf "$TMP"
}
trap cleanup EXIT

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }

TOKEN="123456789:AAFakeTokenForTestsOnly_abc-DEF"
CHAT="-1001234567890"

# подменённый curl: argv и stdin — в файлы, ответ — из FAKE_REPLY
cat > "$FAKE/curl" <<'EOS'
#!/bin/bash
D="$(dirname "$0")"
printf '%s\n' "$@" > "$D/argv"
cat > "$D/stdin"
echo 1 >> "$D/calls"
if [ -e "$D/hang" ]; then echo $$ >> "$D/pids"; exec sleep 30; fi
cat "$D/reply"
EOS
chmod +x "$FAKE/curl"
reply() { printf '%s' "$1" > "$FAKE/reply"; }
reset_fake() { rm -f "$FAKE/argv" "$FAKE/stdin" "$FAKE/calls" "$FAKE/hang"; }
run_with_fake() { PATH="$FAKE:$PATH" "$@"; }

wait_for() {   # wait_for <файл> — до 3 с
    for _ in $(seq 1 30); do [ -e "$1" ] && return 0; sleep 0.1; done
    return 1
}

NOTIFY_CONF="$TMP/etc/usfc/notify.conf"

echo "конфиг"
umask 022
before_umask="$(umask)"
if _notify_write_conf "$TOKEN" "$CHAT" "ssh,ban"; then ok "_notify_write_conf"; else bad "_notify_write_conf"; fi
mode="$(stat -c %a "$NOTIFY_CONF" 2>/dev/null)"
[ "$mode" = 600 ] && ok "права 600" || bad "права $mode"
[ "$(umask)" = "$before_umask" ] && ok "umask процесса не изменился" || bad "umask утёк: $(umask)"
# уже существующий файл с открытыми правами сужается
chmod 644 "$NOTIFY_CONF"
_notify_write_conf "$TOKEN" "$CHAT" "ssh,ban,reboot"
mode="$(stat -c %a "$NOTIFY_CONF")"
[ "$mode" = 600 ] && ok "существующий 644 → 600" || bad "существующий файл: $mode"
_notify_read_conf "$NOTIFY_CONF" keep
{ [ "$REPLY_NF_TOKEN" = "$TOKEN" ] && [ "$REPLY_NF_CHAT" = "$CHAT" ] && [ "$REPLY_NF_EVENTS" = "ssh,ban,reboot" ]; } \
    && ok "чтение обратно" || bad "чтение: «$REPLY_NF_CHAT» «$REPLY_NF_EVENTS»"
_notify_read_conf "$NOTIFY_CONF"
[ -z "$REPLY_NF_TOKEN" ] && [ "$REPLY_NF_HAS" = 1 ] && ok "без keep токен в переменную не выносится" || bad "токен вынесен без keep"

for lang in ru en; do
    # shellcheck disable=SC2034  # читает t() при генерации
    USFC_LANG="$lang"
    echo ""
    echo "скрипты [$lang]"
    SEND="$TMP/bin/usfc-notify-$lang"; SSHW="$TMP/bin/usfc-notify-ssh-$lang"; REB="$TMP/bin/usfc-notify-reboot-$lang"
    notify_send_script "$NOTIFY_CONF" > "$SEND"
    notify_ssh_script "$SEND" > "$SSHW"
    notify_reboot_script "$SEND" "$TMP/reboot-required" "$TMP/reboot-state" > "$REB"
    chmod +x "$SEND" "$SSHW" "$REB"
    for f in "$SEND" "$SSHW" "$REB"; do
        if bash -n "$f" 2>"$TMP/syn"; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f"): $(cat "$TMP/syn")"; fi
        if grep -F "$TOKEN" "$f" >/dev/null; then bad "токен зашит в $(basename "$f")"; fi
    done
    notify_action_conf "$SEND" > "$TMP/action-$lang"
    notify_jail_conf > "$TMP/jail-$lang"
    notify_timer_unit > "$TMP/timer-$lang"
    notify_service_unit "$REB" > "$TMP/service-$lang"
    grep -E '^actionban = .*usfc-notify.* --bg "' "$TMP/action-$lang" >/dev/null && ok "actionban зовёт отправитель" || bad "actionban: $(cat "$TMP/action-$lang")"
    grep -F '<ip>' "$TMP/action-$lang" >/dev/null && ok "в действии есть <ip>" || bad "нет <ip>"
    grep -F 'action = %(action_)s' "$TMP/jail-$lang" >/dev/null && ok "jail: action = %(action_)s + usfc-telegram" || bad "jail"
    [ "$(grep -cE '^(OnCalendar=daily|Persistent=true|RandomizedDelaySec=)' "$TMP/timer-$lang")" -eq 3 ] && ok "таймер: daily, Persistent, Randomized" || bad "таймер"
    grep -F "ExecStart=$REB" "$TMP/service-$lang" >/dev/null && ok "service: ExecStart" || bad "service"
    if [ "$lang" = en ]; then
        if LC_ALL=C.UTF-8 grep -P '[\x{0400}-\x{04FF}]' "$SEND" "$SSHW" "$REB" "$TMP/action-en" >/dev/null 2>&1; then
            bad "en: в скриптах есть кириллица"; else ok "en: кириллицы нет"; fi
    fi

    echo "отправка [$lang]"
    reset_fake; reply '{"ok":true,"result":{"message_id":1}}'
    run_with_fake "$SEND" "привет & мир=1 100%" >"$TMP/o" 2>"$TMP/e"; rc=$?
    [ "$rc" -eq 0 ] && ok "ok:true → код 0" || bad "код $rc: $(cat "$TMP/e")"
    if grep -F "$TOKEN" "$FAKE/argv" >/dev/null; then bad "ТОКЕН В ARGV"; else ok "токена нет в argv"; fi
    grep -F "$TOKEN" "$FAKE/stdin" >/dev/null && ok "токен в stdin" || bad "токена нет в stdin"
    grep -Fx 'url = "https://api.telegram.org/bot'"$TOKEN"'/sendMessage"' "$FAKE/stdin" >/dev/null && ok "url в конфиге curl с кавычками" || bad "stdin: $(cat "$FAKE/stdin")"
    grep -Fx -- '--config' "$FAKE/argv" >/dev/null && grep -Fx -- '-' "$FAKE/argv" >/dev/null && ok "--config -" || bad "нет --config -"
    [ "$(grep -cFx -- '--data-urlencode' "$FAKE/argv")" -eq 2 ] && ok "два --data-urlencode" || bad "argv: $(tr '\n' ' ' < "$FAKE/argv")"
    grep -Fx "chat_id=$CHAT" "$FAKE/argv" >/dev/null && ok "chat_id в argv" || bad "chat_id"
    grep -F 'text=[' "$FAKE/argv" >/dev/null && grep -F '] привет & мир=1 100%' "$FAKE/argv" >/dev/null && ok "текст с префиксом хоста, без экранирования руками" || bad "text: $(grep text= "$FAKE/argv")"

    reset_fake; reply '{"ok":false,"error_code":401,"description":"Unauthorized"}'
    run_with_fake "$SEND" "x" >"$TMP/o" 2>"$TMP/e"; rc=$?
    [ "$rc" -eq 1 ] && ok "ok:false → код 1" || bad "код $rc"
    grep -F 'Unauthorized' "$TMP/e" >/dev/null && ok "причина в stderr" || bad "stderr: $(cat "$TMP/e")"
    # сервер, эхом вернувший токен, не должен его выдать
    reset_fake; reply "{\"ok\":false,\"description\":\"bad $TOKEN\"}"
    run_with_fake "$SEND" "x" >"$TMP/o" 2>"$TMP/e"
    grep -F "$TOKEN" "$TMP/e" "$TMP/o" >/dev/null && bad "токен в выводе ошибки" || ok "токен в выводе ошибки вычищен"

    mv "$NOTIFY_CONF" "$NOTIFY_CONF.off"
    reset_fake; reply '{"ok":true}'
    run_with_fake "$SEND" "x" >"$TMP/o" 2>"$TMP/e"; rc=$?
    { [ "$rc" -eq 1 ] && [ ! -e "$FAKE/calls" ]; } && ok "без конфига: код 1, curl не звали" || bad "без конфига: код $rc"
    mv "$NOTIFY_CONF.off" "$NOTIFY_CONF"
    run_with_fake "$SEND" >"$TMP/o" 2>"$TMP/e"; rc=$?
    [ "$rc" -eq 2 ] && ok "без текста: код 2" || bad "без текста: код $rc"

    echo "PAM-обёртка [$lang]"
    reset_fake; reply '{"ok":true}'
    PAM_TYPE=close_session PAM_USER=bob PAM_RHOST=1.2.3.4 run_with_fake "$SSHW"; rc=$?
    sleep 0.4
    { [ "$rc" -eq 0 ] && [ ! -e "$FAKE/calls" ]; } && ok "close_session: код 0, ничего не отправлено" || bad "close_session: код $rc, вызовов: $(cat "$FAKE/calls" 2>/dev/null | wc -l)"
    PAM_TYPE=open_session PAM_USER=alice PAM_RHOST=203.0.113.7 run_with_fake "$SSHW" </dev/null >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 0 ] && ok "open_session: код 0" || bad "open_session: код $rc"
    if wait_for "$FAKE/argv"; then
        grep -F 'alice' "$FAKE/argv" >/dev/null && grep -F '203.0.113.7' "$FAKE/argv" >/dev/null && ok "в тексте пользователь и адрес" || bad "text: $(grep text= "$FAKE/argv")"
    else bad "фоновая отправка не случилась"; fi
    # curl висит 30 с — обёртка обязана вернуться сразу
    reset_fake; : > "$FAKE/hang"
    t0="${EPOCHREALTIME/[.,]/}"
    PAM_TYPE=open_session PAM_USER=alice PAM_RHOST=203.0.113.7 run_with_fake "$SSHW" </dev/null >/dev/null 2>&1; rc=$?
    t1="${EPOCHREALTIME/[.,]/}"
    ms=$(( (t1 - t0) / 1000 ))
    { [ "$rc" -eq 0 ] && [ "$ms" -lt 1000 ]; } && ok "curl висит 30 с, обёртка вернулась за ${ms} мс" || bad "обёртка: код $rc, ${ms} мс"
    wait_for "$FAKE/pids" || bad "фоновый curl не стартовал"
    # а если отправителя нет — тоже 0
    PAM_TYPE=open_session bash -c 'sed "s|^BIN=.*|BIN=/nonexistent|" "$1" | bash' _ "$SSHW"; rc=$?
    [ "$rc" -eq 0 ] && ok "нет отправителя: код 0" || bad "нет отправителя: код $rc"
    reset_fake

    echo "проверка перезагрузки [$lang]"
    # фоновые отправители прошлых проверок дописывают calls с задержкой — даём им закончить
    if [ -s "$FAKE/pids" ]; then while read -r p; do kill "$p" 2>/dev/null; done < "$FAKE/pids"; : > "$FAKE/pids"; fi
    sleep 1
    reset_fake; reply '{"ok":true}'; rm -f "$TMP/reboot-required" "$TMP/reboot-required.pkgs" "$TMP/reboot-state"
    run_with_fake "$REB"; rc=$?
    { [ "$rc" -eq 0 ] && [ ! -e "$FAKE/calls" ]; } && ok "reboot-required нет → тишина" || bad "reboot без файла: код $rc"
    : > "$TMP/reboot-required"; printf 'linux-image-6.8\nlibc6\n' > "$TMP/reboot-required.pkgs"
    run_with_fake "$REB"; rc=$?
    { [ "$rc" -eq 0 ] && grep -F 'libc6' "$FAKE/argv" >/dev/null; } && ok "отправлено со списком пакетов" || bad "reboot: код $rc"
    reset_fake
    run_with_fake "$REB"
    [ ! -e "$FAKE/calls" ] && ok "повтор на тот же набор пакетов молчит" || bad "повторная отправка"
    printf 'linux-image-6.8\nlibc6\nopenssl\n' > "$TMP/reboot-required.pkgs"
    run_with_fake "$REB"
    [ -e "$FAKE/calls" ] && ok "набор пакетов изменился → снова" || bad "изменение набора не замечено"
    reset_fake; reply '{"ok":false,"description":"x"}'; rm -f "$TMP/reboot-state"
    run_with_fake "$REB" 2>/dev/null; rc=$?
    { [ "$rc" -ne 0 ] && [ ! -e "$TMP/reboot-state" ]; } && ok "сбой отправки → код ≠0 и метка не пишется" || bad "сбой: код $rc"
done

echo ""
echo "PAM: правка sshd"
PAMF="$TMP/pam-sshd"
printf '%s\n' '# PAM configuration for the Secure Shell service' '@include common-auth' 'session required pam_loginuid.so' '@include common-session' > "$PAMF"
cp "$PAMF" "$TMP/pam-orig"
WR="/usr/local/sbin/usfc-notify-ssh"
notify_pam_add "$PAMF" "$WR"
grep -Fx 'session optional pam_exec.so quiet /usr/local/sbin/usfc-notify-ssh' "$PAMF" >/dev/null && ok "строка optional добавлена" || bad "строки нет"
grep -Fx "$NOTIFY_PAM_MARK" "$PAMF" >/dev/null && ok "маркер на месте" || bad "маркера нет"
cp "$PAMF" "$TMP/pam-once"
notify_pam_add "$PAMF" "$WR"
cmp -s "$PAMF" "$TMP/pam-once" && ok "повтор идемпотентен" || bad "повтор изменил файл"
notify_pam_remove "$PAMF" "$WR"
cmp -s "$PAMF" "$TMP/pam-orig" && ok "обратимо байт-в-байт" || { bad "после удаления файл другой"; diff "$TMP/pam-orig" "$PAMF"; }
notify_pam_remove "$PAMF" "$WR"
cmp -s "$PAMF" "$TMP/pam-orig" && ok "повторное удаление ничего не ломает" || bad "повторное удаление"
# файл без перевода строки в конце: метка не должна склеиться с последней строкой
printf '%s' 'session required pam_env.so' > "$PAMF"
notify_pam_add "$PAMF" "$WR"
grep -Fx "$NOTIFY_PAM_MARK" "$PAMF" >/dev/null && grep -Fx 'session required pam_env.so' "$PAMF" >/dev/null && ok "файл без \\n в конце не склеивается" || bad "склейка"

echo ""
echo "статус"
NOTIFY_BIN="$TMP/st/usfc-notify"; NOTIFY_SSH_BIN="$TMP/st/ssh"; NOTIFY_REBOOT_BIN="$TMP/st/reboot"
NOTIFY_CONF="$TMP/st/notify.conf"; NOTIFY_PAM="$TMP/st/pam"; NOTIFY_ACTION="$TMP/st/action"; NOTIFY_JAIL="$TMP/st/jail"
NOTIFY_UNIT_DIR="$TMP/st/units"
mkdir -p "$TMP/st" "$NOTIFY_UNIT_DIR/timers.target.wants"
status_notify >"$TMP/o"; rc=$?
{ [ "$rc" -ne 0 ] && grep -F '○' "$TMP/o" >/dev/null; } && ok "не настроено → ○" || bad "○: $(cat "$TMP/o")"
_notify_write_conf "$TOKEN" "$CHAT" "ssh,ban,reboot"
status_notify >"$TMP/o"; rc=$?
{ [ "$rc" -ne 0 ] && grep -F '!' "$TMP/o" >/dev/null; } && ok "конфиг без частей → !" || bad "!: $(cat "$TMP/o")"
grep -F "$TOKEN" "$TMP/o" >/dev/null && bad "токен в статусе"
for f in "$NOTIFY_BIN" "$NOTIFY_SSH_BIN" "$NOTIFY_REBOOT_BIN"; do : > "$f"; chmod +x "$f"; done
printf '%s\n%s\n' "$NOTIFY_PAM_MARK" "$(notify_pam_line "$NOTIFY_SSH_BIN")" > "$NOTIFY_PAM"
: > "$NOTIFY_ACTION"; : > "$NOTIFY_JAIL"
: > "$NOTIFY_UNIT_DIR/$NOTIFY_TIMER_NAME"; : > "$NOTIFY_UNIT_DIR/timers.target.wants/$NOTIFY_TIMER_NAME"
status_notify >"$TMP/o"; rc=$?
{ [ "$rc" -eq 0 ] && grep -F '✓ Telegram · ssh,ban,reboot' "$TMP/o" >/dev/null; } && ok "всё на месте → ✓" || bad "✓: $(cat "$TMP/o")"
rm -f "$NOTIFY_JAIL"
status_notify >"$TMP/o"; rc=$?
{ [ "$rc" -ne 0 ] && grep -F 'ban' "$TMP/o" >/dev/null; } && ok "нет jail → ! нет: ban" || bad "ban: $(cat "$TMP/o")"
: > "$NOTIFY_JAIL"

# метка осталась, строку pam_exec удалили руками → ssh не «установлен»
printf '%s\n' "$NOTIFY_PAM_MARK" > "$NOTIFY_PAM"
_notify_part_ok ssh && bad "метка без строки pam_exec считается установленной" || ok "метка без строки → ssh не установлен"
status_notify >"$TMP/o"; rc=$?
{ [ "$rc" -ne 0 ] && grep -F 'ssh' "$TMP/o" >/dev/null; } && ok "статус не ✓ без строки pam_exec" || bad "статус: $(cat "$TMP/o")"
# закомментированная строка не считается
printf '%s\n#%s\n' "$NOTIFY_PAM_MARK" "$(notify_pam_line "$NOTIFY_SSH_BIN")" > "$NOTIFY_PAM"
_notify_part_ok ssh && bad "закомментированная строка засчитана" || ok "закомментированная строка не считается"
# повторное применение чинит: дописывает только строку, метку не дублирует
printf '%s\n' "$NOTIFY_PAM_MARK" > "$NOTIFY_PAM"
notify_pam_add "$NOTIFY_PAM" "$NOTIFY_SSH_BIN"
_notify_part_ok ssh && ok "notify_pam_add вернул строку при уцелевшей метке" || bad "строка не добавлена"
[ "$(grep -cFx "$NOTIFY_PAM_MARK" "$NOTIFY_PAM")" -eq 1 ] && ok "метка не задублирована" || bad "метка продублирована"

echo ""
echo "настоящий curl: форма --config - против локального сервера"
if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    python3 -I - "$TMP/srv" <<'PY' &
import http.server, sys
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(n).decode()
        open(out, 'w').write(self.command + ' ' + self.path + '\n' + body + '\n')
        self.send_response(200); self.end_headers()
        self.wfile.write(b'{"ok":true}')
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open(out + '.port', 'w').write(str(s.server_port))
s.handle_request()
PY
    srv=$!
    wait_for "$TMP/srv.port" || true
    port="$(cat "$TMP/srv.port" 2>/dev/null)"
    if [ -n "$port" ]; then
        resp="$(printf 'url = "http://127.0.0.1:%s/bot%s/sendMessage"\n' "$port" "$TOKEN" \
            | curl -sS --max-time 10 --config - --data-urlencode "chat_id=$CHAT" --data-urlencode "text=привет & мир=1" 2>&1)"
        wait "$srv" 2>/dev/null
        [[ "$resp" == *'"ok":true'* ]] && ok "curl принял конфиг со stdin и ответил" || bad "ответ: $resp"
        grep -F "POST /bot$TOKEN/sendMessage" "$TMP/srv" >/dev/null && ok "POST на адрес из конфига" || bad "запрос: $(head -n1 "$TMP/srv" 2>/dev/null)"
        grep -F 'chat_id=-1001234567890' "$TMP/srv" >/dev/null && grep -F 'text=%D0%BF' "$TMP/srv" >/dev/null && grep -F '%26' "$TMP/srv" >/dev/null \
            && ok "тело закодировано (кириллица, &)" || bad "тело: $(tail -n1 "$TMP/srv")"
    else
        kill "$srv" 2>/dev/null; bad "тестовый сервер не поднялся"
    fi
else
    ok "нет curl или python3 — пропущено"
fi

echo ""
echo "пакетный режим и сухой прогон"
rm -f "$NOTIFY_CONF" "$NOTIFY_BIN" "$NOTIFY_SSH_BIN" "$NOTIFY_REBOOT_BIN"; reset_fake
# shellcheck disable=SC2034
BULK_MODE=true
TG_TOKEN_BULK=''; TG_CHAT_BULK="$CHAT"; NOTIFY_EVENTS_BULK=''
( PATH="$FAKE:$PATH"; apply_notify ) >"$TMP/o" 2>&1; rc=$?
{ [ "$rc" -eq 1 ] && [ ! -e "$FAKE/calls" ]; } && ok "нет токена в пакете → rc 1, ничего не отправлено" || bad "нет токена: rc $rc"
grep -F 'TG_TOKEN' "$TMP/o" >/dev/null && ok "причина названа" || bad "причина: $(cat "$TMP/o")"
TG_TOKEN_BULK="$TOKEN"; TG_CHAT_BULK=''
( PATH="$FAKE:$PATH"; apply_notify ) >"$TMP/o" 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "нет chat_id в пакете → rc 1" || bad "нет chat_id: rc $rc"
[ ! -e "$NOTIFY_CONF" ] && ok "конфиг не создан" || bad "конфиг создан без chat_id"

# сухой прогон: ничего не пишет, не отправляет, но токен обнуляется
# shellcheck disable=SC2034  # читает apply_notify
TG_TOKEN_BULK="$TOKEN"
# shellcheck disable=SC2034
TG_CHAT_BULK="$CHAT"
# shellcheck disable=SC2034
NOTIFY_EVENTS_BULK='ssh,ban,reboot'
ensure_pkg() { :; }
(
    PATH="$FAKE:$PATH"
    # shellcheck disable=SC2034
    USFC_DRY_RUN=true
    dry_run_enable
    apply_notify
) >"$TMP/o" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "dry-run: rc 0" || { bad "dry-run: rc $rc"; sed 's/^/      /' "$TMP/o"; }
{ [ ! -e "$NOTIFY_CONF" ] && [ ! -e "$NOTIFY_BIN" ]; } && ok "dry-run: файлы не созданы" || bad "dry-run создал файлы"
[ ! -e "$FAKE/calls" ] && ok "dry-run: curl не звали" || bad "dry-run отправил сообщение"
grep -F "$TOKEN" "$TMP/o" >/dev/null && bad "токен в выводе dry-run" || ok "токена нет в выводе dry-run"

echo ""
[ "$fail" -eq 0 ] && echo "уведомления Telegram: все проверки пройдены" || echo "уведомления Telegram: ЕСТЬ ОШИБКИ"
exit "$fail"
