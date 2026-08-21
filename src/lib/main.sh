# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# run_items <номера...> — прогнать пачку пунктов без вопросов по ходу.
# Вынесено из меню, потому что ровно то же нужно неинтерактивному --apply:
# два экземпляра этого цикла разъехались бы при первой же правке сводки.
run_items() {
    [ "$#" -eq 0 ] && return 0
    local total="$#" pos=0 rc0 t0 num
    BULK_MODE=true
    summary_reset
    for num in "$@"; do
        pos=$((pos + 1))
        now_s; t0="$REPLY_NOW"
        process_item "$num" "$pos" "$total"; rc0=$?
        now_s
        summary_record "$num" "$rc0" "$((REPLY_NOW - t0))"
    done
    BULK_MODE=false
    show_summary
}

# Заготовленные ответы живут ровно один прогон: иначе следующий пакетный
# запуск молча унаследовал бы токен и проценты от предыдущего
reset_bulk_answers() {
    ZRAM_BULK_PERCENT=""
    SWAP_BULK_MB=""
    SYSCTL_BULK=""
    # shellcheck disable=SC2034  # читаются в apply_nginx/apply_docker
    NGINX_AUTOSTART=""
    # shellcheck disable=SC2034
    DOCKER_AUTOSTART=""
    CERTBOT_CF_BULK=""
    CF_TOKEN_BULK=""
}

# Неинтерактивный прогон: cloud-init, Ansible, скрипт развёртывания.
#
# Коды возврата сделаны пригодными для CI, а не «0 или что-то»:
#   0 — всё применилось
#   1 — часть пунктов не удалась
#   2 — не разобрали, что применять (опечатка в профиле или id)
run_noninteractive() {
    resolve_items "$USFC_APPLY_SPEC" || return 2

    # Отсев общий с мастером первого запуска — см. filter_pending в profiles.sh
    filter_pending "${REPLY_ITEM_NUMS[@]}"
    local -a nums=("${REPLY_PENDING[@]+"${REPLY_PENDING[@]}"}")
    local -a skipped=("${REPLY_SKIPPED[@]+"${REPLY_SKIPPED[@]}"}")
    local -a already=("${REPLY_ALREADY[@]+"${REPLY_ALREADY[@]}"}")

    echo ""
    if [ "$USFC_DRY_RUN" = true ]; then
        log_info_t "Сухой прогон: ничего меняться не будет" \
"Dry run: nothing will be changed"
    fi
    log_info_t "Пунктов к применению: ${#nums[@]} ${DIM}(${USFC_APPLY_SPEC})${NC}" \
"Items to apply: ${#nums[@]} ${DIM}(${USFC_APPLY_SPEC})${NC}"
    if [ "${#already[@]}" -gt 0 ]; then
        log_info_t "Уже применено, пропускаю: ${DIM}${already[*]}${NC}" \
"Already applied, skipping: ${DIM}${already[*]}${NC}"
    fi
    if [ "${#skipped[@]}" -gt 0 ]; then
        log_warn_t "Пропускаю ${skipped[*]}: требует явного подтверждения, в неинтерактивном режиме его взять негде" \
"Skipping ${skipped[*]}: it needs explicit confirmation, and there is none in non-interactive mode"
        log_info_t "Настрой отдельно: ${BOLD}sudo usfc${NC}, пункт $(item_number sshhardening)" \
"Set it up separately: ${BOLD}sudo usfc${NC}, item $(item_number sshhardening)"
    fi
    [ "${#nums[@]}" -eq 0 ] && { log_info_t "Применять нечего" \
"Nothing to apply"; return 0; }

    run_items "${nums[@]}"
    reset_bulk_answers

    # В сухом прогоне сводка сравнивает состояние системы с ожидаемым и,
    # разумеется, не находит изменений. Возвращать из-за этого «ошибку»
    # значило бы валить CI на проверке, которая ничего и не должна была менять
    if [ "$USFC_DRY_RUN" = true ]; then
        echo ""
        log_info_t "Сухой прогон закончен: система не изменилась" \
"Dry run finished: the system is unchanged"
        return 0
    fi
    backup_hint
    if [ "${#SUMMARY_FAILED[@]}" -gt 0 ]; then
        return 1
    fi
    return 0
}

