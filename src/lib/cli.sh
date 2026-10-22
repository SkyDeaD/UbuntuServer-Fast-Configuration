# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# Удаление самого скрипта
# ═══════════════════════════════════════════════════════════════
# Раньше отсюда уходили только /opt/vps-setup и команда usfc, а на машине
# оставались лог, снимки конфигов и блок в ~/.bashrc — то есть функция usfc(),
# зовущая уже несуществующую команду. «Удалил» и получил сломанную оболочку.
#
# Границу держим прежнюю и осознанно: всё, что скрипт УСТАНОВИЛ (пакеты,
# Docker, nginx, правки sshd), не трогается. Удаление инструмента и откат его
# работы — разные действия, и склеивать их нельзя: человек сносит меню, а не
# свой сервер. Команды отката лежат на экране I.
#
# По той же причине не трогаются блоки vps-setup:cli и vps-setup:fastfetch:
# они принадлежат ПУНКТАМ, а не самому скрипту, и выключаются своими пунктами.

# Путь команды — переменной, а не строкой в двух местах: так его подменяет
# tests/test_uninstall.sh, не трогая настоящий /usr/local/bin
USFC_BIN="${USFC_BIN:-/usr/local/bin/usfc}"

USFC_RM_PATHS=()      # файлы и каталоги под снос
USFC_RM_BASHRC=()     # .bashrc, где лежит блок обёртки
USFC_RM_KEEP_ROOT=''  # непустое — почему каталог установки оставлен на месте

usfc_collect_traces() {
    USFC_RM_PATHS=(); USFC_RM_BASHRC=(); USFC_RM_KEEP_ROOT=''
    local p home seen=''

    [ -e "$USFC_BIN" ] && USFC_RM_PATHS+=("$USFC_BIN")

    # Запуск прямо из склонированного репозитория — обычное дело при разработке,
    # и USFC_ROOT тогда указывает на src рабочей копии. Снести её по кнопке
    # «удалить скрипт» значит съесть чужую работу вместе с непушнутыми правками
    if [ -d "${USFC_ROOT}/.git" ] || [ -d "${USFC_ROOT}/../.git" ]; then
        USFC_RM_KEEP_ROOT="$USFC_ROOT"
    elif [ -d "$USFC_ROOT" ]; then
        USFC_RM_PATHS+=("$USFC_ROOT")
    fi

    # USFC_LOG равен /dev/null, если писать было некуда (см. log_init)
    for p in "$USFC_LOG" "${USFC_LOG}.1"; do
        case "$p" in /dev/null*) continue ;; esac
        [ -e "$p" ] && USFC_RM_PATHS+=("$p")
    done

    # Обёртку мог получить не один пользователь: switch_target_user переводит
    # контекст на созданного, и блок ложится в .bashrc и ему тоже
    while IFS=: read -r _ _ _ _ _ home _; do
        [ -n "$home" ] || continue
        case " $seen " in *" $home "*) continue ;; esac
        seen="$seen $home"
        [ -f "${home}/.bashrc" ] || continue
        if grep -qF "# >>> vps-setup:self >>>" "${home}/.bashrc" 2>/dev/null; then
            USFC_RM_BASHRC+=("${home}/.bashrc")
        fi
    done < <(getent passwd)
}

# Размер в скобках — чтобы «удалить лог» не выглядело одинаково для 4 КБ
# и 500 МБ. Нули не печатаем: у симлинка /usr/local/bin/usfc du показывает 0,
# и «(0)» в списке выглядит поломкой, а не размером
usfc_size_note() {
    local sz
    sz="$(du -sh "$1" 2>/dev/null | cut -f1)"
    case "$sz" in ''|0|0B) return 0 ;; esac
    printf '  %b(%s)%b' "$DIM" "$sz" "$NC"
}

