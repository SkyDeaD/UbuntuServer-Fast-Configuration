# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# run_items <номера...> — прогнать пачку пунктов без вопросов по ходу.
# Вынесено из меню, потому что ровно то же нужно неинтерактивному `usfc apply`:
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

# Неинтерактивный прогон: cloud-init, Ansible, скрипт развёртывания.
#
# Коды возврата сделаны пригодными для CI, а не «0 или что-то»:
#   0 — всё применилось
#   1 — часть пунктов не удалась
#   2 — не разобрали, что применять (опечатка в профиле или id)
run_noninteractive() {
    # Файл ответов, потом флаги поверх: флаг сильнее файла, файл — дефолта
    apply_cli_answers || return 2
    [ -n "$USFC_APPLY_SPEC" ] || { log_error_t "Не задано, что применять: ни в командной строке, ни ITEMS= в файле ответов" \
"Nothing to apply: neither on the command line nor as ITEMS= in the answers file"; return 2; }
    resolve_items "$USFC_APPLY_SPEC" || return 2
    local -a resolved_ids=()
    local k
    for k in "${REPLY_ITEM_NUMS[@]}"; do resolved_ids+=("${ITEM_IDS[$((k - 1))]}"); done
    check_cli_answer_items "${resolved_ids[@]}" || return 2

    # UFW в списке без явного согласия не включается: вслепую включённый
    # файрвол рвёт VPN и прокси. Согласие — --ufw, UFW=Y или --yes
    if [[ " ${resolved_ids[*]} " == *" ufw "* ]] && [ -z "$UFW_BULK" ]; then
        if [ "$USFC_ASSUME_YES" = true ]; then
            UFW_BULK=Y
        else
            log_warn_t "UFW в списке, но согласия на его включение нет — добавьте --ufw (или --yes)" \
"UFW is in the list, but there is no consent to enable it — add --ufw (or --yes)"
        fi
    fi

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
    # Ansible, usfc apply), вопрос был бы либо навязчивым, либо вовсе некому
    # отвечать — и скрипт завис бы на чтении с /dev/tty
    # Признак первого запуска снимаем ДО вопроса о языке: usfc_ask_language
    # сохраняет выбор, и после него «первого запуска» уже не существует
    local first_run=false
    usfc_lang_saved || first_run=true

    if ! usfc_lang_saved && [ "$USFC_LANG_EXPLICIT" = false ] \
       && [ -z "$USFC_CMD" ] && usfc_interactive; then
        usfc_ask_language
    fi

    dry_run_enable

    case "$USFC_CMD" in
        list)    profile_list; exit 0 ;;
        audit)
            if [ "$USFC_AUDIT_JSON" = true ]; then audit_emit_json; else show_audit; fi
            # код возврата пригоден для мониторинга: 1 — есть важные проблемы
            [ "$AUDIT_CRIT" -eq 0 ]; exit $? ;;
        backups) backup_list; exit $? ;;
        restore) backup_restore "$USFC_RESTORE_STAMP"; exit $? ;;
        apply)   run_noninteractive; exit $? ;;
    esac

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
    # Все неинтерактивные ветки (команды list, audit, apply…) вышли
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
                    local -a pending=() pending_ids=() done_titles=()
                    local id
                    for n in "${valid[@]}"; do
                        id="${ITEM_IDS[$((n-1))]}"
                        if item_applied "$id"; then
                            done_titles+=("${ITEM_TITLES[$((n-1))]}")
                        else
                            pending+=("$n")
                            pending_ids+=("$id")
                        fi
                    done

                    echo ""
                    if [ "${#done_titles[@]}" -gt 0 ]; then
                        local IFS_SAVE="$IFS"; IFS=','
                        log_info_t "Уже применено, пропускаю: ${DIM}${done_titles[*]}${NC}" \
"Already applied, skipping: ${DIM}${done_titles[*]}${NC}"
                        IFS="$IFS_SAVE"
                    fi
                    if [ "${#pending[@]}" -eq 0 ]; then
                        log_info_t "Из выбранного уже всё применено" \
"Everything selected is already applied"
                        pause
                    else
                        local titles=() k
                        for k in "${pending[@]}"; do titles+=("${ITEM_TITLES[$((k-1))]}"); done
                        log_info_t "Будет применено (${#pending[@]}):" "To be applied (${#pending[@]}):"
                        for k in "${titles[@]}"; do printf '      %s\n' "$k"; done
                        echo ""
                        if ask_yn_t "Применить эти ${#pending[@]} пунктов? Вопросы задам сразу, дальше всё пойдёт само" "Apply these ${#pending[@]} items? I will ask everything up front, then it runs on its own"; then
                            # Пользователь — первым и интерактивно: ему нужны имя и
                            # пароль с терминала, а дотфайлы остальных пунктов этого
                            # же прогона иначе легли бы в /root
                            if [[ " ${pending_ids[*]} " == *" newuser "* ]]; then
                                process_item "$(item_number newuser)"
                                invalidate_statuses
                                local -a rest=() rest_ids=()
                                for k in "${!pending_ids[@]}"; do
                                    [ "${pending_ids[$k]}" = newuser ] && continue
                                    rest+=("${pending[$k]}"); rest_ids+=("${pending_ids[$k]}")
                                done
                                pending=("${rest[@]+"${rest[@]}"}"); pending_ids=("${rest_ids[@]+"${rest_ids[@]}"}")
                            fi
                            preask_bulk_answers "${pending_ids[@]+"${pending_ids[@]}"}"
                            run_items "${pending[@]+"${pending[@]}"}"
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
