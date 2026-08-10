# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: tmux ─────────────────────────────────────────
usfc_item tmux база "tmux" \
    "мультиплексор: сессия переживает обрыв связи" \
    "tmux" \
    "multiplexer: sessions survive a dropped link"

usfc_item_full tmux "Мультиплексор терминала: держит сессию живой при обрыве связи. Переподключаешься
по SSH — и всё, что запускал, на месте, включая несколько окон и панелей.
Незаменим, когда запускаешь что-то долгое на сервере через нестабильный канал.

Ставится с минимальным конфигом: мышь, история на 10000 строк, статус-бар." \
"A terminal multiplexer: it keeps your session alive when the link drops.
You reconnect over SSH and everything you started is still there, including
multiple windows and panes. Indispensable when you run something long over
an unreliable connection.

Installed with a minimal config: mouse support, 10000 lines of history,
a status bar."


usfc_item_rollback tmux "sudo apt purge tmux
     rm -f ~/.tmux.conf" \
"sudo apt purge tmux
     rm -f ~/.tmux.conf"

status_tmux() {
    if command -v tmux &>/dev/null; then
        if [ -f "${TARGET_HOME}/.tmux.conf" ]; then
            st "$GREEN" "✓ установлен + конфиг" "✓ installed + config"; return 0
        else
            st "$YELLOW" "! установлен, конфига нет" "! installed, no config"; return 1
        fi
    else
        st "$DIM" "○ не установлен" "○ not installed"; return 1
    fi
}

apply_tmux() {
    if ! command -v tmux &>/dev/null; then
        if ask_yn_t "Установить tmux?" "Install tmux?"; then
            ensure_apt_updated
            run_logged "tmux" apt_get install -y tmux || return 1
            refresh_pkg_cache
        else
            return
        fi
    fi
    local TMUX_CONF="${TARGET_HOME}/.tmux.conf"
    if [ -f "$TMUX_CONF" ]; then
        log_info_t ".tmux.conf уже существует — не трогаю" \
".tmux.conf already exists — leaving it alone"
    elif ask_yn_t "Положить базовый .tmux.conf (мышь, история 10000, статус-бар)?" "Write a basic .tmux.conf (mouse, 10000-line history, status bar)?"; then
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
        log_success_t ".tmux.conf установлен" \
".tmux.conf installed"
    fi
}