uninstall_self() {
    local p n sz drop_backups=false
    usfc_collect_traces

    echo ""
    log_warn_t "Удаление самого usfc" "Removing usfc itself"
    log_info_t "Пакеты, Docker, nginx, правки sshd и всё прочее, что скрипт установил, остаётся на месте — команды отката на экране ${BOLD}I${NC}" \
"Packages, Docker, nginx, sshd changes and everything else the script installed stay put — rollback commands are on screen ${BOLD}I${NC}"

    echo ""
    log_info_t "Будет удалено:" "Will be removed:"
    for p in "${USFC_RM_PATHS[@]}"; do
        printf '      %s%s\n' "$p" "$(usfc_size_note "$p")"
    done
    for p in "${USFC_RM_BASHRC[@]}"; do
        t "блок ${BOLD}usfc()${NC} в" "the ${BOLD}usfc()${NC} block in"
        printf '      %b %s\n' "$REPLY_T" "$p"
    done
    if [ "${#USFC_RM_PATHS[@]}" -eq 0 ] && [ "${#USFC_RM_BASHRC[@]}" -eq 0 ]; then
        log_info_t "  нечего — следов usfc на машине не осталось" \
"  nothing — no traces of usfc left on this machine"
    fi

    if [ -n "$USFC_RM_KEEP_ROOT" ]; then
        echo ""
        log_warn_t "Каталог ${USFC_RM_KEEP_ROOT} НЕ трогаю: это рабочая копия репозитория, а не установка" \
"Leaving ${USFC_RM_KEEP_ROOT} alone: it is a repository working copy, not an install"
    fi

    # Снимки конфигов — отдельным вопросом и по умолчанию «нет». Это
    # единственный способ вернуть sshd_config и fstab к тому, что было до usfc,
    # и сносить их заодно с логом значит закрыть человеку дорогу назад ровно
    # в тот момент, когда он уходит. Снимки переживают удаление сами по себе:
    # это обычные файлы, и откатываются обычным cp, без usfc.
    if [ -d "$USFC_BACKUP_ROOT" ] && [ -n "$(ls -A "$USFC_BACKUP_ROOT" 2>/dev/null)" ]; then
        n="$(find "$USFC_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
        sz="$(du -sh "$USFC_BACKUP_ROOT" 2>/dev/null | cut -f1)"
        echo ""
        log_info_t "Отдельно — снимки конфигов: ${BOLD}${USFC_BACKUP_ROOT}${NC} ${DIM}(${n} шт., ${sz})${NC}" \
"Separately — config snapshots: ${BOLD}${USFC_BACKUP_ROOT}${NC} ${DIM}(${n}, ${sz})${NC}"
        log_info_t "Ими возвращают sshd_config, fstab и остальное к состоянию до usfc. Без скрипта они не пропадут: обычные файлы, копируются обратно вручную" \
"They restore sshd_config, fstab and the rest to what they were before usfc. They keep working without the script: plain files, copied back by hand"
        ask_yn_t "Удалить и снимки тоже?" "Remove the snapshots as well?" N && drop_backups=true
    fi

    echo ""
    if ! ask_yn_t "Удалить перечисленное?" "Remove everything listed above?" N; then
        log_info_t "Отменено, ничего не удалено" "Cancelled, nothing was removed"
        return 0
    fi

    for p in "${USFC_RM_BASHRC[@]}"; do
        remove_block "$p" vps-setup:self
    done
    [ "$drop_backups" = true ] && rm -rf "$USFC_BACKUP_ROOT"
    for p in "${USFC_RM_PATHS[@]}"; do
        rm -rf "$p"
    done

    echo ""
    log_success_t "usfc удалён" "usfc removed"
    if [ "$drop_backups" = false ] && [ -d "$USFC_BACKUP_ROOT" ]; then
        log_info_t "Снимки конфигов остались: ${USFC_BACKUP_ROOT}" \
"Config snapshots remain: ${USFC_BACKUP_ROOT}"
    fi
    if [ "${#USFC_RM_BASHRC[@]}" -gt 0 ]; then
        log_info_t "В текущей оболочке функция ${BOLD}usfc${NC} ещё жива — она исчезнет при следующем входе или после ${BOLD}source ~/.bashrc${NC}" \
"The ${BOLD}usfc${NC} function is still alive in this shell — it goes away on next login or after ${BOLD}source ~/.bashrc${NC}"
    fi
    log_info_t "Пока." "Bye."
    exit 0
}

