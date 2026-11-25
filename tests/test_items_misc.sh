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
saved_backup_file="$(declare -f backup_file)"
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

    printf '{"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3", "compress": "true"}}\n' > "$DOCKER_DAEMON_JSON"
    disable_dockerlog >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 0 ] \
       && ! grep -F '"max-size"' "$DOCKER_DAEMON_JSON" >/dev/null \
       && ! grep -F '"max-file"' "$DOCKER_DAEMON_JSON" >/dev/null \
       && grep -F '"compress": "true"' "$DOCKER_DAEMON_JSON" >/dev/null \
       && grep -F '"log-driver": "json-file"' "$DOCKER_DAEMON_JSON" >/dev/null; then
        ok "disable_dockerlog убрал только max-size/max-file и сохранил compress"
    else
        bad "disable_dockerlog: rc=$rc $(cat "$DOCKER_DAEMON_JSON")"
    fi
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
# status_dockerlog работает без python3: видит свой max-size и journald
printf '{"log-driver": "json-file", "log-opts": {"max-size": "50m"}}\n' > "$DOCKER_DAEMON_JSON"
out="$(python3() { echo "python3 вызван" >&2; return 1; }; status_dockerlog 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [[ "$out" == *"max-size=50m"* ]] && [[ "$out" != *"python3 вызван"* ]]; } \
    && ok "status_dockerlog без python3 видит max-size=50m" \
    || bad "status_dockerlog 50m: rc=$rc «$out»"
printf '{"log-driver": "journald"}\n' > "$DOCKER_DAEMON_JSON"
out="$(python3() { echo "python3 вызван" >&2; return 1; }; status_dockerlog 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [[ "$out" == *"journald"* ]] && [[ "$out" != *"python3 вызван"* ]]; } \
    && ok "status_dockerlog без python3 видит log-driver=journald" \
    || bad "status_dockerlog journald: rc=$rc «$out»"
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
echo "zram: zram_generator_write_conf и zramswap_write_conf (ZRAM_ALGO_BULK=zstd)"
# shellcheck disable=SC2034  # читает zram_generator_write_conf
ZRAM_GENERATOR_CONF="$TMP/zram-generator.conf"
printf '[zram1]\nzram-size = 512' > "$ZRAM_GENERATOR_CONF"   # без завершающего \n
# shellcheck disable=SC2034  # читают zram_generator_write_conf и zramswap_write_conf
ZRAM_ALGO_BULK=zstd
zram_generator_write_conf 75
got="$(command cat "$ZRAM_GENERATOR_CONF")"
want=$'[zram1]\nzram-size = 512\n\n[zram0]\nzram-size = ram * 75 / 100\ncompression-algorithm = zstd\nswap-priority = 100'
[ "$got" = "$want" ] \
    && ok "zram_generator_write_conf: чистый перенос перед [zram0] и compression-algorithm = zstd" \
    || bad "zram_generator_write_conf: «${got//$'\n'/ | }»"

ZCONF="$TMP/zramswap"
printf '#ALGO=lz4\nPERCENT=50\n' > "$ZCONF"
REAL_CAT="$(type -P cat)"
mkdir -p "$TMP/zbin"
cat > "$TMP/zbin/cat" <<EOF
#!/bin/sh
if [ "\${1:-}" = /etc/default/zramswap ]; then exec "$REAL_CAT" "$ZCONF"; fi
exec "$REAL_CAT" "\$@"
EOF
chmod +x "$TMP/zbin/cat"
(
    PATH="$TMP/zbin:$PATH"
    write_file() { "$REAL_CAT" > "$ZCONF"; }
    # shellcheck disable=SC2034
    ZRAM_ALGO_BULK=zstd
    zramswap_write_conf 75
)
grep -Fx 'ALGO=zstd' "$ZCONF" >/dev/null \
    && ok "zramswap_write_conf пишет ALGO=zstd при ZRAM_ALGO_BULK=zstd" \
    || bad "zramswap_write_conf ALGO: $(tr '\n' '|' < "$ZCONF")"
grep -Fx 'PERCENT=75' "$ZCONF" >/dev/null \
    && ok "zramswap_write_conf обновил PERCENT=75" \
    || bad "zramswap_write_conf PERCENT: $(tr '\n' '|' < "$ZCONF")"
# shellcheck disable=SC2034
ZRAM_ALGO_BULK=''

