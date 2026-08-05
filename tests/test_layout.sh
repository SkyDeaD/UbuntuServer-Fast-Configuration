#!/usr/bin/env bash
# Сверяет новые чисто-bash реализации раскладки со СТАРЫМИ python3-версиями
# (те, что были в setup.sh до оптимизации) на общем корпусе строк.
# Запускается без root: USFC_SOURCE_ONLY отключает проверку прав в setup.sh.
set -uo pipefail

SETUP="${1:-$(dirname "$0")/../src/setup.sh}"
USFC_SOURCE_ONLY=1
export USFC_SOURCE_ONLY
# shellcheck disable=SC1090
source "$SETUP"

FAIL=0
CHECKED=0

# ── эталон: ровно тот код, что стоял в setup.sh 2.4.5 ────────────────────────
ref_visible_len() {
    local plain
    plain="$(printf '%s' "$1" | sed -E 's/\x1b\[[0-9;]*m//g; s/\\033\[[0-9;]*m//g')"
    python3 -c "import sys; print(len(sys.argv[1]))" "$plain" 2>/dev/null || echo "${#plain}"
}
ref_pad_title() {
    local s="$1" width="$2" len pad
    len="$(python3 -c "import sys; print(len(sys.argv[1]))" "$s" 2>/dev/null || echo "${#s}")"
    pad=$((width - len))
    [ "$pad" -lt 1 ] && pad=1
    printf '%s%*s' "$s" "$pad" ""
}
ref_truncate_colored() {
    local text="$1" width="$2" plain color body
    if [ "$(ref_visible_len "$text")" -le "$width" ]; then
        printf '%s' "$text"; return
    fi
    plain="$(printf '%s' "$text" | sed -E 's/\x1b\[[0-9;]*m//g; s/\\033\[[0-9;]*m//g')"
    color="$(printf '%s' "$text" | grep -oE '^(\x1b\[[0-9;]*m|\\033\[[0-9;]*m)')"
    body="$(python3 -c "
import sys
s, w = sys.argv[1], int(sys.argv[2])
print(s[:max(w-3,0)] + '...')
" "$plain" "$width")"
    if [ -n "$color" ]; then printf '%s%s%s' "$color" "$body" "$NC"
    else printf '%s' "$body"; fi
}

check() {
    local label="$1" got="$2" want="$3"
    CHECKED=$((CHECKED + 1))
    if [ "$got" != "$want" ]; then
        FAIL=$((FAIL + 1))
        printf 'FAIL %s\n  новое : %q\n  старое: %q\n' "$label" "$got" "$want"
    fi
}

# ── корпус ───────────────────────────────────────────────────────────────────
# PLAIN — без цветовых кодов. Здесь новая реализация обязана совпадать со старой
# ДОСЛОВНО: именно такие строки старый код и получал на всех реальных вызовах.
PLAIN=(
    ""
    "ascii"
    "установлено"
    "✓ установлено"
    "○ не установлен"
    "─│┌┐└┘├┼┤"
    "ZRAM + swap + earlyoom"
    "Пользователь + sudo"
    "! токен CF не задан"
    "Certbot + плагины"
    "○ не хватает: eza, bat, fd-find, ripgrep, zoxide, ncdu"
    "12345678901234567890123456789012345678901234567890"
)

# COLORED — с цветом. Со СТАРОЙ реализацией сверять нельзя, она на них врала:
#   * pad_title считал длину по сырой строке вместе с escape-байтами;
#   * truncate_colored искал цвет через grep -oE '^(\x1b\[...)', а GNU grep
#     в ERE не понимает \x1b — цвет при обрезке терялся молча.
# Поэтому здесь проверяются инварианты корректности, а не старое поведение.
COLORED=(
    "$(printf '\033[0;32m✓ установлено\033[0m')"
    "$(printf '\033[2m○ не хватает: eza, bat, fd-find, ripgrep, zoxide, ncdu\033[0m')"
    "$(printf '\033[0;33m! установлен, не запущен\033[0m')"
    '\033[1mВыбор:\033[0m'
    '\033[0;36m\033[1mB\033[0m \033[0;36mбаза\033[0m'
)

echo "локаль: LANG=${LANG:-<unset>} LC_ALL=${LC_ALL:-<unset>}  CHARLEN_NATIVE=${CHARLEN_NATIVE}"

# ── PLAIN: дословная сверка со старой реализацией ───────────────────────────
for s in "${PLAIN[@]}"; do
    visible_len "$s"
    check "visible_len(${s:0:24})" "$REPLY_LEN" "$(ref_visible_len "$s")"
done
for w in 1 2 3 6 10 14 26 40; do
    for s in "${PLAIN[@]}"; do
        pad_title "$s" "$w"
        check "pad_title(${s:0:16},$w)" "$REPLY_PAD" "$(ref_pad_title "$s" "$w")"
    done
done
for w in 6 10 14 20 26; do
    for s in "${PLAIN[@]}"; do
        truncate_colored "$s" "$w"
        check "truncate_colored(${s:0:16},$w)" "$REPLY_TRUNC" "$(ref_truncate_colored "$s" "$w")"
    done
done

# ── COLORED: visible_len совпадает (тут старый код был прав — sed снимал ANSI) ─
for s in "${COLORED[@]}"; do
    visible_len "$s"
    check "visible_len(colored)" "$REPLY_LEN" "$(ref_visible_len "$s")"
done

# ── COLORED: инварианты корректности вместо старого поведения ───────────────
for w in 6 10 14 20 26; do
    for s in "${COLORED[@]}"; do
        truncate_colored "$s" "$w"
        # 1) цвет обязан сохраниться (старая версия его теряла)
        case "$REPLY_TRUNC" in
            $'\e['*|'\033['*) ;;
            *) FAIL=$((FAIL+1)); printf 'FAIL цвет потерян: %q -> %q\n' "$s" "$REPLY_TRUNC" ;;
        esac
        CHECKED=$((CHECKED + 1))
        # 2) строка должна закрываться сбросом цвета, иначе потечёт на всю рамку
        case "$REPLY_TRUNC" in
            *$'\e[0m'|*'\033[0m') ;;
            *) FAIL=$((FAIL+1)); printf 'FAIL нет сброса цвета: %q\n' "$REPLY_TRUNC" ;;
        esac
        CHECKED=$((CHECKED + 1))
    done