# ═══════════════════════════════════════════════════════════════
# Командная строка 5.0: команды вместо флагов-режимов
# ═══════════════════════════════════════════════════════════════
# До 5.0 режимы были флагами (--apply, --audit, --list, --backups,
# --restore), и между ними действовал негласный приоритет: `--audit --apply
# web` молча выполнял только аудит. Флаги со значением глотали следующий
# флаг (`--lang --audit` ставил язык «--audit»), `--config` молча
# игнорировался вне --apply, а ITEMS= из файла перебивал командную строку.
#
# Теперь: ровно одна команда — первым словом, у каждой свой набор опций,
# чужая опция или лишний аргумент — ошибка с кодом 2 и объяснением. Старые
# формы не работают, а печатают готовую новую строку: скрипт из cloud-init
# упадёт громко, а не сделает что-то не то.

USFC_COMMANDS="apply audit list backups restore help version"

# Что делать вместо меню. Пусто — обычный интерактивный запуск.
USFC_CMD=""
USFC_APPLY_SPEC=""
USFC_CONFIG_FILE=""
USFC_RESTORE_STAMP=""
USFC_HELP_TOPIC=""
USFC_ASSUME_YES=false
# Ответы, заданные флагами: КЛЮЧ → значение. Применяются ПОСЛЕ файла
# ответов — флаг сильнее файла (apply_cli_answers)
declare -A USFC_FLAG_ANS=()

# _cli_die <ru> <en> — ошибка разбора: сообщение, подсказка, код 2
_cli_die() {
    t "$1" "$2"
    printf 'usfc: %s\n' "$REPLY_T" >&2
    t "Справка: usfc help${USFC_CMD:+ ${USFC_CMD}}" "Help: usfc help${USFC_CMD:+ ${USFC_CMD}}"
    printf '%s\n' "$REPLY_T" >&2
    exit 2
}

# Старые формы → готовая новая строка. Флаг режима становится командой и
# уезжает в начало, всё остальное остаётся как было
_cli_old_form() {
    local cmd="" a
    local -a rest=()
    while [ "$#" -gt 0 ]; do
        a="$1"
        case "$a" in
            --apply)    cmd="apply ${2:-}"; shift ;;
            --apply=*)  cmd="apply ${a#*=}" ;;
            --audit)    cmd="audit" ;;
            --list)     cmd="list" ;;
            --backups)  cmd="backups" ;;
            --restore)  cmd="restore"
                        case "${2:-}" in -*|'') ;; *) cmd="restore $2"; shift ;; esac ;;
            *)          rest+=("$a") ;;
        esac
        shift
    done
    t "в 5.0 режимы стали командами. Вместо этого:" "in 5.0 modes became commands. Use this instead:"
    printf 'usfc: %s\n  usfc %s%s\n' "$REPLY_T" "$cmd" "${rest[*]:+ ${rest[*]}}" >&2
    exit 2
}

# _cli_value <опция> <следующее слово> — значение опции. Значение,
# похожее на опцию, — ошибка: иначе `--lang --audit` поставил бы язык «--audit»
REPLY_CLI_VAL=''; REPLY_CLI_SHIFT=1
_cli_value() {
    local opt="$1"
    case "$opt" in
        *=*) REPLY_CLI_VAL="${opt#*=}"; REPLY_CLI_SHIFT=1 ;;
        *)
            if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == -* ]]; then
                _cli_die "${opt} требует значение" "${opt} needs a value"
            fi
            REPLY_CLI_VAL="$2"; REPLY_CLI_SHIFT=2 ;;
    esac
}

