# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: fastfetch ─────────────────────────────────────────
usfc_item fastfetch база "fastfetch" \
    "сводка о сервере при каждом заходе по SSH" \
    "fastfetch" \
    "server summary on every SSH login"

usfc_item_full fastfetch "Показывает информацию о сервере (ОС, ядро, память, диск, IP) при каждом заходе
по SSH. Версия не ниже 2.40.4 (это trixie): конфиг написан без возможностей
новых версий, поэтому одинаково выглядит на Debian 13, Ubuntu 26.04 и из PPA.

Конфиг и автозапуск пишутся в .bashrc сразу этим же пунктом. Автозапуск
срабатывает только в интерактивном SSH-входе вне tmux и молчит, если уже
стоит карточка из пункта «motd» (иначе сводка печаталась бы дважды)." \
"Shows server information (OS, kernel, memory, disk, IP) on every SSH login.
Version 2.40.4 or newer (that is trixie): the config avoids features of newer
releases, so it looks the same on Debian 13, Ubuntu 26.04 and the PPA build.

The config and the login autorun are written to .bashrc by this same item. The
autorun fires only for an interactive SSH login outside tmux and stays silent
when the motd card is installed (otherwise the summary would print twice)."


usfc_item_rollback fastfetch "sudo apt purge fastfetch
     sudo add-apt-repository --remove ppa:zhangsongcui3371/fastfetch
     rm -f ~/.config/fastfetch/config.jsonc
     sed -i '/# >>> vps-setup:fastfetch >>>/,/# <<< vps-setup:fastfetch <<</d' ~/.bashrc" \
"sudo apt purge fastfetch
     sudo add-apt-repository --remove ppa:zhangsongcui3371/fastfetch
     rm -f ~/.config/fastfetch/config.jsonc
     sed -i '/# >>> vps-setup:fastfetch >>>/,/# <<< vps-setup:fastfetch <<</d' ~/.bashrc"

# Метка версии блока в .bashrc: блок любой другой версии (или без метки)
# переписывается целиком, как CLI_BLOCK_MARK в items/cli.sh
FF_BLOCK_MARK="# usfc:fastfetch-block v2"
# Метка версии конфига; конфиг без неё старый или правленый пользователем
FF_CONFIG_MARK="usfc:fastfetch-config v2"
# Минимум — версия в Debian 13 (2.40.4): конфиг проверен на ней, 2.57.1 и 2.70.0.
# Раньше требовали 2.64.0 из-за {formatted}/выравнивания; из конфига это убрано.
FF_MIN_VERSION="2.40.4"
# sha256 конфигов, которые usfc ставил раньше (из истории git). Только такой
# файл обновляем сами: любой другой пользователь мог править руками
FF_OLD_CONFIG_SHA="c21ab7f2768d4dcce55a64eff531706adbb1c40a42cfa044efd868572d3072ac"

# Версия fastfetch → REPLY_TEXT (пусто, если не установлен)
_ff_version() {
    REPLY_TEXT=""
    command -v fastfetch &>/dev/null || return 1
    REPLY_TEXT="$(fastfetch --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    [ -n "$REPLY_TEXT" ]
}

_ff_version_ok() {
    local lowest
    lowest="$(printf '%s\n%s\n' "$1" "$FF_MIN_VERSION" | sort -V | head -n1)"
    [ "$lowest" = "$FF_MIN_VERSION" ]
}

status_fastfetch() {
    if ! _ff_version; then
        st "$DIM" "○ не установлен" "○ not installed"; return 1
    fi
    local v="$REPLY_TEXT" bashrc="${TARGET_HOME}/.bashrc"
    if ! _ff_version_ok "$v"; then
        st "$YELLOW" "! ${v} (нужна >= ${FF_MIN_VERSION})" "! ${v} (needs >= ${FF_MIN_VERSION})"; return 1
    fi
    if [ ! -f "${TARGET_HOME}/.config/fastfetch/config.jsonc" ]; then
        st "$YELLOW" "! ${v}, конфига нет" "! ${v}, no config"; return 1
    fi
    # без блока сводка при входе не появится; блок старой версии печатал бы её
    # и в tmux, и под scp-подобными входами
    if ! grep -qF "# >>> vps-setup:fastfetch >>>" "$bashrc" 2>/dev/null; then
        st "$YELLOW" "! ${v}, автозапуска нет" "! ${v}, no autorun"; return 1
    fi
    if ! grep -qF "$FF_BLOCK_MARK" "$bashrc" 2>/dev/null; then
        st "$YELLOW" "! ${v}, автозапуск устарел" "! ${v}, autorun outdated"; return 1
    fi
    echo -e "${GREEN}✓ ${v}${NC}"; return 0
}

