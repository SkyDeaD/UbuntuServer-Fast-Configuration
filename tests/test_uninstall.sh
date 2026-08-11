#!/usr/bin/env bash
# Полное удаление usfc: что сносится, что остаётся и чего не трогаем.
#
# Тест работает на НАСТОЯЩЕЙ файловой системе во временном каталоге: rm и sed
# здесь честные. Проверять удаление заглушками бессмысленно — половина смысла
# в том, что именно осталось на диске после.
#
# Подменяются ровно три вещи: пути (USFC_ROOT, USFC_BIN, USFC_LOG,
# USFC_BACKUP_ROOT), список пользователей (getent) и ответы на вопросы.
set -uo pipefail
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }
gone()  { if [ -e "$2" ]; then bad "$1: $2 остался"; else ok "$1"; fi; }
alive() { if [ -e "$2" ]; then ok "$1"; else bad "$1: $2 пропал"; fi; }
has()   { if grep -qF "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1: в $3 нет «$2»"; fi; }
hasnt() { if grep -qF "$2" "$3" 2>/dev/null; then bad "$1: в $3 осталось «$2»"; else ok "$1"; fi; }

# ── стенд: установка usfc со всеми следами ───────────────────────────────────
H1="$TMP/home/user"; H2="$TMP/home/other"; H3="$TMP/root"
setup_stand() {
    # ${TMP:?} — не педантизм: пустой TMP превратил бы это в rm -rf /bin
    rm -rf "${TMP:?}/opt" "${TMP:?}/bin" "${TMP:?}/var" "${TMP:?}/home" "${TMP:?}/root"
    mkdir -p "$TMP/opt/vps-setup/lib" "$TMP/bin" "$TMP/var/log" "$H1" "$H2" "$H3"
    echo 4.1.0 > "$TMP/opt/vps-setup/VERSION"
    echo ru    > "$TMP/opt/vps-setup/lang"
    : > "$TMP/opt/vps-setup/lib/core.sh"
    : > "$TMP/bin/usfc"
    echo "лог" > "$TMP/var/log/usfc.log"
    echo "старый лог" > "$TMP/var/log/usfc.log.1"
    mkdir -p "$TMP/var/backups/usfc/20260811-090000-42/etc/ssh"
    echo "PermitRootLogin yes" > "$TMP/var/backups/usfc/20260811-090000-42/etc/ssh/sshd_config"

    # у первого — и обёртка, и блок пункта: второй трогать нельзя
    cat > "$H1/.bashrc" <<'EOF'
export EDITOR=vim

# >>> vps-setup:self >>>
usfc() {
    sudo /usr/local/bin/usfc "$@"
}
# <<< vps-setup:self <<<

# >>> vps-setup:cli >>>
alias ll='eza -la'
# <<< vps-setup:cli <<<
EOF
    # у второго — только обёртка: её ставят и созданному пользователю
    printf '\n# >>> vps-setup:self >>>\nusfc() { :; }\n# <<< vps-setup:self <<<\n' > "$H2/.bashrc"
    # у root — ничего нашего, файл обязан остаться байт в байт
    echo "# чужой bashrc" > "$H3/.bashrc"

    # shellcheck disable=SC2034  # всё это читает usfc_collect_traces из lib/cli.sh
    USFC_ROOT="$TMP/opt/vps-setup"
    # shellcheck disable=SC2034
    USFC_BIN="$TMP/bin/usfc"
    # shellcheck disable=SC2034
    USFC_LOG="$TMP/var/log/usfc.log"
    # shellcheck disable=SC2034
    USFC_BACKUP_ROOT="$TMP/var/backups/usfc"
}

getent() {
    # один и тот же дом дважды: дедупликация обязана его схлопнуть
    printf 'user:x:1000:1000::%s:/bin/bash\n'   "$H1"
    printf 'other:x:1001:1001::%s:/bin/bash\n'  "$H2"
    printf 'root:x:0:0::%s:/bin/bash\n'         "$H3"
    printf 'dup:x:1002:1002::%s:/bin/bash\n'    "$H1"
    printf 'daemon:x:2:2::/nonexistent:/usr/sbin/nologin\n'
}

# Ответы вынимаются из очереди по одному
ANSWERS=()
ask_yn_t() {
    local a="${ANSWERS[0]:-1}"
    ANSWERS=("${ANSWERS[@]:1}")
    return "$a"
}

# uninstall_self заканчивается exit 0 — зовём в подоболочке. Проверяем всё
# равно диск, а он переживает подоболочку
run() { ( uninstall_self ) > "$TMP/out" 2>&1; OUT="$(sed 's/\x1b\[[0-9;]*m//g' "$TMP/out")"; }

