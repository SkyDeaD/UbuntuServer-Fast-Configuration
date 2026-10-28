#!/usr/bin/env bash
# Функции приходят из src/setup.sh, а ниже их подменяют заглушками — SC2218 ложный.
# shellcheck disable=SC2218
# Чужие drop-in'ы sshd, которые перебивают hardening.
#
# Жалоба была ровно на это: у провайдера лежал /etc/ssh/sshd_config.d/00-*.conf
# с `PasswordAuthentication yes`. sshd берёт ПЕРВОЕ значение ключа, а наш файл
# назывался 10-hardening.conf и читался позже — вход по паролю молча оставался.
# Self-test этого не видел: вход по ключу при этом работал.
#
# Проверяем порядок чтения (sshd_config до Include → drop-in'ы по алфавиту →
# наш файл → остальное), поиск конфликтов и закомментирование ровно нужных
# строк. Работаем на настоящих файлах во временном каталоге: sshd не нужен.
set -uo pipefail
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SSHD_CONFIG_DIR="$TMP/ssh"
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }

mkdir -p "$SSHD_CONFIG_DIR/sshd_config.d"
D="$SSHD_CONFIG_DIR/sshd_config.d"

# conflict_keys — ключи найденных конфликтов через пробел, по порядку
conflict_keys() {
    local rec out="" f n k
    for rec in "${REPLY_SSHD_CONFLICTS[@]}"; do
        IFS=$'\t' read -r f n k _ <<< "$rec"
        out="${out}${out:+ }${k}@${f##*/}:${n}"
    done
    printf '%s' "$out"
}
expect() {
    local name="$1" want="$2" got
    got="$(conflict_keys)"
    if [ "$got" = "$want" ]; then ok "$name"; else bad "$name: ждали «$want», получили «$got»"; fi
}