done

# ── инвариант рамки: результат НИКОГДА не шире width (иначе рамка поедет) ────
for w in 6 10 14 26; do
    for s in "${PLAIN[@]}" "${COLORED[@]}"; do
        truncate_colored "$s" "$w"
        visible_len "$REPLY_TRUNC"
        if [ "$REPLY_LEN" -gt "$w" ]; then
            FAIL=$((FAIL + 1))
            printf 'FAIL ширина: truncate_colored(%q,%s) дал %s символов\n' "$s" "$w" "$REPLY_LEN"
        fi
        CHECKED=$((CHECKED + 1))
        # добивка pad_title тоже не должна вылезать за границу
        pad_title "$s" "$w"
        visible_len "$REPLY_PAD"
        if [ "$REPLY_LEN" -lt "$w" ]; then
            FAIL=$((FAIL + 1))
            printf 'FAIL добивка: pad_title(%q,%s) дал %s символов\n' "$s" "$w" "$REPLY_LEN"
        fi
        CHECKED=$((CHECKED + 1))
    done
done

# ── repeat_dash: ровно N символов ───────────────────────────────────────────
for n in 0 1 5 58 78 98; do
    repeat_dash "$n"
    visible_len "$REPLY_DASH"
    check "repeat_dash($n)" "$REPLY_LEN" "$n"
done

