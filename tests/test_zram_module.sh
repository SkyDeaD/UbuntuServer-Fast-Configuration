#!/usr/bin/env bash
# Проверка модуля ядра zram: пять состояний машины и шесть исходов пункта.
#
# Живьём это не проверить: нужны разом машина с zram, машина без него,
# контейнер, сервер с обновлённым ядром без перезагрузки и образ с ядром
# провайдера. Поэтому подменяем ровно четыре внешние точки — modinfo,
# systemd-detect-virt, uname и apt, — а всю остальную логику гоняем настоящую.
#
# Ради этого в zram_module_state вынесены USFC_SYSFS и USFC_MODULES_DIR.
set -uo pipefail
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/sys" "$TMP/modules"

fail=0
ok()   { printf '  ✓ %s\n' "$1"; }
bad()  { printf '  ✗ %s\n' "$1"; fail=1; }
# is <что проверяем> <ожидание> <факт>
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: ожидалось «$2», получено «$3»"; fi; }
# has <что проверяем> <подстрока> <текст>
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1: в выводе нет «$2»" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1: в выводе есть лишнее «$2»" ;; *) ok "$1" ;; esac; }

# ── окружение по умолчанию: своё ядро, модуля нет, не контейнер ───────────────
# shellcheck disable=SC2034  # читаются внутри zram_module_state из src/lib/swap.sh
USFC_SYSFS="$TMP/sys"
# shellcheck disable=SC2034
USFC_MODULES_DIR="$TMP/modules"
uname()               { echo "9.9.9-test"; }
modinfo()             { return 1; }
systemd-detect-virt() { return 1; }
mkdir -p "$TMP/modules/9.9.9-test"

# ── 1. zram_module_state: пять состояний ─────────────────────────────────────
echo "zram_module_state"

: > "$TMP/sys/block_zram0_placeholder"
mkdir -p "$TMP/sys/class"; : > "$TMP/sys/class/zram-control"
zram_module_state; is "устройство уже есть → ok" ok "$REPLY_ZRAM_MOD"
rm -f "$TMP/sys/class/zram-control"

modinfo() { return 0; }
zram_module_state; is "модуль лежит на диске → ok" ok "$REPLY_ZRAM_MOD"
modinfo() { return 1; }

systemd-detect-virt() { return 0; }
zram_module_state; is "контейнер → container" container "$REPLY_ZRAM_MOD"
systemd-detect-virt() { return 1; }

uname() { echo "не-существует"; }
zram_module_state; is "каталога модулей нет → stale" stale "$REPLY_ZRAM_MOD"
uname() { echo "9.9.9-test"; }

zram_module_state; is "своё ядро, модуля нет → absent" absent "$REPLY_ZRAM_MOD"

# ── 2. pkg_candidate_mb: разбор вывода apt ───────────────────────────────────
echo ""
echo "pkg_candidate_mb"

apt-cache() {
    case "$1" in
        policy) printf '%s:\n  Installed: (none)\n  Candidate: %s\n' "$2" "$CAND" ;;
        show)   [ -n "$SIZE" ] && printf 'Package: %s\nSize: %s\n' "$2" "$SIZE" ;;
    esac
}
CAND="6.8.0-31.31"; SIZE=121579712
if pkg_candidate_mb linux-modules-extra-x; then
    is "кандидат есть → размер в МБ" 115 "$REPLY_PKG_MB"
else
    bad "кандидат есть, но функция вернула 1"
fi
CAND="(none)"; SIZE=""
pkg_candidate_mb linux-modules-extra-x && bad "«(none)» принят за кандидата" \
    || ok "кандидата нет → возврат 1"
CAND="1.2.3"; SIZE=""
if pkg_candidate_mb x; then is "apt не сказал размер → 0, но кандидат есть" 0 "$REPLY_PKG_MB"
else bad "кандидат есть, размера нет — функция не должна падать"; fi

# ── 3. zram_ensure_module: шесть исходов ─────────────────────────────────────
echo ""
echo "zram_ensure_module"

# Заглушки внешних действий. DISABLED становится true, если пункт убрал
# за собой упавшую службу, INSTALLED — если дело дошло до установки пакета.
DISABLED=false; INSTALLED=false; RESET=false
ensure_apt_updated() { :; }
systemctl() {
    case "${1:-}" in
        is-enabled)   return 0 ;;               # служба «включена» — есть что гасить
        disable)      DISABLED=true ;;
        reset-failed) RESET=true ;;
    esac
}
ensure_pkg() { INSTALLED=true; return "$PKG_RC"; }
modprobe()   { MODPROBED=true; }

# run → OUT, RC; сбрасывает флаги.
#
# Вывод уходит в файл, а не в $( ): подстановка команд — подоболочка, и
# DISABLED/INSTALLED, выставленные внутри неё, до проверок бы не дожили.
# Первая версия теста именно так и «провалила» половину исправных веток.
run() {
    DISABLED=false; INSTALLED=false; MODPROBED=false; RESET=false; ASKED=""
    zram_ensure_module > "$TMP/out" 2>&1; RC=$?
    OUT="$(sed 's/\x1b\[[0-9;]*m//g' "$TMP/out")"
}

