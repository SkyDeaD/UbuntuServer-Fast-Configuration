# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# Пакеты CLI-набора вынесены в переменную: их перечисляли в трёх местах
# (status_cli, apply_cli, установка), и списки уже начинали расходиться
CLI_PKGS="eza bat fd-find ripgrep zoxide ncdu"
# ── Пункт меню: CLI-утилиты + starship ─────────────────────────────────────────
usfc_item cli база "CLI-утилиты + starship" \
    "современные замены ls/cat/find + промпт"

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

    # алиасы и промпт пишем сразу следом — не отдельным пунктом меню, но только если
    # утилиты реально стоят: если пользователь отказался ставить или apt не смог,
    # алиасы на несуществующие eza/batcat сломают ls/cat в следующей сессии
    if ! command -v eza &>/dev/null && ! command -v batcat &>/dev/null; then
        log_warn "eza/batcat не установлены — алиасы в .bashrc не пишу"
        return
    fi
    local BASHRC="${TARGET_HOME}/.bashrc"
    if grep -qF "# >>> vps-setup:cli >>>" "$BASHRC" 2>/dev/null; then
        log_info "Алиасы CLI-утилит в .bashrc уже есть"
    else
        cat >> "$BASHRC" <<EOF

# >>> vps-setup:cli >>>
alias ls='eza --icons --group-directories-first -1 --long --no-permissions --no-user --no-time'
alias ll='eza -lah --icons --group-directories-first'
alias la='eza -a --icons --group-directories-first -1 --long --no-permissions --no-user --no-time'
alias lt='eza --tree --icons --level=2 --group-directories-first'
alias cat='batcat --paging=never'
alias catp='batcat'
alias scat='sudo batcat --paging=never'
alias fd='fdfind'
command -v zoxide &>/dev/null && eval "\$(zoxide init bash)"
command -v starship &>/dev/null && eval "\$(starship init bash)"
# <<< vps-setup:cli <<<
EOF
        chown "${TARGET_USER}:${TARGET_USER}" "$BASHRC"
        log_success "Алиасы добавлены в .bashrc"
    fi
}
