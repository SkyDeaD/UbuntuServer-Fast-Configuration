#!/usr/bin/env bash
# Приоритет свопа в /etc/fstab: «иногда не пишется».
#
# Жалоба была ровно на это. До 5.0 приоритет ставил sed, понимавший одну форму
# строки — `<путь> none swap sw …`. `defaults`, `sw,nofail`, уже стоящий
# `pri=5`, точка монтирования `swap`, UUID=/LABEL= у разделов молча не
# менялись, а `swap swap` портился в `sw,pri=10ap`. Пункт при этом печатал
# «приоритет 10», и после перезагрузки своп поднимался с -2.
#
# Проверяем разбор по полям на таблице входов: что стало с fstab, нет ли
# дублей, и что повторный прогон ничего не меняет. Плюс правка
# /etc/default/zramswap на месте вместо перезаписи. Файлы настоящие, во
# временном каталоге; подменён только blkid.
set -uo pipefail
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export USFC_FSTAB="$TMP/fstab"
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"
# shellcheck disable=SC2034  # читается в write_file
USFC_DRY_RUN=false
backup_file() { :; }        # снимки проверяет test_backup.sh, здесь они мешают

# UUID есть у раздела и у swap-файла (mkswap пишет его и в файл)
blkid() {
    local dev="${*: -1}" what=""
    case "$*" in *UUID*) what=uuid ;; *LABEL*) what=label ;; esac
    case "$dev:$what" in
        /dev/vda2:uuid)  echo "1111-aaaa" ;;
        /dev/vda2:label) echo "SWAP" ;;
        /swapfile:uuid)  echo "2222-bbbb" ;;
    esac
}

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }

# case <имя> <путь> <вход> <ожидаемый выход>
check() {
    local name="$1" path="$2" input="$3" want="$4" got
    printf '%s\n' "$input" > "$USFC_FSTAB"
    fstab_set_swap_pri "$path" 10 >/dev/null 2>&1
    got="$(cat "$USFC_FSTAB")"
    if [ "$got" = "$want" ]; then ok "$name"; else
        bad "$name"; printf '      ждали: %s\n      вышло: %s\n' "${want//$'\n'/ | }" "${got//$'\n'/ | }"; fi
    # повторный прогон — без изменений
    fstab_set_swap_pri "$path" 10 >/dev/null 2>&1
    [ "$(cat "$USFC_FSTAB")" = "$want" ] || bad "$name: повторный прогон изменил fstab"
}

ROOT='UUID=0000 / ext4 defaults 0 1'

echo "формы строк для swap-файла"
check "sw → sw,pri=10" /swapfile \
    "$ROOT"$'\n''/swapfile none swap sw 0 0' \
    "$ROOT"$'\n''/swapfile none swap sw,pri=10 0 0'
check "defaults → defaults,pri=10" /swapfile \
    "$ROOT"$'\n''/swapfile none swap defaults 0 0' \
    "$ROOT"$'\n''/swapfile none swap defaults,pri=10 0 0'
check "sw,nofail сохраняет nofail" /swapfile \
    '/swapfile none swap sw,nofail 0 0' \
    '/swapfile none swap sw,nofail,pri=10 0 0'
check "pri=5 заменяется, а не дублируется" /swapfile \
    '/swapfile none swap sw,pri=5 0 0' \
    '/swapfile none swap sw,pri=10 0 0'
check "pri=-2 посередине опций" /swapfile \
    '/swapfile none swap pri=-2,discard 0 0' \
    '/swapfile none swap discard,pri=10 0 0'
check "точка монтирования swap (sed превращал в sw,pri=10ap)" /swapfile \
    '/swapfile swap swap swap 0 0' \
    '/swapfile swap swap swap,pri=10 0 0'
check "табы и ведущие пробелы" /swapfile \
    $'  /swapfile\tnone\tswap\tsw\t0\t0' \
    '/swapfile none swap sw,pri=10 0 0'
check "без полей dump/pass" /swapfile \
    '/swapfile none swap sw' \
    '/swapfile none swap sw,pri=10 0 0'

echo ""
echo "строки нет и дубли"
check "строки нет — добавляется" /swapfile \
    "$ROOT" \
    "$ROOT"$'\n''/swapfile none swap sw,pri=10 0 0'
check "дубль комментируется (своп смонтировался бы дважды)" /swapfile \
    '/swapfile none swap sw 0 0'$'\n''/swapfile none swap defaults 0 0' \
    '/swapfile none swap sw,pri=10 0 0'$'\n''# usfc: duplicate swap entry: /swapfile none swap defaults 0 0'
