#!/usr/bin/env bash
# Смена порта SSH (пункт SSH hardening, флаг --ssh-port).
#
# Что ловим. Директива Port у sshd аддитивна: забытая `Port 22` в чужом
# файле оставляет старый порт открытым, а drop-in с одной `Port 2222` без
# `Port 22` закрывает старый сразу — мимо проверки входа. Поэтому проверяем:
# запись Port в наш drop-in, закомментирование чужих Port, признак «перенос
# не завершён», строку port в jail fail2ban, разбор правил UFW — и весь
# двухшаговый перенос на заглушках: шаг 1 оставляет оба порта, повторный
# запуск закрывает старый, третий ничего не делает, провал самопроверки
# откатывает всё.
#
# Внешние команды (sshd, systemctl, ufw, ss, ssh) подменены функциями,
# конфиги — настоящие файлы во временном каталоге. root не нужен.
set -uo pipefail
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SSHD_CONFIG_DIR="$TMP/ssh"
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"

# снимки write_file — во временный каталог, а не в /var/backups
# shellcheck disable=SC2034  # читается внутри backup_file из setup.sh
USFC_BACKUP_DIR="$TMP/backup"
FAIL2BAN_DROPIN="$TMP/jail.d/usfc-sshd.local"
# shellcheck disable=SC2034
USFC_LOG=/dev/null

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }
same() {   # same <имя> <ждали> <получили>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: ждали «$(printf '%s' "$2" | tr '\n' '|')», получили «$(printf '%s' "$3" | tr '\n' '|')»"; fi
}

D="$SSHD_CONFIG_DIR/sshd_config.d"
mkdir -p "$D" "$TMP/jail.d"
DROP="$USFC_SSHD_DROPIN"

# ── 1. drop-in: строки Port ─────────────────────────────────────────────────
echo "запись Port в наш drop-in"
rm -f "$DROP"
got="$(ssh_dropin_render 22 2222 | grep -v '^#')"
same "нового файла нет — только Port" $'Port 22\nPort 2222' "$got"

printf '%s\n' "# usfc: SSH hardening" "PermitRootLogin no" "PasswordAuthentication no" \
    "AllowUsers bob" "# usfc: port. old comment" "Port 22" "Port 2222" > "$DROP"
got="$(ssh_dropin_render 2222 | grep -v '^#')"
same "hardening и AllowUsers сохранены, порты заменены" \
    $'PermitRootLogin no\nPasswordAuthentication no\nAllowUsers bob\nPort 2222' "$got"
got="$(ssh_dropin_render | grep -ci '^port')"
same "без портов — строк Port нет" "0" "$got"

# ── 2. признак «перенос не завершён» ────────────────────────────────────────
echo ""
echo "перенос не завершён"
printf 'PasswordAuthentication no\nPort 22\nPort 2222\n' > "$DROP"
if ssh_port_pending; then
    same "два порта — перенос 22 → 2222" "22>2222" "${REPLY_SSH_PORT_FROM}>${REPLY_SSH_PORT_TO}"
else bad "два Port в drop-in не распознаны как незавершённый перенос"; fi
printf 'PasswordAuthentication no\nPort 2222\n' > "$DROP"
ssh_port_pending && bad "один Port — не перенос" || ok "один Port — переноса нет"
rm -f "$DROP"
ssh_port_pending && bad "нет файла — не перенос" || ok "нет drop-in — переноса нет"

# статус: «!» при двух портах, порт в «✓» при одном нестандартном
printf 'PasswordAuthentication no\nPort 22\nPort 2222\n' > "$DROP"
out="$(status_sshhardening)"; rc=$?
[[ "$out" == *"!"*"22 → 2222"* ]] && [ "$rc" -ne 0 ] && ok "статус: «!» и оба порта" || bad "статус при переносе: «$out» rc=$rc"
printf 'PasswordAuthentication no\nPort 2222\n' > "$DROP"
# shellcheck disable=SC2034  # читаются внутри status_sshhardening
SSH_PORT=2222 SSHD_PORTS=2222 SSHD_PASSWORDAUTH=no SSHD_PERMITROOT=no SSHD_PUBKEY=yes SSHD_KBDINTERACTIVE=no
out="$(status_sshhardening)"; rc=$?
[[ "$out" == *"✓"*"2222"* ]] && [ "$rc" -eq 0 ] && ok "статус: ✓ с портом 2222" || bad "статус после переноса: «$out» rc=$rc"

