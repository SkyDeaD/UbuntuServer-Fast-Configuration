#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  vps-setup — команда: usfc
#  Menu-driven: CLI tools + Docker + zram/swap + fastfetch + starship
#  + hardening (fail2ban, unattended-upgrades, docker log rotation,
#    tmux, SSH key-only hardening (self-testing), UFW)
#  + self-update on every run
#  https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration
# ═══════════════════════════════════════════════════════════════
set -uo pipefail
# ПРИМЕЧАНИЕ: сознательно без -e — это интерактивное меню, которое
# живёт много действий подряд; одна упавшая подкоманда не должна
# убивать всю сессию, только то конкретное действие.

REPO_RAW_BASE="https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/src"

# ── Цвета ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log_info()    { echo -e "  ${CYAN}[i]${NC} ${1:-}"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} ${1:-}"; }
log_warn()    { echo -e "  ${YELLOW}[!]${NC} ${1:-}" >&2; }
log_error()   { echo -e "  ${RED}[✗]${NC} ${1:-}" >&2; }

# на Ubuntu 24.04+ needrestart может всплыть интерактивным диалогом посреди
# apt-get install и подвесить безголовый скрипт — глушим заранее
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

BULK_MODE=false
ZRAM_BULK_PERCENT=""
SWAP_BULK_MB=""

ask_yn() {
    local question="${1:-}" default="${2:-Y}" reply prompt
    if [ "$BULK_MODE" = true ]; then
        [ "$default" = "Y" ] && return 0 || return 1
    fi
    if [ "$default" = "Y" ]; then prompt="[Y/n]"; else prompt="[y/N]"; fi
    echo -en "  ${BOLD}${question}${NC} ${DIM}${prompt}:${NC} "
    read -r reply </dev/tty
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

# ask_value question default — как ask_yn, но для чисел; печатает результат
# в stdout (нужно вызывать через командную подстановку), весь интерактив — в stderr
ask_value() {
    local question="${1:-}" default="${2:-}" reply
    if [ "$BULK_MODE" = true ]; then
        echo "$default"
        return
    fi
    echo -en "  ${BOLD}${question}${NC} ${DIM}[${default}]:${NC} " >&2
    read -r reply </dev/tty
    reply="${reply:-$default}"
    if ! [[ "$reply" =~ ^[0-9]+$ ]]; then
        log_warn "Не похоже на число — использую значение по умолчанию (${default})"
        reply="$default"
    fi
    echo "$reply"
}

show_header() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo ""
    echo -e "  ${CYAN}██╗   ██╗███████╗███████╗ ██████╗${NC}"
    echo -e "  ${CYAN}██║   ██║██╔════╝██╔════╝██╔════╝${NC}"
    echo -e "  ${CYAN}██║   ██║███████╗█████╗  ██║     ${NC}"
    echo -e "  ${CYAN}██║   ██║╚════██║██╔══╝  ██║     ${NC}"
    echo -e "  ${CYAN}╚██████╔╝███████║██║     ╚██████╗${NC}"
    echo -e "  ${CYAN} ╚═════╝ ╚══════╝╚═╝      ╚═════╝${NC}"
    echo -e "  ${BOLD}USFC${NC} ${DIM}v${VERSION} by SkyDeaD${NC}   ${DIM}UbuntuServer Fast Configuration${NC}"
    hr "$CYAN"
}

pause() {
    echo ""
    echo -en "  ${DIM}Enter — продолжить...${NC}"
    read -r _ </dev/tty
}

# ── root / целевой пользователь ────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "Нужны права root: curl -fsSL .../install.sh | sudo bash && source ~/.bashrc" >&2
    exit 1
fi

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
else
    TARGET_USER="$(logname 2>/dev/null || echo root)"
fi
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    echo "Не удалось определить домашнюю директорию пользователя $TARGET_USER" >&2
    exit 1
fi

SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
[ -z "$SSH_PORT" ] && SSH_PORT=22

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

VERSION="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]')"
[ -z "$VERSION" ] && VERSION="0.0.0"

