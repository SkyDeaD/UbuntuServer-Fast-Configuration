# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

uninstall_self() {
    echo ""
    log_warn_t "Это удаляет СЕБЯ (сам скрипт usfc) — /opt/vps-setup и команду usfc" \
"This removes usfc ITSELF — /opt/vps-setup and the usfc command"
    log_info_t "Всё, что скрипт установил на систему (пакеты, Docker, nginx, SSH hardening и т.д.) —" \
"Everything it installed on the system (packages, Docker, nginx, SSH hardening and so on)"
    log_info_t "этим не трогается. Команды на удаление лежат на экране I (справка и откат)" \
"is left alone. Removal commands live on screen I (help and rollback)"
    if ask_yn_t "Точно удалить usfc из системы?" "Really remove usfc from this system?" N; then
        rm -f /usr/local/bin/usfc
        rm -rf /opt/vps-setup
        echo ""
        log_success_t "usfc удалён. Пока." \
"usfc removed. Bye."
        exit 0
    fi
}

show_usage() {
    [ "$USFC_LANG" = en ] && { show_usage_en; return 0; }
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
      --lang ru|en      язык интерфейса (по умолчанию ru)

Неинтерактивный запуск (для cloud-init, Ansible, скриптов развёртывания):
      --apply <что>     применить пункты и выйти, без меню
      --dry-run         показать, что было бы сделано, ничего не меняя
      --config <файл>   ответы на вопросы из файла
      --list            показать профили и id пунктов
      --audit           проверить состояние сервера (только чтение)
      --backups         показать снимки конфигов
      --restore [метка] восстановить конфиги из снимка
  -y, --yes             не спрашивать подтверждения (нужен для --restore)

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
  USFC_LANG=en              то же, что --lang en
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
USFC_ACTION=""
USFC_RESTORE_STAMP=""
USFC_ASSUME_YES=false

show_usage_en() {
    cat <<EOF
usfc ${VERSION} — UbuntuServer Fast Configuration
  https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration

Usage: sudo usfc [options]

With no options it opens the interactive menu.

Options:
  -h, --help            this help
  -V, --version         print version and exit
      --no-update       do not check for or install usfc updates
      --verbose         show raw command output instead of the spinner
      --lang ru|en      interface language (default: ru)

Non-interactive use (cloud-init, Ansible, provisioning scripts):
      --apply <what>    apply items and exit, no menu
      --dry-run         show what would be done, change nothing
      --config <file>   read answers from a file
      --list            list profiles and item ids
      --audit           check the server's current state (read-only)
      --backups         list config snapshots
      --restore [stamp] restore configs from a snapshot
  -y, --yes             skip confirmation (required by --restore)

  <what> is a profile, or a list of ids or numbers:
      --apply web                 a profile
      --apply docker,nginx,ufw    your own items
      --apply all                 everything

  Items that need explicit confirmation (SSH hardening) are skipped in
  non-interactive mode: locking yourself out of the server because of
  somebody else's config file is not a fair price for automation.

Config file example (--config):
      ITEMS=web
      NGINX_AUTOSTART=Y
      DOCKER_AUTOSTART=N
      ZRAM_PERCENT=75
      SWAP_MB=2048
      CERTBOT_CF=Y
      CF_TOKEN=...

Environment:
  USFC_NO_UPDATE=1          same as --no-update
  USFC_VERBOSE=1            same as --verbose
  USFC_LANG=en              same as --lang en
  USFC_REPO_RAW_BASE=URL    where to fetch updates and modules from
  USFC_KEEP_LOCALE=1        do not force LC_ALL=C.UTF-8
  NO_COLOR=1                no colour (also disabled automatically when
                            TERM=dumb or output is not a terminal)
  USFC_APT_LOCK_TIMEOUT=N   seconds to wait for the dpkg lock
                            (default ${APT_LOCK_TIMEOUT}; on a fresh server it is
                            held by unattended-upgrades)

Command log: ${USFC_LOG}
EOF
}

parse_args() {
    local want_help=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            # Справку и версию печатаем ПОСЛЕ разбора всех аргументов:
            # иначе `usfc --help --lang en` выдавал бы русский текст — просто
            # потому, что --help встретился первым
            -h|--help)    want_help=true ;;
            -V|--version) echo "$VERSION"; exit 0 ;;
            --no-update)  USFC_NO_UPDATE=1 ;;
            --verbose)    USFC_VERBOSE=1 ;;
            --lang)
                [ -n "${2:-}" ] || { echo "--lang требует ru или en" >&2; exit 2; }
                USFC_LANG="$2"; shift ;;
            --lang=*)     USFC_LANG="${1#*=}" ;;
            --dry-run)    USFC_DRY_RUN=true; USFC_NO_UPDATE=1 ;;
            --list)       USFC_LIST_ONLY=true ;;
            --audit)      USFC_ACTION=audit ;;
            --backups)    USFC_ACTION=backups ;;
            --restore)
                USFC_ACTION=restore
                case "${2:-}" in -*|'') ;; *) USFC_RESTORE_STAMP="$2"; shift ;; esac ;;
            --apply)
                [ -n "${2:-}" ] || { echo "--apply требует список пунктов или профиль" >&2; exit 2; }
                USFC_APPLY_SPEC="$2"; shift ;;
            --apply=*)    USFC_APPLY_SPEC="${1#*=}" ;;
            --config)
                [ -n "${2:-}" ] || { echo "--config требует путь к файлу" >&2; exit 2; }
                USFC_CONFIG_FILE="$2"; shift ;;
            --config=*)   USFC_CONFIG_FILE="${1#*=}" ;;
            # Для --apply он не нужен (вопросов там и так нет), а вот
            # --restore перезаписывает работающие конфиги и всегда спрашивает.
            # Без явного --yes откат из скрипта был бы невозможен
            --yes|-y)     USFC_ASSUME_YES=true ;;
            *)
                echo "Неизвестная опция: $1" >&2
                echo "" >&2
                show_usage >&2
                exit 2
                ;;
        esac
        shift
    done
    case "$USFC_LANG" in ru|en) ;; *) USFC_LANG=ru ;; esac
    if [ "$want_help" = true ]; then show_usage; exit 0; fi
}

