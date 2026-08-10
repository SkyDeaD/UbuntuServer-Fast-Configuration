# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: tmux ─────────────────────────────────────────
usfc_item tmux база "tmux" \
    "мультиплексор: сессия переживает обрыв связи"

usfc_item_full tmux "Мультиплексор терминала: держит сессию живой при обрыве связи. Переподключаешься
по SSH — и всё, что запускал, на месте, включая несколько окон и панелей.
Незаменим, когда запускаешь что-то долгое на сервере через нестабильный канал.

Ставится с минимальным конфигом: мышь, история на 10000 строк, статус-бар."


usfc_item_rollback tmux "sudo apt purge tmux
     rm -f ~/.tmux.conf"

status_tmux() {
    if command -v tmux &>/dev/null; then
        if [ -f "${TARGET_HOME}/.tmux.conf" ]; then
            echo -e "${GREEN}✓ установлен + конфиг${NC}"; return 0
        else
            echo -e "${YELLOW}! установлен, конфига нет${NC}"; return 1
        fi
    else
        echo -e "${DIM}○ не установлен${NC}"; return 1
    fi
}

apply_tmux() {
    if ! command -v tmux &>/dev/null; then
        if ask_yn "Установить tmux?"; then
            ensure_apt_updated
            run_logged "tmux" apt_get install -y tmux || return 1
            refresh_pkg_cache
        else
            return
        fi
    fi
    local TMUX_CONF="${TARGET_HOME}/.tmux.conf"
    if [ -f "$TMUX_CONF" ]; then
        log_info ".tmux.conf уже существует — не трогаю"
    elif ask_yn "Положить базовый .tmux.conf (мышь, история 10000, статус-бар)?"; then
        write_file "$TMUX_CONF" <<'EOF'
set -g mouse on
set -g history-limit 10000
set -g status-bg colour234
set -g status-fg colour250
set -g status-left '#[fg=colour39,bold]#S '
set -g status-right '%H:%M %d-%b-%y'
setw -g automatic-rename on
EOF
        chown "${TARGET_USER}:${TARGET_USER}" "$TMUX_CONF"
        log_success ".tmux.conf установлен"
    fi
}