check "комментарий с тем же путём не трогается" /swapfile \
    '# /swapfile none swap sw 0 0'$'\n''/swapfile none swap sw 0 0' \
    '# /swapfile none swap sw 0 0'$'\n''/swapfile none swap sw,pri=10 0 0'
check "чужой своп не трогается" /swapfile \
    '/swap.img none swap sw 0 0' \
    '/swap.img none swap sw 0 0'$'\n''/swapfile none swap sw,pri=10 0 0'
check "не-swap строка с тем же путём не трогается" /swapfile \
    '/swapfile /mnt/x ext4 defaults 0 0' \
    '/swapfile /mnt/x ext4 defaults 0 0'$'\n''/swapfile none swap sw,pri=10 0 0'

echo ""
echo "разделы по UUID= и LABEL="
check "UUID= раздела" /dev/vda2 \
    'UUID=1111-aaaa none swap sw 0 0' \
    'UUID=1111-aaaa none swap sw,pri=10 0 0'
check "LABEL= раздела" /dev/vda2 \
    'LABEL=SWAP none swap defaults 0 0' \
    'LABEL=SWAP none swap defaults,pri=10 0 0'
check "by-uuid путь" /dev/vda2 \
    '/dev/disk/by-uuid/1111-aaaa none swap sw 0 0' \
    '/dev/disk/by-uuid/1111-aaaa none swap sw,pri=10 0 0'
check "UUID= и путь на одно устройство — второй дубль" /dev/vda2 \
    'UUID=1111-aaaa none swap sw 0 0'$'\n''/dev/vda2 none swap sw 0 0' \
    'UUID=1111-aaaa none swap sw,pri=10 0 0'$'\n''# usfc: duplicate swap entry: /dev/vda2 none swap sw 0 0'

echo ""
echo "чтение приоритета для статуса"
printf '/swapfile none swap sw,pri=10 0 0\n' > "$USFC_FSTAB"
fstab_swap_pri /swapfile
[ "$REPLY_FSTAB_PRI" = 10 ] && ok "pri=10 прочитан" || bad "прочитано «$REPLY_FSTAB_PRI»"
printf '/swapfile none swap sw 0 0\n' > "$USFC_FSTAB"
fstab_swap_pri /swapfile
[ -z "$REPLY_FSTAB_PRI" ] && ok "pri нет — пусто" || bad "прочитано «$REPLY_FSTAB_PRI»"
printf 'UUID=1111-aaaa none swap sw,pri=-2 0 0\n' > "$USFC_FSTAB"
fstab_swap_pri /dev/vda2
[ "$REPLY_FSTAB_PRI" = -2 ] && ok "отрицательный pri раздела по UUID" || bad "прочитано «$REPLY_FSTAB_PRI»"

echo ""
echo "/etc/default/zramswap правится на месте"
ZCONF="$TMP/zramswap"
write_file() { cat > "$ZCONF"; }
cat() { if [ "${1:-}" = /etc/default/zramswap ]; then command cat "$ZCONF"; else command cat "$@"; fi; }
printf '# Compression algorithm\n#ALGO=lz4\n# my note\nSIZE=256\nPERCENT=50\nCUSTOM=keep\n' > "$ZCONF"
zramswap_write_conf 75
unset -f cat
got="$(command cat "$ZCONF")"
case "$got" in *"PERCENT=75"*) ok "PERCENT обновлён" ;; *) bad "PERCENT: $got" ;; esac
case "$got" in *"ALGO=lz4"*) ok "ALGO раскомментирован" ;; *) bad "ALGO: $got" ;; esac
case "$got" in *"PRIORITY=100"*) ok "PRIORITY дописан" ;; *) bad "PRIORITY: $got" ;; esac
case "$got" in *"# usfc: PERCENT is used instead: SIZE=256"*) ok "SIZE закомментирован" ;; *) bad "SIZE: $got" ;; esac
case "$got" in *"CUSTOM=keep"*"# my note"*|*"# my note"*"CUSTOM=keep"*) ok "чужие строки целы" ;; *) bad "чужое пропало: $got" ;; esac
[ "$(grep -c '^PERCENT=' <<< "$got")" = 1 ] && ok "PERCENT ровно один" || bad "PERCENT несколько раз"

echo ""
[ "$fail" -eq 0 ] && echo "приоритет свопа в fstab: все проверки пройдены" || echo "приоритет свопа в fstab: ЕСТЬ ОШИБКИ"
exit "$fail"
