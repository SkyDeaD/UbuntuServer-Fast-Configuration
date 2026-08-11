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

# Эталон построен на python3. Без него ref_* молча свалились бы на побайтовый
# фолбэк и сравнивали новую реализацию с заведомо неверными числами — то есть
# тесты «проходили» бы, ничего не проверяя. Лучше отказаться сразу.
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 не найден — эталонные реализации работать не смогут, тесты бессмысленны" >&2
    exit 2
fi

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

# ── регрессия: пустые массивы под set -u ────────────────────────────────────
# `declare -A x` БЕЗ присваивания оставляет переменную «необъявленной» для
# set -u, и первое же ${#x[@]} роняет скрипт с «unbound variable» (bash 5.3).
# Ловилось это на самом первом показе шапки — то есть у каждого пользователя.
for arr in PKG_INSTALLED _DASH_CACHE STATUS_TEXT STATUS_RC LOGO_COLORS HEADER_INFO \
           SUMMARY_TITLES SUMMARY_RESULTS SUMMARY_TIMES SUMMARY_FAILED; do
    if (set -u; eval "n=\${#${arr}[@]}") 2>/dev/null; then
        CHECKED=$((CHECKED + 1))
    else
        FAIL=$((FAIL + 1)); CHECKED=$((CHECKED + 1))
        echo "FAIL: \${#${arr}[@]} падает под set -u — нужно объявить с =()"
    fi
done

# build_progress обязана переживать непостроенный кэш статусов: шапка рисуется
# раньше, чем refresh_statuses успевает отработать
# shellcheck disable=SC2034  # читаются внутри build_progress из setup.sh
STATUS_TEXT=()
# shellcheck disable=SC2034
STATUS_RC=()
if (set -u; build_progress) 2>/dev/null; then
    CHECKED=$((CHECKED + 1))
else
    FAIL=$((FAIL + 1)); CHECKED=$((CHECKED + 1))
    echo "FAIL: build_progress падает при пустом кэше статусов"
fi

# ── справка по пунктам: массивы параллельны и заполнены ─────────────────────
check "len(ITEM_SHORT)" "${#ITEM_SHORT[@]}" "${#ITEM_IDS[@]}"
check "len(ITEM_FULL)"  "${#ITEM_FULL[@]}"  "${#ITEM_IDS[@]}"
for idx in "${!ITEM_IDS[@]}"; do
    if [ -z "${ITEM_SHORT[$idx]}" ]; then
        FAIL=$((FAIL+1)); echo "FAIL: пустое ITEM_SHORT у пункта $((idx+1))"
    fi
    CHECKED=$((CHECKED + 1))
    if [ -z "${ITEM_FULL[$idx]}" ]; then
        FAIL=$((FAIL+1)); echo "FAIL: пустое ITEM_FULL у пункта $((idx+1))"
    fi
    CHECKED=$((CHECKED + 1))
done

# ── у каждого устанавливаемого пакета есть описание ─────────────────────────
# Иначе в отчёте после установки будет пустая строка вместо пояснения
for pkg in $BASE_PKGS $CLI_PKGS; do
    if [ -z "${PKG_DESC[$pkg]:-}" ]; then
        FAIL=$((FAIL+1)); echo "FAIL: нет PKG_DESC[$pkg]"
    fi
    CHECKED=$((CHECKED + 1))
done

# ── режим NO_COLOR: разметка не должна ломаться на пустых цветах ────────────
# Сохраняем цвета, обнуляем, проверяем длины, возвращаем обратно
_save_nc="$NC"; _save_bold="$BOLD"; _save_green="$GREEN"
NC=''; BOLD=''; GREEN=''
visible_len "${GREEN}✓ установлено${NC}"
check "NO_COLOR: visible_len" "$REPLY_LEN" "13"
pad_title "${BOLD}Пункт${NC}" 20
visible_len "$REPLY_PAD"
check "NO_COLOR: pad_title"   "$REPLY_LEN" "20"
NC="$_save_nc"; BOLD="$_save_bold"; GREEN="$_save_green"