parse_args() {
    local a opt want_help=false want_version=false
    local -a used=()       # «опция:разрешённые команды» — проверяются в конце

    # Язык выясняем ДО разбора: ошибки ниже должны говорить на нём
    for a in "$@"; do
        case "$a" in --lang=en) USFC_LANG=en ;; --lang=ru) USFC_LANG=ru ;; esac
    done
    local prev=''
    for a in "$@"; do
        [ "$prev" = --lang ] && case "$a" in ru|en) USFC_LANG="$a" ;; esac
        prev="$a"
    done

    for a in "$@"; do
        case "$a" in --apply|--apply=*|--audit|--list|--backups|--restore) _cli_old_form "$@" ;; esac
    done

    while [ "$#" -gt 0 ]; do
        a="$1"
        case "$a" in
            -h|--help)    want_help=true ;;
            -V|--version) want_version=true ;;
            --no-update)  USFC_NO_UPDATE=1 ;;
            --verbose)    USFC_VERBOSE=1 ;;
            --lang|--lang=*)
                _cli_value "$@"; shift $((REPLY_CLI_SHIFT - 1))
                case "$REPLY_CLI_VAL" in
                    ru|en) USFC_LANG="$REPLY_CLI_VAL"; USFC_LANG_EXPLICIT=true ;;
                    *) _cli_die "--lang: ru или en, а не «${REPLY_CLI_VAL}»" "--lang: ru or en, not \"${REPLY_CLI_VAL}\"" ;;
                esac ;;
            --dry-run)    USFC_DRY_RUN=true; USFC_NO_UPDATE=1; used+=("--dry-run: apply") ;;
            -y|--yes)     USFC_ASSUME_YES=true; used+=("--yes:apply restore") ;;
            --json)       USFC_AUDIT_JSON=true; used+=("--json:audit") ;;
            --config|--config=*)
                _cli_value "$@"; shift $((REPLY_CLI_SHIFT - 1))
                USFC_CONFIG_FILE="$REPLY_CLI_VAL"; used+=("--config:apply") ;;
            --set|--set=*)
                _cli_value "$@"; shift $((REPLY_CLI_SHIFT - 1))
                [[ "$REPLY_CLI_VAL" == *=* ]] || _cli_die "--set: ожидается КЛЮЧ=значение" "--set: expected KEY=value"
                _answer_row key "${REPLY_CLI_VAL%%=*}" || _cli_die "--set: неизвестный ключ ${REPLY_CLI_VAL%%=*}" "--set: unknown key ${REPLY_CLI_VAL%%=*}"
                USFC_FLAG_ANS[$REPLY_ANS_KEY]="${REPLY_CLI_VAL#*=}"; used+=("--set:apply") ;;
            --*)
                # флаги ответов из таблицы: --x (Y), --no-x (N), --x <значение>
                opt="${a%%=*}"
                if _answer_row flag "$opt" && [ "$REPLY_ANS_TYPE" != yn ]; then
                    _cli_value "$@"; shift $((REPLY_CLI_SHIFT - 1))
                    USFC_FLAG_ANS[$REPLY_ANS_KEY]="$REPLY_CLI_VAL"
                elif _answer_row flag "$opt" && [ "$opt" = "$a" ]; then
                    USFC_FLAG_ANS[$REPLY_ANS_KEY]=Y
                elif [[ "$a" == --no-* ]] && _answer_row flag "--${a#--no-}" && [ "$REPLY_ANS_TYPE" = yn ]; then
                    USFC_FLAG_ANS[$REPLY_ANS_KEY]=N
                else
                    _cli_die "неизвестная опция ${a}" "unknown option ${a}"
                fi
                used+=("${opt}:apply") ;;
            -*) _cli_die "неизвестная опция ${a}" "unknown option ${a}" ;;
            *)
                if [ -z "$USFC_CMD" ]; then
                    case " $USFC_COMMANDS " in
                        *" $a "*) USFC_CMD="$a" ;;
                        *) _cli_die "неизвестная команда «${a}». Команды: ${USFC_COMMANDS}" "unknown command \"${a}\". Commands: ${USFC_COMMANDS}" ;;
                    esac
                else
                    case "$USFC_CMD" in
                        apply)   USFC_APPLY_SPEC="${USFC_APPLY_SPEC}${USFC_APPLY_SPEC:+,}${a}" ;;
                        restore) [ -z "$USFC_RESTORE_STAMP" ] || _cli_die "restore: метка одна" "restore: only one stamp"
                                 USFC_RESTORE_STAMP="$a" ;;
                        help)    USFC_HELP_TOPIC="$a" ;;
                        *)       _cli_die "${USFC_CMD}: лишний аргумент «${a}»" "${USFC_CMD}: unexpected argument \"${a}\"" ;;
                    esac
                fi ;;
        esac
        shift
    done

    [ "$want_version" = true ] || [ "$USFC_CMD" = version ] && { echo "$VERSION"; exit 0; }
    if [ "$want_help" = true ] || [ "$USFC_CMD" = help ]; then
        show_usage "${USFC_HELP_TOPIC:-${USFC_CMD#help}}"; exit 0
    fi

    # Опция не от своей команды. Пустая команда (меню) принимает только --dry-run
    local u name allowed
    for u in "${used[@]+"${used[@]}"}"; do
        name="${u%%:*}"; allowed=" ${u#*:} "
        [[ "$allowed" == *" ${USFC_CMD} "* ]] && continue
        [ -z "$USFC_CMD" ] && [ "$name" = --dry-run ] && continue
        if [ -z "$USFC_CMD" ]; then
            _cli_die "${name} работает только с командой: usfc${allowed% } ${name} …" "${name} only works with a command: usfc${allowed% } ${name} …"
        fi
        _cli_die "${name} не относится к команде ${USFC_CMD}" "${name} does not belong to the ${USFC_CMD} command"
    done

    case "$USFC_CMD" in
        apply)
            [ -n "$USFC_APPLY_SPEC" ] || [ -n "$USFC_CONFIG_FILE" ] \
                || _cli_die "apply: что применять? Профиль, id или номера: usfc apply web" "apply: what to apply? A profile, ids or numbers: usfc apply web" ;;
        restore)
            # без метки откат спрашивает её с терминала — в скрипте спросить некого
            if [ -z "$USFC_RESTORE_STAMP" ] && ! usfc_interactive; then
                _cli_die "restore: укажите метку снимка (список — usfc backups)" "restore: give a snapshot stamp (list them with usfc backups)"
            fi ;;
    esac
    # Обновление проверяется только для меню: у команд его результат никто
    # не показывает, а фоновый curl лишь задерживает выход
    [ -n "$USFC_CMD" ] && USFC_NO_UPDATE=1
    return 0
}

