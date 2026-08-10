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
  -h, --help            эта справка
  -V, --version         версия и выход
      --no-update       не проверять и не ставить обновления самого usfc
      --verbose         показывать сырой вывод команд вместо спиннера

Неинтерактивный запуск (для cloud-init, Ansible, скриптов развёртывания):
      --apply <что>     применить пункты и выйти, без меню
      --dry-run         показать, что было бы сделано, ничего не меняя
      --config <файл>   ответы на вопросы из файла
      --list            показать профили и id пунктов

  <что> — это профиль, список id или номеров:
      --apply web                 профиль
      --apply docker,nginx,ufw    свои пункты
      --apply all                 все

  Пункты, требующие явного подтверждения (SSH hardening), в неинтерактивном
  режиме пропускаются: закрыть себе доступ к серверу по чужому конфигу —
  не та цена за автоматизацию.

Пример конфига (--config):
      ITEMS=web
      NGINX_AUTOSTART=Y
      DOCKER_AUTOSTART=N
      ZRAM_PERCENT=75
      SWAP_MB=2048
      CERTBOT_CF=Y
      CF_TOKEN=...

Переменные окружения:
  USFC_NO_UPDATE=1          то же, что --no-update
  USFC_VERBOSE=1            то же, что --verbose
  USFC_REPO_RAW_BASE=URL    откуда качать обновления и модули
  USFC_KEEP_LOCALE=1        не форсировать LC_ALL=C.UTF-8
  NO_COLOR=1                вывод без цвета (цвет отключается сам, если
                            TERM=dumb или вывод идёт не в терминал)
  USFC_APT_LOCK_TIMEOUT=N   сколько секунд ждать освобождения блокировки dpkg
                            (по умолчанию ${APT_LOCK_TIMEOUT}; на свежем сервере её
                            держит unattended-upgrades)

Лог всех выполненных команд: ${USFC_LOG}
EOF
}

# Что делать вместо меню. Пусто — обычный интерактивный запуск.
USFC_APPLY_SPEC=""
USFC_CONFIG_FILE=""
USFC_LIST_ONLY=false

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)    show_usage; exit 0 ;;
            -V|--version) echo "$VERSION"; exit 0 ;;
            --no-update)  USFC_NO_UPDATE=1 ;;
            --verbose)    USFC_VERBOSE=1 ;;
            --dry-run)    USFC_DRY_RUN=true; USFC_NO_UPDATE=1 ;;
            --list)       USFC_LIST_ONLY=true ;;
            --apply)
                [ -n "${2:-}" ] || { echo "--apply требует список пунктов или профиль" >&2; exit 2; }
                USFC_APPLY_SPEC="$2"; shift ;;
            --apply=*)    USFC_APPLY_SPEC="${1#*=}" ;;
            --config)
                [ -n "${2:-}" ] || { echo "--config требует путь к файлу" >&2; exit 2; }
                USFC_CONFIG_FILE="$2"; shift ;;
            --config=*)   USFC_CONFIG_FILE="${1#*=}" ;;
            # --yes принимаем ради привычки, но он ничего не включает:
            # --apply и так не задаёт вопросов. Молча игнорировать флаг хуже,
            # чем сказать, что он лишний
            --yes|-y)     : ;;
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

