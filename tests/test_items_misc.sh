#!/usr/bin/env bash
# Мелкие пункты (bbr, dockerlog, hostname): поведение, которое ломается молча.
#   • bbr в контейнере: пункт не пишет файлы впустую, даже если в списке
#     доступных алгоритмов уже есть bbr (ядро хозяина);
#   • bbr «применён», только если его выставит и загрузка: /etc/sysctl.conf
#     без ссылки 99-sysctl.conf (Ubuntu 26.04, Debian 13) не в счёт;
#   • обёртка usfc в ~/.bashrc ставится и пакетным apply, не только меню;
#   • dockerlog: чужой log-driver не перетирается, нет python3 — честное
#     сообщение, сбой записи не маскируется фразой «обновлён»;
#   • hostname: preserve_hostname для cloud-init пишется и тогда, когда имя
#     уже задано (не только при смене).
# Root не нужен: пути вынесены в переменные, внешние команды подменены функциями.
set -uo pipefail
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"
# shellcheck disable=SC2034  # читается в write_file / log_*
USFC_DRY_RUN=false
# shellcheck disable=SC2034
USFC_NO_COLOR=true
backup_file() { :; }    # снимки проверяет test_backup.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }

ask_yn_t() { return 0; }

echo ""
echo "bbr: контейнер определяется первым"
systemd-detect-virt() { return 0; }
modinfo() { return 0; }            # «модуль есть» — старый код выходил здесь с ok
BBR_SYSCTL="$TMP/bbr/sysctl.conf"; BBR_MODLOAD="$TMP/bbr/modload.conf"
mkdir -p "$TMP/bbr"
bbr_kernel_state
[ "$REPLY_BBR_KERNEL" = container ] && ok "в контейнере состояние — container" || bad "состояние: $REPLY_BBR_KERNEL"
apply_bbr >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "apply в контейнере отказывает" || bad "apply вернул 0"
{ [ ! -e "$BBR_SYSCTL" ] && [ ! -e "$BBR_MODLOAD" ]; } && ok "файлы не пишутся" || bad "файлы записаны впустую"
unset -f systemd-detect-virt modinfo

echo ""
echo "bbr: статус учитывает, что выставит загрузка"
# живое значение подменяем; каталоги sysctl — временные
BBR_LIVE=bbr
sysctl() { case "$*" in *tcp_congestion_control*) echo "$BBR_LIVE" ;; *default_qdisc*) echo fq ;; esac; }
B="$TMP/sc"; mkdir -p "$B/etc/sysctl.d" "$B/usr/lib/sysctl.d" "$B/run/sysctl.d"
# конфиг ядра — тоже временный: умолчание хоста (XanMod — bbr) не должно влиять
# shellcheck disable=SC2034  # читает bbr_boot_value
BBR_KCONFIG_DIR="$TMP/boot"; mkdir -p "$BBR_KCONFIG_DIR"
# shellcheck disable=SC2034  # читает bbr_boot_value
BBR_SYSCTL_DIRS=("$B/etc/sysctl.d" "$B/run/sysctl.d" "$B/usr/lib/sysctl.d")
printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > "$B/etc/sysctl.conf"
out="$(status_bbr)"; rc=$?
{ [ "$rc" -ne 0 ] && [[ "$out" == *"перезагрузки"* ]]; } \
    && ok "bbr только в sysctl.conf без ссылки 99-sysctl.conf (26.04) — «до перезагрузки», rc≠0" || bad "sysctl.conf без ссылки: rc=$rc «$out»"
ln -s ../sysctl.conf "$B/etc/sysctl.d/99-sysctl.conf"
status_bbr >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "со ссылкой 99-sysctl.conf (24.04) — применён" || bad "со ссылкой: rc=$rc"
rm -f "$B/etc/sysctl.d/99-sysctl.conf" "$B/etc/sysctl.conf"
printf 'net.ipv4.tcp_congestion_control = bbr\n' > "$B/usr/lib/sysctl.d/50-x.conf"
printf -- '-net/ipv4/tcp_congestion_control=cubic\n' > "$B/etc/sysctl.d/50-x.conf"
bbr_boot_value
[ "$REPLY_BBR_BOOT" = cubic ] && ok "одноимённый файл из /etc перекрывает /usr/lib (и «-», и «/»)" || bad "перекрытие: «$REPLY_BBR_BOOT»"
rm -f "$B"/etc/sysctl.d/*.conf "$B"/usr/lib/sysctl.d/*.conf
printf 'net.ipv4.tcp_congestion_control=bbr\n' > "$B/etc/sysctl.d/60-usfc-bbr.conf"
printf 'net.ipv4.tcp_congestion_control=cubic\n' > "$B/usr/lib/sysctl.d/99-hoster.conf"
bbr_boot_value
{ [ "$REPLY_BBR_BOOT" = cubic ] && [[ "$REPLY_BBR_BOOT_FILE" == */99-hoster.conf ]]; } \
    && ok "побеждает последний по имени файла: $(basename "$REPLY_BBR_BOOT_FILE")" || bad "порядок: «$REPLY_BBR_BOOT» из $REPLY_BBR_BOOT_FILE"