# apply_cli_answers — файл ответов, потом флаги поверх, потом проверка, что
# у каждого флага есть свой пункт в списке. Зовётся из run_noninteractive,
# когда список пунктов уже известен
apply_cli_answers() {
    local key bad=0 id
    if [ -n "$USFC_CONFIG_FILE" ]; then
        local cfg="$USFC_CONFIG_FILE"
        case "$cfg" in
            https://*) fetch_config "$cfg" || return 2; cfg="$REPLY_CONFIG_PATH" ;;
            http://*)  log_error_t "Файл ответов только по https: в нём бывают токены" \
"The answers file must come over https: it may hold tokens"; return 2 ;;
        esac
        load_config "$cfg" || bad=1
        [ "$cfg" != "$USFC_CONFIG_FILE" ] && rm -f "$cfg"
    fi
    for key in "${!USFC_FLAG_ANS[@]}"; do
        answer_set "$key" "${USFC_FLAG_ANS[$key]}" flag || bad=1
    done
    [ "$bad" -eq 0 ] || return 2
    return 0
}

# check_cli_answer_items <id...> — флаг для пункта, которого нет в списке.
# Тот же ключ из файла ответов — норма: один файл обычно делят все ноды
check_cli_answer_items() {
    local key chosen=" $* " bad=0
    for key in "${!USFC_ANS_SRC[@]}"; do
        [ "${USFC_ANS_SRC[$key]}" = flag ] || continue
        _answer_row key "$key"
        [[ "$chosen" == *" ${REPLY_ANS_ITEM} "* ]] && continue
        log_error_t "${REPLY_ANS_FLAG:-$key} задан, а пункта ${REPLY_ANS_ITEM} в списке нет" \
"${REPLY_ANS_FLAG:-$key} is set, but item ${REPLY_ANS_ITEM} is not in the list"
        bad=1
    done
    return "$bad"
}