main() {
    # curl за VERSION стартует ПЕРВЫМ и крутится в фоне, пока идёт вся локальная
    # работа ниже — так проверка обновлений остаётся на каждом запуске, но
    # перестаёт быть последовательной задержкой перед первым экраном
    start_update_check
    log_init

    # Проверяем ДО того, как что-то делать: раньше на чужой системе скрипт
    # доходил до середины и падал на apt (сам detect_os отработал при загрузке)
    require_supported_os || exit 1
    # --lang разбирается уже после загрузки модулей, поэтому нормализуем
    # значение здесь ещё раз: «--lang de» не должен молча ломать вывод
    case "$USFC_LANG" in ru|en) ;; *) log_warn_t "Неизвестный язык «${USFC_LANG}», беру ru" \
"Unknown language ${USFC_LANG}, falling back to ru"; USFC_LANG=ru ;; esac

    # Язык спрашиваем только при первом интерактивном запуске: если выбор уже
    # сохранён, задан флагом или нас позвали неинтерактивно (cloud-init,
    # Ansible, --apply), вопрос был бы либо навязчивым, либо вовсе некому
    # отвечать — и скрипт завис бы на чтении с /dev/tty
    # Признак первого запуска снимаем ДО вопроса о языке: usfc_ask_language
    # сохраняет выбор, и после него «первого запуска» уже не существует
    local first_run=false
    usfc_lang_saved || first_run=true

    if ! usfc_lang_saved && [ "$USFC_LANG_EXPLICIT" = false ] \
       && [ -z "$USFC_APPLY_SPEC" ] && [ -z "$USFC_ACTION" ] \
       && [ "$USFC_LIST_ONLY" = false ] && usfc_interactive; then
        usfc_ask_language
    fi

    dry_run_enable

    if [ "$USFC_LIST_ONLY" = true ]; then
        profile_list
        exit 0
    fi
    case "$USFC_ACTION" in
        audit)   if [ "$USFC_AUDIT_JSON" = true ]; then audit_emit_json; else show_audit; fi; exit 0 ;;
        backups) backup_list; exit $? ;;
        restore) backup_restore "$USFC_RESTORE_STAMP"; exit $? ;;
    esac
    if [ -n "$USFC_CONFIG_FILE" ]; then
        load_config "$USFC_CONFIG_FILE" || exit 2
    fi
    if [ -n "$USFC_APPLY_SPEC" ]; then
        run_noninteractive
        exit $?
    fi

    show_header
    log_info_t "Пользователь: ${BOLD}${TARGET_USER}${NC} ${DIM}(${TARGET_HOME})${NC}" \
"User: ${BOLD}${TARGET_USER}${NC} ${DIM}(${TARGET_HOME})${NC}"
    log_info_t "SSH-порт: ${SSH_PORT}" \
"SSH port: ${SSH_PORT}"

    # usfc-обёртка — не отдельный пункт меню, ставится сама при первом запуске,
    # свой маркер, идемпотентно. Пропускаем для прямого root — sudo тут бесполезен
    # (и может быть даже не установлен на такой машине).
    # Это bash-ФУНКЦИЯ, а не alias: после того как дочерний sudo-процесс меню
    # завершится, функция сама делает "source ~/.bashrc" — но уже в ТЕКУЩЕЙ
    # интерактивной оболочке (функции выполняются в вызывающем шелле, не в
    # подпроцессе), так что новые алиасы/промпт подхватываются без ручного
    # source и без переподключения. USFC_RESOURCE гейтит fastfetch-автозапуск
    # (см. apply_fastfetch) — иначе баннер печатался бы второй раз при каждом
    # выходе из меню.
    install_usfc_wrapper

    # apt-get update со старта убран: списки нужны только перед реальной установкой,
    # и ensure_apt_updated возьмёт их сам, если они успели протухнуть. Просто открыть
    # меню и посмотреть статусы теперь не стоит ни одного сетевого запроса.
    refresh_pkg_cache

    # Версию сверяем при КАЖДОМ запуске — но curl уже крутится в фоне (см. main),
    # пока считался кэш пакетов, так что ждать почти нечего.
    if check_for_update; then
        pause
    fi

    # Голый root — самый частый способ получить VPS. Предлагаем завести нормального
    # пользователя ДО того, как что-то поставится в /root и потеряется при перелогине.
    if [ "$TARGET_USER" = "root" ] && [ "$ROOT_PROMPT_SHOWN" = false ]; then
        ROOT_PROMPT_SHOWN=true
        echo ""
        log_warn_t "Скрипт запущен от имени root." \
