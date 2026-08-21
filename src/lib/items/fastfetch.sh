# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: fastfetch ─────────────────────────────────────────
usfc_item fastfetch база "fastfetch" \
    "сводка о сервере при каждом заходе по SSH" \
    "fastfetch" \
    "server summary on every SSH login"

usfc_item_full fastfetch "Показывает информацию о сервере (ОС, ядро, память, диск, IP) при каждом заходе
по SSH. Версия не ниже 2.64.0: более старые не умеют выравнивание в format-
строках, которое использует прилагаемый config.jsonc.

Конфиг и автозапуск пишутся в .bashrc сразу этим же пунктом." \
"Shows server information (OS, kernel, memory, disk, IP) on every SSH login.
Version 2.64.0 or newer: older releases lack the padding syntax in format
strings that the bundled config.jsonc relies on.

The config and the login autorun are written to .bashrc by this same item."


usfc_item_rollback fastfetch "sudo apt purge fastfetch
     sudo add-apt-repository --remove ppa:zhangsongcui3371/fastfetch
     rm -f ~/.config/fastfetch/config.jsonc
     sed -i '/# >>> vps-setup:fastfetch >>>/,/# <<< vps-setup:fastfetch <<</d' ~/.bashrc" \
"sudo apt purge fastfetch
     sudo add-apt-repository --remove ppa:zhangsongcui3371/fastfetch
     rm -f ~/.config/fastfetch/config.jsonc
     sed -i '/# >>> vps-setup:fastfetch >>>/,/# <<< vps-setup:fastfetch <<</d' ~/.bashrc"

status_fastfetch() {
    if ! command -v fastfetch &>/dev/null; then
        st "$DIM" "○ не установлен" "○ not installed"; return 1
    fi
    local v lowest
    v="$(fastfetch --version | grep -oP '\d+\.\d+\.\d+' | head -n1)"
    lowest="$(printf '%s\n%s\n' "$v" "2.64.0" | sort -V | head -n1)"
    if [ "$lowest" != "2.64.0" ]; then
        st "$YELLOW" "! ${v} (нужна >= 2.64.0)" "! ${v} (needs >= 2.64.0)"; return 1
    fi
    if [ ! -f "${TARGET_HOME}/.config/fastfetch/config.jsonc" ]; then
        st "$YELLOW" "! ${v}, конфига нет" "! ${v}, no config"; return 1
    fi
    echo -e "${GREEN}✓ ${v}${NC}"; return 0
}

