#!/usr/bin/env bash
# Снимок конфига и возврат из него. Запускать в одноразовом контейнере: root.
#
# Проверяется главное свойство — что восстановленный файл совпадает с тем,
# что было ДО правки. Формально «Восстановлен ✓» его не гарантирует: одна
# из первых версий рапортовала успех, вернув то же, от чего уходили, потому
# что снимок отката затирал восстанавливаемый снимок (совпали метки времени).
set -uo pipefail

CONF=/etc/apt/apt.conf.d/20auto-upgrades
MARK="МАРКЕР-СТАРОГО-$$"
fail=0

printf '%s\n' "$MARK" > "$CONF"
before="$(cat "$CONF")"

usfc apply unattended >/tmp/backup-apply.log 2>&1
after="$(cat "$CONF")"
if [ "$after" = "$before" ]; then
    echo "FAIL: пункт не изменил ${CONF}, проверять нечего" >&2
    fail=1
fi

stamp="$(ls -1 /var/backups/usfc 2>/dev/null | head -1)"
if [ -z "$stamp" ]; then
    echo "FAIL: снимок не создан" >&2
    exit 1
fi

usfc restore "$stamp" --yes >/tmp/backup-restore.log 2>&1
restored="$(cat "$CONF")"
if [ "$restored" != "$before" ]; then
    echo "FAIL: после отката содержимое не совпало с исходным" >&2
    echo "  было:       $before" >&2
    echo "  после отката: $restored" >&2
    fail=1
fi

# откат отката тоже должен быть возможен
if [ "$(ls -1 /var/backups/usfc | wc -l)" -lt 2 ]; then
    echo "FAIL: снимок перед восстановлением не сделан" >&2
    fail=1
fi

# ── restore latest --diff, restore latest --yes и backups prune ──────────────
# Пауза в 1 с гарантирует строго более свежую метку YYYYMMDD-HHMMSS: при совпадении
# секунды лексикографическая сортировка PID могла бы поменять порядок снимков.
sleep 1
MARK2="МАРКЕР-ВТОРОЙ-$$"
printf '%s\n' "$MARK2" > "$CONF"
before2="$(cat "$CONF")"

usfc apply unattended >/tmp/backup-apply2.log 2>&1
after2="$(cat "$CONF")"
if [ "$after2" = "$before2" ]; then
    echo "FAIL: повторный apply unattended не изменил ${CONF}" >&2
    fail=1
fi

stamps_pre_diff="$(ls -1 /var/backups/usfc 2>/dev/null | LC_ALL=C sort)"
usfc restore latest --diff >/tmp/backup-diff.log 2>&1
diff_rc=$?
if [ "$diff_rc" -ne 0 ]; then
    echo "FAIL: restore latest --diff вернул ${diff_rc}" >&2
    tail -15 /tmp/backup-diff.log >&2
    fail=1
fi
if [ "$(cat "$CONF")" != "$after2" ]; then
    echo "FAIL: restore latest --diff изменил ${CONF}" >&2
    fail=1
fi
if [ "$(ls -1 /var/backups/usfc 2>/dev/null | LC_ALL=C sort)" != "$stamps_pre_diff" ]; then
    echo "FAIL: restore latest --diff создал или удалил снимки" >&2
    fail=1
fi
if ! grep -F "$CONF" /tmp/backup-diff.log >/dev/null 2>&1 \
   || ! grep -F "$MARK2" /tmp/backup-diff.log >/dev/null 2>&1; then
    echo "FAIL: restore latest --diff не показал отличий для ${CONF}" >&2
    cat /tmp/backup-diff.log >&2
    fail=1
fi

sleep 1
usfc restore latest --yes >/tmp/backup-restore-latest.log 2>&1
latest_rc=$?
if [ "$latest_rc" -ne 0 ]; then
    echo "FAIL: restore latest --yes вернул ${latest_rc}" >&2
    tail -15 /tmp/backup-restore-latest.log >&2
    fail=1
fi
if [ "$(cat "$CONF")" != "$before2" ]; then
    echo "FAIL: restore latest --yes восстановил не из самого свежего снимка" >&2
    echo "  ждали:  $before2" >&2
    echo "  вышло:  $(cat "$CONF")" >&2
    fail=1
fi

stamps_all="$(ls -1 /var/backups/usfc 2>/dev/null | LC_ALL=C sort)"
count_all="$(printf '%s\n' "$stamps_all" | grep -c .)"
newest_stamp="$(printf '%s\n' "$stamps_all" | tail -n 1)"
if [ "$count_all" -lt 3 ]; then
    echo "FAIL: ожидалось не меньше 3 снимков перед prune, нашлось ${count_all}" >&2
    fail=1
fi

usfc backups prune --keep 1 --dry-run >/tmp/backup-prune-dry.log 2>&1
prune_dry_rc=$?
if [ "$prune_dry_rc" -ne 0 ]; then
    echo "FAIL: backups prune --keep 1 --dry-run вернул ${prune_dry_rc}" >&2
    cat /tmp/backup-prune-dry.log >&2
    fail=1
fi
if [ "$(ls -1 /var/backups/usfc 2>/dev/null | LC_ALL=C sort)" != "$stamps_all" ]; then
    echo "FAIL: backups prune --dry-run удалил снимки" >&2
    fail=1
fi
if ! grep -F 'сухой прогон' /tmp/backup-prune-dry.log >/dev/null 2>&1; then
    echo "FAIL: в выводе backups prune --dry-run нет пометки сухого прогона" >&2
    cat /tmp/backup-prune-dry.log >&2
    fail=1
fi

usfc backups prune --keep 1 --yes >/tmp/backup-prune.log 2>&1
prune_rc=$?
if [ "$prune_rc" -ne 0 ]; then
    echo "FAIL: backups prune --keep 1 --yes вернул ${prune_rc}" >&2
    cat /tmp/backup-prune.log >&2
    fail=1
fi
stamps_after="$(ls -1 /var/backups/usfc 2>/dev/null | LC_ALL=C sort)"
count_after="$(printf '%s\n' "$stamps_after" | grep -c .)"
if [ "$count_after" -ne 1 ] || [ "$stamps_after" != "$newest_stamp" ]; then
    echo "FAIL: после prune --keep 1 должен остаться один самый свежий снимок (${newest_stamp}), осталось (${count_after}): ${stamps_after}" >&2
    fail=1
fi

[ "$fail" -eq 0 ] && echo "снимок и откат: содержимое вернулось точно, откат отката, latest/--diff и prune работают"
exit "$fail"
