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
echo "созданные файлы: restore их удаляет"
new="$TMP/etc/sysctl.d/99-usfc.conf"
mkdir -p "${new%/*}"
printf 'a=1\n' | write_file "$new"
printf 'b=2\n' | append_file "$new"          # дописанный созданный — всё ещё созданный
grep -qxF "$new" "${USFC_BACKUP_DIR}/.usfc-created" && [ ! -e "${USFC_BACKUP_DIR}${new}" ] \
    && ok "записан в список созданных, копии нет" || bad "список: $(cat "${USFC_BACKUP_DIR}/.usfc-created" 2>/dev/null)"
[ "$(grep -c . "${USFC_BACKUP_DIR}/.usfc-created")" -eq 1 ] && ok "в списке один раз" || bad "повтор в списке"
out="$(USFC_ASSUME_YES=true backup_restore 20260101-000000-1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$new" ] && ok "restore удалил созданный файл" || bad "rc=$rc, файл остался: $(ls "$new" 2>&1)"
[ "$(cat "$f" 2>/dev/null)" = "исходный" ] && ok "и вернул изменённый" || bad ".bashrc: $(tr '\n' '|' < "$f")"
[[ "$out" == *"будут удалены"* ]] && ok "удаляемые показаны до подтверждения" || bad "список удаляемых не показан"
[ -f "${USFC_BACKUP_DIR}-restore${new}" ] && ok "удалённый попал в снимок отката отката" || bad "снимка удалённого нет"

echo ""
echo "sudo без пароля"
# shellcheck disable=SC2034  # читается в sudo_nopasswd_file
SUDOERS_DIR="$TMP/sudoers.d"
mkdir -p "$SUDOERS_DIR"
visudo() { [ "$1" = -cf ] && grep -qE '^[a-z_][a-z0-9_.-]* ALL=\(ALL\) NOPASSWD:ALL$' "$2"; }
sudo_nopasswd "first.last" >/dev/null 2>&1
[ -f "$SUDOERS_DIR/90-usfc-first_last" ] && ok "точка в имени файла заменена (sudo пропускает файлы с точкой)" \
    || bad "файлы: $(ls "$SUDOERS_DIR")"
grep -qx 'first.last ALL=(ALL) NOPASSWD:ALL' "$SUDOERS_DIR/90-usfc-first_last" 2>/dev/null && ok "правило на имя как есть" || bad "правило не то"
[ "$(stat -c %a "$SUDOERS_DIR/90-usfc-first_last" 2>/dev/null)" = 440 ] && ok "права 440" || bad "права $(stat -c %a "$SUDOERS_DIR/90-usfc-first_last")"
printf 'old ALL=(ALL) NOPASSWD:ALL\n' > "$SUDOERS_DIR/old"
sudo_nopasswd_set old && ok "файл до 5.0 (/etc/sudoers.d/<имя>) считается настроенным" || bad "старый файл не узнан"
visudo() { return 1; }
sudo_nopasswd "bad" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ ! -e "$SUDOERS_DIR/90-usfc-bad" ] && ok "visudo против — файла нет" || bad "rc=$rc"
unset -f visudo

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