# ── арифметика ширин таблицы меню ───────────────────────────────────────────
# Колонок теперь три (#/Пункт/Статус), а не четыре: раздел уехал в подзаголовок
# группы. Инвариант: рамка обязана точно совпадать с TERM_W, иначе на реальном
# pty многобайтовые "─" рвутся переносом строки посреди символа.
for tw in 58 78 98 118; do
    idx_w=3; title_w=26
    status_w=$(( tw - idx_w - title_w - 10 ))
    [ "$status_w" -lt 6 ] && status_w=6
    # box_line рисует: left + (w+2) + mid + (w+2) + mid + (w+2) + right
    frame=$(( (idx_w + 2) + (title_w + 2) + (status_w + 2) + 4 ))
    check "ширина рамки при TERM_W=$tw" "$frame" "$tw"
done
# и та же проверка на живой функции, а не только на арифметике
for tw in 58 78 98 118; do
    box_line "" '╭' '┬' '╮' 3 26 $(( tw - 3 - 26 - 10 )) > /tmp/usfc_frame.$$ 2>/dev/null
    line="$(sed 's/^  //' /tmp/usfc_frame.$$)"
    rm -f /tmp/usfc_frame.$$
    visible_len "$line"
    check "box_line при TERM_W=$tw" "$REPLY_LEN" "$tw"
done

# Рамка экрана справки здесь НЕ проверяется: на тесном терминале ширины колонок
# пересчитываются с ужатием, и повторять эту логику в тесте значило бы завести
# второй источник истины, который разъедется с первым. Вместо этого есть
# tests/test_help_widths.sh — он гоняет саму show_item_help и меряет её вывод.

# ── метка ⇄ стоит ровно у тех пунктов, что умеют отключаться ────────────────
# Раньше об этом была строка в легенде, и она врала: обещала «любой применённый
# пункт защиты», хотя SSH hardening — тоже защита, но отключаться не умеет.
# Метка не должна разъехаться с DISABLE_SUPPORTED.
for id in "${ITEM_IDS[@]}"; do
    in_list=false
    for d in "${DISABLE_SUPPORTED[@]}"; do [ "$d" = "$id" ] && in_list=true; done
    if item_supports_disable "$id"; then got=true; else got=false; fi
    check "item_supports_disable($id)" "$got" "$in_list"
done
# и сама функция отключения обязана существовать у каждого помеченного
for d in "${DISABLE_SUPPORTED[@]}"; do
    if declare -F "disable_${d}" >/dev/null; then got=есть; else got=нет; fi
    check "disable_${d} определена" "$got" "есть"
done

# ── status_marker: маркер берётся из STATUS_TEXT, а не выдумывается ─────────
for pair in "✓ установлено:0:✓" "○ не установлен:1:○" "! конфига нет:1:!" "— (нужен Docker):1:—"; do
    txt="${pair%%:*}"; rest="${pair#*:}"; rc="${rest%%:*}"; want="${rest##*:}"
    # shellcheck disable=SC2034,SC2154  # читаются внутри status_marker из setup.sh
    STATUS_TEXT['__t']="$txt"
    # shellcheck disable=SC2034
    STATUS_RC['__t']="$rc"
    STATUS_DIRTY=false          # чтобы refresh_statuses не перезатёр подставленное
    status_marker __t
    strip_ansi "$REPLY_MARKER"
    check "status_marker(${txt:0:14})" "$REPLY_PLAIN" "$want"
    # маркер обязан занимать ровно одну колонку, иначе поедет узкая колонка
    visible_len "$REPLY_MARKER"
    check "ширина маркера(${txt:0:14})" "$REPLY_LEN" "1"
done
unset 'STATUS_TEXT[__t]' 'STATUS_RC[__t]'
# shellcheck disable=SC2034  # читается внутри refresh_statuses из setup.sh
STATUS_DIRTY=true