# ── expand_section_letter: сверка с ITEM_SECTIONS ───────────────────────────
expand_section_letter C; check "section C" "$REPLY_SECTION_ITEMS" "1"
expand_section_letter B; check "section B" "$REPLY_SECTION_ITEMS" "2 3 4 5"
expand_section_letter S; check "section S" "$REPLY_SECTION_ITEMS" "6 7 8"
expand_section_letter P; check "section P" "$REPLY_SECTION_ITEMS" "9 10 11 12 13 14"
expand_section_letter X && { FAIL=$((FAIL+1)); echo "FAIL: неизвестная буква X принята"; }
CHECKED=$((CHECKED + 1))

# ── регрессия: logname без login-сессии ─────────────────────────────────────
# На свежей VPS (консоль хостера, cloud-init, systemd-юнит) logname печатает
# "no login name" в stderr и выходит с кодом НОЛЬ. Старый код делал
# `logname 2>/dev/null || echo root` — "||" не срабатывал, TARGET_USER оставался
# пустым, и скрипт падал ещё до меню на ровно том сценарии, ради которого
# всё затевалось. Проверяем, что теперь пустое имя превращается в root.
resolve_target_user() {   # копия логики из шапки setup.sh
    local sudo_user="$1" logname_out="$2" out
    if [ -n "$sudo_user" ] && [ "$sudo_user" != "root" ]; then
        out="$sudo_user"
    else
        out="$logname_out"
    fi
    if [ -z "$out" ] || ! id -u "$out" >/dev/null 2>&1; then
        out=root
    fi
    printf '%s' "$out"
}
check "logname пуст -> root"        "$(resolve_target_user "" "")"            "root"
check "logname мусор -> root"       "$(resolve_target_user "" "нет-такого")"  "root"
check "SUDO_USER=root -> root"      "$(resolve_target_user "root" "")"        "root"
check "SUDO_USER=реальный юзер"     "$(resolve_target_user "root" "root")"    "root"

# ── регрессия: кэш пакетов самоинициализируется ─────────────────────────────
# pkg_installed до refresh_pkg_cache молча отвечал «не установлен» на всё.
# Сбрасываем кэш из setup.sh и проверяем, что pkg_installed наполнит его сам.
# shellcheck disable=SC2034  # читаются внутри pkg_installed из setup.sh
PKG_CACHE_READY=false
# shellcheck disable=SC2034
PKG_INSTALLED=()
if pkg_installed bash; then
    CHECKED=$((CHECKED + 1))
else
    FAIL=$((FAIL + 1)); CHECKED=$((CHECKED + 1))
    echo "FAIL: pkg_installed bash = ложь при непрогретом кэше"
fi

# ── параллельность массивов меню ────────────────────────────────────────────
check "len(ITEM_TITLES)"   "${#ITEM_TITLES[@]}"   "${#ITEM_IDS[@]}"
check "len(ITEM_SECTIONS)" "${#ITEM_SECTIONS[@]}" "${#ITEM_IDS[@]}"
check "len(ROLLBACK_NOTES)" "${#ROLLBACK_NOTES[@]}" "${#ITEM_IDS[@]}"

# у каждого пункта должны существовать status_ и apply_/disable_
for id in "${ITEM_IDS[@]}"; do
    declare -F "status_${id}" >/dev/null || { FAIL=$((FAIL+1)); echo "FAIL: нет status_${id}"; }
    declare -F "apply_${id}"  >/dev/null || { FAIL=$((FAIL+1)); echo "FAIL: нет apply_${id}"; }
    CHECKED=$((CHECKED + 2))
done
for id in "${DISABLE_SUPPORTED[@]}"; do
    declare -F "disable_${id}" >/dev/null || { FAIL=$((FAIL+1)); echo "FAIL: нет disable_${id}"; }
    CHECKED=$((CHECKED + 1))
done

echo "проверок: ${CHECKED}, провалов: ${FAIL}"
[ "$FAIL" -eq 0 ]
