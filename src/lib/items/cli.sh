# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# Пакеты CLI-набора вынесены в переменную: их перечисляли в трёх местах
# (status_cli, apply_cli, установка), и списки уже начинали расходиться
CLI_PKGS="bat fd-find ripgrep zoxide ncdu"
# eza приехал в Debian только с trixie. На bookworm его нет, и без этой ветки
# пункт вечно показывал бы «не хватает: eza» — состояние, которое пользователь
# не может исправить, потому что пакета попросту не существует
if os_is_ubuntu || os_version_at_least 13; then
    CLI_PKGS="eza ${CLI_PKGS}"
fi
# ── Пункт меню: CLI-утилиты + starship ─────────────────────────────────────────
usfc_item cli база "CLI-утилиты + starship" \
    "современные замены ls/cat/find + промпт" \
    "CLI tools + starship" \
    "modern ls/cat/find replacements plus a prompt"

usfc_item_full cli "Современные замены классических утилит: eza вместо ls с иконками, bat вместо
cat с подсветкой, fd вместо find, ripgrep для поиска по содержимому, zoxide —
«умный» cd, ncdu для разбора места на диске. Плюс промпт starship.

Всё вместе, потому что это один и тот же слой «как выглядит и ощущается
терминал». Алиасы в .bashrc и eval-строки для zoxide/starship пишутся сразу
этим же пунктом. Список алиасов — на экране H."


usfc_item_rollback cli "sudo apt purge eza bat fd-find ripgrep zoxide ncdu
     sudo rm -f \"\$(command -v starship)\"   # если ставился этим же пунктом"

status_cli() {
    local c missing=""
    # $CLI_PKGS объявляется ниже по файлу, но присваивание верхнего уровня
    # отрабатывает до первого вызова этой функции — читать безопасно
    for c in $CLI_PKGS; do
        pkg_installed "$c" || missing="${missing}${missing:+, }${c}"
    done
    command -v starship &>/dev/null || missing="${missing}${missing:+, }starship"
    if [ -n "$missing" ]; then
        echo -e "${DIM}○ не хватает: ${missing}${NC}"; return 1
    fi
    if ! grep -qF "# >>> vps-setup:cli >>>" "${TARGET_HOME}/.bashrc" 2>/dev/null; then
        echo -e "${YELLOW}! всё стоит, алиасов в .bashrc нет${NC}"; return 1
    fi
    echo -e "${GREEN}✓ установлено${NC}"; return 0
}

apply_cli() {
    local need_install=false p
    for p in $CLI_PKGS; do
        pkg_installed "$p" || need_install=true
    done
    command -v starship &>/dev/null || need_install=true

    if [ "$need_install" = true ]; then
        if ask_yn "Установить ${CLI_PKGS// /, }, starship?"; then
            ensure_apt_updated
            # shellcheck disable=SC2086
            snapshot_pkgs $CLI_PKGS
            # shellcheck disable=SC2086
            run_logged "CLI-утилиты (${CLI_PKGS// /, })" apt_get install -y $CLI_PKGS
            refresh_pkg_cache
            if ! command -v starship &>/dev/null; then
                run_logged "starship" bash -c 'curl -sS https://starship.rs/install.sh | sh -s -- -y'
            fi
            # shellcheck disable=SC2086
            show_pkg_report $CLI_PKGS
        fi
    else
        log_success "eza/bat/fd/ripgrep/zoxide/ncdu/starship уже установлены"
    fi

    # Алиасы и промпт пишем сразу следом — не отдельным пунктом меню, но
    # КАЖДЫЙ только если его утилита реально стоит. Прежняя проверка была
    # «нет ни eza, ни batcat» и пропускала смешанный случай: на Debian 12
    # batcat есть, а eza в репозиториях нет вовсе — и alias ls='eza …'
    # ломал ls в следующей же сессии. То же случалось бы на Ubuntu, если бы
    # один пакет поставился, а другой нет.
    if ! command -v eza &>/dev/null && ! command -v batcat &>/dev/null \
       && ! command -v fdfind &>/dev/null; then
        log_warn "CLI-утилиты не установлены — алиасы в .bashrc не пишу"
        return
    fi
    local BASHRC="${TARGET_HOME}/.bashrc"
    if grep -qF "# >>> vps-setup:cli >>>" "$BASHRC" 2>/dev/null; then
        log_info "Алиасы CLI-утилит в .bashrc уже есть"
        return
    fi
    {
        echo ""
        echo "# >>> vps-setup:cli >>>"
        if command -v eza &>/dev/null; then
            echo "alias ls='eza --icons --group-directories-first -1 --long --no-permissions --no-user --no-time'"
            echo "alias ll='eza -lah --icons --group-directories-first'"
            echo "alias la='eza -a --icons --group-directories-first -1 --long --no-permissions --no-user --no-time'"
            echo "alias lt='eza --tree --icons --level=2 --group-directories-first'"
        fi
        if command -v batcat &>/dev/null; then
            echo "alias cat='batcat --paging=never'"
            echo "alias catp='batcat'"
            echo "alias scat='sudo batcat --paging=never'"
        fi
        command -v fdfind &>/dev/null && echo "alias fd='fdfind'"
        # эти две строки проверяют наличие сами, уже в момент запуска оболочки
        echo 'command -v zoxide &>/dev/null && eval "$(zoxide init bash)"'
        echo 'command -v starship &>/dev/null && eval "$(starship init bash)"'
        echo "# <<< vps-setup:cli <<<"
    } | append_file "$BASHRC"
    chown "${TARGET_USER}:${TARGET_USER}" "$BASHRC"
    log_success "Алиасы добавлены в .bashrc"
}
