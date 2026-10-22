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
has   "версия блока — v3"       "usfc:cli-block v3"       "$TMP/.bashrc"
has   "функция ports в блоке"   "ports() {"               "$TMP/.bashrc"
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

# ── 3б. status_cli видит устаревший блок ─────────────────────────────────────
# Раньше смотрел только на наличие блока: устаревший давал «✓ установлено», и
# повторный выбор пункта нечем было оправдать
echo ""
echo "status_cli и версия блока"
pkg_installed() { return 0; }
printf '# >>> vps-setup:cli >>>\nalias ls=x\n# <<< vps-setup:cli <<<\n' > "$TMP/.bashrc"
out="$(status_cli 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "устаревший блок → status_cli возвращает 1" || bad "устаревший блок прошёл как применённый"
[[ "$out" == *"!"* ]] && ok "устаревший блок помечен «!»" || bad "нет «!» в статусе: $out"
cli_write_aliases >/dev/null 2>&1
status_cli >/dev/null 2>&1 && ok "свежий блок → status_cli возвращает 0" || bad "свежий блок не считается применённым"

# ── 3в. функции блока: ports, dps, extract, myip ────────────────────────────
echo ""
echo "функции блока"
sed -n '/# >>> vps-setup:cli >>>/,/# <<< vps-setup:cli <<</p' "$TMP/.bashrc" > "$TMP/block.sh"
bash -n "$TMP/block.sh" && ok "вырезанный блок проходит bash -n" || bad "блок не разбирается"
for fn in ports extract myip _usfc_need; do
    bash -c 'source "$1"; declare -F "$2" >/dev/null' _ "$TMP/block.sh" "$fn" \
        && ok "функция ${fn} определена" || bad "функции ${fn} нет"
done
# dps — только при docker на момент запуска оболочки
bash -c 'PATH=/nonexistent; source "$1"; declare -F dps >/dev/null' _ "$TMP/block.sh" \
    && bad "dps определена без docker" || ok "dps нет, пока docker не установлен"
mkdir "$TMP/fakebin"; printf '#!/bin/sh\necho "$@"\n' > "$TMP/fakebin/docker"; chmod +x "$TMP/fakebin/docker"
bash -c 'PATH="$2:$PATH"; source "$1"; dps' _ "$TMP/block.sh" "$TMP/fakebin" 2>&1 | grep 'table {{.Names}}' >/dev/null \
    && ok "dps зовёт docker ps с компактным форматом" || bad "dps не отработала"
# extract: реальные архивы
mkdir "$TMP/ex" && cd "$TMP/ex" || exit 1
echo hello > f.txt
tar -czf a.tar.gz f.txt && gzip -k f.txt
archives=(a.tar.gz)
# (type -P: command в этом тесте подменён) в минимальном образе нет xz — тогда .tar.xz не проверить, это не провал extract
type -P xz >/dev/null && tar -cJf b.tar.xz f.txt && archives+=(b.tar.xz)
for a in "${archives[@]}"; do
    rm -f f.txt; bash -c 'source "$1"; extract "$2"' _ "$TMP/block.sh" "$a" 2>/dev/null
    [ "$(cat f.txt 2>/dev/null)" = hello ] && ok "extract ${a}" || bad "extract ${a} не распаковал"
done
rm -f f.txt; bash -c 'source "$1"; extract f.txt.gz' _ "$TMP/block.sh" 2>/dev/null
[ "$(cat f.txt 2>/dev/null)" = hello ] && ok "extract f.txt.gz" || bad "extract .gz не распаковал"
bash -c 'source "$1"; extract nofile.tar.gz' _ "$TMP/block.sh" 2>/dev/null \
    && bad "extract несуществующего файла вернул 0" || ok "extract: нет файла → ошибка"
echo x > weird.foo
out="$(bash -c 'source "$1"; extract weird.foo' _ "$TMP/block.sh" 2>&1)"
[[ "$out" == *"unknown archive"* ]] \
    && ok "extract: неизвестный тип → понятная ошибка" || bad "нет сообщения о неизвестном типе"
if ! builtin command -v unzip >/dev/null 2>&1; then
    : > z.zip
    out="$(bash -c 'source "$1"; extract z.zip' _ "$TMP/block.sh" 2>&1)"
    [[ "$out" == *"'unzip' is not installed"* ]] \
        && ok "extract: нет unzip → понятная ошибка" || bad "нет сообщения про unzip"
fi
cd - >/dev/null || exit 1
if builtin command -v ss >/dev/null 2>&1; then
    bash -c 'source "$1"; ports' _ "$TMP/block.sh" 2>/dev/null | grep '^PROTO' >/dev/null \
        && ok "ports печатает заголовок" || bad "ports не отработала"
fi

# ── 4. .bashrc остаётся исполнимым ───────────────────────────────────────────
echo ""
bash -n "$TMP/.bashrc" && ok "получившийся .bashrc синтаксически цел" \
                       || bad "получившийся .bashrc не разбирается"

echo ""
[ "$fail" -eq 0 ] && echo "блок алиасов: все проверки пройдены" || echo "блок алиасов: ЕСТЬ ПРОВАЛЫ"
exit "$fail"