# ── Справка ──────────────────────────────────────────────────────────────────
# Флаги ответов печатаются из таблицы USFC_ANSWER_KEYS, а не перечисляются
# руками: ручной список уже однажды разошёлся с кодом
_usage_answer_flags() {
    local row k v ty fl it ru en name desc
    for row in "${USFC_ANSWER_KEYS[@]}"; do
        IFS='|' read -r k v ty fl it ru en <<< "$row"
        [ -n "$fl" ] || continue
        case "$ty" in
            yn)  name="${fl} / --no-${fl#--}" ;;
            pct) name="${fl} <1..400>" ;;
            *)   name="${fl} <N>" ;;
        esac
        if [ "$USFC_LANG" = en ]; then desc="$en"; else desc="$ru"; fi
        printf '  %-30s %s (%s)\n' "$name" "$desc" "$it"
    done
}
_usage_answer_keys() {
    local row k v ty fl it ru en desc
    for row in "${USFC_ANSWER_KEYS[@]}"; do
        IFS='|' read -r k v ty fl it ru en <<< "$row"
        if [ "$USFC_LANG" = en ]; then desc="$en"; else desc="$ru"; fi
        printf '  %-18s %s\n' "$k" "$desc"
    done
}

# show_usage [команда] — общая справка или справка по одной команде
show_usage() {
    local topic="${1:-}"
    case "$topic" in
        ''|apply|audit|list|backups|restore|version) ;;
        *) _cli_die "нет справки по «${topic}». Команды: ${USFC_COMMANDS}" "no help for \"${topic}\". Commands: ${USFC_COMMANDS}" ;;
    esac
    if [ "$USFC_LANG" = en ]; then show_usage_en "$topic"; else show_usage_ru "$topic"; fi
}

show_usage_ru() {
    case "$1" in
        apply)
            cat <<EOF
usfc apply <что> [опции] — применить пункты без вопросов по ходу

<что>  профиль, all, id или номера пунктов через запятую, вперемешку:
         usfc apply web
         usfc apply basepkgs,cli,docker,zram,ufw
         usfc apply web,bbr
       профили и id — usfc list

Опции:
  --dry-run                      показать, что будет сделано, ничего не меняя
  -y, --yes                      отвечать «да» и там, где дефолт «нет»
                                 (кроме перезапуска Docker — для него --docker-restart)
  --config <файл|https://…>      файл ответов КЛЮЧ=значение (см. ниже)
  --set КЛЮЧ=значение            любой ключ файла ответов прямо в командной строке

Ответы на вопросы пунктов (сильнее файла ответов):
$(_usage_answer_flags)

Ключи файла ответов:
  ITEMS              что применять, если <что> не задано
$(_usage_answer_keys)

Флаг для пункта, которого нет в списке, — ошибка. SSH hardening и создание
пользователя в apply не выполняются: им нужен человек у терминала.

Коды возврата: 0 — всё применилось или нечего применять; 1 — часть пунктов
не удалась; 2 — ошибка в аргументах или в файле ответов.
EOF
            ;;
        audit)
            cat <<'EOF'
usfc audit [--json] — проверить сервер, ничего не меняя

  --json   машинно-читаемый отчёт (id проверки, уровень, текст)

Коды возврата: 0 — важных проблем нет; 1 — есть важные (crit).
EOF
            ;;
        restore)
            cat <<'EOF'
usfc restore [метка] [--yes] — вернуть конфиги из снимка

Снимок делается перед каждой правкой системного файла. Список меток —
usfc backups. Без метки спросит её (нужен терминал); --yes — не спрашивать
подтверждения.
EOF
            ;;
        list)    echo "usfc list — профили и id пунктов для usfc apply" ;;   # i18n-ok: пара — show_usage_en
        backups) echo "usfc backups — снимки конфигов, свежие снизу; откат — usfc restore <метка>" ;;   # i18n-ok: пара — show_usage_en
        version) echo "usfc version — версия (то же: -V, --version)" ;;   # i18n-ok: пара — show_usage_en
        *)
            cat <<EOF
usfc ${VERSION} — UbuntuServer Fast Configuration

Использование: sudo usfc [команда] [опции]
Без команды открывается меню.

Команды:
  apply <что>        применить пункты без вопросов по ходу
  audit              проверить сервер (только чтение)
  list               профили и id пунктов
  backups            снимки конфигов
  restore [метка]    вернуть конфиги из снимка
  help [команда]     справка; по команде — подробнее
  version            версия