# ═══════════════════════════════════════════════════════════════
# Самообновление — сверяется при каждом запуске
# ═══════════════════════════════════════════════════════════════
check_for_update() {
    local remote_version
    remote_version="$(curl -fsSL --max-time 5 "${REPO_RAW_BASE}/VERSION" 2>/dev/null | tr -d '[:space:]')"

    if [ -z "$remote_version" ]; then
        log_warn "Не удалось проверить обновления (нет сети или файла VERSION в репо)"
        return 0
    fi

    if [ "$remote_version" = "$VERSION" ]; then
        return 1
    fi

    # sort -V — версии сравниваются по-настоящему (4.2.0 > 4.1.1), а не строковым "!="
    local newest
    newest="$(printf '%s\n%s\n' "$VERSION" "$remote_version" | sort -V | tail -n1)"
    if [ "$newest" = "$VERSION" ]; then
        # локальная версия уже новее (или равна) той, что в репозитории — предлагать
        # "обновиться" на более старую значило бы откатывать себя назад молча
        return 1
    fi

    log_info "Доступна новая версия: ${BOLD}${remote_version}${NC} ${DIM}(у вас ${VERSION})${NC}"
    if ask_yn "Обновить usfc до ${remote_version} сейчас?"; then
        local tmp
        tmp="$(mktemp)"
        if curl -fsSL "${REPO_RAW_BASE}/setup.sh" -o "$tmp"; then
            if bash -n "$tmp" 2>/dev/null; then
                cp "$tmp" "$SCRIPT_PATH"
                chmod +x "$SCRIPT_PATH"
                rm -f "$tmp"
                log_success "Обновлено до ${remote_version}, перезапускаю..."
                exec "$SCRIPT_PATH"
            else
                log_error "Новая версия не прошла проверку синтаксиса (bash -n) — не обновляю, остаюсь на ${VERSION}"
                rm -f "$tmp"
            fi
        else
            log_error "Не удалось скачать новую версию — остаюсь на ${VERSION}"
            rm -f "$tmp"
        fi
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════
# STATUS-функции — только читают состояние, ничего не меняют
# ═══════════════════════════════════════════════════════════════
status_cli() {
    local c missing=""
    for c in eza bat fd-find ripgrep zoxide ncdu; do
        dpkg -s "$c" &>/dev/null || missing="${missing}${missing:+, }${c}"
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

# dnsutils в Ubuntu 26.04 — виртуальный пакет (алиас), apt install его резолвит,
# но dpkg -s dnsutils ничего не находит; реальное имя пакета — bind9-dnsutils
BASE_PKGS="micro curl wget git nano certbot python3-certbot-nginx unzip htop bind9-dnsutils jq software-properties-common ca-certificates gnupg rsync"

status_basepkgs() {
    local p missing=""
    for p in $BASE_PKGS; do
        dpkg -s "$p" &>/dev/null || missing="${missing}${missing:+, }${p}"
    done
    if [ -n "$missing" ]; then
        echo -e "${DIM}○ не хватает: ${missing}${NC}"; return 1
    fi
    echo -e "${GREEN}✓ установлено${NC}"; return 0
}

status_nginx() {
    if dpkg -s nginx-full &>/dev/null; then
        if systemctl is-active nginx &>/dev/null; then
            echo -e "${GREEN}✓ установлен и запущен${NC}"; return 0
        else
            echo -e "${YELLOW}! установлен, не запущен${NC}"; return 1
        fi
    else
        echo -e "${DIM}○ не установлен${NC}"; return 1
    fi
}

status_docker() {
    if command -v docker &>/dev/null; then
        echo -e "${GREEN}✓ установлен ($(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1))${NC}"; return 0
    else
        echo -e "${DIM}○ не установлен${NC}"; return 1
    fi
}

status_fastfetch() {
    if ! command -v fastfetch &>/dev/null; then
        echo -e "${DIM}○ не установлен${NC}"; return 1
    fi
    local v lowest
    v="$(fastfetch --version | grep -oP '\d+\.\d+\.\d+' | head -n1)"
    lowest="$(printf '%s\n%s\n' "$v" "2.64.0" | sort -V | head -n1)"
    if [ "$lowest" != "2.64.0" ]; then
        echo -e "${YELLOW}! ${v} (нужна >= 2.64.0)${NC}"; return 1
    fi
    if [ ! -f "${TARGET_HOME}/.config/fastfetch/config.jsonc" ]; then
        echo -e "${YELLOW}! ${v}, конфига нет${NC}"; return 1
    fi
    echo -e "${GREEN}✓ ${v}${NC}"; return 0
}

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

status_dockerlog() {
    if ! command -v docker &>/dev/null; then
        echo -e "${DIM}— (нужен Docker)${NC}"; return 1
    fi
    if [ -f /etc/docker/daemon.json ] && python3 -c "
import json,sys
try:
    d=json.load(open('/etc/docker/daemon.json'))
    sys.exit(0 if d.get('log-opts',{}).get('max-size')=='10m' else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
        echo -e "${GREEN}✓ настроено (max-size=10m)${NC}"; return 0
    else
        echo -e "${DIM}○ не настроено${NC}"; return 1
    fi
}

status_fail2ban() {
    systemctl is-active fail2ban &>/dev/null \
        && { echo -e "${GREEN}✓ запущен${NC}"; return 0; } \
        || { echo -e "${DIM}○ не запущен${NC}"; return 1; }
}

status_unattended() {
    if [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
        echo -e "${GREEN}✓ включено${NC}"; return 0
    else
        echo -e "${DIM}○ выключено${NC}"; return 1
    fi
}

status_zram() {
    local zram_ok=false swap_ok=false
    local n t s u p
    while read -r n t s u p; do
        case "$n" in
            /dev/zram*) [ "$p" = "100" ] && zram_ok=true ;;
            *)          [ "$p" = "10" ] && swap_ok=true ;;
        esac
    done < <(swapon --show --noheadings --raw 2>/dev/null)
    if [ "$zram_ok" = true ] && [ "$swap_ok" = true ]; then
        echo -e "${GREEN}✓ настроено${NC}"; return 0
    elif [ "$zram_ok" = true ] || [ "$swap_ok" = true ]; then
        echo -e "${YELLOW}! настроено частично${NC}"; return 1
    else
        echo -e "${DIM}○ не настроено${NC}"; return 1
    fi
}

status_sshhardening() {
    if [ -f /etc/ssh/sshd_config.d/10-hardening.conf ]; then
        local pa
        pa="$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2; exit}')"
        if [ "$pa" = "no" ]; then
            echo -e "${GREEN}✓ применено (пароль выключен)${NC}"; return 0
        else
            echo -e "${YELLOW}! конфиг есть, но passwordauthentication=${pa}${NC}"; return 1
        fi
    else
        echo -e "${DIM}○ не применено${NC}"; return 1
    fi
}

status_ufw() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "${GREEN}✓ включён${NC}"; return 0
    else
        echo -e "${DIM}○ выключен${NC}"; return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# APPLY-функции
# ═══════════════════════════════════════════════════════════════
apply_cli() {
    local need_install=false p
    for p in eza bat fd-find ripgrep zoxide ncdu; do
        dpkg -s "$p" &>/dev/null || need_install=true
    done
    command -v starship &>/dev/null || need_install=true

    if [ "$need_install" = true ]; then
        if ask_yn "Установить eza, bat, fd-find, ripgrep, zoxide, ncdu, starship?"; then
            apt-get install -y eza bat fd-find ripgrep zoxide ncdu \
                && log_success "CLI-утилиты установлены" || log_error "Установка не удалась"
            if ! command -v starship &>/dev/null; then
                curl -sS https://starship.rs/install.sh | sh -s -- -y \
                    && log_success "starship установлен" || log_error "Установка starship не удалась"
            fi
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
alias ls='eza --icons --group-directories-first'
alias ll='eza -lah --icons --group-directories-first'
alias la='eza -a --icons --group-directories-first'
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

apply_basepkgs() {
    if ask_yn "Установить базовый набор пакетов (${BASE_PKGS})?"; then
        # shellcheck disable=SC2086
        apt-get install -y $BASE_PKGS \
            && log_success "Базовый набор установлен" || log_error "Установка не удалась"
    fi
}

apply_nginx() {
    if dpkg -s nginx-full &>/dev/null; then
        log_info "nginx уже установлен"
    else
        if ! ask_yn "Установить nginx-full?"; then return; fi
        apt-get install -y nginx-full || { log_error "Установка не удалась"; return 1; }
        log_success "nginx-full установлен"
    fi
    if ! systemctl is-active nginx &>/dev/null; then
        if ask_yn "Запустить nginx и включить автозапуск?"; then
            systemctl enable --now nginx >/dev/null \
                && log_success "nginx запущен и включён в автозапуск" || log_error "Не удалось запустить nginx"
        fi
    else
        log_success "nginx уже запущен"
    fi
}

apply_docker() {
    if ! ask_yn "Установить Docker + Docker Compose (официальный репозиторий)?"; then return; fi
    apt-get install -y ca-certificates curl || { log_error "Не удалось поставить зависимости"; return 1; }
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || { log_error "Не удалось скачать GPG-ключ Docker"; return 1; }
    chmod a+r /etc/apt/keyrings/docker.asc
    local codename
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    if ! apt-cache policy docker-ce-cli 2>/dev/null | grep -q 'Candidate:.*[0-9]'; then
        log_warn "У Docker пока нет пакетов под '${codename}' — переключаюсь на noble (24.04, совместимо)"
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
    fi
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
        || { log_error "Установка Docker не удалась"; return 1; }
    systemctl enable --now docker >/dev/null
    usermod -aG docker "$TARGET_USER"
    log_success "Docker установлен: $(docker --version)"
    log_info "Пользователь ${TARGET_USER} добавлен в группу docker — перелогинься для применения без sudo"
}

apply_fastfetch() {
    local need_ppa=true
    if command -v fastfetch &>/dev/null; then
        local v lowest
        v="$(fastfetch --version | grep -oP '\d+\.\d+\.\d+' | head -n1)"
        lowest="$(printf '%s\n%s\n' "$v" "2.64.0" | sort -V | head -n1)"
        [ "$lowest" = "2.64.0" ] && need_ppa=false
    fi
    if [ "$need_ppa" = true ]; then
        if ask_yn "Установить/обновить fastfetch (через PPA)?"; then
            add-apt-repository -y ppa:zhangsongcui3371/fastfetch
            apt-get update -qq
            apt-get install -y fastfetch && log_success "fastfetch: $(fastfetch --version)" || log_error "Установка не удалась"
        fi
    else
        log_success "fastfetch уже подходящей версии"
    fi

    # конфиг и автозапуск в .bashrc пишем сразу следом — не отдельным пунктом меню
    if ! command -v fastfetch &>/dev/null; then return; fi

    sudo -u "$TARGET_USER" mkdir -p "${TARGET_HOME}/.config/fastfetch"
    if [ -f "${TARGET_HOME}/.config/fastfetch/config.jsonc" ]; then
        log_info "config.jsonc уже есть"
    elif curl -fsSL "${REPO_RAW_BASE}/config.jsonc" -o "${TARGET_HOME}/.config/fastfetch/config.jsonc" 2>/dev/null; then
        chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.config/fastfetch/config.jsonc"
        log_success "config.jsonc установлен"
    else
        log_warn "Не удалось скачать config.jsonc из ${REPO_RAW_BASE}"
    fi

    local BASHRC="${TARGET_HOME}/.bashrc" need_fastfetch_block=false
    if grep -qF "# >>> vps-setup:fastfetch >>>" "$BASHRC" 2>/dev/null; then
        # старый блок (без гейта USFC_RESOURCE) печатал бы fastfetch второй раз
        # при каждом auto-source из usfc-обёртки (см. main()) — апгрейдим его
        if grep -qF "USFC_RESOURCE:-" "$BASHRC" 2>/dev/null; then
            log_info "Автозапуск fastfetch в .bashrc уже есть"
        else
            sed -i '/# >>> vps-setup:fastfetch >>>/,/# <<< vps-setup:fastfetch <<</d' "$BASHRC"
            need_fastfetch_block=true
        fi
    else
        need_fastfetch_block=true
    fi
    if [ "$need_fastfetch_block" = true ]; then
        cat >> "$BASHRC" <<'EOF'

# >>> vps-setup:fastfetch >>>
if [ -z "${USFC_RESOURCE:-}" ] && [ -x "$(command -v fastfetch)" ]; then
    fastfetch
fi
# <<< vps-setup:fastfetch <<<
EOF
        chown "${TARGET_USER}:${TARGET_USER}" "$BASHRC"
        log_success "Автозапуск добавлен в .bashrc"
    fi
}

apply_tmux() {
    if ! command -v tmux &>/dev/null; then
        if ask_yn "Установить tmux?"; then
            apt-get install -y tmux && log_success "tmux установлен" || { log_error "Установка не удалась"; return 1; }
        else
            return
        fi
    fi
    local TMUX_CONF="${TARGET_HOME}/.tmux.conf"
    if [ -f "$TMUX_CONF" ]; then
        log_info ".tmux.conf уже существует — не трогаю"
    elif ask_yn "Положить базовый .tmux.conf (мышь, история 10000, статус-бар)?"; then
        cat > "$TMUX_CONF" <<'EOF'
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

apply_dockerlog() {
    if ! command -v docker &>/dev/null; then
        log_info "Docker не установлен — сначала установи Docker (пункт 5)"
        return
    fi
    [ -f /etc/docker/daemon.json ] && log_warn "daemon.json уже существует, будет дополнен (не перезаписан целиком)"
    if ! ask_yn "Ограничить логи контейнеров (max-size=10m, max-file=3)?"; then return; fi
    mkdir -p /etc/docker
    python3 - /etc/docker/daemon.json <<'PYEOF'
import json, sys, os
path = sys.argv[1]
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
data["log-driver"] = "json-file"
data.setdefault("log-opts", {})
data["log-opts"]["max-size"] = "10m"
data["log-opts"]["max-file"] = "3"
json.dump(data, open(path, "w"), indent=2)
PYEOF
    log_success "daemon.json обновлён"
    if ask_yn "Перезапустить Docker сейчас? ВСЕ контейнеры перезапустятся вместе с демоном" N; then
        systemctl restart docker && log_success "Docker перезапущен"
    else
        log_info "Применится при следующем перезапуске Docker/сервера"
    fi
}

apply_fail2ban() {
    if ! ask_yn "Установить fail2ban?"; then return; fi
    apt-get install -y fail2ban || { log_error "Установка не удалась"; return 1; }
    cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    systemctl enable --now fail2ban >/dev/null
    log_success "fail2ban установлен и настроен на порт ${SSH_PORT}"
}

apply_unattended() {
    if ! ask_yn "Включить автообновление security-патчей?"; then return; fi
    apt-get install -y unattended-upgrades || { log_error "Установка не удалась"; return 1; }
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    systemctl enable --now unattended-upgrades >/dev/null
    log_success "unattended-upgrades включён"
}

# suggest_swap_mb — предлагает размер резервного swap-файла: 10% свободного
# места на /, зажатое в 512-4096 МБ. На тесном диске (мало свободного места)
# не раздувает своп; на просторном — не ограничивается устаревшим 1GB
suggest_swap_mb() {
    local free_mb suggested
    free_mb="$(df -m / 2>/dev/null | awk 'NR==2{print $4}')"
    [[ "$free_mb" =~ ^[0-9]+$ ]] || free_mb=0
    suggested=$(( free_mb * 10 / 100 ))
    [ "$suggested" -lt 512 ] && suggested=512
    [ "$suggested" -gt 4096 ] && suggested=4096
    echo "$suggested"
}

# читает текущее состояние zram/swap в глобальные переменные — общий
# парсинг для apply_zram() и предзапроса значений перед bulk-режимом в main()
read_swap_state() {
    ZRAM_ACTIVE=false; ZRAM_PRIO=""; SWAP_ACTIVE=false; SWAP_PRIO=""; SWAP_PATH=""
    local n t s u p
    while read -r n t s u p; do
        case "$n" in
            /dev/zram*) ZRAM_ACTIVE=true; ZRAM_PRIO="$p" ;;
            *)          SWAP_ACTIVE=true; SWAP_PRIO="$p"; SWAP_PATH="$n" ;;
        esac
    done < <(swapon --show --noheadings --raw 2>/dev/null)
}

apply_zram() {
    read_swap_state
    local zram_active="$ZRAM_ACTIVE" zram_prio="$ZRAM_PRIO" \
          swap_active="$SWAP_ACTIVE" swap_prio="$SWAP_PRIO" swap_path="$SWAP_PATH"

    if [ "$zram_active" = true ]; then
        if [ "$zram_prio" = "100" ]; then
            log_success "zram уже настроен (приоритет 100) — пропускаю"
        else
            log_warn "zram активен, но приоритет ${zram_prio} (рекомендуется 100), похоже настраивали вручную"
            if ask_yn "Перенастроить под рекомендованные значения?" N; then
                local cur_percent zram_percent
                cur_percent="$(grep -oP '^PERCENT=\K[0-9]+' /etc/default/zramswap 2>/dev/null)"
                [ -z "$cur_percent" ] && cur_percent=75
                zram_percent="$(ask_value "Размер zram в % от RAM?" "$cur_percent")"
                if apt-get install -y zram-tools; then
                    systemctl stop zramswap 2>/dev/null
                    swapoff /dev/zram0 2>/dev/null || true
                    printf 'ALGO=lz4\nPERCENT=%s\nPRIORITY=100\n' "$zram_percent" > /etc/default/zramswap
                    if ! systemctl start zramswap; then
                        sleep 2
                        systemctl start zramswap
                    fi
                    if swapon --show --noheadings --raw 2>/dev/null | awk '{print $1}' | grep -q '^/dev/zram'; then
                        log_success "zram перенастроен (${zram_percent}% RAM)"
                    else
                        log_error "Не удалось поднять zram — попробуйте вручную: systemctl restart zramswap"
                    fi
                else
                    log_error "Установка zram-tools не удалась"
                fi
            fi
        fi
    elif ask_yn "Установить и настроить zram (lz4, приоритет 100)?"; then
        local zram_percent
        zram_percent="$(ask_value "Размер zram в % от RAM?" "${ZRAM_BULK_PERCENT:-75}")"
        if apt-get install -y zram-tools; then
            systemctl stop zramswap 2>/dev/null
            swapoff /dev/zram0 2>/dev/null || true
            printf 'ALGO=lz4\nPERCENT=%s\nPRIORITY=100\n' "$zram_percent" > /etc/default/zramswap
            if ! systemctl start zramswap; then
                sleep 2
                systemctl start zramswap
            fi
            if swapon --show --noheadings --raw 2>/dev/null | awk '{print $1}' | grep -q '^/dev/zram'; then
                log_success "zram-tools установлен и настроен (${zram_percent}% RAM)"
            else
                log_error "Не удалось поднять zram — попробуйте вручную: systemctl restart zramswap"
            fi
        else
            log_error "Установка zram-tools не удалась"
        fi
    fi

    if [ "$swap_active" = true ]; then
        if [ "$swap_prio" = "10" ]; then
            log_success "Резервный своп на диске (${swap_path}) уже настроен (приоритет 10) — пропускаю"
        else
            log_warn "Своп на диске (${swap_path}) активен, но приоритет ${swap_prio} (рекомендуется 10)"
            if ask_yn "Исправить приоритет ${swap_path} в /etc/fstab на 10?"; then
                local esc_path
                esc_path="$(printf '%s' "$swap_path" | sed 's/[.[\*^$/]/\\&/g')"
                sed -i -E "s#^(${esc_path}\s+none\s+swap\s+)sw([^,].*)?\$#\1sw,pri=10\2#" /etc/fstab
                swapoff "$swap_path" 2>/dev/null || true
                swapon -a
                # sed молча не найдёт строку, если своп в fstab указан через
                # UUID=/LABEL=, а не путём (типично для разделов) — тогда без
                # этой проверки log_success был бы враньём
                if swapon --show --noheadings --raw 2>/dev/null | awk -v p="$swap_path" '$1==p {print $5}' | grep -q '^10$'; then
                    log_success "Приоритет исправлен"
                else
                    log_error "Не удалось исправить приоритет ${swap_path} — возможно, в /etc/fstab он указан через UUID=/LABEL=, а не путём. Поправьте вручную: pri=10 в опциях монтирования"
                fi
            fi
        fi
    else
        local suggested_mb
        suggested_mb="$(suggest_swap_mb)"
        if ask_yn "Создать резервный swap-файл (по умолчанию ${suggested_mb} МБ, приоритет 10)?"; then
            local swap_mb
            swap_mb="$(ask_value "Размер swap-файла, МБ?" "${SWAP_BULK_MB:-$suggested_mb}")"
            fallocate -l "${swap_mb}M" /swapfile
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null
            if grep -qE '^/swapfile\s' /etc/fstab 2>/dev/null; then
                sed -i -E 's#^(/swapfile\s+none\s+swap\s+)sw([^,].*)?$#\1sw,pri=10\2#' /etc/fstab
            else
                echo "/swapfile none swap sw,pri=10 0 0" >> /etc/fstab
            fi
            swapon -a
            log_success "swapfile создан (${swap_mb} МБ, приоритет 10)"
        fi
    fi

    local cur_sw cur_vfs
    cur_sw="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo '?')"
    cur_vfs="$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo '?')"
    if [ "$cur_sw" = "80" ] && [ "$cur_vfs" = "50" ]; then
        log_success "sysctl уже настроен как рекомендуется"
    else
        log_info "Сейчас: swappiness=${cur_sw}, vfs_cache_pressure=${cur_vfs} ${DIM}(рекомендуется 80/50)${NC}"
        local sysctl_default=Y
        [ "$cur_sw" != "60" ] || [ "$cur_vfs" != "100" ] && sysctl_default=N
        if ask_yn "Применить рекомендованные значения sysctl?" "$sysctl_default"; then
            printf 'vm.swappiness=80\nvm.vfs_cache_pressure=50\n' > /etc/sysctl.d/99-zram.conf
            sysctl --system >/dev/null
            log_success "sysctl применён"
        fi
    fi

    if systemctl is-enabled earlyoom &>/dev/null 2>&1; then
        log_success "earlyoom уже включён"
    elif ask_yn "Установить earlyoom (защита от полного падения при нехватке памяти)?"; then
        if apt-get install -y earlyoom; then
            systemctl enable --now earlyoom >/dev/null
            log_success "earlyoom установлен"
        else
            log_error "Установка earlyoom не удалась"
        fi
    fi

    echo ""
    log_info "Текущее состояние свопа:"
    swapon --show 2>/dev/null | sed 's/^/      /'
}

apply_sshhardening() {
    if [ "$TARGET_USER" = "root" ]; then
        log_warn "Скрипт запущен напрямую под root — hardening требует отдельного пользователя"
        log_warn "Создай его (adduser <имя> && usermod -aG sudo <имя>) и перезайди под ним"
        return
    fi
    if [ "$BULK_MODE" = true ]; then
        log_warn "SSH hardening требует явного подтверждения — пропущено в bulk-режиме. Настройте отдельно пунктом 11."
        return
    fi
    if ! ask_yn "Настроить SSH hardening для ${TARGET_USER} (ключи вместо пароля, запрет root-логина)?" N; then return; fi

    local SSH_DIR="${TARGET_HOME}/.ssh"
    local AUTH_KEYS="${SSH_DIR}/authorized_keys"
    sudo -u "$TARGET_USER" mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    sudo -u "$TARGET_USER" touch "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$SSH_DIR"

    if [ -s "$AUTH_KEYS" ]; then
        log_info "В authorized_keys уже есть $(grep -c '^ssh-\|^ecdsa-' "$AUTH_KEYS" 2>/dev/null || echo 0) ключ(ей)"
    else
        log_info "authorized_keys пока пуст"
    fi

    if ask_yn "Добавить новый публичный ключ (вставить содержимое .pub со своей машины)?"; then
        echo -en "  ${BOLD}Вставь публичный ключ одной строкой:${NC} "
        local pubkey_line
        read -r pubkey_line </dev/tty
        if [[ "$pubkey_line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-) ]]; then
            if grep -qF "$pubkey_line" "$AUTH_KEYS" 2>/dev/null; then
                log_info "Такой ключ уже есть"
            else
                echo "$pubkey_line" >> "$AUTH_KEYS"
                log_success "Ключ добавлен"
            fi
        else
            log_error "Не похоже на публичный SSH-ключ — не добавляю"
        fi
    fi

    if [ ! -s "$AUTH_KEYS" ]; then
        log_error "authorized_keys пуст — отключать пароль нельзя. Hardening прерван."
        return 1
    fi

    if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
        log_info "Найден 50-cloud-init.conf — наш 10-hardening.conf побеждает при слиянии (10 < 50)"
    fi

    local TEST_KEY="/tmp/vps-setup-selftest-$$"
    ssh-keygen -t ed25519 -N '' -f "$TEST_KEY" -C "vps-setup-selftest" -q
    local TEST_PUB
    TEST_PUB="$(cat "${TEST_KEY}.pub")"
    echo "$TEST_PUB" >> "$AUTH_KEYS"

    ssh_selftest() {
        ssh -i "$TEST_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "$SSH_PORT" \
            "${TARGET_USER}@127.0.0.1" 'echo VPS_SETUP_KEY_OK' 2>/dev/null | grep -q VPS_SETUP_KEY_OK
    }
    cleanup_test_key() {
        grep -vF "$TEST_PUB" "$AUTH_KEYS" > "${AUTH_KEYS}.tmp" 2>/dev/null && mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
        chown "${TARGET_USER}:${TARGET_USER}" "$AUTH_KEYS"
        chmod 600 "$AUTH_KEYS"
        rm -f "$TEST_KEY" "${TEST_KEY}.pub"
    }

    log_info "Проверяю базовый вход по ключу (до изменений конфига)..."
    if ! ssh_selftest; then
        log_error "Вход по ключу не проходит даже сейчас — hardening не запускаю"
        cleanup_test_key
        return 1
    fi
    log_success "Базовый вход по ключу подтверждён"
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
    cat > /etc/ssh/sshd_config.d/10-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers ${TARGET_USER}
EOF

    if ! sshd -t 2>/dev/null; then
        log_error "sshd -t не прошёл — откатываю"
        rm -f /etc/ssh/sshd_config.d/10-hardening.conf
        cleanup_test_key
        return 1
    fi

    systemctl restart ssh
    sleep 1
    log_info "Проверяю вход по ключу ПОСЛЕ применения hardening..."
    if ssh_selftest; then
        # вход по ключу подтверждает только то, что ключевая аутентификация жива —
        # отдельно сверяем через sshd -T, что PasswordAuthentication реально no
        # (например, без "Include .../sshd_config.d/*.conf" в базовом sshd_config
        # наш дроп-ин просто не подхватился бы, а ключевой вход при этом всё равно работал)
        local pa
        pa="$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2; exit}')"
        if [ "$pa" != "no" ]; then
            log_error "Вход по ключу работает, но sshd -T показывает passwordauthentication=${pa:-?} — конфиг не применился"
            log_error "Вероятная причина: в /etc/ssh/sshd_config нет 'Include /etc/ssh/sshd_config.d/*.conf'"
            log_warn "Дроп-ин не откатываю — он и так не действует, откат ничего не изменит"
            cleanup_test_key
            return 1
        fi
        log_success "SSH hardening применён: root-логин выключен, пароль выключен"
        log_info "Текущая сессия не разрывалась — рестарт sshd не убивает открытые соединения"
        cleanup_test_key
        if ask_yn "Настроить passwordless sudo для ${TARGET_USER}?"; then
            local SUDOERS_FILE="/etc/sudoers.d/${TARGET_USER}"
            echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > "${SUDOERS_FILE}.tmp"
            if visudo -c -f "${SUDOERS_FILE}.tmp" >/dev/null 2>&1; then
                mv "${SUDOERS_FILE}.tmp" "$SUDOERS_FILE"
                chmod 440 "$SUDOERS_FILE"
                log_success "Passwordless sudo настроен"
            else
                log_error "Синтаксическая ошибка в sudoers — не применяю"
                rm -f "${SUDOERS_FILE}.tmp"
            fi
        fi
    else
        log_error "После рестарта sshd вход по ключу НЕ проходит — АВАРИЙНЫЙ ОТКАТ"
        rm -f /etc/ssh/sshd_config.d/10-hardening.conf
        systemctl restart ssh
        cleanup_test_key
        log_error "Конфиг откачен. Текущая сессия жива — ничего не сломано."
        return 1
    fi
}

apply_ufw() {
    log_info "Обнаруженные слушающие TCP-порты:"
    local listening
    listening="$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\])' | grep -oE '[0-9]+$' | sort -un)"
    echo "$listening" | sed 's/^/      /'
    echo ""
    log_warn "Если на сервере уже крутится VPN/прокси — включение без разрешения ЕГО портов оборвёт его"
    if [ "$BULK_MODE" = true ]; then
        log_warn "UFW требует явного подтверждения — пропущено в bulk-режиме. Настройте отдельно пунктом 12."
        return
    fi
    if ! ask_yn "Включить UFW, разрешив SSH-порт (${SSH_PORT}) и все порты выше?" N; then return; fi
    apt-get install -y ufw || { log_error "Установка UFW не удалась"; return 1; }
    ufw allow "${SSH_PORT}"/tcp >/dev/null
    while read -r p; do
        [ -n "$p" ] && ufw allow "${p}"/tcp >/dev/null
    done <<< "$listening"
    ufw --force enable >/dev/null
    log_success "UFW включён"
    ufw status | sed 's/^/      /'
}

# ═══════════════════════════════════════════════════════════════
# DISABLE-функции — только для безопасно обратимых пунктов
# ═══════════════════════════════════════════════════════════════
disable_dockerlog() {
    if [ ! -f /etc/docker/daemon.json ]; then log_info "daemon.json нет — нечего отключать"; return; fi
    if ask_yn "Убрать лимиты логов из daemon.json?" N; then
        python3 - /etc/docker/daemon.json <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception:
    data = {}
data.pop("log-opts", None)
if data.get("log-driver") == "json-file":
    data.pop("log-driver", None)
json.dump(data, open(path, "w"), indent=2)
PYEOF
        log_success "Лимиты убраны из daemon.json"
        ask_yn "Перезапустить Docker сейчас?" N && { systemctl restart docker && log_success "Docker перезапущен"; }
    fi
}
disable_fail2ban() {
    ask_yn "Остановить и выключить fail2ban?" N && { systemctl disable --now fail2ban &>/dev/null; log_success "fail2ban выключен"; }
}
disable_unattended() {
    if ask_yn "Выключить unattended-upgrades?" N; then
        printf 'APT::Periodic::Update-Package-Lists "0";\nAPT::Periodic::Unattended-Upgrade "0";\n' > /etc/apt/apt.conf.d/20auto-upgrades
        systemctl disable unattended-upgrades &>/dev/null || true
        log_success "unattended-upgrades выключен"
    fi
}
disable_zram() {
    if ask_yn "Выключить zram-устройство (swapfile на диске НЕ трогается)?" N; then
        systemctl disable --now zramswap &>/dev/null || true
        log_success "zram выключен. swapfile (если есть) продолжает работать"
    fi
}
disable_ufw() {
    ask_yn "Выключить UFW?" N && { ufw disable &>/dev/null; log_success "UFW выключен"; }
}

# ═══════════════════════════════════════════════════════════════
# Меню
# ═══════════════════════════════════════════════════════════════
ITEM_IDS=(basepkgs cli fastfetch tmux docker nginx dockerlog fail2ban unattended zram sshhardening ufw)
ITEM_TITLES=(
    "Базовые пакеты"
    "CLI-утилиты + starship"
    "fastfetch"
    "tmux"
    "Docker + Compose"
    "nginx-full"
    "Docker log rotation"
    "fail2ban"
    "unattended-upgrades"
    "ZRAM + swap + earlyoom"
    "SSH hardening"
    "UFW firewall"
)
ITEM_SECTIONS=(база база база база сервисы сервисы защита защита защита защита защита защита)
DISABLE_SUPPORTED=(dockerlog fail2ban unattended zram ufw)

# Параллельно ITEM_IDS — команды отката для справочного экрана (R). Пусто там,
# где пункт входит в DISABLE_SUPPORTED: для них show_rollback_reference() сама
# генерирует единую строку вместо ручных команд, так что нумерация/маркеры
# никогда не расходятся с реальным меню.
ROLLBACK_NOTES=(
"sudo apt purge micro certbot python3-certbot-nginx unzip htop bind9-dnsutils jq rsync
     (осторожно: curl/git/ca-certificates часто нужны другим программам — не удаляй не глядя)"
"sudo apt purge eza bat fd-find ripgrep zoxide ncdu
     sudo rm -f \"\$(command -v starship)\"   # если ставился этим же пунктом"
"sudo apt purge fastfetch
     sudo add-apt-repository --remove ppa:zhangsongcui3371/fastfetch
     rm -f ~/.config/fastfetch/config.jsonc
     sed -i '/# >>> vps-setup:fastfetch >>>/,/# <<< vps-setup:fastfetch <<</d' ~/.bashrc"
"sudo apt purge tmux
     rm -f ~/.tmux.conf"
"sudo systemctl stop docker
     sudo apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
     sudo rm -rf /var/lib/docker /var/lib/containerd
     # УДАЛЯЕТ все контейнеры/образы/volume без возврата — сначала забэкапь данные"
"sudo systemctl stop nginx
     sudo apt purge nginx-full
     sudo rm -rf /etc/nginx
     # УДАЛЯЕТ конфиги сайтов в /etc/nginx — если уже настраивал поверх, забэкапь"
""
""
""
""
"sudo rm -f /etc/ssh/sshd_config.d/10-hardening.conf
     sudo systemctl restart ssh
     sudo rm -f /etc/sudoers.d/${TARGET_USER}
     # возвращает вход по паролю — убедись, что есть другой способ попасть на сервер"
""
)

item_supports_disable() {
    local id="${1:-}" d
    for d in "${DISABLE_SUPPORTED[@]}"; do [ "$d" = "$id" ] && return 0; done
    return 1
}

# ── Адаптивная раскладка — один источник истины для ширины разделителей/рамок ──
# возвращает не сырую ширину терминала, а уже за вычетом 2-пробельного отступа,
# который hr()/box_line()/строки меню всегда добавляют слева — иначе рамка
# оказывается на 2 колонки шире реального терминала, и на настоящем pty это
# рвёт многобайтовые "─" переносом строки посреди символа
term_width() {
    local w
    w="$(tput cols 2>/dev/null)"
    [[ "$w" =~ ^[0-9]+$ ]] || w=80
    [ "$w" -lt 60 ] && w=60
    [ "$w" -gt 100 ] && w=100
    echo "$((w - 2))"
}

# N штук "─" одной строкой. Специально не через "printf '%*s' | tr ' ' '─'" —
# на боксах со сломанным/негенерированным locale (LANG=en_US.UTF-8 объявлен,
# но сам locale не собран — нередкая история именно на свежих VPS-образах) tr
# начинает работать побайтово и режет 3-байтовый UTF-8 "─" на мусорные байты.
# printf с "%.0s" многобайтовый символ не трогает вообще — печатает его из
# формат-строки как есть на каждой итерации, независимо от locale
repeat_dash() {
    local n="$1"
    printf -- '─%.0s' $(seq 1 "$n")
}

hr() {
    local color="${1:-$DIM}" width
    width="$(term_width)"
    echo -e "  ${color}$(repeat_dash "$width")${NC}"
}

# box_line color left mid right w1 w2 ... — одна строка рамки (┌─┬─┐ / ├─┼─┤ / └─┴─┘)
box_line() {
    local color="$1" left="$2" mid="$3" right="$4"; shift 4
    local out="$left" first=true w seg
    for w in "$@"; do
        seg="$(repeat_dash "$((w + 2))")"
        if [ "$first" = true ]; then
            out="${out}${seg}"; first=false
        else
            out="${out}${mid}${seg}"
        fi
    done
    echo -e "  ${color}${out}${right}${NC}"
}

pad_title() {
    local s="$1" width="$2" len pad
    len="$(python3 -c "import sys; print(len(sys.argv[1]))" "$s" 2>/dev/null || echo "${#s}")"
    pad=$((width - len))
    [ "$pad" -lt 1 ] && pad=1
    printf '%s%*s' "$s" "$pad" ""
}

# видимая (без ANSI-кодов) длина строки, Cyrillic-safe — общий счётчик для
# паддинга/обрезки цветного текста (статусная колонка, рамка легенды)
visible_len() {
    local plain
    # два разных вида "цветового кода" встречаются в этом файле: настоящий ESC-байт
    # (\x1b) — так выглядит вывод, прошедший через echo -e/printf %b (например,
    # результат status_* функций) — и буквальный 4-символьный текст "\033" — так
    # выглядит цвет, если переменную типа $BOLD (объявлена в '...', без раскрытия
    # escape-последовательностей) подставили в строку напрямую, минуя echo -e.
    # Оба варианта не несут видимой ширины и должны вырезаться одинаково.
    plain="$(printf '%s' "$1" | sed -E 's/\x1b\[[0-9;]*m//g; s/\\033\[[0-9;]*m//g')"
    python3 -c "import sys; print(len(sys.argv[1]))" "$plain" 2>/dev/null || echo "${#plain}"
}

# обрезает цветную строку до width видимых символов, добавляя "…" если длиннее.
# Предполагает, что вся строка обёрнута РОВНО в один цветовой код (так и есть
# у всех status_* — один ${COLOR}...${NC} на всю строку)
truncate_colored() {
    local text="$1" width="$2" plain color body
    if [ "$(visible_len "$text")" -le "$width" ]; then
        printf '%s' "$text"
        return
    fi
    plain="$(printf '%s' "$text" | sed -E 's/\x1b\[[0-9;]*m//g; s/\\033\[[0-9;]*m//g')"
    # цветовой код в начале строки — в любом из двух видов (см. visible_len)
    color="$(printf '%s' "$text" | grep -oE '^(\x1b\[[0-9;]*m|\\033\[[0-9;]*m)')"
    body="$(python3 -c "
import sys
s, w = sys.argv[1], int(sys.argv[2])
print(s[:max(w-3,0)] + '...')
" "$plain" "$width")"
    # NC добавляем только если реально был цветовой код — иначе для обычного
    # текста (без цвета) это дописывает буквальный "\033[0m" как текст,
    # который потом портит и вид, и подсчёт длины в pad_title
    if [ -n "$color" ]; then
        printf '%s%s%s' "$color" "$body" "$NC"
    else
        printf '%s' "$body"
    fi
}

show_menu() {
    show_header
    echo -e "  ${DIM}Пользователь:${NC} ${BOLD}${TARGET_USER}${NC}   ${DIM}SSH-порт:${NC} ${BOLD}${SSH_PORT}${NC}"
    echo ""

    # ширины колонок — фикс для #/Раздел/Пункт, Статус забирает остаток term_width()
    # idx_w=3, не 2: pad_title всегда добавляет минимум 1 пробел-паддинга (см. её
    # реализацию), поэтому при ширине ровно "12" (2 символа) паддинг обнулялся бы
    # и принудительно поднимался до 1, ломая выравнивание рамки именно на пунктах 10-12
    local idx_w=3 section_w=10 title_w=26 status_w inner_w
    inner_w="$(term_width)"
    # -7: 5 символов рамки (┌/│×3/┐ или их аналоги на разных строках) + 2 — паддинг
    # самой статусной колонки, которую эта формула вычисляет (её собственные "+2"
    # не должны компенсироваться дважды)
    status_w=$(( inner_w - (idx_w + 2) - (section_w + 2) - (title_w + 2) - 7 ))
    # 6 — минимум, при котором рамка ещё точно влезает в нижнюю границу term_width()
    # (60 сырых колонок терминала); при более узком клампе сама рамка вылезала бы
    # за пределы терминала независимо от длины текста статуса
    [ "$status_w" -lt 6 ] && status_w=6

    box_line "$DIM" '┌' '┬' '┐' "$idx_w" "$section_w" "$title_w" "$status_w"
    printf "  ${DIM}│${NC} ${BOLD}%s${NC} ${DIM}│${NC} ${BOLD}%s${NC} ${DIM}│${NC} ${BOLD}%s${NC} ${DIM}│${NC} ${BOLD}%s${NC} ${DIM}│${NC}\n" \
        "$(pad_title "#" "$idx_w")" "$(pad_title "Раздел" "$section_w")" \
        "$(pad_title "Пункт" "$title_w")" "$(pad_title "Статус" "$status_w")"
    box_line "$DIM" '├' '┼' '┤' "$idx_w" "$section_w" "$title_w" "$status_w"

    local i=1 id section section_color
    for id in "${ITEM_IDS[@]}"; do
        local status_line status_len status_pad
        section="${ITEM_SECTIONS[$((i-1))]}"
        case "$section" in
            база)     section_color="$CYAN" ;;
            сервисы)  section_color="$BLUE" ;;
            защита)   section_color="$MAGENTA" ;;
        esac
        status_line="$(status_"$id")"
        # длинный статус (например, большой список недостающих пакетов) обрезаем
        # с "…" вместо того, чтобы дать ему вылезти за правую рамку — рамка должна
        # оставаться ровной на любой строке
        status_line="$(truncate_colored "$status_line" "$status_w")"
        status_len="$(visible_len "$status_line")"
        status_pad=$((status_w - status_len))
        [ "$status_pad" -lt 0 ] && status_pad=0
        printf "  ${DIM}│${NC} %s ${DIM}│${NC} ${section_color}%s${NC} ${DIM}│${NC} %s ${DIM}│${NC} %b%*s ${DIM}│${NC}\n" \
            "$(pad_title "$i" "$idx_w")" "$(pad_title "$section" "$section_w")" \
            "$(pad_title "${ITEM_TITLES[$((i-1))]}" "$title_w")" "$status_line" "$status_pad" ""
        i=$((i+1))
    done
    box_line "$DIM" '└' '┴' '┘' "$idx_w" "$section_w" "$title_w" "$status_w"

    echo ""
    # legend_w = inner_w - 4: box_line/рамка сама добавляет 2 бордюрных символа
    # (┌/┐ или │/│) + 2 паддинга вокруг содержимого одной колонки — если отдать
    # ей inner_w напрямую, итоговая рамка окажется на 4 символа шире терминала
    local legend_w=$((inner_w - 4)) line
    local lbl_choice lbl_sections lbl_commands legend1 legend2 legend3 legend4
    lbl_choice="$(pad_title "Выбор:" 10)"
    lbl_sections="$(pad_title "Разделы:" 10)"
    lbl_commands="$(pad_title "Команды:" 10)"
    legend1="${BOLD}${lbl_choice}${NC}${CYAN}${BOLD}5${NC} / ${CYAN}${BOLD}1 3 5${NC} / ${CYAN}${BOLD}1,3,5${NC} — один или несколько пунктов сразу"
    legend2="$(pad_title "" 10)${DIM}буквы разделов тоже можно сочетать (B,S); применённый пункт «защиты» — повторный выбор предложит отключить${NC}"

    # Разделы:/Команды: — сеткой в 4 равные колонки вместо инлайн-списка через
    # три пробела, чтобы пункты стояли ровно друг под другом, а не вразнобой
    grid_cell() {
        local content="$1" width="$2" clen cpad
        clen="$(visible_len "$content")"
        cpad=$((width - clen))
        [ "$cpad" -lt 0 ] && cpad=0
        printf '%s%*s' "$content" "$cpad" ""
    }
    local item_w=$(( (legend_w - 10) / 4 ))
    legend3="${BOLD}${lbl_sections}${NC}$(grid_cell "${CYAN}${BOLD}B${NC} ${CYAN}база${NC}" "$item_w")$(grid_cell "${BLUE}${BOLD}S${NC} ${BLUE}сервисы${NC}" "$item_w")$(grid_cell "${MAGENTA}${BOLD}P${NC} ${MAGENTA}защита${NC}" "$item_w")${BOLD}A${NC} всё"
    legend4="${BOLD}${lbl_commands}${NC}$(grid_cell "${CYAN}${BOLD}H${NC} алиасы" "$item_w")$(grid_cell "${CYAN}${BOLD}R${NC} откат" "$item_w")$(grid_cell "${CYAN}${BOLD}U${NC} удалить" "$item_w")${CYAN}${BOLD}Q${NC} выход"
    box_line "$DIM" '┌' '┬' '┐' "$legend_w"
    for line in "$legend1" "$legend2" "$legend3" "$legend4"; do
        local ltrunc llen lpad
        ltrunc="$(truncate_colored "$line" "$legend_w")"
        llen="$(visible_len "$ltrunc")"
        lpad=$((legend_w - llen))
        [ "$lpad" -lt 0 ] && lpad=0
        printf "  ${DIM}│${NC} %b%*s ${DIM}│${NC}\n" "$ltrunc" "$lpad" ""
    done
    box_line "$DIM" '└' '┴' '┘' "$legend_w"
    echo ""
}

process_item() {
    local idx="$1"
    local id="${ITEM_IDS[$((idx-1))]}"
    echo ""
    if item_supports_disable "$id"; then
        status_"$id" >/dev/null
        if [ $? -eq 0 ]; then
            echo -e "  ${CYAN}${BOLD}→ Отключить: ${ITEM_TITLES[$((idx-1))]}${NC}"
            hr
            "disable_${id}"
            return
        fi
    fi
    echo -e "  ${CYAN}${BOLD}→ ${ITEM_TITLES[$((idx-1))]}${NC}"
    hr
    "apply_${id}"
}

show_aliases_help() {
    show_header
    echo -e "  ${BOLD}Алиасы${NC} ${DIM}(usfc — сам при первом запуске; ls/ll/la/lt/cat/catp/scat/fd — пункт «CLI-утилиты»)${NC}"
    echo ""

    local col1=8 col2=30 col3 inner_w
    inner_w="$(term_width)"
    # 6 = 4 бордюрных символа (│×3 + внешние) + 2 паддинга третьей колонки,
    # которую эта формула вычисляет (её собственные "+2" не должны
    # компенсироваться дважды) — тот же приём, что и в show_menu()
    col3=$(( inner_w - (col1 + 2) - (col2 + 2) - 6 ))
    [ "$col3" -lt 10 ] && col3=10

    local rows=(
        "ls|eza --icons --group-directories-first|список файлов с иконками (замена ls)"
        "ll|eza -lah --icons --group-directories-first|подробный список, аналог ls -la"
        "la|eza -a --icons --group-directories-first|список вместе со скрытыми файлами"
        "lt|eza --tree --icons --level=2 ...|дерево каталогов, 2 уровня вглубь"
        "cat|batcat --paging=never|вывод файла с подсветкой, без пейджера"
        "catp|batcat|то же, с пейджером (для длинных файлов)"
        "scat|sudo batcat --paging=never|cat для файлов, читаемых только под root"
        "fd|fdfind|быстрый поиск файлов, замена find"
        "usfc|sudo usfc + auto-source ~/.bashrc|запуск меню, .bashrc подхватится само"
    )

    box_line "$DIM" '┌' '┬' '┐' "$col1" "$col2" "$col3"
    local hdr3="Что делает" hdr3_len hdr3_pad
    # col3 динамический (зависит от term_width()) и на узких терминалах может
    # совпасть по длине с заголовком — та же ловушка pad_title(), что и у cmd_t/desc_t
    hdr3_len="$(visible_len "$hdr3")"; hdr3_pad=$((col3 - hdr3_len)); [ "$hdr3_pad" -lt 0 ] && hdr3_pad=0
    printf "  ${DIM}│${NC} ${BOLD}%s${NC} ${DIM}│${NC} ${BOLD}%s${NC} ${DIM}│${NC} ${BOLD}%s%*s${NC} ${DIM}│${NC}\n" \
        "$(pad_title "Алиас" "$col1")" "$(pad_title "Реальная команда" "$col2")" "$hdr3" "$hdr3_pad" ""
    box_line "$DIM" '├' '┼' '┤' "$col1" "$col2" "$col3"
    local row alias cmd desc cmd_t desc_t cmd_len cmd_pad desc_len desc_pad
    for row in "${rows[@]}"; do
        IFS='|' read -r alias cmd desc <<< "$row"
        cmd_t="$(truncate_colored "$cmd" "$col2")"
        desc_t="$(truncate_colored "$desc" "$col3")"
        # руками, не через pad_title(): та форсирует минимум 1 пробел паддинга,
        # а truncate_colored() при обрезке всегда возвращает СТРОКУ РОВНО В width
        # символов — pad был бы 0, форс поднял бы его до 1, и рамка бы поехала
        # (та же схема, что уже используется для status_line/легенды в show_menu())
        cmd_len="$(visible_len "$cmd_t")";   cmd_pad=$((col2 - cmd_len));  [ "$cmd_pad" -lt 0 ] && cmd_pad=0
        desc_len="$(visible_len "$desc_t")"; desc_pad=$((col3 - desc_len)); [ "$desc_pad" -lt 0 ] && desc_pad=0
        printf "  ${DIM}│${NC} ${CYAN}%s${NC} ${DIM}│${NC} %s%*s ${DIM}│${NC} %s%*s ${DIM}│${NC}\n" \
            "$(pad_title "$alias" "$col1")" \
            "$cmd_t" "$cmd_pad" "" \
            "$desc_t" "$desc_pad" ""
    done
    box_line "$DIM" '└' '┴' '┘' "$col1" "$col2" "$col3"

    echo ""
    log_info "eza/bat умеют работать и без алиасов: eza --icons -la, batcat file.txt и т.д."
    log_info "Почему у cat/ls вообще другое поведение под sudo — см. README, раздел FAQ"
    echo ""
    pause
}

show_rollback_reference() {
    show_header
    echo -e "  ${BOLD}Откат по пунктам${NC} ${DIM}— только справка, ни одна из этих команд не выполняется скриптом сама${NC}"
    echo ""
    local i=1 id section section_color note
    for id in "${ITEM_IDS[@]}"; do
        section="${ITEM_SECTIONS[$((i-1))]}"
        case "$section" in
            база)     section_color="$CYAN" ;;
            сервисы)  section_color="$BLUE" ;;
            защита)   section_color="$MAGENTA" ;;
        esac
        echo -e "  ${section_color}${BOLD}[$i] ${ITEM_TITLES[$((i-1))]}${NC}"
        if item_supports_disable "$id"; then
            echo -e "     ${DIM}уже откатывается прямо в меню — выбери пункт [$i] ещё раз, скрипт сам увидит, что применено, и предложит отключить${NC}"
        else
            note="${ROLLBACK_NOTES[$((i-1))]}"
            echo -e "     ${DIM}${note}${NC}"
        fi
        echo ""
        i=$((i+1))
    done
    pause
}