# ── 1. сбор следов ───────────────────────────────────────────────────────────
echo "usfc_collect_traces"
setup_stand
usfc_collect_traces
printf '%s\n' "${USFC_RM_PATHS[@]}" > "$TMP/paths"
for p in "$TMP/bin/usfc" "$TMP/opt/vps-setup" "$TMP/var/log/usfc.log" "$TMP/var/log/usfc.log.1"; do
    if grep -qxF "$p" "$TMP/paths"; then ok "в списке: ${p#$TMP}"; else bad "в списке нет ${p#$TMP}"; fi
done
[ "${#USFC_RM_BASHRC[@]}" -eq 2 ] \
    && ok "найдено 2 .bashrc с обёрткой (дубль схлопнут)" \
    || bad "найдено ${#USFC_RM_BASHRC[@]} .bashrc, ожидалось 2"

# ── 2. отказ на последнем вопросе ────────────────────────────────────────────
echo ""
echo "отказ"
setup_stand
ANSWERS=(1 1)          # снимки — нет, удалять — нет
run
alive "отказ → каталог на месте"      "$TMP/opt/vps-setup"
alive "отказ → команда на месте"      "$TMP/bin/usfc"
alive "отказ → лог на месте"          "$TMP/var/log/usfc.log"
has   "отказ → обёртка не тронута"    "vps-setup:self" "$H1/.bashrc"

# ── 3. удаляем, снимки оставляем ─────────────────────────────────────────────
echo ""
echo "удаление без снимков"
setup_stand
ANSWERS=(1 0)          # снимки — нет, удалять — да
run
gone  "каталог установки удалён"      "$TMP/opt/vps-setup"
gone  "команда удалена"               "$TMP/bin/usfc"
gone  "лог удалён"                    "$TMP/var/log/usfc.log"
gone  "ротированный лог удалён"       "$TMP/var/log/usfc.log.1"
alive "снимки конфигов остались"      "$TMP/var/backups/usfc/20260811-090000-42/etc/ssh/sshd_config"
hasnt "обёртка вырезана у первого"    "vps-setup:self" "$H1/.bashrc"
hasnt "обёртка вырезана у второго"    "vps-setup:self" "$H2/.bashrc"
has   "блок пункта cli НЕ тронут"     "vps-setup:cli"  "$H1/.bashrc"
has   "чужие строки .bashrc целы"     "export EDITOR=vim" "$H1/.bashrc"
[ "$(cat "$H3/.bashrc")" = "# чужой bashrc" ] \
    && ok "посторонний .bashrc не менялся" || bad "посторонний .bashrc изменён"
case "$OUT" in *"Снимки конфигов остались"*) ok "сказано, что снимки остались" ;;
               *) bad "про оставшиеся снимки не сказано" ;; esac

# ── 4. удаляем вместе со снимками ────────────────────────────────────────────
echo ""
echo "удаление со снимками"
setup_stand
ANSWERS=(0 0)          # снимки — да, удалять — да
run
gone "снимки удалены"                 "$TMP/var/backups/usfc"
gone "каталог установки удалён"       "$TMP/opt/vps-setup"

# ── 5. рабочая копия репозитория ─────────────────────────────────────────────
# Запуск из клона — обычное дело при разработке, и USFC_ROOT тогда указывает
# на src. Снести его по кнопке «удалить» значит съесть непушнутые правки
echo ""
echo "запуск из клона репозитория"
setup_stand
mkdir -p "$TMP/opt/.git"          # /opt/vps-setup/../.git
ANSWERS=(1 0)
run
alive "рабочая копия НЕ удалена"      "$TMP/opt/vps-setup"
gone  "команда всё равно удалена"     "$TMP/bin/usfc"
case "$OUT" in *"рабочая копия репозитория"*) ok "сказано, почему каталог оставлен" ;;
               *) bad "не объяснено, почему каталог оставлен" ;; esac
rm -rf "$TMP/opt/.git"

# ── 6. следов не осталось ────────────────────────────────────────────────────
echo ""
echo "удалять нечего"
setup_stand
rm -rf "${TMP:?}/opt" "${TMP:?}/bin" "${TMP:?}/var" "$H1/.bashrc" "$H2/.bashrc"
ANSWERS=(0)
run
case "$OUT" in *"следов usfc на машине не осталось"*) ok "сказано, что удалять нечего" ;;
               *) bad "про отсутствие следов не сказано" ;; esac

echo ""
[ "$fail" -eq 0 ] && echo "удаление: все проверки пройдены" || echo "удаление: ЕСТЬ ПРОВАЛЫ"
exit "$fail"