Общие опции:
  --lang ru|en       язык этого запуска (не запоминается)
  --no-update        не проверять обновление
  --verbose          показывать вывод команд целиком
  --dry-run          меню в режиме предпросмотра: ничего не меняется
  -h, --help         справка
  -V, --version      версия

Примеры:
  sudo usfc apply web --dry-run
  sudo usfc apply basepkgs,cli,docker,zram,ufw --swap 2048 --yes
  sudo usfc apply --config https://example.com/node.conf
  sudo usfc audit --json

Установка с командой сразу:
  curl -fsSL …/install.sh | sudo bash -s -- apply web --yes

Переменные окружения: USFC_LANG, USFC_NO_UPDATE, USFC_VERBOSE,
USFC_REPO_RAW_BASE, USFC_KEEP_LOCALE, USFC_APT_LOCK_TIMEOUT, NO_COLOR.
Лог всех выполненных команд: ${USFC_LOG}
EOF
            ;;
    esac
}

show_usage_en() {
    case "$1" in
        apply)
            cat <<EOF
usfc apply <what> [options] — apply items without questions along the way

<what>  a profile, all, item ids or numbers, comma-separated, mixed freely:
          usfc apply web
          usfc apply basepkgs,cli,docker,zram,ufw
          usfc apply web,bbr
        profiles and ids — usfc list

Options:
  --dry-run                      show what would be done, change nothing
  -y, --yes                      answer "yes" even where the default is "no"
                                 (except restarting Docker — use --docker-restart)
  --config <file|https://…>      answers file, KEY=value (see below)
  --set KEY=value                any answers-file key right on the command line

Answers to item questions (override the answers file):
$(_usage_answer_flags)

Answers file keys:
  ITEMS              what to apply when <what> is not given
$(_usage_answer_keys)

A flag for an item that is not in the list is an error. SSH hardening and
user creation are not run by apply: they need a person at the terminal.

Exit codes: 0 — everything applied or nothing to do; 1 — some items failed;
2 — an error in the arguments or the answers file.
EOF
            ;;
        audit)
            cat <<'EOF'
usfc audit [--json] — check the server without changing anything

  --json   machine-readable report (check id, level, text)

Exit codes: 0 — no critical problems; 1 — there are critical ones (crit).
EOF
            ;;
        restore)
            cat <<'EOF'
usfc restore [stamp] [--yes] — bring configs back from a snapshot

A snapshot is taken before every change to a system file. List the stamps
with usfc backups. Without a stamp it asks for one (needs a terminal);
--yes skips the confirmation.
EOF
            ;;
        list)    echo "usfc list — profiles and item ids for usfc apply" ;;
        backups) echo "usfc backups — config snapshots, newest last; undo with usfc restore <stamp>" ;;
        version) echo "usfc version — the version (same as -V, --version)" ;;
        *)
            cat <<EOF
usfc ${VERSION} — UbuntuServer Fast Configuration

Usage: sudo usfc [command] [options]
With no command, the menu opens.

Commands:
  apply <what>       apply items without questions along the way
  audit              check the server (read-only)
  list               profiles and item ids
  backups            config snapshots
  restore [stamp]    bring configs back from a snapshot
  help [command]     help; per command — in detail
  version            the version

Common options:
  --lang ru|en       language for this run (not remembered)
  --no-update        skip the update check
  --verbose          show full command output
  --dry-run          the menu in preview mode: nothing changes
  -h, --help         help
  -V, --version      the version

Examples:
  sudo usfc apply web --dry-run
  sudo usfc apply basepkgs,cli,docker,zram,ufw --swap 2048 --yes
  sudo usfc apply --config https://example.com/node.conf
  sudo usfc audit --json

Install and run a command right away:
  curl -fsSL …/install.sh | sudo bash -s -- apply web --yes

Environment: USFC_LANG, USFC_NO_UPDATE, USFC_VERBOSE, USFC_REPO_RAW_BASE,
USFC_KEEP_LOCALE, USFC_APT_LOCK_TIMEOUT, NO_COLOR.
Log of every command run: ${USFC_LOG}
EOF
            ;;
    esac
}
