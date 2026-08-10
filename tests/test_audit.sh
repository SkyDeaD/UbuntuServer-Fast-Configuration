#!/usr/bin/env bash
# Аудит обязан быть ЧИСТО читающим. Это его главное свойство: диагностика,
# которая что-то чинит по дороге, перестаёт быть диагностикой.
#
# Проверяем тем же слепком, что и сухой прогон, — на глаз такое не ловится.
set -uo pipefail

snapshot() {
    {
        find /etc /root /home -maxdepth 4 -type f -printf '%p %s\n' 2>/dev/null | sort
        dpkg-query -W -f='${Package} ${db:Status-Status}\n' 2>/dev/null | sort
        cat /etc/passwd /etc/group 2>/dev/null
        swapon --show --noheadings --raw 2>/dev/null | sort
        ls /var/lib/apt/lists/ 2>/dev/null | sort
    } | sha256sum | cut -d' ' -f1
}

before="$(snapshot)"
usfc --audit >/tmp/audit.log 2>&1
rc=$?
after="$(snapshot)"

fail=0
[ "$before" = "$after" ] || { echo "FAIL: аудит изменил систему" >&2; fail=1; }
[ "$rc" -eq 0 ] || { echo "FAIL: аудит вернул ${rc}" >&2; fail=1; }
grep -q 'Итог:' /tmp/audit.log || { echo "FAIL: нет итоговой строки" >&2; tail -5 /tmp/audit.log >&2; fail=1; }
# отчёт должен быть содержательным, а не пустым каркасом
[ "$(grep -cE '^\s+[✓!✗]' /tmp/audit.log)" -ge 8 ] \
    || { echo "FAIL: слишком мало проверок в отчёте" >&2; fail=1; }

[ "$fail" -eq 0 ] && echo "аудит: система не изменилась, отчёт содержательный"
exit "$fail"
