# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# Снимки конфигов перед изменением
# ═══════════════════════════════════════════════════════════════
# До сих пор откат был только справкой: экран I показывал команды, которые
# надо набирать руками. Для sshd_config.d или fstab это плохая шутка —
# вспоминать, что там было до, приходится уже после.
#
# Снимок вешается на write_file/append_file, и это не случайность: приводя
# сухой прогон в порядок, все записи в системные файлы свели именно к ним.
# Одна точка и для «не трогать», и для «сначала сохранить» — расходиться
# этим двум вещам теперь негде.
USFC_BACKUP_ROOT="/var/backups/usfc"
USFC_SKIP_BACKUP=false
USFC_RESTORE_DIFF=false
USFC_BACKUPS_ACTION=""
USFC_BACKUPS_KEEP=10

# Путь считается ОДИН РАЗ при загрузке, а не лениво внутри backup_file.
# Причина не в экономии: write_file зовут через пайп (`printf ... | write_file`),
# а пайп — это подоболочка. Присвоение переменной внутри неё до родителя
# не доходит, и в конце прогона подсказка печатала пустой путь, хотя копии
# на диске лежали. Признак «копии были» тоже берём с диска, а не из переменной.
# PID в метке не украшение. Без него откат снимка, сделанного в ту же секунду,
# съедал сам себя: backup_file перед восстановлением писал ТЕКУЩЕЕ содержимое
# в каталог с тем же именем, затирал снимок, и «восстановление» возвращало
# ровно то, от чего уходили. Ловится только на быстрой машине — тем хуже.
USFC_BACKUP_DIR="${USFC_BACKUP_ROOT}/$(date '+%Y%m%d-%H%M%S')-$$"

backup_session_dir() {
    [ -d "$USFC_BACKUP_DIR" ] && { printf '%s' "$USFC_BACKUP_DIR"; return 0; }
    ( umask 077; mkdir -p "$USFC_BACKUP_ROOT" "$USFC_BACKUP_DIR" ) 2>/dev/null || return 1
    chmod 700 "$USFC_BACKUP_ROOT" "$USFC_BACKUP_DIR" 2>/dev/null
    printf '%s' "$USFC_BACKUP_DIR"
}

# Состояние на диске, а не в переменной — см. комментарий выше про подоболочку
backup_made() {
    [ -d "$USFC_BACKUP_DIR" ] && [ -n "$(ls -A "$USFC_BACKUP_DIR" 2>/dev/null)" ]
}

# Список файлов, которых до прогона не было: restore их удаляет. Лежит в
# корне снимка рядом с копиями и в списки файлов не попадает
USFC_CREATED_LIST=".usfc-created"

# backup_file <путь> — сохранить копию, если файл существует, или запомнить,
# что его не было: откат созданного — удаление (drop-in sshd, sysctl.d…).
#
# Первая запись за прогон — единственная. .bashrc за один заход дописывают
# обёртка, cli и fastfetch; раньше каждая запись перезаписывала снимок, и
# `usfc restore` возвращал файл, в котором уже были почти все наши правки.
# По той же причине созданный и потом дописанный файл остаётся «созданным»
backup_file() {
    local src="$1" dir dst
    [ "$USFC_DRY_RUN" = true ] && return 0
    [ "${USFC_SKIP_BACKUP:-false}" = true ] && return 0
    [ -f "$src" ] || [ ! -e "$src" ] || return 0      # каталог, сокет — не наше
    dir="$(backup_session_dir)" || return 0
    dst="${dir}${src}"
    [ -e "$dst" ] && return 0
    grep -qxF -- "$src" "${dir}/${USFC_CREATED_LIST}" 2>/dev/null && return 0
    if [ ! -e "$src" ]; then
        printf '%s\n' "$src" >> "${dir}/${USFC_CREATED_LIST}"
        return 0
    fi
    mkdir -p "$(dirname "$dst")" 2>/dev/null || return 0
    # -p сохраняет права и время: восстановленный sudoers с чужими правами
    # хуже, чем не восстановленный вовсе
    if ! cp -p "$src" "$dst" 2>/dev/null; then
        # запись всё равно пойдёт — но человек должен знать, что отката нет
        log_warn_t "Снимок ${src} не сохранился (место на диске?) — откатить эту правку будет нечем" "Could not snapshot ${src} (disk space?) — this change cannot be rolled back"
    fi
    return 0
}