apply_fastfetch() {
    local need_ppa=true
    if _ff_version && _ff_version_ok "$REPLY_TEXT"; then
        need_ppa=false
    fi
    if [ "$need_ppa" = false ]; then
        log_success_t "fastfetch уже подходящей версии" \
"fastfetch is already a suitable version"
    elif os_is_ubuntu; then
        if ask_yn_t "Установить/обновить fastfetch (через PPA)?" "Install or update fastfetch (via PPA)?"; then
            ensure_apt_updated
            # add-apt-repository живёт в software-properties-common, которого нет
            # в минимальных образах: без него PPA молча не подключался
            ensure_pkg "software-properties-common" software-properties-common || return 1
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
            else
                return 1
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

    ensure_user_dir "${TARGET_HOME}/.config/fastfetch"
    local cfg="${TARGET_HOME}/.config/fastfetch/config.jsonc" write_cfg=false
    if [ ! -f "$cfg" ]; then
        write_cfg=true
    elif grep -F "$FF_CONFIG_MARK" "$cfg" >/dev/null 2>&1; then
        log_info_t "config.jsonc уже актуальной версии" \
"config.jsonc is already up to date"
    elif [ "$(sha256sum "$cfg" 2>/dev/null | cut -d' ' -f1)" = "$FF_OLD_CONFIG_SHA" ]; then
        # байт-в-байт наш прежний конфиг — правок пользователя нет, обновляем
        write_cfg=true
    else
        # чужой или правленый конфиг не трогаем, но говорим об этом: новая
        # карточка (CPU с ядрами, виртуализация) в нём не появится
        log_warn_t "config.jsonc изменён вручную — оставлен как есть" \
"config.jsonc was edited by hand — left untouched"
        log_info_t "Свежий образец: ${REPO_RAW_BASE}/config.jsonc" \
"Fresh sample: ${REPO_RAW_BASE}/config.jsonc"
    fi
    if [ "$write_cfg" = true ]; then
        # Во временный файл, а на место — через write_file (снимок, сухой
        # прогон). Прямой curl -o оставлял обрубок при оборванной закачке,
        # и дальше пункт считал «config.jsonc уже есть»
        local tmp
        tmp="$(mktemp)"
        if curl -fsSL --max-time 30 "${REPO_RAW_BASE}/config.jsonc" -o "$tmp" 2>/dev/null \
           && grep '"modules"' "$tmp" >/dev/null; then
            write_file "$cfg" < "$tmp"
            chown "${TARGET_USER}:$(id -g "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$cfg"
            log_success_t "config.jsonc установлен" \
"config.jsonc installed"
        else
            log_warn_t "Не удалось скачать config.jsonc из ${REPO_RAW_BASE}" \
"Could not download config.jsonc from ${REPO_RAW_BASE}"
        fi
        rm -f "$tmp"
    fi

    local BASHRC="${TARGET_HOME}/.bashrc" need_fastfetch_block=false
    if grep -qF "# >>> vps-setup:fastfetch >>>" "$BASHRC" 2>/dev/null; then
        if grep -qF "$FF_BLOCK_MARK" "$BASHRC" 2>/dev/null; then
            log_info_t "Автозапуск fastfetch в .bashrc уже есть" \
"The fastfetch autorun is already in .bashrc"
        else
            # блок любой прежней версии: старые печатали сводку и в tmux,
            # и поверх карточки motd
            remove_block "$BASHRC" vps-setup:fastfetch || return 1
            need_fastfetch_block=true
        fi
    else
        need_fastfetch_block=true
    fi
    if [ "$need_fastfetch_block" = true ]; then
        # Условия: SSH-вход, login-оболочка (иначе каждый `bash` внутри сессии
        # печатал бы сводку), не tmux (каждая панель = новый вход), не наш
        # usfc-source (USFC_RESOURCE) и нет карточки motd — она уже всё показала.
        # Метка внутри блока: при смене условий версию поднимаем, блок перепишется.
        append_file "$BASHRC" <<EOF

# >>> vps-setup:fastfetch >>>
${FF_BLOCK_MARK}
if [ -n "\${SSH_CONNECTION:-}" ] && [ -z "\${TMUX:-}" ] && [ -z "\${USFC_RESOURCE:-}" ] \\
   && shopt -q login_shell && [ ! -x /etc/update-motd.d/01-usfc ] \\
   && command -v fastfetch >/dev/null 2>&1; then
    fastfetch
fi
# <<< vps-setup:fastfetch <<<
EOF
        chown "${TARGET_USER}:$(id -g "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$BASHRC"
        log_success_t "Автозапуск добавлен в .bashrc" \
"Autorun added to .bashrc"
    fi
}