# ── suggest_swap_mb: min(RAM, свободно/4), кламп 512..4096 ──────────────────
# Формула чистая, но зависит от df и /proc/meminfo — подменяем их заглушками,
# чтобы прогнать таблицу входов, включая обе границы клампа
suggest_swap_stub() {   # <RAM_МБ> <свободно_МБ> -> рекомендация
    local ram="$1" free="$2" want
    want=$(( free / 4 ))
    [ "$ram" -lt "$want" ] && want="$ram"
    [ "$want" -lt 512 ] && want=512
    [ "$want" -gt 4096 ] && want=4096
    echo "$want"
}
check "swap: RAM ограничил"        "$(suggest_swap_stub 1642 6838)" "1642"
check "swap: диск ограничил"       "$(suggest_swap_stub 8192 6000)" "1500"
check "swap: нижний кламп"         "$(suggest_swap_stub 256 1000)"  "512"
check "swap: верхний кламп"        "$(suggest_swap_stub 32768 65536)" "4096"
check "swap: крошечная машина"     "$(suggest_swap_stub 512 2048)"  "512"

# ── swap_needs_resize: порог 10% ────────────────────────────────────────────
swap_needs_resize 1945 1642 && r=да || r=нет; check "resize 1945 vs 1642" "$r" "да"
swap_needs_resize 1700 1642 && r=да || r=нет; check "resize 1700 vs 1642" "$r" "нет"
swap_needs_resize 1642 1642 && r=да || r=нет; check "resize равные"       "$r" "нет"
swap_needs_resize 512 4096  && r=да || r=нет; check "resize 512 vs 4096"  "$r" "да"
swap_needs_resize 1000 0    && r=да || r=нет; check "resize без цели"     "$r" "нет"

# ── human_to_mb: разбор вывода swapon --raw ─────────────────────────────────
check "human_to_mb 1.9G"  "$(human_to_mb 1.9G)"   "1945"
check "human_to_mb 12.1M" "$(human_to_mb 12.1M)"  "12"
check "human_to_mb 2G"    "$(human_to_mb 2G)"     "2048"
check "human_to_mb 4096M" "$(human_to_mb 4096M)"  "4096"
check "human_to_mb 0B"    "$(human_to_mb 0B)"     "0"
check "human_to_mb мусор" "$(human_to_mb '')"     "0"

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

# ── права на cloudflare.ini ─────────────────────────────────────────────────
# Порог тот же, что у certbot: он смотрит ТОЛЬКО биты «остальных»
# (filesystem.has_world_permissions), группа его не волнует. Если разойтись,
# меню начнёт пугать там, где сам certbot молчит.
cf_tmp="$(mktemp)"
# shellcheck disable=SC2034  # читается внутри cf_creds_world_readable из setup.sh
CF_CREDENTIALS="$cf_tmp"
echo "dns_cloudflare_api_token = x" > "$cf_tmp"
for pair in "600:безопасно" "640:безопасно" "660:безопасно" "400:безопасно" \
            "644:опасно" "604:опасно" "606:опасно" "666:опасно"; do
    mode="${pair%%:*}"; want="${pair##*:}"
    chmod "$mode" "$cf_tmp"
    if cf_creds_world_readable; then got=опасно; else got=безопасно; fi
    check "cf_creds_world_readable(${mode})" "$got" "$want"
done
# пустой или отсутствующий файл — это «токена нет», а не «права плохие»
: > "$cf_tmp"; chmod 644 "$cf_tmp"
if cf_creds_world_readable; then got=опасно; else got=безопасно; fi
check "cf_creds_world_readable(пустой файл)" "$got" "безопасно"
rm -f "$cf_tmp"
if cf_creds_world_readable; then got=опасно; else got=безопасно; fi
check "cf_creds_world_readable(файла нет)" "$got" "безопасно"

