#!/usr/bin/env bash
# Сухой прогон обязан НЕ МЕНЯТЬ систему.
#
# Проверять это глазами бессмысленно: изменяющих вызовов около сотни, и
# забытый однажды вернёт ту же ложь. Поэтому сверяем слепок системы до и
# после `apply all --dry-run`. Именно так и нашлась исходная поломка:
# на живой Ubuntu 26.04 сухой прогон писал docker.list и дёргал usermod.
#
# Запускать только в одноразовом контейнере: прогон идёт от root.
set -uo pipefail

created_swapfile=false
cleanup() {
    [ "$created_swapfile" = true ] && rm -f /swapfile
}
trap cleanup EXIT

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

log_state() {
    if [ ! -e /var/log/usfc.log ]; then
        printf 'absent'
    else
        stat -c '%s %Y' /var/log/usfc.log 2>/dev/null
        sha256sum /var/log/usfc.log 2>/dev/null | cut -d' ' -f1
    fi
}

# Создаём заранее 1 МБ /swapfile до слепка: раньше create_swapfile делал голый
# `rm -f "$path"`, а rm в сухом прогоне не подменяется — --dry-run удалял файл
if [ ! -e /swapfile ]; then
    dd if=/dev/zero of=/swapfile bs=1M count=1 status=none 2>/dev/null
    created_swapfile=true
fi
swapfile_before="$(sha256sum /swapfile | cut -d' ' -f1)"
log_before="$(log_state)"

before="$(snapshot)"
usfc apply all --dry-run >/tmp/dryrun.log 2>&1
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
if [ "$(log_state)" != "$log_before" ]; then
    echo "FAIL: apply all --dry-run создал или изменил /var/log/usfc.log" >&2
    fail=1
fi
if [ ! -f /swapfile ] || [ "$(sha256sum /swapfile | cut -d' ' -f1)" != "$swapfile_before" ]; then
    echo "FAIL: apply all --dry-run удалил или изменил /swapfile" >&2
    fail=1
fi

# ── регрессия 5.3: /swapfile и /var/log/usfc.log при сухом прогоне zram ──────
# Проверяем и команду `usfc apply zram --dry-run`, и саму create_swapfile под
# USFC_DRY_RUN=true: в контейнере с активным свопом хоста apply_zram может не
# дойти до ветки создания /swapfile, а прямой вызов покрывает обе ветки rm -f
usfc apply zram --dry-run >/tmp/dryrun-zram.log 2>&1
zram_rc=$?
if [ "$zram_rc" -ne 0 ]; then
    echo "FAIL: apply zram --dry-run вернул ${zram_rc}" >&2
    tail -15 /tmp/dryrun-zram.log >&2
    fail=1
fi
if [ ! -f /swapfile ] || [ "$(sha256sum /swapfile | cut -d' ' -f1)" != "$swapfile_before" ]; then
    echo "FAIL: apply zram --dry-run удалил или изменил /swapfile" >&2
    fail=1
fi
if [ "$(log_state)" != "$log_before" ]; then
    echo "FAIL: apply zram --dry-run создал или изменил /var/log/usfc.log" >&2
    fail=1
fi

USFC_SOURCE_ONLY=1 bash -c '
    # shellcheck disable=SC1091
    source /opt/vps-setup/setup.sh
    USFC_DRY_RUN=true
    dry_run_enable >/dev/null 2>&1
    create_swapfile /swapfile 64 || exit 1
    # Вторая ветка rm -f: отказ mkswap и пересоздание через dd
    mkswap() { return 1; }
    create_swapfile /swapfile 64 && exit 1
    exit 0
' >/tmp/dryrun-swapfile.log 2>&1
sf_rc=$?
if [ "$sf_rc" -ne 0 ]; then
    echo "FAIL: проверка create_swapfile под USFC_DRY_RUN вернула ${sf_rc}" >&2
    tail -15 /tmp/dryrun-swapfile.log >&2
    fail=1
fi
if [ ! -f /swapfile ] || [ "$(sha256sum /swapfile | cut -d' ' -f1)" != "$swapfile_before" ]; then
    echo "FAIL: create_swapfile под USFC_DRY_RUN удалил или изменил /swapfile" >&2
    fail=1
fi
if ! grep -F 'rm -f /swapfile' /tmp/dryrun-swapfile.log >/dev/null 2>&1; then
    echo "FAIL: create_swapfile под USFC_DRY_RUN не показал перехваченный rm -f /swapfile" >&2
    fail=1
fi

# ── вторая половина: пункты, до которых `apply all` не доходит ─────────────
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

# ── третья половина: предпросмотр из меню по КАЖДОМУ пункту ──────────────────
# Клавиша V делает достижимым интерактивный путь любого пункта, включая те,
# что `apply all` отфильтровывает. Здесь и вылезали cp/mv/ssh-keygen.
prev_before="$(snapshot)"
USFC_SOURCE_ONLY=1 bash -c '
    # shellcheck disable=SC1091
    source /opt/vps-setup/setup.sh
    TARGET_USER=nobody; TARGET_HOME=/nonexistent
    for i in $(seq 1 "${#ITEM_IDS[@]}"); do
        preview_item "$i" || exit 1
    done
    # Сухой режим обязан выключиться вместе с подоболочкой: заглушки не должны
    # пережить предпросмотр, иначе следующее РЕАЛЬНОЕ применение ничего не сделает
    [ "$USFC_DRY_RUN" = false ] || { echo "USFC_DRY_RUN остался true" >&2; exit 1; }
    [ -z "$(declare -F usermod)" ] || { echo "заглушка usermod пережила предпросмотр" >&2; exit 1; }
    [ -z "$(declare -F cp)" ]      || { echo "заглушка cp пережила предпросмотр" >&2; exit 1; }
' > /tmp/preview.log 2>&1
prev_rc=$?

if [ "$prev_before" != "$(snapshot)" ]; then
    echo "FAIL: предпросмотр изменил систему" >&2
    fail=1
fi
if [ "$prev_rc" -ne 0 ]; then
    echo "FAIL: предпросмотр вернул ${prev_rc}" >&2
    tail -12 /tmp/preview.log >&2
    fail=1
fi
if [ "$(log_state)" != "$log_before" ]; then
    echo "FAIL: предпросмотр создал или изменил /var/log/usfc.log" >&2
    fail=1
fi

[ "$fail" -eq 0 ] && echo "сухой прогон: система не изменилась, код возврата 0"
exit "$fail"