# Список валидных меток снимков в порядке возрастания (свежие внизу) → REPLY_BACKUP_STAMPS
REPLY_BACKUP_STAMPS=()
_backup_collect_stamps() {
    local d name
    REPLY_BACKUP_STAMPS=()
    [ -d "$USFC_BACKUP_ROOT" ] || return 0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [[ "$name" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+(-restore)?$ ]] || continue
        [ -d "${USFC_BACKUP_ROOT}/${name}" ] && REPLY_BACKUP_STAMPS+=("$name")
    done < <(for d in "$USFC_BACKUP_ROOT"/*/; do [ -d "$d" ] && basename "$d"; done | LC_ALL=C sort)
}

# Самый свежий снимок → REPLY_BACKUP_LATEST (код 1 — снимков нет)
REPLY_BACKUP_LATEST=''
_backup_latest_stamp() {
    REPLY_BACKUP_LATEST=''
    _backup_collect_stamps
    [ "${#REPLY_BACKUP_STAMPS[@]}" -gt 0 ] || return 1
    REPLY_BACKUP_LATEST="${REPLY_BACKUP_STAMPS[$(( ${#REPLY_BACKUP_STAMPS[@]} - 1 ))]}"
    return 0
}

# Список снимков, свежие снизу
backup_list() {
    local d n
    if [ ! -d "$USFC_BACKUP_ROOT" ] || [ -z "$(ls -A "$USFC_BACKUP_ROOT" 2>/dev/null)" ]; then
        log_info_t "Снимков пока нет: ${USFC_BACKUP_ROOT}" "No snapshots yet: ${USFC_BACKUP_ROOT}"
        return 1
    fi
    echo ""
    log_info_t "Снимки конфигов:" "Config snapshots:"
    for d in "$USFC_BACKUP_ROOT"/*/; do
        [ -d "$d" ] || continue
        n="$(find "$d" -type f ! -name "$USFC_CREATED_LIST" 2>/dev/null | wc -l | tr -d ' ')"
        [ -f "${d}${USFC_CREATED_LIST}" ] && n=$(( n + $(grep -c . "${d}${USFC_CREATED_LIST}") ))
        t "файлов" "files"
        printf '    %b%s%b  %s: %s\n' "$BOLD" "$(basename "$d")" "$NC" "$REPLY_T" "$n"
        find "$d" -type f ! -name "$USFC_CREATED_LIST" -printf '        %P\n' 2>/dev/null | sed "s|^        |        /|"
        t "(создан — откат удалит)" "(created — restore removes it)"
        [ -f "${d}${USFC_CREATED_LIST}" ] && sed "s|^|        |; s|\$|  ${REPLY_T}|" "${d}${USFC_CREATED_LIST}"
    done
    echo ""
    return 0
}

# backup_show_diff <каталог-снимка> — показать отличия текущих файлов от снимка
backup_show_diff() {
    local dir="$1" f target any=false
    echo ""
    log_info_t "Отличия между текущей системой и снимком $(basename "$dir"):" "Differences between current files and snapshot $(basename "$dir"):"
    while IFS= read -r f; do
        target="/${f#"${dir}/"}"
        if [ ! -e "$target" ]; then
            any=true
            log_warn_t "${target} отсутствует — будет восстановлен из снимка" "${target} is missing — will be restored from the snapshot"
        elif cmp -s "$target" "$f" 2>/dev/null; then
            log_info_t "${target}: без изменений" "${target}: unchanged"
        else
            any=true
            echo ""
            printf '  %b%s%b\n' "$BOLD" "$target" "$NC"
            if command -v diff >/dev/null 2>&1; then
                diff -u --label "current:${target}" --label "snapshot:${target}" "$target" "$f" 2>/dev/null \
                    | sed 's/^/    /' || true
            else
                log_info_t "diff не установлен — файл отличается от снимка" "diff is not installed — file differs from the snapshot"
            fi
        fi
    done < <(find "$dir" -type f ! -name "$USFC_CREATED_LIST" 2>/dev/null | LC_ALL=C sort)

    if [ -s "${dir}/${USFC_CREATED_LIST}" ]; then
        while IFS= read -r target; do
            case "$target" in /*) ;; *) continue ;; esac
            if [ -e "$target" ]; then
                any=true
                log_warn_t "${target}: был создан в том прогоне — откат удалит его" "${target}: was created in that run — restore will remove it"
            fi
        done < "${dir}/${USFC_CREATED_LIST}"
    fi
    [ "$any" = false ] && log_info_t "Все файлы уже совпадают со снимком" "All files already match the snapshot"
    echo ""
    return 0
}

# Очистка старых снимков: оставляет N самых свежих (по умолчанию 10)
backup_prune() {
    local keep="${1:-10}" total drop i name sz
    [[ "$keep" =~ ^[0-9]+$ ]] || {
        log_error_t "--keep: ожидается целое число ≥ 0" "--keep: expected a whole number ≥ 0"
        return 2
    }
    keep=$((10#$keep))
    _backup_collect_stamps
    total="${#REPLY_BACKUP_STAMPS[@]}"
    if [ "$total" -eq 0 ]; then
        log_info_t "Снимков нет: ${USFC_BACKUP_ROOT}" "No snapshots: ${USFC_BACKUP_ROOT}"
        return 0
    fi
    drop=$(( total - keep ))
    if [ "$drop" -le 0 ]; then
        log_info_t "Снимков ${total} — это не больше лимита (${keep}), удалять нечего" "${total} snapshots — within the keep limit (${keep}), nothing to prune"
        return 0
    fi

    echo ""
    log_info_t "Будет удалено старых снимков: ${drop} ${DIM}(остаются последние ${keep} из ${total})${NC}" "Old snapshots to remove: ${drop} ${DIM}(keeping the latest ${keep} of ${total})${NC}"
    for ((i = 0; i < drop; i++)); do
        name="${REPLY_BACKUP_STAMPS[$i]}"
        sz="$(du -sh "${USFC_BACKUP_ROOT}/${name}" 2>/dev/null | cut -f1)"
        printf '    %s  %b(%s)%b\n' "$name" "$DIM" "${sz:-?}" "$NC"
    done
    echo ""

    if [ "$USFC_DRY_RUN" = true ]; then
        for ((i = 0; i < drop; i++)); do
            _dry_say "rm -rf ${USFC_BACKUP_ROOT}/${REPLY_BACKUP_STAMPS[$i]}"
        done
        return 0
    fi
    if [ "$USFC_ASSUME_YES" != true ]; then
        ask_yn_t "Удалить эти ${drop} снимков?" "Remove these ${drop} snapshots?" N || {
            log_info_t "Отменено" "Cancelled"
            return 0
        }
    fi
    local removed=0
    for ((i = 0; i < drop; i++)); do
        name="${REPLY_BACKUP_STAMPS[$i]}"
        if rm -rf "${USFC_BACKUP_ROOT:?}/${name}"; then
            removed=$((removed + 1))
        else
            log_error_t "Не удалось удалить ${name}" "Could not remove ${name}"
        fi
    done
    log_success_t "Удалено снимков: ${removed}" "Snapshots removed: ${removed}"
    return 0
}

# Восстановление из снимка. Всегда спрашивает: перезапись работающего
# конфига — не то действие, которое делают молча.
backup_restore() {
    local stamp="${1:-}" dir f target restored=0

    # Полный список снимков печатаем только когда метка НЕ задана явно
    if [ -z "$stamp" ]; then
        backup_list || return 1
        t "Метка снимка (или latest)" "Snapshot stamp (or latest)"; local _q="$REPLY_T"
        t "Enter — отмена" "Enter to cancel"
        ui_prompt "$_q" "$REPLY_T"
        read -r stamp </dev/tty || stamp=""
        [ -z "$stamp" ] && { log_info_t "Отменено" "Cancelled"; return 0; }
    fi
    if [ "$stamp" = "latest" ]; then
        if ! _backup_latest_stamp; then
            log_info_t "Снимков пока нет: ${USFC_BACKUP_ROOT}" "No snapshots yet: ${USFC_BACKUP_ROOT}"
            return 1
        fi
        stamp="$REPLY_BACKUP_LATEST"
    fi
    # Метка — только в том виде, в каком её ставит backup.sh: иначе
    # `restore ..` превращается в /var/backups, а `restore .` — в
    # восстановление всех снимков разом в порядке find
    if [[ ! "$stamp" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+(-restore)?$ ]]; then
        log_error_t "Метка «${stamp}» не похожа на снимок (ГГГГММДД-ЧЧММСС-PID или latest)" "«${stamp}» does not look like a snapshot stamp (YYYYMMDD-HHMMSS-PID or latest)"
        return 1
    fi
    dir="${USFC_BACKUP_ROOT}/${stamp}"
    if [ ! -d "$dir" ]; then
        log_error_t "Нет снимка «${stamp}»" "No snapshot named ${stamp}"
        return 1
    fi

    if [ "$USFC_RESTORE_DIFF" = true ]; then
        backup_show_diff "$dir"
        return 0
    fi

    # Страховка поверх уникальной метки: писать снимок отката в тот самый
    # каталог, который восстанавливаем, нельзя ни при каких обстоятельствах
    if [ "$dir" = "$USFC_BACKUP_DIR" ]; then
        USFC_BACKUP_DIR="${USFC_BACKUP_DIR}-restore"
    fi

    echo ""
    log_warn_t "Файлы будут перезаписаны содержимым снимка ${stamp}:" "These files will be overwritten from snapshot ${stamp}:"
    find "$dir" -type f ! -name "$USFC_CREATED_LIST" -printf '    /%P\n' 2>/dev/null
    if [ -s "${dir}/${USFC_CREATED_LIST}" ]; then
        log_warn_t "Файлы, созданные в том прогоне, будут удалены:" "Files created in that run will be removed:"
        sed 's/^/    /' "${dir}/${USFC_CREATED_LIST}"
    fi
    log_info_t "Посмотреть отличия: ${BOLD}sudo usfc restore ${stamp} --diff${NC}" "Preview diff: ${BOLD}sudo usfc restore ${stamp} --diff${NC}"
    echo ""
    if [ "$USFC_ASSUME_YES" = true ]; then
        log_info_t "--yes: подтверждение пропущено" "--yes: confirmation skipped"
    else
        ask_yn_t "Восстановить?" "Restore?" N || { log_info_t "Отменено" "Cancelled"; return 0; }
    fi

    while IFS= read -r f; do
        target="/${f#"${dir}/"}"
        # Перед перезаписью снимаем ещё один снимок: откат отката тоже
        # должен быть возможен
        backup_file "$target"
        if cp -p "$f" "$target" 2>/dev/null; then
            log_success_t "Восстановлен ${target}" "Restored ${target}"
            restored=$((restored + 1))
        else
            log_error_t "Не удалось восстановить ${target}" "Could not restore ${target}"
        fi
    done < <(find "$dir" -type f ! -name "$USFC_CREATED_LIST" 2>/dev/null)

    # Созданные — удаляем через remove_file: со снимком, то есть откат отката
    # вернёт и их
    if [ -s "${dir}/${USFC_CREATED_LIST}" ]; then
        while IFS= read -r target; do
            case "$target" in /*) ;; *) continue ;; esac
            [ -e "$target" ] || continue
            if remove_file "$target"; then
                log_success_t "Удалён ${target}" "Removed ${target}"
                restored=$((restored + 1))
            else
                log_error_t "Не удалось удалить ${target}" "Could not remove ${target}"
            fi
        done < "${dir}/${USFC_CREATED_LIST}"
    fi

    echo ""
    log_info_t "Восстановлено файлов: ${restored}" "Files restored: ${restored}"
    log_warn_t "Сервисы не перезапускались — примени изменения сам, например:" "No services were restarted — apply the changes yourself, for example:"
    log_info_t "  ${BOLD}systemctl restart ssh${NC} после sshd_config.d, ${BOLD}sysctl --system${NC} после sysctl.d" "  ${BOLD}systemctl restart ssh${NC} after sshd_config.d, ${BOLD}sysctl --system${NC} after sysctl.d"
    return 0
}

# Сообщаем о снимках один раз в конце прогона. Молча складывать копии
# в /var/backups и не говорить об этом — всё равно что не делать их вовсе:
# в нужный момент про них не вспомнят
backup_hint() {
    backup_made || return 0
    echo ""
    log_info_t "Конфиги, которые правились, сохранены: ${BOLD}${USFC_BACKUP_DIR}${NC}" "Configs that were edited are saved in: ${BOLD}${USFC_BACKUP_DIR}${NC}"
    log_info_t "Вернуть как было: ${BOLD}sudo usfc restore $(basename "$USFC_BACKUP_DIR")${NC} ${DIM}(или restore latest)${NC}"                "Undo: ${BOLD}sudo usfc restore $(basename "$USFC_BACKUP_DIR")${NC} ${DIM}(or restore latest)${NC}"
}