status_bbr >/dev/null; rc=$?
[ "$rc" -ne 0 ] && ok "наш файл перебит — не применён" || bad "перебитый файл считается применённым"
rm -f "$B/usr/lib/sysctl.d/99-hoster.conf"
status_bbr >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "наш 60-usfc-bbr.conf — применён" || bad "наш файл: rc=$rc"
# файлы молчат — значит, умолчание ядра из /boot/config-<ядро> (XanMod: bbr)
rm -f "$B"/etc/sysctl.d/*.conf
read -r krel < /proc/sys/kernel/osrelease
echo 'CONFIG_DEFAULT_TCP_CONG="bbr"' > "$BBR_KCONFIG_DIR/config-$krel"
status_bbr >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "bbr — умолчание ядра, файлов нет: применён" || bad "умолчание ядра bbr: rc=$rc"
echo 'CONFIG_DEFAULT_TCP_CONG="cubic"' > "$BBR_KCONFIG_DIR/config-$krel"
status_bbr >/dev/null; rc=$?
[ "$rc" -ne 0 ] && ok "bbr руками при умолчании cubic — не применён" || bad "sysctl -w без файлов считается применённым"
rm -f "$BBR_KCONFIG_DIR/config-$krel"
status_bbr >/dev/null; rc=$?
[ "$rc" -ne 0 ] && ok "конфига ядра нет — честное «не знаю», не применён" || bad "без конфига ядра: rc=$rc"
BBR_LIVE=cubic
out="$(status_bbr)"; rc=$?
{ [ "$rc" -ne 0 ] && [[ "$out" == *"○ cubic"* ]]; } && ok "сейчас cubic — «○ cubic»" || bad "cubic: rc=$rc «$out»"
unset -f sysctl

echo ""
echo "обёртка usfc: ставится и в пакетном apply"
# shellcheck disable=SC2034  # читают install_usfc_wrapper и run_noninteractive
TARGET_USER=bob; TARGET_HOME="$TMP/home-bob"; mkdir -p "$TARGET_HOME"
# shellcheck disable=SC2034  # читают run_noninteractive и filter_pending
( USFC_APPLY_SPEC=tmux; filter_pending() { REPLY_PENDING=(); REPLY_SKIPPED=(); REPLY_ALREADY=(); }
  chown() { :; }; run_noninteractive ) >/dev/null 2>&1
grep -F '# >>> vps-setup:self >>>' "$TARGET_HOME/.bashrc" >/dev/null 2>&1 \
    && ok "apply поставил блок vps-setup:self пользователю" || bad "после apply блока обёртки нет"
# shellcheck disable=SC2034  # читают install_usfc_wrapper и run_noninteractive
TARGET_USER=root; TARGET_HOME="$TMP/home-root"; mkdir -p "$TARGET_HOME"
# shellcheck disable=SC2034  # читают run_noninteractive и filter_pending
( USFC_APPLY_SPEC=tmux; filter_pending() { REPLY_PENDING=(); REPLY_SKIPPED=(); REPLY_ALREADY=(); }
  run_noninteractive ) >/dev/null 2>&1
[ ! -e "$TARGET_HOME/.bashrc" ] && ok "root — без обёртки" || bad "root получил обёртку"

echo ""
echo "dockerlog"
docker() { :; }
systemctl() { :; }
# shellcheck disable=SC2034  # читает apply_dockerlog
BULK_MODE=true
# shellcheck disable=SC2034
DOCKER_RESTART_BULK=N
DOCKER_DAEMON_JSON="$TMP/docker/daemon.json"
mkdir -p "$TMP/docker"

printf '{"log-driver": "syslog"}\n' > "$DOCKER_DAEMON_JSON"
cp "$DOCKER_DAEMON_JSON" "$TMP/dj-orig"
apply_dockerlog >"$TMP/o" 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "чужой log-driver: пункт пропущен (код ≠0)" || bad "код 0 при чужом драйвере"
cmp -s "$DOCKER_DAEMON_JSON" "$TMP/dj-orig" && ok "daemon.json не тронут" || bad "daemon.json изменён: $(cat "$DOCKER_DAEMON_JSON")"
grep -F 'log-driver' "$TMP/o" >/dev/null && ok "причина названа" || bad "причины в выводе нет"

# shellcheck disable=SC2218  # command подменяется ниже, здесь нужен настоящий
if command -v python3 >/dev/null 2>&1; then
    printf '{"log-driver": "local", "x": 1}\n' > "$DOCKER_DAEMON_JSON"
    apply_dockerlog >/dev/null 2>&1; rc=$?
    { [ "$rc" -eq 0 ] && grep -F '"local"' "$DOCKER_DAEMON_JSON" >/dev/null && grep -F '"max-size": "10m"' "$DOCKER_DAEMON_JSON" >/dev/null; } \
        && ok "local сохранён, лимит добавлен" || bad "local: rc=$rc $(cat "$DOCKER_DAEMON_JSON")"

    rm -f "$DOCKER_DAEMON_JSON"
    apply_dockerlog >/dev/null 2>&1
    grep -F '"json-file"' "$DOCKER_DAEMON_JSON" >/dev/null && ok "чистая настройка: json-file + лимит" || bad "нет json-file"

    # сбой записи не прячется за «обновлён» (подмена — в подоболочке)
    rm -f "$DOCKER_DAEMON_JSON"
    ( write_file() { cat >/dev/null; return 1; }; apply_dockerlog ) >"$TMP/o" 2>&1; rc=$?
    { [ "$rc" -ne 0 ] && ! grep -F 'обновлён' "$TMP/o" >/dev/null; } && ok "сбой записи → ошибка, без «обновлён»" || bad "сбой записи замаскирован: rc=$rc"
    printf '{"log-opts": {"max-size": "10m"}}\n' > "$DOCKER_DAEMON_JSON"
    ( write_file() { cat >/dev/null; return 1; }; disable_dockerlog ) >"$TMP/o" 2>&1; rc=$?
    { [ "$rc" -ne 0 ] && ! grep -F 'убраны' "$TMP/o" >/dev/null; } && ok "disable: сбой записи → ошибка" || bad "disable замаскировал сбой: rc=$rc"
fi

# нет python3 — не «не JSON», а честное «нужен python3»
command() {
    if [ "${1:-}" = -v ] && [ "${2:-}" = python3 ]; then return 1; fi
    builtin command "$@"
}
printf '{}\n' > "$DOCKER_DAEMON_JSON"
apply_dockerlog >"$TMP/o" 2>&1; rc=$?
{ [ "$rc" -ne 0 ] && grep -F 'python3' "$TMP/o" >/dev/null && ! grep -F 'не JSON' "$TMP/o" >/dev/null; } \
    && ok "нет python3 → «нужен python3», а не «не JSON»" || bad "нет python3: rc=$rc $(cat "$TMP/o")"
unset -f command docker systemctl

echo ""
echo "hostname: cloud-init при неизменном имени"
HN_CLOUD_ETC="$TMP/cloud/etc"; HN_CLOUD_LIB="$TMP/cloud/lib"
mkdir -p "$HN_CLOUD_ETC/cloud.cfg.d" "$HN_CLOUD_LIB"
: > "$HN_CLOUD_ETC/cloud.cfg"
hostname() { echo srv1; }
# shellcheck disable=SC2034  # читает _hn_apply_name
_hn_ask_name() { REPLY_HN=srv1; }
_hn_write_hosts() { return 0; }
_hn_apply_name >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && grep -F 'preserve_hostname: true' "$HN_CLOUD_ETC/cloud.cfg.d/99-usfc-hostname.cfg" >/dev/null; } \
    && ok "имя не менялось, preserve_hostname записан" || bad "preserve_hostname не записан (rc=$rc)"
cp "$HN_CLOUD_ETC/cloud.cfg.d/99-usfc-hostname.cfg" "$TMP/cc1"
_hn_apply_name >/dev/null 2>&1
cmp -s "$TMP/cc1" "$HN_CLOUD_ETC/cloud.cfg.d/99-usfc-hostname.cfg" && ok "повтор идемпотентен" || bad "повтор изменил файл"

echo ""
echo "journald: статус показывает занятое место без journalctl"
mkdir -p "$TMP/journal/abc"
head -c 300000 /dev/zero > "$TMP/journal/abc/system.journal"
printf '[Journal]\nSystemMaxUse=200M\n' > "$TMP/jd.conf"
saved_jd="$(declare -f journalctl 2>/dev/null)"
journalctl() { echo "journalctl вызван" >&2; return 1; }
# shellcheck disable=SC2034  # читаются в status_journald
JOURNALD_DIR="$TMP/journal"
# shellcheck disable=SC2034
JOURNALD_DROPIN="$TMP/jd.conf"
out="$(status_journald 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [[ "$out" == *"200M"* ]] && ok "лимит виден (код 0)" || bad "статус: «${out}» rc=$rc"
[[ "$out" =~ ·\ [0-9.,]+K ]] && ok "размер журнала виден: ${out##*· }" || bad "размера нет: «${out}»"
[[ "$out" != *"journalctl вызван"* ]] && ok "journalctl не вызывается" || bad "статус зовёт journalctl"
unset -f journalctl; [ -n "$saved_jd" ] && eval "$saved_jd"

echo ""
[ "$fail" -eq 0 ] && echo "мелкие пункты: все проверки пройдены" || echo "мелкие пункты: ЕСТЬ ОШИБКИ"
exit "$fail"