# ── 3. чужие Port и ListenAddress с портом ──────────────────────────────────
echo ""
echo "чужие Port"
cat > "$SSHD_CONFIG_DIR/sshd_config" <<EOF
Port 22
Include $D/*.conf
ListenAddress ::1
ListenAddress 0.0.0.0
EOF
printf 'Port 2200\n' > "$D/50-cloud.conf"
printf 'Port 9999\n' > "$DROP"          # наш — не чужой
ssh_foreign_ports
got="$(for r in "${REPLY_SSH_FOREIGN[@]}"; do IFS=$'\t' read -r f n p <<< "$r"; printf '%s:%s=%s ' "${f##*/}" "$n" "$p"; done)"
same "найдены и до, и после нашего файла; наш пропущен" "sshd_config:1=22 50-cloud.conf:1=2200 " "$got"
same "ListenAddress без порта — не помеха" "0" "${#REPLY_SSH_LISTEN_PORTED[@]}"
printf 'ListenAddress 0.0.0.0:2222\nListenAddress [::]:22\n' >> "$SSHD_CONFIG_DIR/sshd_config"
ssh_foreign_ports
same "ListenAddress с портом (IPv4 и [IPv6]) найдены" "2" "${#REPLY_SSH_LISTEN_PORTED[@]}"

