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
        sed -i '/# >>> vps-setup:self >>>/,/# <<< vps-setup:self <<</d' "$p"
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
      --lang ru|en      язык интерфейса на этот запуск (не сохраняется;
                        постоянный выбор — клавиша L в меню)

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
      --lang ru|en      interface language for this run (not persisted;
                        to change it for good use the L key in the menu)

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
                echo "Unknown option: $1" >&2
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