echo ""
echo "certbot: cf_write_credentials (600 и .usfc-created)"
CF_CREDS="$TMP/cf/secrets/cloudflare.ini"
CF_BK_ROOT="$TMP/cf-backups"; CF_BK_DIR="$CF_BK_ROOT/20261125-000000-$$"
(
    eval "$saved_backup_file"
    # shellcheck disable=SC2034  # читают backup_file и cf_write_credentials
    USFC_BACKUP_ROOT="$CF_BK_ROOT"
    # shellcheck disable=SC2034
    USFC_BACKUP_DIR="$CF_BK_DIR"
    # shellcheck disable=SC2034
    USFC_DRY_RUN=false
    # shellcheck disable=SC2034
    USFC_SKIP_BACKUP=false
    # shellcheck disable=SC2034
    CF_CREDENTIALS="$CF_CREDS"
    chown() { :; }   # без root chown root:root вернёт ошибку
    cf_write_credentials "cf-test-token-123"
) >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "cf_write_credentials: rc 0" || bad "cf_write_credentials: rc=$rc"
mode="$(stat -c %a "$CF_CREDS" 2>/dev/null)"
[ "$mode" = 600 ] && ok "новый CF_CREDENTIALS создан с правами 600" || bad "права CF_CREDENTIALS: «$mode»"
grep -Fx 'dns_cloudflare_api_token = cf-test-token-123' "$CF_CREDS" >/dev/null 2>&1 \
    && ok "токен записан в CF_CREDENTIALS" || bad "содержимое CF_CREDENTIALS не совпало"
grep -qxF -- "$CF_CREDS" "${CF_BK_DIR}/.usfc-created" 2>/dev/null \
    && ok "новый файл записан в .usfc-created внутри USFC_BACKUP_DIR" \
    || bad "путь не найден в ${CF_BK_DIR}/.usfc-created"
[ ! -e "${CF_BK_DIR}${CF_CREDS}" ] \
    && ok "пустая копия файла в каталоге снимка не создана" \
    || bad "в снимке создана копия нового файла: ${CF_BK_DIR}${CF_CREDS}"

echo ""
echo "fastfetch: debian_small из локального config.jsonc и без curl в dry-run"
FF_SRC_DIR="$(cd "$(dirname "${1:-src/setup.sh}")" && pwd)"
FF_HOME="$TMP/ff-deb"; mkdir -p "$FF_HOME"
rm -f "$TMP/ff-curl-deb" "$TMP/ff-curl-dry"
(
    # shellcheck disable=SC2034  # читают os_is_debian, ensure_user_dir и apply_fastfetch
    OS_ID=debian
    # shellcheck disable=SC2034
    SCRIPT_DIR="$FF_SRC_DIR"
    # shellcheck disable=SC2034
    TARGET_USER="$(id -un)"
    # shellcheck disable=SC2034
    TARGET_HOME="$FF_HOME"
    # shellcheck disable=SC2034
    USFC_DRY_RUN=false
    fastfetch() { echo "fastfetch 2.40.4"; }
    curl() { echo "$*" >> "$TMP/ff-curl-deb"; return 1; }
    chown() { :; }
    apply_fastfetch
) >/dev/null 2>&1; rc=$?
FF_CFG="$FF_HOME/.config/fastfetch/config.jsonc"
[ "$rc" -eq 0 ] && [ -f "$FF_CFG" ] \
    && ok "apply_fastfetch на Debian создал config.jsonc" || bad "apply_fastfetch Debian: rc=$rc"
if grep -F '"debian_small"' "$FF_CFG" >/dev/null 2>&1 \
   && ! grep -F '"ubuntu_small"' "$FF_CFG" >/dev/null 2>&1; then
    ok "на Debian ubuntu_small заменён на debian_small"
else
    bad "логотип в config.jsonc на Debian не заменён"
fi
[ ! -e "$TMP/ff-curl-deb" ] \
    && ok "использован локальный config.jsonc без вызова curl" \
    || bad "curl был вызван при наличии локального config.jsonc: $(cat "$TMP/ff-curl-deb")"

