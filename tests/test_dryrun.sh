#!/usr/bin/env bash
# Сухой прогон обязан НЕ МЕНЯТЬ систему.
#
# Проверять это глазами бессмысленно: изменяющих вызовов около сотни, и
# забытый однажды вернёт ту же ложь. Поэтому сверяем слепок системы до и
# после `--apply all --dry-run`. Именно так и нашлась исходная поломка:
# на живой Ubuntu 26.04 сухой прогон писал docker.list и дёргал usermod.
#
# Запускать только в одноразовом контейнере: прогон идёт от root.
set -uo pipefail

snapshot() {
    {
        find /etc -type f -printf '%p %s %T@\n' 2>/dev/null | sort
        echo "--- dpkg ---"
        dpkg-query -W -f='${Package} ${db:Status-Status}\n' 2>/dev/null | sort
        echo "--- passwd/group ---"
        cat /etc/passwd /etc/group 2>/dev/null
        echo "--- swap ---"
        swapon --show --noheadings --raw 2>/dev/null | sort
        echo "--- apt lists ---"
        ls /var/lib/apt/lists/ 2>/dev/null | sort
        echo "--- домашние каталоги ---"
        # .bashrc правят три пункта, и раньше слепок сюда не заглядывал —
        # сухой прогон мог дописать туда алиасы, и тест этого не заметил бы
        find /root /home -maxdepth 3 -type f -printf '%p %s\n' 2>/dev/null | sort
    } | sha256sum | cut -d' ' -f1
}

before="$(snapshot)"
usfc --apply all --dry-run >/tmp/dryrun.log 2>&1
rc=$?
after="$(snapshot)"

fail=0
if [ "$before" != "$after" ]; then
    echo "FAIL: сухой прогон изменил систему" >&2
    echo "  до:    $before" >&2
    echo "  после: $after" >&2
    fail=1
fi
if [ "$rc" -ne 0 ]; then
    echo "FAIL: сухой прогон завершился с кодом ${rc}, ожидался 0" >&2
    tail -20 /tmp/dryrun.log >&2
    fail=1
fi
# и он должен был что-то показать, а не молча выйти
if ! grep -q 'сухой прогон' /tmp/dryrun.log; then
    echo "FAIL: в выводе нет ни одной строки сухого прогона" >&2
    fail=1
fi

[ "$fail" -eq 0 ] && echo "сухой прогон: система не изменилась, код возврата 0"
exit "$fail"
