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

usfc --apply unattended >/tmp/backup-apply.log 2>&1
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

usfc --restore "$stamp" --yes >/tmp/backup-restore.log 2>&1
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

[ "$fail" -eq 0 ] && echo "снимок и откат: содержимое вернулось точно, откат отката доступен"
exit "$fail"