uninstall_self() {
    echo ""
    log_warn "Это удаляет СЕБЯ (сам скрипт usfc) — /opt/vps-setup и команду usfc"
    log_info "Всё, что скрипт установил на систему (пакеты, Docker, nginx, SSH hardening и т.д.) —"
    log_info "этим не трогается. Для этого есть пункт R (справка по откату)"
    if ask_yn "Точно удалить usfc из системы?" N; then
        rm -f /usr/local/bin/usfc
        rm -rf /opt/vps-setup
        echo ""
        log_success "usfc удалён. Пока."
        exit 0
    fi
}

main() {
    show_header
    log_info "Пользователь: ${BOLD}${TARGET_USER}${NC} ${DIM}(${TARGET_HOME})${NC}"
    log_info "SSH-порт: ${SSH_PORT}"

    # usfc-обёртка — не отдельный пункт меню, ставится сама при первом запуске,
    # свой маркер, идемпотентно. Пропускаем для прямого root — sudo тут бесполезен
    # (и может быть даже не установлен на такой машине).
    # Это bash-ФУНКЦИЯ, а не alias: после того как дочерний sudo-процесс меню
    # завершится, функция сама делает "source ~/.bashrc" — но уже в ТЕКУЩЕЙ
    # интерактивной оболочке (функции выполняются в вызывающем шелле, не в
    # подпроцессе), так что новые алиасы/промпт подхватываются без ручного
    # source и без переподключения. USFC_RESOURCE гейтит fastfetch-автозапуск
    # (см. apply_fastfetch) — иначе баннер печатался бы второй раз при каждом
    # выходе из меню.
    local BASHRC="${TARGET_HOME}/.bashrc" need_self_block=false
    if [ "$TARGET_USER" != "root" ]; then
        if grep -qF "# >>> vps-setup:self >>>" "$BASHRC" 2>/dev/null; then
            if grep -qF "alias usfc='sudo usfc'" "$BASHRC" 2>/dev/null; then
                sed -i '/# >>> vps-setup:self >>>/,/# <<< vps-setup:self <<</d' "$BASHRC"
                need_self_block=true
            fi
        else
            need_self_block=true
        fi
    fi
    if [ "$need_self_block" = true ]; then
        cat >> "$BASHRC" <<'EOF'

# >>> vps-setup:self >>>
usfc() {
    sudo /usr/local/bin/usfc "$@"
    USFC_RESOURCE=1 source ~/.bashrc 2>/dev/null
    unset USFC_RESOURCE
}
# <<< vps-setup:self <<<
EOF
        chown "${TARGET_USER}:${TARGET_USER}" "$BASHRC" 2>/dev/null
    fi

    # apt update один раз за сессию — дальше все apt install по всему меню используют свежие списки,
    # отдельного пункта "обновление системы" больше нет (apt upgrade — дело юзера, не скрипта)
    apt-get update -qq 2>/dev/null

    # check_for_update возвращает 0, если реально что-то показал (есть апдейт / сеть недоступна) —
    # тогда стоит дать прочитать. Если 1 — всё тихо (последняя версия или локальная новее репозитория),
    # сразу в меню без лишнего Enter.
    if check_for_update; then
        pause
    fi

    while true; do
        show_menu
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        read -r choice </dev/tty
        case "$choice" in
            [Qq]) echo ""; log_info "Пока. Повторный запуск: usfc"; break ;;
            [Hh]) show_aliases_help ;;
            [Rr]) show_rollback_reference ;;
            [Uu]) uninstall_self; pause ;;
            *)
                # номера и буквы разделов вперемешку через пробел/запятую:
                # "5", "1 3 5", "1,3,5", "B", "B,S", "B,14" — всё разбирается одинаково
                local -a nums valid=()
                IFS=', ' read -ra nums <<< "$choice"
                local tok upper i
                for tok in "${nums[@]}"; do
                    [ -z "$tok" ] && continue
                    upper="$(echo "$tok" | tr '[:lower:]' '[:upper:]')"
                    case "$upper" in
                        B) valid+=(1 2 3 4) ;;
                        S) valid+=(5 6) ;;
                        P) valid+=(7 8 9 10 11 12) ;;
                        A) for ((i = 1; i <= ${#ITEM_IDS[@]}; i++)); do valid+=("$i"); done ;;
                        *)
                            if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "${#ITEM_IDS[@]}" ]; then
                                valid+=("$tok")
                            else
                                log_error "Нет пункта «${tok}»"
                            fi
                            ;;
                    esac
                done

                # убрать дубликаты, сохраняя порядок (могут возникнуть при пересечении, например "3,B")
                local -a dedup=()
                local n already
                for n in "${valid[@]}"; do
                    already=false
                    for i in "${dedup[@]}"; do [ "$i" = "$n" ] && already=true && break; done
                    [ "$already" = false ] && dedup+=("$n")
                done
                valid=("${dedup[@]}")

                if [ "${#valid[@]}" -eq 0 ]; then
                    log_error "Не понял ввод — номер пункта, буква раздела (B/S/P/A), можно сочетать через пробел/запятую, либо H, R, U, Q"
                    sleep 1
                elif [ "${#valid[@]}" -eq 1 ]; then
                    # один пункт — как обычно, интерактивно, со всеми вопросами внутри
                    process_item "${valid[0]}"
                    pause
                else
                    # несколько пунктов разом — сначала убираем то, что уже применено
                    # (иначе "B,S" при частично готовой системе будет зря переспрашивать про то, что и так стоит)
                    local -a pending=() id
                    for n in "${valid[@]}"; do
                        id="${ITEM_IDS[$((n-1))]}"
                        status_"$id" >/dev/null
                        [ $? -ne 0 ] && pending+=("$n")
                    done

                    echo ""
                    if [ "${#pending[@]}" -eq 0 ]; then
                        log_info "Из выбранного (${valid[*]}) уже всё применено"
                        sleep 1
                    else
                        log_info "Не применено из выбранного: ${pending[*]} (${#pending[@]} шт.)"
                        log_info "Каждый пункт применится со своими настройками по умолчанию, без вопросов по ходу"
                        # пункт 10 (zram) — единственное исключение: % под zram и МБ
                        # резервного swap-файла спрашиваем один раз здесь, ДО BULK_MODE=true
                        # (пока ask_value ещё реально интерактивна), а не молча дефолтим
                        if printf '%s\n' "${pending[@]}" | grep -qx 10; then
                            read_swap_state
                            if ! { [ "$ZRAM_ACTIVE" = true ] && [ "$ZRAM_PRIO" = "100" ]; }; then
                                ZRAM_BULK_PERCENT="$(ask_value "Размер zram в % от RAM?" 75)"
                            fi
                            if [ "$SWAP_ACTIVE" != true ]; then
                                SWAP_BULK_MB="$(ask_value "Размер резервного swap-файла, МБ?" "$(suggest_swap_mb)")"
                            fi
                        fi
                        if ask_yn "Применить сразу?"; then
                            BULK_MODE=true
                            for num in "${pending[@]}"; do
                                process_item "$num"
                            done
                            BULK_MODE=false
                        fi
                        ZRAM_BULK_PERCENT=""
                        SWAP_BULK_MB=""
                        pause
                    fi
                fi
                ;;
        esac
    done

    if [ -f /var/run/reboot-required ]; then
        echo ""
        log_warn "Требуется перезагрузка сервера (было обновление ядра/библиотек)"
    fi
    echo ""
}

main
