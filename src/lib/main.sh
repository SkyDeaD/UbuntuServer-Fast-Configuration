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

    local -a nums=() skipped=() already=()
    local n id
    for n in "${REPLY_ITEM_NUMS[@]}"; do
        id="${ITEM_IDS[$((n - 1))]}"
        # SSH hardening умеет закрыть доступ к серверу и потому всегда требовал
        # явного подтверждения. Молча пропускать его тоже нельзя — скажем прямо
        if [ "$id" = "sshhardening" ]; then
            skipped+=("$id")
            continue
        fi
        # Уже применённое пропускаем. Это не оптимизация, а вопрос смысла:
        # в меню повторный выбор ⇄-пункта означает «переключить», и без этой
        # проверки `--apply` из cloud-init ВЫКЛЮЧАЛ бы то, что просили включить.
        # Заодно повторный запуск становится честным no-op — как и положено
        # в провижининге
        if item_applied "$id"; then
            already+=("$id")
            continue
        fi
        nums+=("$n")
    done

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
    dry_run_enable

    if [ "$USFC_LIST_ONLY" = true ]; then
        profile_list
        exit 0
    fi
    case "$USFC_ACTION" in
        audit)   show_audit; exit 0 ;;
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

    while true; do
        show_menu
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        read -r choice </dev/tty
        case "$choice" in
            [Qq]) echo ""; log_info_t "Пока. Повторный запуск: usfc" \
"Bye. Run it again with: usfc"; break ;;
            [Hh]) show_aliases_help ;;
            # "?" как синоним I: привычнее для тех, кто ищет справку вслепую
            [Dd]) show_audit; pause ;;
            [Ii]|'?') show_item_help ;;
            # R когда-то открывала отдельный экран отката. Теперь откат живёт
            # в той же справке, но клавишу принимаем — она у людей в пальцах
            [Rr]) show_item_help ;;
            [Uu]) uninstall_self; pause ;;
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
                    log_error_t "Не понял ввод — номер пункта, буква раздела (C/B/S/P/A), можно сочетать через пробел/запятую, либо I, H, D, U, Q" \
"Did not understand — an item number, a section letter (C/B/S/P/A), combinable with spaces or commas, or I, H, D, U, Q"
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

                        # Всё, что нельзя молча задефолтить, спрашиваем ЗДЕСЬ — до
                        # BULK_MODE=true, пока ask_yn/ask_value ещё интерактивны.
                        # Сверяемся по id, а не по номеру пункта: номера меняются при
                        # добавлении пунктов, id — нет.
                        local pid
                        for pid in "${pending_ids[@]}"; do
                            case "$pid" in
                                zram)
                                    read_swap_state
                                    if ! { [ "$ZRAM_ACTIVE" = true ] && [ "$ZRAM_PRIO" = "100" ]; }; then
                                        echo ""
                                        log_info_t "zram — сжатая память вместо свопа на диске: быстрее и не треплет SSD." \
"zram — compressed memory instead of on-disk swap: faster, and it spares the SSD."
                                        log_info_t "75% — разумный дефолт, менять обычно не нужно" \
"75% is a sensible default and rarely needs changing"
                                        ZRAM_BULK_PERCENT="$(ask_value_t "Размер zram в % от RAM?" "zram size, % of RAM?" 75)"
                                    fi
                                    if [ "$SWAP_ACTIVE" != true ]; then
                                        echo ""
                                        log_info_t "Своп-файл — запас на диске на случай, если zram кончится" \
"A swap file is the on-disk reserve for when zram runs out"
                                        SWAP_BULK_MB="$(ask_value_t "Размер резервного swap-файла, МБ?" "Backup swap file size, MB?" "$(suggest_swap_mb)")"
                                    elif [ "$SWAP_TYPE" = "file" ]; then
                                        # своп есть, но размер мог разъехаться с рекомендацией —
                                        # спрашиваем ЗДЕСЬ, пока ask_value ещё интерактивна
                                        local sw_want
                                        sw_want="$(suggest_swap_mb "$SWAP_SIZE_MB")"
                                        if swap_needs_resize "$SWAP_SIZE_MB" "$sw_want"; then
                                            log_info_t "Своп ${SWAP_PATH}: сейчас ${SWAP_SIZE_MB} МБ, рекомендуется ${sw_want} МБ" \
"Swap ${SWAP_PATH}: currently ${SWAP_SIZE_MB} MB, recommended ${sw_want} MB"
                                            SWAP_BULK_MB="$(ask_value "Размер резервного swap-файла, МБ?" "$sw_want")"
                                        fi
                                    fi
                                    ;;
                                nginx)
                                    echo ""
                                    log_info_t "nginx — веб-сервер и реверс-прокси. Если сайты пока не настроены," \
"nginx is a web server and reverse proxy. If no sites are configured yet,"
                                    log_info_t "поднимать его не обязательно — включишь потом пунктом $(item_number nginx) в меню" \
"there is no need to start it — you can enable it later via menu item $(item_number nginx)"
                                    # shellcheck disable=SC2034  # читается косвенно через resolve_autostart
                                    ask_yn_t "Запускать nginx после установки (и включать автозапуск)?" "Start nginx after installing (and enable autostart)?" N \
                                        && NGINX_AUTOSTART=Y || NGINX_AUTOSTART=N
                                    ;;
                                docker)
                                    echo ""
                                    log_info_t "Docker — запуск приложений в контейнерах. Если сейчас не нужен," \
"Docker runs applications in containers. If you do not need it right now,"
                                    log_info_t "можно не поднимать — включишь потом пунктом $(item_number docker) в меню" \
"you can leave it down — enable it later via menu item $(item_number docker)"
                                    # shellcheck disable=SC2034  # читается косвенно через resolve_autostart
                                    ask_yn_t "Запускать Docker после установки (и включать автозапуск)?" "Start Docker after installing (and enable autostart)?" N \
                                        && DOCKER_AUTOSTART=Y || DOCKER_AUTOSTART=N
                                    ;;
                                certbot)
                                    # В BULK_MODE вопрос внутри apply_certbot молча
                                    # ушёл бы в дефолт N, и плагин не поставился бы
                                    # вовсе — спрашиваем здесь, вместе с токеном
                                    if ! pkg_installed python3-certbot-dns-cloudflare; then
                                        echo ""
                                        log_info_t "Плагин Cloudflare нужен только для wildcard-сертификатов (*.example.com)." \
"The Cloudflare plugin is only needed for wildcard certificates (*.example.com)."
                                        log_info_t "Для обычных сертификатов хватает плагина nginx, который поставится сам" \
"Ordinary certificates only need the nginx plugin, which is installed automatically"
                                        if ask_yn_t "Установить плагин Cloudflare?" "Install the Cloudflare plugin?" N; then
                                            CERTBOT_CF_BULK=Y
                                            log_info_t "Токену нужны права Zone:DNS:Edit. Без него плагин работать не будет" \
"The token needs Zone:DNS:Edit. Without it the plugin will not work"
                                            ask_cf_token && CF_TOKEN_BULK="$REPLY_CF_TOKEN"
                                            REPLY_CF_TOKEN=""
                                        else
                                            CERTBOT_CF_BULK=N
                                        fi
                                    fi
                                    ;;
                            esac
                        done

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
