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
    mkdir -p "$USFC_BACKUP_DIR" 2>/dev/null || return 1
    chmod 700 "$USFC_BACKUP_DIR" 2>/dev/null
    printf '%s' "$USFC_BACKUP_DIR"
}

# Состояние на диске, а не в переменной — см. комментарий выше про подоболочку
backup_made() {
    [ -d "$USFC_BACKUP_DIR" ] && [ -n "$(ls -A "$USFC_BACKUP_DIR" 2>/dev/null)" ]
}

# backup_file <путь> — сохранить копию, если файл существует.
# Молчит про несуществующие: создание нового файла откатывать нечем,
# для этого есть команды удаления на экране I.
backup_file() {
    local src="$1" dir dst
    [ -f "$src" ] || return 0
    [ "$USFC_DRY_RUN" = true ] && return 0
    dir="$(backup_session_dir)" || return 0
    dst="${dir}${src}"
    mkdir -p "$(dirname "$dst")" 2>/dev/null || return 0
    # -p сохраняет права и время: восстановленный sudoers с чужими правами
    # хуже, чем не восстановленный вовсе
    cp -p "$src" "$dst" 2>/dev/null || return 0
    return 0
}

# Список снимков, свежие снизу
backup_list() {
    local d n
    if [ ! -d "$USFC_BACKUP_ROOT" ] || [ -z "$(ls -A "$USFC_BACKUP_ROOT" 2>/dev/null)" ]; then
        log_info_t "Снимков пока нет: ${USFC_BACKUP_ROOT}" \
"No snapshots yet: ${USFC_BACKUP_ROOT}"
        return 1
    fi
    echo ""
    log_info_t "Снимки конфигов:" \
"Config snapshots:"
    for d in "$USFC_BACKUP_ROOT"/*/; do
        [ -d "$d" ] || continue
        n="$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')"
        t "файлов" "files"
        printf '    %b%s%b  %s: %s\n' "$BOLD" "$(basename "$d")" "$NC" "$REPLY_T" "$n"
        find "$d" -type f -printf '        %P\n' 2>/dev/null | sed "s|^        |        /|"
    done
    echo ""
    return 0
}

# Восстановление из снимка. Всегда спрашивает: перезапись работающего
# конфига — не то действие, которое делают молча.
backup_restore() {
    local stamp="${1:-}" dir f target restored=0
    backup_list || return 1

    if [ -z "$stamp" ]; then
        t "Метка снимка (Enter — отмена):" "Snapshot stamp (Enter to cancel):"
        echo -en "  ${BOLD}${REPLY_T}${NC} "
        read -r stamp </dev/tty
        [ -z "$stamp" ] && { log_info_t "Отменено" \
"Cancelled"; return 0; }
    fi
    dir="${USFC_BACKUP_ROOT}/${stamp}"
    if [ ! -d "$dir" ]; then
        log_error_t "Нет снимка «${stamp}»" \
"No snapshot named ${stamp}"
        return 1
    fi
    # Страховка поверх уникальной метки: писать снимок отката в тот самый
    # каталог, который восстанавливаем, нельзя ни при каких обстоятельствах
    if [ "$dir" = "$USFC_BACKUP_DIR" ]; then
        USFC_BACKUP_DIR="${USFC_BACKUP_DIR}-restore"
    fi

    echo ""
    log_warn_t "Файлы будут перезаписаны содержимым снимка ${stamp}:" \
"These files will be overwritten from snapshot ${stamp}:"
    find "$dir" -type f -printf '    /%P\n' 2>/dev/null
    echo ""
    if [ "$USFC_ASSUME_YES" = true ]; then
        log_info_t "--yes: подтверждение пропущено" \
"--yes: confirmation skipped"
    else
        ask_yn_t "Восстановить?" "Restore?" N || { log_info_t "Отменено" \
"Cancelled"; return 0; }
    fi

    while IFS= read -r f; do
        target="/${f#"${dir}/"}"
        # Перед перезаписью снимаем ещё один снимок: откат отката тоже
        # должен быть возможен
        backup_file "$target"
        if cp -p "$f" "$target" 2>/dev/null; then
            log_success_t "Восстановлен ${target}" \
"Restored ${target}"
            restored=$((restored + 1))
        else
            log_error_t "Не удалось восстановить ${target}" \
"Could not restore ${target}"
        fi
    done < <(find "$dir" -type f 2>/dev/null)

    echo ""
    log_info_t "Восстановлено файлов: ${restored}" \
"Files restored: ${restored}"
    log_warn_t "Сервисы не перезапускались — примени изменения сам, например:" \
"No services were restarted — apply the changes yourself, for example:"
    log_info_t "  ${BOLD}systemctl restart ssh${NC} после sshd_config.d, ${BOLD}sysctl --system${NC} после sysctl.d" \
"  ${BOLD}systemctl restart ssh${NC} after sshd_config.d, ${BOLD}sysctl --system${NC} after sysctl.d"
    return 0
}

# Сообщаем о снимках один раз в конце прогона. Молча складывать копии
# в /var/backups и не говорить об этом — всё равно что не делать их вовсе:
# в нужный момент про них не вспомнят
backup_hint() {
    backup_made || return 0
    echo ""
    log_info_t "Конфиги, которые правились, сохранены: ${BOLD}${USFC_BACKUP_DIR}${NC}" \
"Configs that were edited are saved in: ${BOLD}${USFC_BACKUP_DIR}${NC}"
    log_info_t "Вернуть как было: ${BOLD}sudo usfc --restore $(basename "$USFC_BACKUP_DIR")${NC}" \
               "Undo: ${BOLD}sudo usfc --restore $(basename "$USFC_BACKUP_DIR")${NC}"
}
