# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# preask_bulk_answers <id пунктов...> — задать ВСЕ интерактивные вопросы
# заранее, до BULK_MODE=true.
#
# Вынесено из main(), потому что тот же предзапрос нужен мастеру первого
# запуска. Второй экземпляр этого блока разошёлся бы с первым на ближайшей
# правке — та же причина, по которой рядом живёт filter_pending.
preask_bulk_answers() {
    local pid

                            # Всё, что нельзя молча задефолтить, спрашиваем ЗДЕСЬ — до
                            # BULK_MODE=true, пока ask_yn/ask_value ещё интерактивны.
                            # Сверяемся по id, а не по номеру пункта: номера меняются при
                            # добавлении пунктов, id — нет.
                                                        for pid in "$@"; do
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
                                                SWAP_BULK_MB="$(ask_value_t "Размер резервного swap-файла, МБ?" "Backup swap file size, MB?" "$sw_want")"
                                            fi
                                        fi
                                        # sysctl — такая же рекомендация пункта, как
                                        # процент zram, и спрашивать её надо здесь же.
                                        # В пакетном прогоне ask_yn вопросов не задаёт,
                                        # а прежний дефолт вычислялся из текущих
                                        # значений и выпадал в «нет» на любой машине,
                                        # где их хоть немного трогали, — рекомендация
                                        # тихо не применялась
                                        local cur_sw cur_vfs
                                        cur_sw="$(cat "${USFC_PROC_VM}"/swappiness 2>/dev/null || echo '?')"
                                        cur_vfs="$(cat "${USFC_PROC_VM}"/vfs_cache_pressure 2>/dev/null || echo '?')"
                                        if ! { [ "$cur_sw" = "80" ] && [ "$cur_vfs" = "50" ]; }; then
                                            echo ""
                                            log_info_t "Сейчас swappiness=${cur_sw}, vfs_cache_pressure=${cur_vfs}. Под zram рекомендуются 80 и 50: своп быстрый, и отдавать в него страницы охотнее выгодно" \
    "Currently swappiness=${cur_sw}, vfs_cache_pressure=${cur_vfs}. With zram 80 and 50 are recommended: swap is fast here, so paging out more eagerly pays off"
                                            if ask_yn_t "Применить рекомендованные значения sysctl?" \
                                                        "Apply the recommended sysctl values?"; then
                                                SYSCTL_BULK=Y
                                            else
                                                SYSCTL_BULK=N
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
}
