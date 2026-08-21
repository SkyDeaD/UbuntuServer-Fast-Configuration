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

# ── вторая половина: пункты, до которых `--apply all` не доходит ─────────────
# SSH hardening отфильтровывается в неинтерактивном режиме, поэтому прогон выше
# его не касается — и дыра в перехвате жила там незамеченной: пункт делал
# `cp /etc/ssh/sshd_config .bak.$(date +%s)` и `mv` поверх authorized_keys,
# а cp и mv в сухом прогоне не подменялись вовсе. Всплыло это только когда
# предпросмотр пункта сделал такой путь достижимым из меню.
ssh_before="$(find /etc/ssh -maxdepth 1 -type f 2>/dev/null | sort)"
home_before="$(find /root /home -maxdepth 3 -type f -printf '%p %s\n' 2>/dev/null | sort)"

USFC_SOURCE_ONLY=1 bash -c '
    # shellcheck disable=SC1091
    source /opt/vps-setup/setup.sh
    USFC_DRY_RUN=true
    dry_run_enable >/dev/null 2>&1
    # пункт требует не-root и явного согласия
    TARGET_USER=nobody
    TARGET_HOME=/nonexistent
    BULK_MODE=false
    ask_yn_t() { return 0; }
    apply_sshhardening
' > /tmp/dryrun-ssh.log 2>&1
ssh_rc=$?

ssh_after="$(find /etc/ssh -maxdepth 1 -type f 2>/dev/null | sort)"
home_after="$(find /root /home -maxdepth 3 -type f -printf '%p %s\n' 2>/dev/null | sort)"

if [ "$ssh_before" != "$ssh_after" ]; then
    echo "FAIL: сухой прогон SSH hardening наследил в /etc/ssh" >&2
    diff <(printf '%s\n' "$ssh_before") <(printf '%s\n' "$ssh_after") >&2
    fail=1
fi
if [ "$home_before" != "$home_after" ]; then
    echo "FAIL: сухой прогон SSH hardening тронул домашние каталоги" >&2
    fail=1
fi
if [ "$ssh_rc" -ne 0 ]; then
    echo "FAIL: сухой прогон SSH hardening вернул ${ssh_rc}" >&2
    tail -10 /tmp/dryrun-ssh.log >&2
    fail=1
fi
# и он не должен пугать «вход по ключу не проходит даже сейчас»: самопроверку
# в сухом режиме мы не делаем именно потому, что она соврала бы
if grep -F 'не проходит даже сейчас' /tmp/dryrun-ssh.log >/dev/null 2>&1; then
    echo "FAIL: сухой прогон соврал про неработающий вход по ключу" >&2
    fail=1
fi

[ "$fail" -eq 0 ] && echo "сухой прогон: система не изменилась, код возврата 0"
exit "$fail"