CAND="6.8.0-31.31"; SIZE=121579712; PKG_RC=0
ask_yn_t() { return "$ANSWER"; }

# 3.1 модуль на месте — ничего не делаем
modinfo() { return 0; }
run
is   "модуль есть → 0" 0 "$RC"
is   "модуль есть → ничего не ставили" false "$INSTALLED"
is   "модуль есть → службу не трогали" false "$DISABLED"
modinfo() { return 1; }

# 3.2 контейнер
systemd-detect-virt() { return 0; }
run
is  "контейнер → 1" 1 "$RC"
has "контейнер → сказано про контейнер" "контейнер" "$OUT"
is  "контейнер → упавшая служба выключена" true "$DISABLED"
# disable не снимает записанное состояние failed, и `systemctl --failed`
# продолжает показывать юнит — ту самую красную строку, ради которой всё это
is  "контейнер → состояние failed сброшено" true "$RESET"
is  "контейнер → пакет не ставили" false "$INSTALLED"
systemd-detect-virt() { return 1; }

# 3.3 ядро обновлено без перезагрузки
uname() { echo "не-существует"; }
run
is  "ядро без перезагрузки → 1" 1 "$RC"
has "ядро без перезагрузки → сказано перезагрузиться" "ерезагруз" "$OUT"
is  "ядро без перезагрузки → служба выключена" true "$DISABLED"
uname() { echo "9.9.9-test"; }

# 3.4 модуля нет и пакета нет — ядро провайдера
CAND="(none)"
run
is  "пакета нет → 1" 1 "$RC"
has "пакета нет → назван пакет" "linux-modules-extra-9.9.9-test" "$OUT"
is  "пакета нет → служба выключена" true "$DISABLED"
is  "пакета нет → ничего не ставили" false "$INSTALLED"
CAND="6.8.0-31.31"

# 3.5 пакет есть, человек отказался
ANSWER=1
run
is  "отказ → 1" 1 "$RC"
is  "отказ → ничего не поставили" false "$INSTALLED"
is  "отказ → служба выключена" true "$DISABLED"

# 3.6 пакет есть, согласился, модуль появился
ANSWER=0
modinfo() { [ "${MODPROBED:-false}" = true ] && return 0; return 1; }
run
is  "согласие и модуль появился → 0" 0 "$RC"
is  "согласие → пакет поставлен" true "$INSTALLED"
is  "успех → службу не гасим" false "$DISABLED"

# 3.7 поставили, а модуля всё равно нет
modinfo() { return 1; }
run
is  "модуль не появился → 1" 1 "$RC"
has "модуль не появился → сказано про перезагрузку" "ерезагруз" "$OUT"
is  "модуль не появился → служба выключена" true "$DISABLED"

# 3.8 сухой прогон не должен объявлять неудачу установки, которой не было
USFC_DRY_RUN=true
run
is    "сухой прогон → 0" 0 "$RC"
hasnt "сухой прогон → без ложной ошибки" "так и не появился" "$OUT"
is    "сухой прогон → службу не гасим" false "$DISABLED"
# shellcheck disable=SC2034  # читается внутри zram_ensure_module
USFC_DRY_RUN=false

# 3.9 размер пакета берётся из apt и попадает в вопрос
ASKED=""
ask_yn_t() { ASKED="$1"; return 1; }
run
has "в вопросе есть размер из apt" "115 МБ" "$ASKED"

# ── 4. строка аудита про подкачку ────────────────────────────────────────────
# Пометку «(zram)» ставила подстановка ${ZRAM_ACTIVE:+ …}, которая срабатывает
# на любую непустую строку — то есть и на слово «false». Аудит бодро писал
# «Подкачка есть (zram)» на машине, где zram выключен или падает.
echo ""
echo "audit_memory"

item_number() { echo 12; }
systemctl()   { return 1; }   # zramswap не включён — про него аудит молчит

audit_line() {  # audit_line <zram активен> → OUT
    # shellcheck disable=SC2034  # читается внутри audit_memory
    ZRAM_ACTIVE="$1"
    # shellcheck disable=SC2034
    SWAP_ACTIVE=true
    read_swap_state() { :; }
    audit_memory > "$TMP/out" 2>&1
    OUT="$(sed 's/\x1b\[[0-9;]*m//g' "$TMP/out")"
}

audit_line false
hasnt "zram выключен → без пометки (zram)" "(zram)" "$OUT"
has   "zram выключен → про подкачку всё равно сказано" "Подкачка есть" "$OUT"
audit_line true
has   "zram работает → пометка (zram) на месте" "Подкачка есть (zram)" "$OUT"

echo ""
[ "$fail" -eq 0 ] && echo "zram: все проверки пройдены" || echo "zram: ЕСТЬ ПРОВАЛЫ"
exit "$fail"
