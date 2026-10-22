#!/usr/bin/env bash
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

echo ""
[ "$fail" -eq 0 ] && echo "drop-in'ы sshd: все проверки пройдены" || echo "drop-in'ы sshd: ЕСТЬ ОШИБКИ"
exit "$fail"