"Running as root."
        log_info_t "РЕКОМЕНДУЮ создать обычного пользователя с sudo: работать из-под root" \
"RECOMMENDED: create a normal sudo user. Working as root is unsafe,"
        log_info_t "небезопасно, SSH hardening без отдельного пользователя не работает вообще," \
"SSH hardening does not work at all without a separate user, and aliases,"
        log_info_t "а алиасы/fastfetch/tmux сейчас лягут в /root и пропадут после перелогина." \
"fastfetch and tmux would land in /root and vanish once you re-login."
        echo ""
        if ask_yn_t "Создать пользователя сейчас?" "Create the user now?" Y; then
            apply_newuser
            invalidate_statuses
        else
            log_info_t "Ок. Пункт 1 в меню доступен в любой момент." \
"Fine. Item 1 in the menu is available at any time."
        fi
        pause
    fi

    # Мастер — ПОСЛЕ проверки обновлений и блока про голого root: статусы уже
    # посчитаны, а TARGET_USER уже переключён, если пользователя создавали.
    # Все неинтерактивные ветки (--list, --audit, --apply, --config) вышли
    # раньше по exit, поэтому отдельных гейтов здесь не нужно.
    if [ "$first_run" = true ] && usfc_interactive; then
        usfc_wizard
        # Флаг --lang на первом запуске пропускает вопрос о языке, и файл выбора
        # так и не появляется — мастер тогда всплывал бы каждый раз. Знакомство
        # состоялось, язык известен: запоминаем
        usfc_lang_saved || usfc_lang_save "$USFC_LANG"
    fi

    while true; do
        show_menu
        t "Выбор:" "Choose:"
        echo -en "  ${BOLD}${REPLY_T}${NC} "
        local choice
        read -r choice </dev/tty
        case "$choice" in
            [Qq]) echo ""; log_info_t "Пока. Повторный запуск: usfc" \