# ── что сканируют статические проверки ───────────────────────────────────────
# Загрузчик И ВСЕ МОДУЛИ. Раньше здесь стоял один "$SETUP", и после разбиения
# монолита в 4.0.0 запрет `| grep -q` замолчал: в загрузчике такого кода нет
# по определению, а вся логика уехала в lib/. Проверено намеренной регрессией —
# `grep -q` в модуле тест не заметил. Список берём из манифеста, а не глобом:
# так он не разойдётся с тем, что реально грузится.
SCAN_SRC="$(dirname "$SETUP")"
SCAN_FILES=("$SETUP")
while IFS= read -r _m || [ -n "$_m" ]; do
    case "$_m" in ''|'#'*) continue ;; esac
    [ -f "${SCAN_SRC}/${_m}" ] && SCAN_FILES+=("${SCAN_SRC}/${_m}")
done < "${SCAN_SRC}/MODULES"
if [ "${#SCAN_FILES[@]}" -lt 10 ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: под статические проверки попало ${#SCAN_FILES[@]} файлов — манифест не прочитался"
fi
CHECKED=$((CHECKED + 1))

# ── запрет `| grep -q` под set -o pipefail ──────────────────────────────────
# grep -q выходит на первом совпадении, продюсер получает SIGPIPE и умирает с
# кодом 141, а pipefail делает 141 статусом всего пайплайна. Условие становится
# ложным ровно тогда, когда совпадение нашлось, а вывод длинный. На этом молча
# сидел фолбэк Docker: «нет пакетов под 'noble' — переключаюсь на noble»
# печаталось на КАЖДОЙ машине. Ошибка не воспроизводится на коротком выводе,
# поэтому ловим её запретом самого шаблона, а не поведением.
qgrep_hits="$(grep -nE '\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q' "${SCAN_FILES[@]}" | grep -v ':[0-9]*:[[:space:]]*#' || true)"
if [ -n "$qgrep_hits" ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: '| grep -q' под pipefail — обычный grep + >/dev/null:"
    printf '%s\n' "$qgrep_hits" | sed 's/^/      /'
fi
CHECKED=$((CHECKED + 1))

# И сам механизм: если он вдруг перестанет быть проблемой, тест должен об этом
# сказать, а не молча охранять неактуальное правило.
#
# Сверяем НЕ конкретный код, а факт «статус ненулевой, хотя совпадение есть»:
# продюсер может либо умереть от SIGPIPE (141), либо, если сигнал у него
# заблокирован, получить EPIPE и выйти с 1 — на раннере GitHub так и вышло.
# Ломает условие и то, и другое.
sigpipe_demo="$(bash -c 'set -uo pipefail; seq 1 200000 2>/dev/null | grep -q "^1$"; echo $?')"
if [ "$sigpipe_demo" = "0" ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: grep -q в пайплайне больше не ломает статус — запрет выше устарел, перепроверь"
fi
CHECKED=$((CHECKED + 1))

# ── цвет в printf передаётся только через %b ────────────────────────────────
# Цвета заданы строками с escape-последовательностями (DIM='\033[2m'), а printf
# разворачивает их лишь в САМОМ формате и в %b. Через %s на экран уезжает
# «\033[2m[ 1/38]\033[0m lib/core.sh» — ровно это и печатал прогресс
# самообновления, причём видно это было только во время настоящего обновления.
#
# Правило: если цветовая переменная идёт аргументом, в формате обязан быть %b.
pb_hits="$(grep -nE 'printf[^#]*"\$(DIM|NC|BOLD|GREEN|RED|YELLOW|CYAN)"' "${SCAN_FILES[@]}" \
           | grep -v '%b' | grep -v ':[0-9]*:[[:space:]]*#' || true)"
if [ -n "$pb_hits" ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: цвет в printf аргументом, но в формате нет %b — уедет буквально:"
    printf '%s\n' "$pb_hits" | sed 's/^/      /'
fi
CHECKED=$((CHECKED + 1))

# И сам механизм: %s не разворачивает escape, %b разворачивает
esc_demo="$(printf '%s' '\033[2m' | wc -c | tr -d ' ')"
if [ "$esc_demo" != "7" ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: printf %s внезапно разворачивает escape — запрет выше устарел, перепроверь"
fi
CHECKED=$((CHECKED + 1))

echo "проверок: ${CHECKED}, провалов: ${FAIL}"
[ "$FAIL" -eq 0 ]