FF_DRY="$TMP/ff-dry"; mkdir -p "$FF_DRY"
(
    # shellcheck disable=SC2034  # читают dry_run_enable и apply_fastfetch
    OS_ID=debian
    # shellcheck disable=SC2034
    TARGET_USER="$(id -un)"
    # shellcheck disable=SC2034
    TARGET_HOME="$FF_DRY"
    # shellcheck disable=SC2034
    SCRIPT_DIR="$TMP/no-local-cfg"
    # shellcheck disable=SC2034
    USFC_DRY_RUN=true
    dry_run_enable
    fastfetch() { echo "fastfetch 2.40.4"; }
    curl() { echo "$*" >> "$TMP/ff-curl-dry"; return 1; }
    apply_fastfetch
) >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && [ ! -e "$TMP/ff-curl-dry" ] && [ ! -e "$FF_DRY/.config/fastfetch/config.jsonc" ]; } \
    && ok "USFC_DRY_RUN=true: curl не вызывается и config.jsonc не создаётся" \
    || bad "dry-run fastfetch: rc=$rc curl=$(cat "$TMP/ff-curl-dry" 2>/dev/null)"

echo ""
echo "hostname: _hn_tz_matches находит симлинки часовых поясов"
ZI="$TMP/zoneinfo"
mkdir -p "$ZI/Europe" "$ZI/Asia"
: > "$ZI/Europe/Kyiv"
ln -s Kyiv "$ZI/Europe/Kiev"
: > "$ZI/Asia/Kolkata"
ln -s Kolkata "$ZI/Asia/Calcutta"
out="$(
    _hn_systemd() { return 1; }
    cd() {
        if [ "${1:-}" = /usr/share/zoneinfo ]; then
            builtin cd "$ZI" || return 1
        else
            builtin cd "$@" || return 1
        fi
    }
    _hn_tz_matches "Kiev"
)"
[ "$out" = "Europe/Kiev" ] \
    && ok "_hn_tz_matches находит симлинк Europe/Kiev" \
    || bad "_hn_tz_matches симлинк: «${out}»"
out="$(
    _hn_systemd() { return 1; }
    cd() {
        if [ "${1:-}" = /usr/share/zoneinfo ]; then
            builtin cd "$ZI" || return 1
        else
            builtin cd "$@" || return 1
        fi
    }
    _hn_tz_matches "Kyiv"
)"
[ "$out" = "Europe/Kyiv" ] \
    && ok "_hn_tz_matches по-прежнему находит обычный файл Europe/Kyiv" \
    || bad "_hn_tz_matches файл: «${out}»"

echo ""
echo "fail2ban: расхождение порта FAIL2BAN_DROPIN с SSH_PORT"
F2B_DROPIN="$TMP/f2b-sshd.local"
printf '[sshd]\nenabled = true\nport = 22\n' > "$F2B_DROPIN"
out="$(
    # shellcheck disable=SC2034  # читает status_fail2ban
    FAIL2BAN_DROPIN="$F2B_DROPIN"
    # shellcheck disable=SC2034
    SSH_PORT=2222
    # shellcheck disable=SC2034
    SSHD_PORTS='2222'
    systemctl() { return 0; }
    fail2ban-client() { return 0; }
    status_fail2ban
)"; rc=$?
{ [ "$rc" -ne 0 ] && [[ "$out" == *"!"* ]] && [[ "$out" == *"22"* && "$out" == *"2222"* ]]; } \
    && ok "порт в drop-in (22) ≠ SSH_PORT (2222) → rc≠0 и «! ...»" \
    || bad "status_fail2ban mismatch: rc=$rc «$out»"
printf '[sshd]\nenabled = true\nport = 2222\n' > "$F2B_DROPIN"
out="$(
    # shellcheck disable=SC2034
    FAIL2BAN_DROPIN="$F2B_DROPIN"
    # shellcheck disable=SC2034
    SSH_PORT=2222
    # shellcheck disable=SC2034
    SSHD_PORTS='2222'
    systemctl() { return 0; }
    fail2ban-client() { return 0; }
    status_fail2ban
)"; rc=$?
{ [ "$rc" -eq 0 ] && [[ "$out" == *"✓"* ]]; } \
    && ok "совпадающий порт (2222) → rc 0 и «✓»" \
    || bad "status_fail2ban match: rc=$rc «$out»"

echo ""
echo "sshkeys: проверка строк, ключи с опциями и импорт gh:octocat"
# Синтетические валидные Ed25519-записи (формат OpenSSH, без приватного ключа)
KEY1='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB test@usfc'
KEY1_OPT="restrict,from=\"10.0.0.1\" ${KEY1}"
KEY2='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC octocat@github'