"Bye. Run it again with: usfc"; break ;;
            [Hh]) show_aliases_help ;;
            # "?" как синоним I: привычнее для тех, кто ищет справку вслепую
            [Dd]) show_audit; pause ;;
            # Переключение языка перезапускает скрипт — см. usfc_switch_language
            # pause отработает только когда язык НЕ сменился: при успешной
            # смене usfc_switch_language уходит в exec и не возвращается
            [Ll]) usfc_switch_language; pause ;;
            [Ii]|'?') show_item_help ;;
            # R когда-то открывала отдельный экран отката. Теперь откат живёт
            # в той же справке, но клавишу принимаем — она у людей в пальцах
            [Rr]) show_item_help ;;
            [Uu]) uninstall_self; pause ;;
            # V <номер> — предпросмотр. Отдельной веткой ДО разбора номеров:
            # иначе "V 5" уехало бы в общий парсер и стало бы применением пункта
            [Vv]|[Vv][[:space:],]*[0-9]*)
                local vnum="${choice#[Vv]}"; vnum="${vnum//[ ,]/}"
                if [ -z "$vnum" ]; then
                    t "Номер пункта для предпросмотра (Enter — отмена):" \
                      "Item number to preview (Enter to cancel):"
                    echo -en "  ${BOLD}${REPLY_T}${NC} "
                    read -r vnum </dev/tty
                fi
                [ -n "$vnum" ] && { preview_item "$vnum"; pause; }
                ;;
            *)
                # номера и буквы разделов вперемешку через пробел/запятую:
                # "5", "1 3 5", "1,3,5", "B", "B,S", "B,14" — всё разбирается одинаково
                local -a nums valid=()
                IFS=', ' read -ra nums <<< "$choice"
                local tok upper i
                for tok in "${nums[@]}"; do
                    [ -z "$tok" ] && continue
                    upper="${tok^^}"
                    if [ "$upper" = "A" ]; then
                        for ((i = 1; i <= ${#ITEM_IDS[@]}; i++)); do valid+=("$i"); done
                    elif expand_section_letter "$upper"; then
                        # номера раздела выводятся из ITEM_SECTIONS, а не зашиты числами —
                        # добавление пункта больше не может разойтись с буквами
                        # shellcheck disable=SC2206
                        valid+=($REPLY_SECTION_ITEMS)
                    elif [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "${#ITEM_IDS[@]}" ]; then
                        valid+=("$tok")
                    else
                        log_error_t "Нет пункта «${tok}»" \
"No such item: ${tok}"
                    fi
                done

                # убрать дубликаты, сохраняя порядок (могут возникнуть при пересечении, например "3,B")
                local -a dedup=()
                local n already
                for n in "${valid[@]}"; do
                    already=false
                    for i in "${dedup[@]}"; do [ "$i" = "$n" ] && already=true && break; done
                    [ "$already" = false ] && dedup+=("$n")
                done
                valid=("${dedup[@]}")

                if [ "${#valid[@]}" -eq 0 ]; then
                    log_error_t "Не понял ввод — номер пункта, буква раздела (C/B/S/P/A), можно сочетать через пробел/запятую, либо I, H, D, L, U, Q" \
"Did not understand — an item number, a section letter (C/B/S/P/A), combinable with spaces or commas, or I, H, D, L, U, Q"
                    sleep 1
                elif [ "${#valid[@]}" -eq 1 ]; then
                    # один пункт — как обычно, интерактивно, со всеми вопросами внутри
                    process_item "${valid[0]}"
                    pause
                else
                    # несколько пунктов разом — сначала убираем то, что уже применено
                    # (иначе "B,S" при частично готовой системе будет зря переспрашивать про то, что и так стоит)
                    local -a pending=() pending_ids=()
                    local id
                    for n in "${valid[@]}"; do
                        id="${ITEM_IDS[$((n-1))]}"
                        if ! item_applied "$id"; then
                            pending+=("$n")
                            pending_ids+=("$id")
                        fi
                    done

                    echo ""
                    if [ "${#pending[@]}" -eq 0 ]; then
                        log_info_t "Из выбранного (${valid[*]}) уже всё применено" \
"Everything selected (${valid[*]}) is already applied"
                        sleep 1
                    else
                        log_info_t "Не применено из выбранного: ${pending[*]} (${#pending[@]} шт.)" \
"Not yet applied from your selection: ${pending[*]} (${#pending[@]})"
                        log_info_t "Каждый пункт применится со своими настройками по умолчанию, без вопросов по ходу" \
"Each item runs with its own defaults, with no questions along the way"
                        preask_bulk_answers "${pending_ids[@]}"

                        echo ""
                        if ask_yn_t "Применить эти ${#pending[@]} пунктов сейчас?" "Apply these ${#pending[@]} items now?"; then
                            run_items "${pending[@]}"
                        fi
                        reset_bulk_answers
                        pause
                    fi
                fi
                ;;
        esac
    done

    print_relogin_hint
    backup_hint

    if [ -f /var/run/reboot-required ]; then
        echo ""
        log_warn_t "Требуется перезагрузка сервера (было обновление ядра/библиотек)" \
"The server needs a reboot (kernel or libraries were updated)"
    fi
    echo ""
}