apply_fastfetch() {
    local need_ppa=true
    if command -v fastfetch &>/dev/null; then
        local v lowest
        v="$(fastfetch --version | grep -oP '\d+\.\d+\.\d+' | head -n1)"
        lowest="$(printf '%s\n%s\n' "$v" "2.64.0" | sort -V | head -n1)"
        [ "$lowest" = "2.64.0" ] && need_ppa=false
    fi
    if [ "$need_ppa" = false ]; then
        log_success_t "fastfetch уже подходящей версии" \
"fastfetch is already a suitable version"
    elif os_is_ubuntu; then
        if ask_yn_t "Установить/обновить fastfetch (через PPA)?" "Install or update fastfetch (via PPA)?"; then
            ensure_apt_updated
            # -n (--no-update): add-apt-repository в конце сам дёргает apt update,
            # но опцию DPkg::Lock::Timeout ему не передать — значит он споткнётся
            # о ту же блокировку dpkg. Добавляем только репозиторий, а списки
            # обновляем своим apt_get, у которого таймаут уже есть.
            run_logged "PPA fastfetch" add-apt-repository -y -n ppa:zhangsongcui3371/fastfetch
            t "Списки пакетов PPA" "PPA package lists"
    run_logged "$REPLY_T" apt_get update -qq
            if run_logged "fastfetch" apt_get install -y fastfetch; then
                refresh_pkg_cache
                log_info_t "Версия: $(fastfetch --version 2>/dev/null)" \
"Version: $(fastfetch --version 2>/dev/null)"
            fi
        fi
    # PPA — механизм Launchpad, на Debian его нет. Зато с trixie fastfetch
    # лежит в обычных репозиториях (проверено: в bookworm его ещё нет)
    elif apt-cache policy fastfetch 2>/dev/null | grep 'Candidate:.*[0-9]' >/dev/null; then
        if ask_yn_t "Установить fastfetch из репозиториев ${OS_ID}?" "Install fastfetch from the ${OS_ID} repositories?"; then
            if ensure_pkg "fastfetch" fastfetch; then
                log_info_t "Версия: $(fastfetch --version 2>/dev/null)" \
"Version: $(fastfetch --version 2>/dev/null)"
            fi
        fi
    else
        # Молчать нельзя: пункт остался бы вечно «не установлен» без объяснения,
        # почему его невозможно применить именно здесь
        log_warn_t "В репозиториях ${OS_PRETTY:-$OS_ID} нет пакета fastfetch" \
"There is no fastfetch package in ${OS_PRETTY:-$OS_ID}"
        log_info_t "PPA существует только для Ubuntu. Варианты: поставить .deb" \
"The PPA is Ubuntu-only. Options: install the .deb from"
        log_info_t "с github.com/fastfetch-cli/fastfetch/releases или обновить дистрибутив" \
"github.com/fastfetch-cli/fastfetch/releases, or upgrade the distribution"
        return 0
    fi

    # конфиг и автозапуск в .bashrc пишем сразу следом — не отдельным пунктом меню
    if ! command -v fastfetch &>/dev/null; then return; fi

    install -d -o "$TARGET_USER" -g "$(id -g "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" \
        -m 755 "${TARGET_HOME}/.config/fastfetch"
    if [ -f "${TARGET_HOME}/.config/fastfetch/config.jsonc" ]; then
        log_info_t "config.jsonc уже есть" \
"config.jsonc is already there"
    elif [ "$USFC_DRY_RUN" = true ]; then
        # curl с -o пишет файл мимо write_file, то есть мимо всего перехвата.
        # На машине, где fastfetch уже стоит, а конфига нет, сухой прогон
        # реально создавал бы ~/.config/fastfetch/config.jsonc
        t "скачивание config.jsonc → ${TARGET_HOME}/.config/fastfetch/config.jsonc" \
          "downloading config.jsonc → ${TARGET_HOME}/.config/fastfetch/config.jsonc"
        _dry_say "$REPLY_T"
    elif curl -fsSL "${REPO_RAW_BASE}/config.jsonc" -o "${TARGET_HOME}/.config/fastfetch/config.jsonc" 2>/dev/null; then
        chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.config/fastfetch/config.jsonc"
        log_success_t "config.jsonc установлен" \
"config.jsonc installed"
    else
        log_warn_t "Не удалось скачать config.jsonc из ${REPO_RAW_BASE}" \
"Could not download config.jsonc from ${REPO_RAW_BASE}"
    fi

    local BASHRC="${TARGET_HOME}/.bashrc" need_fastfetch_block=false
    if grep -qF "# >>> vps-setup:fastfetch >>>" "$BASHRC" 2>/dev/null; then
        # старый блок (без гейта USFC_RESOURCE) печатал бы fastfetch второй раз
        # при каждом auto-source из usfc-обёртки (см. main()) — апгрейдим его
        if grep -qF "USFC_RESOURCE:-" "$BASHRC" 2>/dev/null; then
            log_info_t "Автозапуск fastfetch в .bashrc уже есть" \
"The fastfetch autorun is already in .bashrc"
        else
            sed -i '/# >>> vps-setup:fastfetch >>>/,/# <<< vps-setup:fastfetch <<</d' "$BASHRC"
            need_fastfetch_block=true
        fi
    else
        need_fastfetch_block=true
    fi
    if [ "$need_fastfetch_block" = true ]; then
        append_file "$BASHRC" <<'EOF'

# >>> vps-setup:fastfetch >>>
if [ -z "${USFC_RESOURCE:-}" ] && [ -x "$(command -v fastfetch)" ]; then
    fastfetch
fi
# <<< vps-setup:fastfetch <<<
EOF
        chown "${TARGET_USER}:${TARGET_USER}" "$BASHRC"
        log_success_t "Автозапуск добавлен в .bashrc" \
"Autorun added to .bashrc"
    fi
}
