#!/usr/bin/env bash
# Пакетный режим задаёт те же вопросы, что ручной, — только заранее.
#
# Жалоба: раздел целиком (S — docker, nginx, certbot) применялся не так, как
# те же пункты, выбранные по одному. Причина — ask_yn в пакетном прогоне
# молча возвращает дефолт, и всякий вопрос с дефолтом «нет» внутри apply_*
# превращался в «нет»: TLS-заготовки certbot не ставились никогда, UFW не
# включался даже в профилях, где он есть, nginx оставался выключенным.
#
# Инвариант: вопрос с дефолтом N вне preask_/disable_/status_ либо идёт через
# ask_bulk_yn (ответ задаётся заранее), либо помечен `# bulk-ok: <причина>`
# на строке выше — например, когда пункт целиком исключён из пакета.
# Плюс: каждая переменная, которую читает ask_bulk_yn, обнуляется
# reset_bulk_answers — иначе ответ протёк бы в следующий прогон.
set -uo pipefail
ROOT="$(dirname "${1:-src/setup.sh}")"
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }

echo "вопросы с дефолтом «нет» в apply_*"
hits="$(awk '
    FNR == 1 { fn = "" }
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{/ { fn = $1; sub(/\(\).*/, "", fn) }
    /ask_yn_t / && / N(;|\)| *$| *&&| *\|\||; then)/ {
        if (fn !~ /^(preask_|disable_|status_)/ && $0 !~ /bulk-ok/ && prev !~ /bulk-ok/)
            print FILENAME ":" FNR " [" fn "]"
    }
    { prev = $0 }' "$ROOT"/lib/items/*.sh)"
if [ -z "$hits" ]; then ok "каждый либо ask_bulk_yn, либо помечен bulk-ok"; else
    bad "вопрос молча станет «нет» в пакетном режиме:"; printf '      %s\n' "$hits"; fi

echo ""
echo "переменные ask_bulk_yn обнуляются между прогонами"
missing=""
while IFS= read -r v; do
    [[ " ${USFC_BULK_VARS[*]} " == *" $v "* ]] || missing="${missing} ${v}"
done < <(grep -ohE 'ask_bulk_yn [A-Z_]+' "$ROOT"/lib/items/*.sh | awk '{print $2}' | sort -u)
[ -z "$missing" ] && ok "все в USFC_BULK_VARS" || bad "нет в USFC_BULK_VARS:${missing}"

# и сама очистка работает
for v in "${USFC_BULK_VARS[@]}"; do printf -v "$v" '%s' 'Y'; done
reset_bulk_answers
left=""
for v in "${USFC_BULK_VARS[@]}"; do [ -z "${!v}" ] || left="${left} ${v}"; done
[ -z "$left" ] && ok "reset_bulk_answers очищает все" || bad "не очищены:${left}"

echo ""
echo "ask_bulk_yn: заготовленный ответ сильнее дефолта"
# shellcheck disable=SC2034  # читаются через ask_bulk_yn по имени
BULK_MODE=true
# shellcheck disable=SC2034
UFW_BULK=Y
ask_bulk_yn UFW_BULK "в" "q" N && ok "Y при дефолте N → да" || bad "Y проигнорирован"
# shellcheck disable=SC2034
UFW_BULK=N
ask_bulk_yn UFW_BULK "в" "q" Y && bad "N при дефолте Y проигнорирован" || ok "N при дефолте Y → нет"
# shellcheck disable=SC2034
UFW_BULK=''
ask_bulk_yn UFW_BULK "в" "q" N && bad "без ответа в пакете не дефолт" || ok "без ответа в пакете — дефолт"

echo ""
echo "предзапрос вызывается для каждого пункта, у которого он есть"
called=""
preask_tmux() { called="${called} tmux"; }   # у tmux своего нет — подставим
preask_bulk_answers tmux nosuchitem >/dev/null 2>&1
[ "$called" = " tmux" ] && ok "preask_<id> вызван, отсутствующий пропущен" || bad "вызвано: «${called}»"
[[ "$USFC_PREASK_IDS" == *" nosuchitem "* ]] && ok "весь список доступен предзапросам" || bad "USFC_PREASK_IDS: ${USFC_PREASK_IDS}"

echo ""
echo "применённый пункт с новыми ответами прогоняется ещё раз"
# каждая строка: <id> <переменная> <значение> — ответ, ради которого
# filter_pending не должен отсеять уже применённый пункт
while read -r id var val; do
    reset_bulk_answers
    _item_has_new_answers "$id" && bad "${id}: без ответов считается «есть новые»"
    printf -v "$var" '%s' "$val"
    _item_has_new_answers "$id" && ok "${id}: ${var}" || bad "${id}: ${var} не заставил прогнать пункт"
done <<'ROWS'
hostname HOSTNAME_BULK node-1
hostname TIMEZONE_BULK UTC
journald JOURNAL_MAX_BULK 200
cli STARSHIP_PRESET_BULK git
cli STARSHIP_PROD_BULK Y
notify TG_CHAT_BULK 12345
notify NOTIFY_EVENTS_BULK ssh
motd MOTD_CLEAN_BULK Y
docker LAZYDOCKER_BULK Y
zram ZRAM_RECONF_BULK Y
zram SWAP_BULK_MB 1024
unattended REBOOT_TIME_BULK 04:00
sshhardening SSH_PORT_NEW_BULK 2222
ROWS
reset_bulk_answers

echo ""
echo "меню: повторный выбор настроенного пункта"
# process_item на применённом ⇄-пункте: у перенастраиваемого сначала
# вопрос «настроить заново?», у остальных — сразу disable_<id>
saved_pi="$(declare -f item_applied ask_yn_t apply_unattended disable_unattended apply_bbr disable_bbr)"
ran=""
item_applied() { return 0; }
apply_unattended()   { ran="apply"; }
disable_unattended() { ran="disable"; }
apply_bbr()          { ran="apply"; }
disable_bbr()        { ran="disable"; }
# shellcheck disable=SC2034  # читается process_item
BULK_MODE=false
ua_n=0; bbr_n=0
for i in "${!ITEM_IDS[@]}"; do
    [ "${ITEM_IDS[$i]}" = unattended ] && ua_n=$((i + 1))
    [ "${ITEM_IDS[$i]}" = bbr ] && bbr_n=$((i + 1))
done
ask_yn_t() { return 0; }
ran=""; process_item "$ua_n" >/dev/null 2>&1
[ "$ran" = apply ] && ok "unattended: «да» — настроить заново" || bad "unattended, «да»: ${ran}"
ask_yn_t() { return 1; }
ran=""; process_item "$ua_n" >/dev/null 2>&1
[ "$ran" = disable ] && ok "unattended: «нет» — выключить" || bad "unattended, «нет»: ${ran}"
ask_yn_t() { return 0; }
ran=""; process_item "$bbr_n" >/dev/null 2>&1
[ "$ran" = disable ] && ok "bbr: без вопроса — переключатель" || bad "bbr: ${ran}"
item_supports_reconf notify && ok "notify перенастраивается" || bad "notify не помечен usfc_item_reconf"
eval "$saved_pi"
# shellcheck disable=SC2034
BULK_MODE=true

echo ""
[ "$fail" -eq 0 ] && echo "паритет пакетного режима: все проверки пройдены" || echo "паритет пакетного режима: ЕСТЬ ОШИБКИ"
exit "$fail"