sshkeys_line_matches "$KEY1" && ok "sshkeys_line_matches: обычный ed25519 принят" || bad "обычный ключ отвергнут"
sshkeys_line_matches "$KEY1_OPT" && ok "sshkeys_line_matches: ключ с опциями (restrict,from=...) принят" || bad "ключ с опциями отвергнут"
if ! sshkeys_line_matches "# $KEY1" && ! sshkeys_line_matches "" \
   && ! sshkeys_line_matches "not-a-key" && ! sshkeys_line_matches "${KEY1}"$'\n'"${KEY2}"; then
    ok "sshkeys_line_matches: комментарий, пусто, мусор и многострочный ввод отвергнуты"
else
    bad "sshkeys_line_matches принял некорректную строку"
fi

sshkeys_validate_line "$KEY1" && ok "sshkeys_validate_line: обычный ключ валиден" || bad "validate KEY1 провалился"
sshkeys_validate_line "$KEY1_OPT" && ok "sshkeys_validate_line: ключ с опциями валиден" || bad "validate KEY1_OPT провалился"
! sshkeys_validate_line "not-a-key" && ok "sshkeys_validate_line: мусор отклонён" || bad "validate принял мусор"
if command -v ssh-keygen >/dev/null 2>&1; then
    sshkeys_validate_line "$KEY1_OPT"
    [[ "$REPLY_SSHKEY_FP" == *"ED25519"* ]] \
        && ok "sshkeys_validate_line заполняет отпечаток через ssh-keygen" \
        || bad "отпечаток неверен: «$REPLY_SSHKEY_FP»"
    ! sshkeys_validate_line 'ssh-ed25519 AAAAnotavalidkeypayload bad@key' \
        && ok "sshkeys_validate_line: битый base64 отклонён ssh-keygen" \
        || bad "битый base64 прошёл ssh-keygen"
fi

AK="$TMP/sshkeys_ak"; : > "$AK"
sshkeys_import_spec "$AK" "$KEY1_OPT" >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && grep -qxF -- "$KEY1_OPT" "$AK"; } \
    && ok "sshkeys_import_spec: добавлен ключ с опциями" \
    || bad "import KEY1_OPT: rc=$rc"
sshkeys_import_spec "$AK" "$KEY1_OPT" >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(grep -cxF -- "$KEY1_OPT" "$AK")" -eq 1 ]; } \
    && ok "sshkeys_import_spec: повторный импорт не дублирует ключ" \
    || bad "дубль ключа: count=$(grep -cxF -- "$KEY1_OPT" "$AK")"
sshkeys_import_spec "$AK" "gh:../evil" >/dev/null 2>&1 \
    && bad "недопустимый gh:../evil принят" || ok "недопустимое имя gh:../evil отклонено"

rm -f "$TMP/gh-curl.args"
(
    curl() {
        printf '%s\n' "$*" > "$TMP/gh-curl.args"
        printf '# keys for octocat\n%s\ngarbage-not-a-key\n' "$KEY2"
    }
    sshkeys_import_spec "$AK" "gh:octocat"
) >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && grep -F 'https://github.com/octocat.keys' "$TMP/gh-curl.args" >/dev/null; } \
    && ok "sshkeys_import_spec gh:octocat запросил https://github.com/octocat.keys" \
    || bad "gh:octocat: rc=$rc args=$(cat "$TMP/gh-curl.args" 2>/dev/null)"
{ grep -qxF -- "$KEY2" "$AK" && ! grep -F 'garbage-not-a-key' "$AK" >/dev/null; } \
    && ok "gh:octocat: валидный ключ добавлен, мусор и комментарии пропущены" \
    || bad "содержимое AK после gh:octocat: $(tr '\n' '|' < "$AK")"
(
    curl() { printf '%s\n' "$KEY2"; }
    sshkeys_import_spec "$AK" "gh:octocat"
) >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(grep -cxF -- "$KEY2" "$AK")" -eq 1 ]; } \
    && ok "повторный gh:octocat: rc 0, ключ не продублирован" \
    || bad "повторный gh:octocat: rc=$rc count=$(grep -cxF -- "$KEY2" "$AK")"

echo ""
[ "$fail" -eq 0 ] && echo "мелкие пункты: все проверки пройдены" || echo "мелкие пункты: ЕСТЬ ОШИБКИ"
exit "$fail"
