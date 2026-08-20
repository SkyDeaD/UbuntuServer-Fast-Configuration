#!/usr/bin/env bash
# Блок алиасов в ~/.bashrc: добавление, обновление устаревшего, идемпотентность.
#
# Проверка ровно на ту ловушку, из-за которой btop чуть не остался незамеченным:
# apply_cli выходил по одному факту наличия маркера блока, и любой добавленный
# позже алиас не доезжал НИ ДО ОДНОЙ уже настроенной машины — молча, потому что
# пункт при этом рапортовал успех.
#
# Работаем на настоящем файле во временном каталоге: смысл проверки в том, ЧТО
# осталось в .bashrc после записи.
set -uo pipefail
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }
has()   { if grep -qF "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1: нет «$2»"; fi; }
hasnt() { if grep -qF "$2" "$3" 2>/dev/null; then bad "$1: осталось «$2»"; else ok "$1"; fi; }
count() { grep -cF "$2" "$3" 2>/dev/null || echo 0; }

# Утилиты в контейнере не установлены, поэтому гейт «ничего не стоит» отсекал бы
# запись целиком. Подменяем ровно проверку наличия — она и есть внешняя точка.
command() {
    if [ "${1:-}" = "-v" ]; then
        case "${2:-}" in eza|batcat|fdfind|btop|zoxide|starship) return 0 ;; esac
        return 1
    fi
    builtin command "$@"
}

# shellcheck disable=SC2034  # читаются внутри cli_write_aliases
TARGET_USER="$(id -un)"
# shellcheck disable=SC2034
TARGET_HOME="$TMP"
chown() { :; }          # в контейнере пользователь один, менять владельца нечему

# ── 1. чистый .bashrc: блок появляется ───────────────────────────────────────
echo "чистая машина"
printf 'export EDITOR=vim\n' > "$TMP/.bashrc"
cli_write_aliases >/dev/null 2>&1
has   "блок записан"            "# >>> vps-setup:cli >>>" "$TMP/.bashrc"
has   "маркер версии на месте"  "$CLI_BLOCK_MARK"         "$TMP/.bashrc"
has   "алиас htop→btop есть"    'alias htop="btop"'       "$TMP/.bashrc"
has   "чужие строки целы"       "export EDITOR=vim"       "$TMP/.bashrc"

# ── 2. повторный прогон ничего не дублирует ──────────────────────────────────
echo ""
echo "повторный прогон"
cli_write_aliases >/dev/null 2>&1
n="$(count x "# >>> vps-setup:cli >>>" "$TMP/.bashrc")"
[ "$n" -eq 1 ] && ok "блок по-прежнему один" || bad "блоков стало $n"

# ── 3. УСТАРЕВШИЙ блок переписывается ────────────────────────────────────────
# Ровно то, что было сломано: старый блок без маркера версии и без btop
echo ""
echo "устаревший блок"
{
  printf 'export EDITOR=vim\n\n'
  printf '# >>> vps-setup:cli >>>\n'
  printf "alias ls='eza --icons'\n"
  printf '# <<< vps-setup:cli <<<\n\n'
  printf 'export PAGER=less\n'
} > "$TMP/.bashrc"
cli_write_aliases >/dev/null 2>&1
has   "маркер версии дописан"     "$CLI_BLOCK_MARK"   "$TMP/.bashrc"
has   "новый алиас доехал"        'alias htop="btop"' "$TMP/.bashrc"
has   "строки до блока целы"      "export EDITOR=vim" "$TMP/.bashrc"
has   "строки после блока целы"   "export PAGER=less" "$TMP/.bashrc"
n="$(count x "# >>> vps-setup:cli >>>" "$TMP/.bashrc")"
[ "$n" -eq 1 ] && ok "старый блок не продублирован" || bad "блоков стало $n"

# ── 4. .bashrc остаётся исполнимым ───────────────────────────────────────────
echo ""
bash -n "$TMP/.bashrc" && ok "получившийся .bashrc синтаксически цел" \
                       || bad "получившийся .bashrc не разбирается"

echo ""
[ "$fail" -eq 0 ] && echo "блок алиасов: все проверки пройдены" || echo "блок алиасов: ЕСТЬ ПРОВАЛЫ"
exit "$fail"
