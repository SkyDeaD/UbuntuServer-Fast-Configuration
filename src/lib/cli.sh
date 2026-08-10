# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

uninstall_self() {
    echo ""
    log_warn "Это удаляет СЕБЯ (сам скрипт usfc) — /opt/vps-setup и команду usfc"
    log_info "Всё, что скрипт установил на систему (пакеты, Docker, nginx, SSH hardening и т.д.) —"
    log_info "этим не трогается. Команды на удаление лежат на экране I (справка и откат)"
    if ask_yn "Точно удалить usfc из системы?" N; then
        rm -f /usr/local/bin/usfc
        rm -rf /opt/vps-setup
        echo ""
        log_success "usfc удалён. Пока."
        exit 0
    fi
}

show_usage() {
    cat <<EOF
usfc ${VERSION} — UbuntuServer Fast Configuration
  https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration

Использование: sudo usfc [опции]

Без опций открывается интерактивное меню.

Опции:
  -h, --help       эта справка
  -V, --version    версия и выход
      --no-update  не проверять и не ставить обновления самого usfc
      --verbose    показывать сырой вывод команд вместо спиннера

Переменные окружения:
  USFC_NO_UPDATE=1          то же, что --no-update
  USFC_VERBOSE=1            то же, что --verbose
  USFC_KEEP_LOCALE=1        не форсировать LC_ALL=C.UTF-8
  NO_COLOR=1                вывод без цвета (цвет отключается сам, если
                            TERM=dumb или вывод идёт не в терминал)
  USFC_APT_LOCK_TIMEOUT=N   сколько секунд ждать освобождения блокировки dpkg
                            (по умолчанию ${APT_LOCK_TIMEOUT}; на свежем сервере её
                            держит unattended-upgrades)

Лог всех выполненных команд: ${USFC_LOG}
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)    show_usage; exit 0 ;;
            -V|--version) echo "$VERSION"; exit 0 ;;
            --no-update)  USFC_NO_UPDATE=1 ;;
            --verbose)    USFC_VERBOSE=1 ;;
            *)
                echo "Неизвестная опция: $1" >&2
                echo "" >&2
                show_usage >&2
                exit 2
                ;;
        esac
        shift
    done
}