# ── 1. Ubuntu по умолчанию: Include сверху, конфликтов нет ──────────────────
echo "чистый Ubuntu"
cat > "$SSHD_CONFIG_DIR/sshd_config" <<EOF
Include $D/*.conf
#PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
EOF
sshd_conflicts
[ "$REPLY_SSHD_INCLUDED" = true ] && ok "каталог drop-in'ов подключён" || bad "Include не распознан"
expect "конфликтов нет" ""

# ── 2. ровно жалоба: 00-provider.conf с паролем ─────────────────────────────
echo ""
echo "00-provider.conf с PasswordAuthentication yes"
printf 'PasswordAuthentication yes\n' > "$D/00-provider.conf"
sshd_conflicts
expect "найден файл провайдера" "passwordauthentication@00-provider.conf:1"

# 50-cloud-init.conf читается ПОСЛЕ нашего 00-usfc-… — он нам не мешает
printf 'PasswordAuthentication yes\n' > "$D/50-cloud-init.conf"
sshd_conflicts
expect "50-cloud-init.conf не считается конфликтом" "passwordauthentication@00-provider.conf:1"

# ── 3. 00-a.conf сортируется раньше нашего 00-usfc — тоже конфликт ──────────
echo ""
echo "имя раньше нашего по алфавиту"
rm -f "$D/00-provider.conf"
printf '# comment\n  PermitRootLogin   yes\n' > "$D/00-a.conf"
sshd_conflicts
expect "00-a.conf найден, с номером строки и отступом" "permitrootlogin@00-a.conf:2"

# совпадающее значение конфликтом не является
printf 'PermitRootLogin no\n' > "$D/00-a.conf"
sshd_conflicts
expect "совпадающее значение — не конфликт" ""

# ── 4. значение в sshd_config ДО Include и старое имя ключа ─────────────────
echo ""
echo "главный конфиг до Include"
cat > "$SSHD_CONFIG_DIR/sshd_config" <<EOF
ChallengeResponseAuthentication yes
PasswordAuthentication=yes
Include $D/*.conf
PermitRootLogin yes
EOF
sshd_conflicts
expect "до Include — конфликт, после — нет; старое имя ключа понято" \
    "kbdinteractiveauthentication@sshd_config:1 passwordauthentication@sshd_config:2"

# ── 5. Match-блок не глобальный ─────────────────────────────────────────────
echo ""
echo "Match-блок"
cat > "$SSHD_CONFIG_DIR/sshd_config" <<EOF
Match User backup
    PasswordAuthentication yes
Include $D/*.conf
EOF
sshd_conflicts
expect "строки внутри Match не считаются" ""

# ── 6. Include нет вовсе ────────────────────────────────────────────────────
echo ""
echo "нет Include"
printf 'PasswordAuthentication no\n' > "$SSHD_CONFIG_DIR/sshd_config"
sshd_conflicts
[ "$REPLY_SSHD_INCLUDED" = false ] && ok "отсутствие Include замечено" || bad "Include «найден», хотя его нет"

# ── 7. закомментирование трогает только нужные строки ──────────────────────
echo ""
echo "закомментирование"
printf 'Port 2222\nPasswordAuthentication yes\nX11Forwarding no\nPermitRootLogin yes\n' > "$D/00-x.conf"
sshd_comment_lines "$D/00-x.conf" 2 4 >/dev/null 2>&1
want=$'Port 2222\n# usfc: PasswordAuthentication yes\nX11Forwarding no\n# usfc: PermitRootLogin yes'
if [ "$(cat "$D/00-x.conf")" = "$want" ]; then ok "закомментированы ровно строки 2 и 4"; else
    bad "результат: $(cat "$D/00-x.conf" | tr '\n' '|')"; fi

# ── 8. authorized_keys: подсчёт ключей и временный ключ самопроверки ────────
echo ""
echo "authorized_keys"
# Переменные ниже читаются внутри backup_file и ssh_selftest_end
# shellcheck disable=SC2034
USFC_BACKUP_DIR="$TMP/backup"
# shellcheck disable=SC2034
USFC_LOG=/dev/null
# shellcheck disable=SC2034
TARGET_USER="$(id -un)"
# shellcheck disable=SC2034
SSH_TEST_GID="$(id -g)"
AK="$TMP/authorized_keys"
REAL='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIRealKeyRealKeyRealKeyRealKey me@laptop'
printf '# только комментарий\n\n' > "$AK"
authkeys_count "$AK"
[ "$REPLY_AUTHKEYS_COUNT" = 0 ] && ok "файл из комментариев — 0 ключей" || bad "комментарии посчитаны как $REPLY_AUTHKEYS_COUNT ключ(а)"
printf '# ssh-ed25519 AAAAold\nrestrict,from="10.0.0.1" %s\n%s\n' "$REAL" "$REAL" > "$AK"
authkeys_count "$AK"
[ "$REPLY_AUTHKEYS_COUNT" = 2 ] && ok "ключ с опциями посчитан, закомментированный — нет" || bad "посчитано $REPLY_AUTHKEYS_COUNT вместо 2"

# ровно находка ревью: последний ключ без перевода строки
printf '%s' "$REAL" > "$AK"
SSH_TEST_DIR="$(mktemp -d)"; SSH_TEST_AUTH="$AK"
SSH_TEST_PUB='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITempKeyTempKeyTempKeyTempKey usfc-selftest'
authkeys_add "$SSH_TEST_AUTH" "$SSH_TEST_PUB" >/dev/null 2>&1
same_lines="$(grep -cxF "$SSH_TEST_PUB" "$AK")"
[ "$same_lines" = 1 ] && ok "временный ключ лёг отдельной строкой" || bad "временный ключ склеился: $(tr '\n' '|' < "$AK")"
ssh_selftest_end >/dev/null 2>&1
[ "$(cat "$AK")" = "$REAL" ] && ok "после самопроверки настоящий ключ на месте" || bad "authorized_keys после самопроверки: «$(tr '\n' '|' < "$AK")»"

# строка, где временный ключ — лишь часть, не удаляется
# shellcheck disable=SC2034
SSH_TEST_DIR="$(mktemp -d)"; SSH_TEST_PUB="$REAL"
printf 'command="x" %s\n' "$REAL" > "$AK"
ssh_selftest_end >/dev/null 2>&1
[ -s "$AK" ] && ok "удаляется только строка, равная ключу целиком" || bad "удалена чужая строка с ключом внутри"

echo ""
echo "аудит: без Include конфликта drop-in'ов нет"
printf 'PasswordAuthentication yes\nPermitRootLogin yes\n' > "$SSHD_CONFIG_DIR/sshd_config"
saved_audit="$(declare -f _audit_t)"
sshd() { printf 'passwordauthentication yes\npermitrootlogin yes\n'; }
systemctl() { return 1; }
_audit_t() { echo "$1 $2"; }
out="$(audit_ssh 2>&1)"
[[ "$out" == *"ssh.dropin_order"* ]] && bad "без Include аудит пишет «перебивает hardening»" || ok "без Include — нет ложного «перебивает hardening»"
[[ "$out" == *"ssh.password_auth warn"* ]] && ok "вход по паролю по-прежнему замечен" || bad "аудит пропустил пароль: $out"
printf 'Include %s/*.conf\n' "$D" > "$SSHD_CONFIG_DIR/sshd_config"
printf 'PasswordAuthentication yes\n' > "$D/00-provider.conf"
out="$(audit_ssh 2>&1)"
[[ "$out" == *"ssh.dropin_order warn"* ]] && ok "с Include настоящий конфликт виден" || bad "конфликт с Include не замечен: $out"
rm -f "$D/00-provider.conf"
unset -f sshd systemctl
eval "$saved_audit"

# ── 9. откат hardening берёт СВОЙ снимок, а не первый за прогон ─────────────
# backup_file хранит первую запись за прогон (в меню — за сессию). Если до
# hardening в той же сессии уже переносили порт, снимок прогона содержит
# старую строку Port; откат hardening не должен её возвращать.
# apply_sshhardening гоняем на заглушках до первого провала самопроверки
echo ""
echo "откат hardening: снимок перед правкой, а не снимок прогона"
SELFTEST_BEGIN_CALLS=0
ask_yn_t() { case "$1" in "Настроить SSH hardening"*|"Закомментировать"*) return 0 ;; *) return 1 ;; esac; }
# shellcheck disable=SC2034  # читается в apply_sshhardening
ensure_ssh_dir() { REPLY_AUTHKEYS="$TMP/ak9"; return 0; }
# shellcheck disable=SC2034
_ssh_key_users() { REPLY_SSH_KEY_USERS=(); }
ssh_selftest_begin() { SELFTEST_BEGIN_CALLS=$((SELFTEST_BEGIN_CALLS + 1)); return 0; }
ssh_selftest() { return 1; }          # «вход по ключу не проходит» → ранний откат
ssh_selftest_end() { return 0; }
sshd() { return 0; }
# shellcheck disable=SC2034  # читаются внутри apply_sshhardening
TARGET_USER=testuser
# shellcheck disable=SC2034
BULK_MODE=false
# shellcheck disable=SC2034
USFC_DRY_RUN=false
SSHCFG="$SSHD_CONFIG_DIR/sshd_config"
rm -f "$D"/*.conf "$USFC_SSHD_DROPIN"

# снимок прогона: sshd_config ещё со старым портом
mkdir -p "$USFC_BACKUP_DIR${SSHD_CONFIG_DIR}"
printf 'Port 22\nPasswordAuthentication yes\nInclude %s/*.conf\n' "$D" > "$USFC_BACKUP_DIR${SSHCFG}"
# …затем порт перенесли: файл изменился уже после снимка прогона
printf 'Port 2222\nPasswordAuthentication yes\nInclude %s/*.conf\n' "$D" > "$SSHCFG"
before_cfg="$(cat "$SSHCFG")"
printf '%s\n' "$REAL" > "$TMP/ak9"
apply_sshhardening >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "самопроверка провалилась — код 1" || bad "код $rc вместо 1"
[ "$SELFTEST_BEGIN_CALLS" -eq 1 ] && ok "дошли до самопроверки (правка конфига была)" || bad "самопроверка не вызывалась"
if [ "$(cat "$SSHCFG")" = "$before_cfg" ]; then ok "sshd_config вернулся к состоянию ПЕРЕД hardening (Port 2222)"; else
    bad "sshd_config после отката: $(tr '\n' '|' < "$SSHCFG")"; fi
[ ! -e "$USFC_SSHD_DROPIN" ] && ok "наш drop-in не создан" || bad "drop-in остался после отката"
[ -z "$SSH_PORT_SNAP" ] && ok "каталог снимков убран" || bad "каталог снимков не удалён: $SSH_PORT_SNAP"

# authorized_keys из одних комментариев: прерываемся ДО самопроверки и
# до отключения пароля (ключи считаем, а не размер файла), конфиг на месте
echo ""
echo "hardening: в authorized_keys нет ключей — пароль не выключается"
SELFTEST_BEGIN_CALLS=0
printf '# только комментарий\n\n' > "$TMP/ak9"
printf 'PasswordAuthentication yes\nInclude %s/*.conf\n' "$D" > "$SSHCFG"
before_cfg="$(cat "$SSHCFG")"
apply_sshhardening >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "код 1" || bad "код $rc вместо 1"
[ "$SELFTEST_BEGIN_CALLS" -eq 0 ] && ok "самопроверка не запускалась" || bad "дошли до самопроверки без ключей"
[ ! -e "$USFC_SSHD_DROPIN" ] && ok "drop-in с PasswordAuthentication no не записан" || bad "drop-in записан при пустом authorized_keys"
[ "$(cat "$SSHCFG")" = "$before_cfg" ] && ok "sshd_config возвращён" || bad "sshd_config остался изменённым: $(tr '\n' '|' < "$SSHCFG")"

# Ctrl+C посреди hardening: откат всего, что успело измениться. Гоняем в
# подоболочке — обработчик делает exit 130. Прерывание шлём из заглушки
# ssh_selftest: первая — до записи drop-in, вторая — после рестарта sshd
echo ""
echo "hardening: Ctrl+C откатывает конфиги"
printf '%s\n' "$REAL" > "$TMP/ak9"
hard_int_case() {   # $1 — на каком вызове ssh_selftest прерывать
    INT_AT="$1"; SELFTEST_N=0
    printf 'PasswordAuthentication yes\nInclude %s/*.conf\n' "$D" > "$SSHCFG"
    before_cfg="$(cat "$SSHCFG")"
    rm -f "$USFC_SSHD_DROPIN" "$TMP/systemctl.log"
    (
        trap 'echo outer >> "$TMP/systemctl.log"' INT
        ssh_selftest() { SELFTEST_N=$((SELFTEST_N + 1)); [ "$SELFTEST_N" -eq "$INT_AT" ] && kill -INT "$BASHPID"; return 0; }
        systemctl() { echo "$*" >> "$TMP/systemctl.log"; return 0; }
        sleep() { :; }
        apply_sshhardening >/dev/null 2>&1
        echo "не прервалось" >> "$TMP/systemctl.log"
    ); rc=$?
}
hard_int_case 1
[ "$rc" -eq 130 ] && ok "до drop-in: код 130" || bad "до drop-in: код $rc вместо 130"
[ "$(cat "$SSHCFG")" = "$before_cfg" ] && ok "до drop-in: sshd_config возвращён" || bad "до drop-in: sshd_config $(tr '\n' '|' < "$SSHCFG")"
[ ! -e "$USFC_SSHD_DROPIN" ] && ok "до drop-in: drop-in нет" || bad "до drop-in: drop-in появился"
hard_int_case 2
[ "$rc" -eq 130 ] && ok "после рестарта: код 130" || bad "после рестарта: код $rc вместо 130"
[ "$(cat "$SSHCFG")" = "$before_cfg" ] && ok "после рестарта: sshd_config возвращён" || bad "после рестарта: sshd_config $(tr '\n' '|' < "$SSHCFG")"
[ ! -e "$USFC_SSHD_DROPIN" ] && ok "после рестарта: наш drop-in убран" || bad "после рестарта: drop-in остался"
[ "$(grep -c '^restart ssh$' "$TMP/systemctl.log" 2>/dev/null)" = 2 ] && ok "после рестарта: sshd перезапущен на возвращённом конфиге" \
    || bad "после рестарта: рестартов ssh $(grep -c '^restart ssh$' "$TMP/systemctl.log" 2>/dev/null) вместо 2"
# обычный выход (самопроверка не прошла) возвращает прежний trap
after_trap="$(
    trap 'echo outer' INT
    ssh_selftest() { return 1; }
    apply_sshhardening >/dev/null 2>&1
    trap -p INT
)"
[[ "$after_trap" == *"echo outer"* ]] && ok "после выхода прежний trap INT на месте" || bad "trap INT после выхода: ${after_trap:-пусто}"
unset -f ask_yn_t ensure_ssh_dir _ssh_key_users ssh_selftest_begin ssh_selftest ssh_selftest_end sshd

echo ""
[ "$fail" -eq 0 ] && echo "drop-in'ы sshd: все проверки пройдены" || echo "drop-in'ы sshd: ЕСТЬ ОШИБКИ"
exit "$fail"