echo ""
echo "закомментирование чужих Port и запись нашего drop-in"
cat > "$SSHD_CONFIG_DIR/sshd_config" <<EOF
Port 22
Include $D/*.conf
EOF
printf 'PasswordAuthentication no\n' > "$DROP"
_ssh_snap_reset
_ssh_set_ports 22 2222 >/dev/null 2>&1
same "sshd_config: Port закомментирован" $'# usfc: Port 22\nInclude '"$D"'/*.conf' "$(cat "$SSHD_CONFIG_DIR/sshd_config")"
same "50-cloud.conf: Port закомментирован" "# usfc: Port 2200" "$(cat "$D/50-cloud.conf")"
same "наш drop-in: hardening + оба порта" $'PasswordAuthentication no\nPort 22\nPort 2222' "$(grep -v '^#' "$DROP")"
_ssh_snap_restore
same "откат по снимку вернул sshd_config" $'Port 22\nInclude '"$D"'/*.conf' "$(cat "$SSHD_CONFIG_DIR/sshd_config")"
same "откат по снимку вернул drop-in" "PasswordAuthentication no" "$(cat "$DROP")"
_ssh_snap_reset

# ── 4. fail2ban ─────────────────────────────────────────────────────────────
echo ""
echo "строка port в jail fail2ban"
J="$TMP/jail.local"
printf '[DEFAULT]\nport = 1\n[sshd]\nenabled = true\nport = 22\nbackend = systemd\n' > "$J"
same "port в [sshd] заменён, в [DEFAULT] не тронут" \
    $'[DEFAULT]\nport = 1\n[sshd]\nenabled = true\nport = 22,2222\nbackend = systemd' "$(f2b_render_port "$J" 22,2222)"
printf '[sshd]\nenabled = true\n[other]\nport = 5\n' > "$J"
same "нет port в [sshd] — добавлен до следующей секции" \
    $'[sshd]\nenabled = true\nport = 2222\n[other]\nport = 5' "$(f2b_render_port "$J" 2222)"
printf '[sshd]\nenabled = true\n' > "$J"
same "нет port, [sshd] последняя — добавлен в конец" $'[sshd]\nenabled = true\nport = 2222' "$(f2b_render_port "$J" 2222)"

# ── 5. правила UFW ──────────────────────────────────────────────────────────
echo ""
echo "правила UFW для порта"
UFW_OUT='Status: active

To                         Action      From
--                         ------      ----
OpenSSH                    ALLOW       Anywhere
22/tcp                     ALLOW       Anywhere
2222/tcp                   ALLOW       Anywhere
22                         ALLOW       10.0.0.0/8
22/tcp                     LIMIT       Anywhere
OpenSSH (v6)               ALLOW       Anywhere (v6)
22/tcp (v6)                ALLOW       Anywhere (v6)'
ufw_port_rules 22 "$UFW_OUT"
same "для 22: OpenSSH и 22/tcp; с адреса и LIMIT — нет; v6 не дублируется" "OpenSSH 22/tcp" "${REPLY_UFW_RULES[*]}"
ufw_port_rules 2222 "$UFW_OUT"
same "для 2222 — только 2222/tcp" "2222/tcp" "${REPLY_UFW_RULES[*]}"
ufw_port_rules 3333 "$UFW_OUT"
same "для 3333 — ничего" "0" "${#REPLY_UFW_RULES[@]}"

# ── 6. весь перенос на заглушках ────────────────────────────────────────────
# Модель: sshd -T отдаёт порты из нашего drop-in (или 22, если их нет);
# «слушается» то, что было в конфиге на момент последнего рестарта.
# Вход по ключу проходит на любой слушаемый порт, кроме BROKEN
LISTEN='22'; BROKEN=''; F2B_RESTARTS=0
_cfg_ports() {
    ssh_dropin_scan
    if [ "${#REPLY_SSH_DROPIN_PORTS[@]}" -gt 0 ]; then printf '%s' "${REPLY_SSH_DROPIN_PORTS[*]}"; else printf '22'; fi
}
sshd() {
    case "${1:-}" in
        -T) local p; for p in $(_cfg_ports); do printf 'port %s\n' "$p"; done
            printf 'passwordauthentication no\npermitrootlogin no\npubkeyauthentication yes\nkbdinteractiveauthentication no\n' ;;
        -t) return 0 ;;
    esac
}
systemctl() {
    case "$*" in
        "restart ssh") LISTEN="$(_cfg_ports)" ;;
        "is-active --quiet fail2ban") return 0 ;;
        "restart fail2ban") F2B_RESTARTS=$((F2B_RESTARTS + 1)) ;;
        is-active*|is-enabled*) return 1 ;;   # ssh.socket нет — Debian-вариант
    esac
    return 0
}
ss() { local p="$*"; p="${p##*:}"; p="${p%% *}"; [[ " $LISTEN " == *" $p "* ]] && echo "LISTEN 0 128 0.0.0.0:$p 0.0.0.0:*"; return 0; }
# правила UFW — в файле: _fw_ufw зовёт ufw через $(…), то есть в подоболочке
UFW_FILE="$TMP/ufw_rules"
ufw() {
    local r rules
    rules="$(cat "$UFW_FILE")"
    case "$1" in
        status) printf 'Status: active\n\nTo Action From\n-- ------ ----\n'
                for r in $rules; do printf '%s ALLOW Anywhere\n' "$r"; done ;;
        allow)  printf '%s %s' "$rules" "$2" > "$UFW_FILE" ;;
        delete) rules=" $rules "; rules="${rules// $3 / }"; printf '%s' "$rules" > "$UFW_FILE" ;;
    esac
}
ufw_rules_now() { local r; r="$(cat "$UFW_FILE")"; echo $r; }   # нормализованный список
ssh_selftest_begin() { :; }
ssh_selftest_end() { :; }
ssh_selftest() { [ "$1" != "$BROKEN" ] && [[ " $LISTEN " == *" $1 "* ]]; }
sleep() { :; }
hostname() { echo 203.0.113.5; }

reset_world() {
    cat > "$SSHD_CONFIG_DIR/sshd_config" <<EOF
Port 22
Include $D/*.conf
EOF
    rm -f "$D/50-cloud.conf"
    printf 'PasswordAuthentication no\n' > "$DROP"
    printf '[sshd]\nenabled = true\nport = 22\n' > "$FAIL2BAN_DROPIN"
    LISTEN='22'; BROKEN=''; F2B_RESTARTS=0
    printf 'OpenSSH 22/tcp' > "$UFW_FILE"
    refresh_sshd_config
}

echo ""
echo "перенос без терминала: шаг 1, повтор — шаг 2, ещё повтор — ничего"
# shellcheck disable=SC2034  # читается внутри ssh_port_change
BULK_MODE=true
reset_world
# не через $(…): подоболочка унесла бы состояние заглушек (LISTEN, F2B_RESTARTS)
ssh_port_change 2222 > "$TMP/log1" 2>&1; rc=$?; log1="$(cat "$TMP/log1")"
same "шаг 1: код 0" "0" "$rc"
same "шаг 1: слушаются оба порта" "22 2222" "$LISTEN"
same "шаг 1: drop-in с двумя Port" $'Port 22\nPort 2222' "$(grep '^Port' "$DROP")"
same "шаг 1: Port в sshd_config закомментирован" "# usfc: Port 22" "$(head -1 "$SSHD_CONFIG_DIR/sshd_config")"
same "шаг 1: UFW разрешил 2222/tcp, старые правила на месте" "OpenSSH 22/tcp 2222/tcp" "$(ufw_rules_now)"
same "шаг 1: fail2ban сторожит оба" "port = 22,2222" "$(grep '^port' "$FAIL2BAN_DROPIN")"
[ "$F2B_RESTARTS" -ge 1 ] && ok "шаг 1: fail2ban перезапущен" || bad "шаг 1: fail2ban не перезапущен"
[[ "$log1" == *"--ssh-port 2222"* ]] && ok "шаг 1: подсказка, как завершить" || bad "нет подсказки про повторный запуск"
ssh_port_pending && ok "шаг 1: перенос помечен незавершённым" || bad "перенос не виден как незавершённый"

ssh_port_change 2222 >/dev/null 2>&1; rc=$?
same "шаг 2: код 0" "0" "$rc"
same "шаг 2: слушается только 2222" "2222" "$LISTEN"
same "шаг 2: в drop-in один Port" "Port 2222" "$(grep '^Port' "$DROP")"
same "шаг 2: UFW — OpenSSH и 22/tcp сняты" "2222/tcp" "$(ufw_rules_now)"
same "шаг 2: fail2ban — только новый" "port = 2222" "$(grep '^port' "$FAIL2BAN_DROPIN")"
same "шаг 2: SSH_PORT обновлён" "2222" "$SSH_PORT"
ssh_port_pending && bad "после шага 2 перенос всё ещё «не завершён»" || ok "шаг 2: перенос завершён"

ssh_port_change 2222 > "$TMP/log3" 2>&1; rc=$?; log3="$(cat "$TMP/log3")"
[ "$rc" -eq 0 ] && [[ "$log3" == *2222* ]] && [ "$LISTEN" = 2222 ] && ok "повтор: «уже на порту», ничего не тронуто" || bad "повтор: rc=$rc, $log3"

echo ""
echo "в меню: старый порт закрывается только после «да»"
# shellcheck disable=SC2034
BULK_MODE=false
reset_world
ask_yn_t() { return 1; }
ssh_port_change 2222 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$LISTEN" = "22 2222" ] && ok "ответ «нет» — оба порта остаются" || bad "«нет»: rc=$rc, слушается «$LISTEN»"
ask_yn_t() { return 0; }
ssh_port_change 2222 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$LISTEN" = "2222" ] && ok "повторный выбор и «да» — старый закрыт" || bad "«да»: rc=$rc, слушается «$LISTEN»"
reset_world
ssh_port_change 2222 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$LISTEN" = "2222" ] && ok "сразу «да» — перенос за один заход" || bad "один заход: rc=$rc, слушается «$LISTEN»"
unset -f ask_yn_t
# shellcheck disable=SC2034
BULK_MODE=true

echo ""
echo "провал самопроверки — полный откат"
reset_world
before_cfg="$(cat "$SSHD_CONFIG_DIR/sshd_config")"; before_drop="$(cat "$DROP")"; before_f2b="$(cat "$FAIL2BAN_DROPIN")"
BROKEN=2222
ssh_port_change 2222 >/dev/null 2>&1; rc=$?
same "код 1" "1" "$rc"
same "sshd_config вернулся" "$before_cfg" "$(cat "$SSHD_CONFIG_DIR/sshd_config")"
same "drop-in вернулся" "$before_drop" "$(cat "$DROP")"
same "fail2ban вернулся" "$before_f2b" "$(cat "$FAIL2BAN_DROPIN")"
same "добавленное правило UFW снято" "OpenSSH 22/tcp" "$(ufw_rules_now)"
same "слушается снова только 22" "22" "$LISTEN"

echo ""
echo "проверки до изменений"
reset_world
LISTEN='22 8080'
ssh_port_change 8080 >/dev/null 2>&1 && bad "занятый порт принят" || ok "порт, занятый другим процессом, отвергнут"
same "…и ничего не изменилось" "Port 22" "$(head -1 "$SSHD_CONFIG_DIR/sshd_config")"
reset_world
ssh_port_change 80 >/dev/null 2>&1 && bad "порт 80 принят" || ok "порт ниже 1024 (кроме 22) отвергнут"
printf 'ListenAddress 0.0.0.0:22\n' >> "$SSHD_CONFIG_DIR/sshd_config"
ssh_port_change 2222 >/dev/null 2>&1 && bad "ListenAddress с портом не остановил перенос" || ok "ListenAddress с портом — перенос не начат"

echo ""
echo "сухой прогон: ничего не меняется"
reset_world
# shellcheck disable=SC2034  # читается внутри write_file и ssh_port_change
USFC_DRY_RUN=true
before_cfg="$(cat "$SSHD_CONFIG_DIR/sshd_config")"; before_drop="$(cat "$DROP")"
ssh_port_change 2222 >/dev/null 2>&1; rc=$?
# shellcheck disable=SC2034
USFC_DRY_RUN=false
same "код 0" "0" "$rc"
same "sshd_config не тронут" "$before_cfg" "$(cat "$SSHD_CONFIG_DIR/sshd_config")"
same "drop-in не тронут" "$before_drop" "$(cat "$DROP")"

echo ""
[ "$fail" -eq 0 ] && echo "смена порта SSH: все проверки пройдены" || echo "смена порта SSH: ЕСТЬ ОШИБКИ"
exit "$fail"
