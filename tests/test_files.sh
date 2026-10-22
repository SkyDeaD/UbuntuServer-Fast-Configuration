#!/usr/bin/env bash
# Запись файлов: снимок, вырезание блоков, дозапись ключей, метка отката.
#
# Каждая проверка — найденная ревью поломка 4.x:
#   • снимок перезаписывался на каждой записи, и `restore` возвращал файл
#     уже с нашими правками (.bashrc за прогон трогают три пункта);
#   • блоки .bashrc вырезались `sed -i` мимо снимка, а без строки-конца —
#     до конца файла;
#   • ключ дописывался к последней строке authorized_keys без перевода строки;
#   • `restore ..` принимался за метку.
set -uo pipefail
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"
# shellcheck disable=SC2034  # читаются в log_* и backup_file
USFC_NO_COLOR=true

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck disable=SC2034
USFC_BACKUP_ROOT="$TMP/backups"
USFC_BACKUP_DIR="$TMP/backups/20260101-000000-1"

echo "снимок: первая копия за прогон — единственная"
f="$TMP/home/.bashrc"
mkdir -p "${f%/*}"
printf 'исходный\n' > "$f"
printf 'правка 1\n' | append_file "$f"
printf 'правка 2\n' | append_file "$f"
[ "$(cat "${USFC_BACKUP_DIR}${f}")" = "исходный" ] && ok "в снимке исходный файл, а не предпоследняя правка" \
    || bad "в снимке: $(tr '\n' '|' < "${USFC_BACKUP_DIR}${f}")"

echo ""
echo "remove_block"
printf 'до\n# >>> vps-setup:cli >>>\nalias x=y\n# <<< vps-setup:cli <<<\nпосле\n' > "$f"
remove_block "$f" vps-setup:cli
[ "$(cat "$f")" = $'до\nпосле' ] && ok "блок вырезан, остальное на месте" || bad "получили: $(tr '\n' '|' < "$f")"
remove_block "$f" vps-setup:cli; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$f")" = $'до\nпосле' ] && ok "нет блока — ничего не делает" || bad "rc=$rc"
printf 'до\n# >>> vps-setup:cli >>>\nalias x=y\nважное\n' > "$f"
remove_block "$f" vps-setup:cli >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -qx 'важное' "$f" && ok "нет строки-конца — файл не тронут, код 1" || bad "rc=$rc, файл: $(tr '\n' '|' < "$f")"
printf 'a\n# >>> vps-setup:self >>>\nx\n# <<< vps-setup:self <<<\n' > "$f"
(
    # shellcheck disable=SC2034
    USFC_DRY_RUN=true
    remove_block "$f" vps-setup:self >/dev/null
)
grep -qF 'vps-setup:self' "$f" && ok "сухой прогон файл не меняет" || bad "сухой прогон вырезал блок"

echo ""
echo "authkeys_add"
k="$TMP/authorized_keys"
printf 'ssh-ed25519 AAAA1 old' > "$k"           # без перевода строки в конце
authkeys_add "$k" "ssh-ed25519 AAAA2 new"
[ "$(wc -l < "$k")" -eq 2 ] && grep -qx 'ssh-ed25519 AAAA1 old' "$k" && grep -qx 'ssh-ed25519 AAAA2 new' "$k" \
    && ok "ключ на своей строке, старый цел" || bad "получили: $(od -c "$k" | head -3)"
: > "$k"
authkeys_add "$k" "ssh-ed25519 AAAA3 x"
[ "$(cat "$k")" = "ssh-ed25519 AAAA3 x" ] && [ "$(head -c1 "$k")" = "s" ] && ok "в пустой файл — без лишней пустой строки" \
    || bad "получили: $(od -c "$k" | head -2)"

echo ""
echo "метка снимка в restore"
for s in .. . ../.. 'x; rm' 2026 20260101-000000; do
    out="$(backup_restore "$s" 2>&1 </dev/null)"; rc=$?
    if [ "$rc" -ne 1 ] || [[ "$out" != *"не похожа на снимок"* ]]; then bad "«$s» принят (rc=$rc)"; continue; fi
done
[ "$fail" -eq 0 ] && ok "кривые метки отвергнуты до обращения к диску"

echo ""
[ "$fail" -eq 0 ] && echo "запись файлов: все проверки пройдены" || echo "запись файлов: ЕСТЬ ОШИБКИ"
exit "$fail"
