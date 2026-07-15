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

VERSION="1.4.0"
REPO_RAW_BASE="https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main"

# ── Цвета ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log_info()    { echo -e "  ${CYAN}[i]${NC} ${1:-}"; }
log_success() { echo -e "  ${GREEN}[✓]${NC} ${1:-}"; }
log_warn()    { echo -e "  ${YELLOW}[!]${NC} ${1:-}" >&2; }
log_error()   { echo -e "  ${RED}[✗]${NC} ${1:-}" >&2; }

BULK_MODE=false

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

show_header() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo ""
    echo -e "  ${CYAN}██╗   ██╗██████╗ ███████╗      ███████╗███████╗████████╗██╗   ██╗██████╗ ${NC}"
    echo -e "  ${CYAN}██║   ██║██╔══██╗██╔════╝      ██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗${NC}"
    echo -e "  ${CYAN}██║   ██║██████╔╝███████╗█████╗███████╗█████╗     ██║   ██║   ██║██████╔╝${NC}"
    echo -e "  ${CYAN}╚██╗ ██╔╝██╔═══╝ ╚════██║╚════╝╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝ ${NC}"
    echo -e "  ${CYAN} ╚████╔╝ ██║     ███████║      ███████║███████╗   ██║   ╚██████╔╝██║     ${NC}"
    echo -e "  ${CYAN}  ╚═══╝  ╚═╝     ╚══════╝      ╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝     ${NC}"
    echo -e "  ${BOLD}vps-setup${NC} ${DIM}v${VERSION} by SkyDeaD${NC}    ${DIM}CLI · Docker · zram/swap · fastfetch · starship · hardening${NC}"
    echo -e "  ${CYAN}────────────────────────────────────────────────────────────────────${NC}"
}

pause() {
    echo ""
    echo -en "  ${DIM}Enter — продолжить...${NC}"
    read -r _ </dev/tty
}

# ── root / целевой пользователь ────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "Нужны права root: curl -fsSL .../install.sh | sudo bash" >&2
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
    if ask_yn "Обновить vps-setup до ${remote_version} сейчас?"; then
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
status_update()   { echo -e "${DIM}(действие, не отслеживается)${NC}"; return 1; }

status_cli() {
    local c missing=""
    for c in eza bat fd-find ripgrep zoxide ncdu; do
        dpkg -s "$c" &>/dev/null || missing="${missing}${missing:+, }${c}"
    done
    if [ -n "$missing" ]; then
        echo -e "${YELLOW}○ не хватает: ${missing}${NC}"; return 1
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
        echo -e "${YELLOW}○ не хватает: ${missing}${NC}"; return 1
    fi
    echo -e "${GREEN}✓ установлено${NC}"; return 0
}

status_nginx() {
    if command -v nginx &>/dev/null; then
        if systemctl is-active nginx &>/dev/null; then
            echo -e "${GREEN}✓ установлен и запущен${NC}"; return 0
        else
            echo -e "${YELLOW}! установлен, не запущен${NC}"; return 1
        fi
    else
        echo -e "${YELLOW}○ не установлен${NC}"; return 1
    fi
}

status_docker() {
    if command -v docker &>/dev/null; then
        echo -e "${GREEN}✓ установлен ($(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1))${NC}"; return 0
    else
        echo -e "${YELLOW}○ не установлен${NC}"; return 1
    fi
}

status_fastfetch() {
    if command -v fastfetch &>/dev/null; then
        local v lowest
        v="$(fastfetch --version | grep -oP '\d+\.\d+\.\d+' | head -n1)"
        lowest="$(printf '%s\n%s\n' "$v" "2.64.0" | sort -V | head -n1)"
        if [ "$lowest" = "2.64.0" ]; then
            echo -e "${GREEN}✓ ${v}${NC}"; return 0
        else
            echo -e "${YELLOW}! ${v} (нужна >= 2.64.0)${NC}"; return 1
        fi
    else
        echo -e "${YELLOW}○ не установлен${NC}"; return 1
    fi
}

status_starship() {
    command -v starship &>/dev/null \
        && { echo -e "${GREEN}✓ установлен${NC}"; return 0; } \
        || { echo -e "${YELLOW}○ не установлен${NC}"; return 1; }
}

status_dotfiles() {
    local cfg_ok=false marker_ok=false
    [ -f "${TARGET_HOME}/.config/fastfetch/config.jsonc" ] && cfg_ok=true
    grep -qF "# >>> vps-setup >>>" "${TARGET_HOME}/.bashrc" 2>/dev/null && marker_ok=true
    if [ "$cfg_ok" = true ] && [ "$marker_ok" = true ]; then
        echo -e "${GREEN}✓ установлено${NC}"; return 0
    else
        echo -e "${YELLOW}○ не установлено${NC}"; return 1
    fi
}

status_tmux() {
    if command -v tmux &>/dev/null; then
        if [ -f "${TARGET_HOME}/.tmux.conf" ]; then
            echo -e "${GREEN}✓ установлен + конфиг${NC}"; return 0
        else
            echo -e "${YELLOW}! установлен, конфига нет${NC}"; return 1
        fi
    else
        echo -e "${YELLOW}○ не установлен${NC}"; return 1
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
        echo -e "${YELLOW}○ не настроено${NC}"; return 1
    fi
}

status_fail2ban() {
    systemctl is-active fail2ban &>/dev/null \
        && { echo -e "${GREEN}✓ запущен${NC}"; return 0; } \
        || { echo -e "${YELLOW}○ не запущен${NC}"; return 1; }
}

status_unattended() {
    if [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
        echo -e "${GREEN}✓ включено${NC}"; return 0
    else
        echo -e "${YELLOW}○ выключено${NC}"; return 1
    fi
}

status_zram() {
    local zram_ok=false swap_ok=false
    while read -r n t s u p; do
        case "$n" in
            /dev/zram*) [ "$p" = "100" ] && zram_ok=true ;;
            *)          [ "$p" = "10" ] && swap_ok=true ;;
        esac
    done < <(swapon --show --noheadings --raw 2>/dev/null)
    if [ "$zram_ok" = true ] && [ "$swap_ok" = true ]; then
        echo -e "${GREEN}✓ настроено по гайду${NC}"; return 0
    elif [ "$zram_ok" = true ] || [ "$swap_ok" = true ]; then
        echo -e "${YELLOW}! настроено частично${NC}"; return 1
    else
        echo -e "${YELLOW}○ не настроено${NC}"; return 1
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
        echo -e "${YELLOW}○ не применено${NC}"; return 1
    fi
}

status_ufw() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "${GREEN}✓ включён${NC}"; return 0
    else
        echo -e "${YELLOW}○ выключен${NC}"; return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# APPLY-функции
# ═══════════════════════════════════════════════════════════════
apply_update() {
    if ask_yn "Выполнить apt update && apt upgrade?"; then
        apt-get update -qq
        apt-get upgrade -y -qq
        log_success "Система обновлена"
        [ -f /var/run/reboot-required ] && log_warn "Требуется перезагрузка (обновилось ядро или системная библиотека)"
    else
        apt-get update -qq
        log_info "Только apt update, upgrade пропущен"
    fi
}

apply_cli() {
    if ask_yn "Установить eza, bat, fd-find, ripgrep, zoxide, ncdu?"; then
        apt-get install -y eza bat fd-find ripgrep zoxide ncdu \
            && log_success "Установлено" || log_error "Установка не удалась"
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
    if command -v nginx &>/dev/null; then
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
    if ! ask_yn "Установить/обновить fastfetch (через PPA)?"; then return; fi
    add-apt-repository -y ppa:zhangsongcui3371/fastfetch
    apt-get update -qq
    apt-get install -y fastfetch && log_success "fastfetch: $(fastfetch --version)" || log_error "Установка не удалась"
}

apply_starship() {
    if ask_yn "Установить starship?"; then
        curl -sS https://starship.rs/install.sh | sh -s -- -y && log_success "starship установлен" || log_error "Установка не удалась"
    fi
}

apply_dotfiles() {
    if ! ask_yn "Установить fastfetch config.jsonc и алиасы/хуки в .bashrc?"; then return; fi
    sudo -u "$TARGET_USER" mkdir -p "${TARGET_HOME}/.config/fastfetch"
    if curl -fsSL "${REPO_RAW_BASE}/config.jsonc" -o "${TARGET_HOME}/.config/fastfetch/config.jsonc" 2>/dev/null; then
        chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.config/fastfetch/config.jsonc"
        log_success "config.jsonc установлен"
    else
        log_warn "Не удалось скачать config.jsonc из ${REPO_RAW_BASE}"
    fi

    local BASHRC="${TARGET_HOME}/.bashrc"
    if grep -qF "# >>> vps-setup >>>" "$BASHRC" 2>/dev/null; then
        log_info "Блок vps-setup уже есть в .bashrc"
    else
        cat >> "$BASHRC" <<EOF

# >>> vps-setup >>>
alias ls='eza --icons --group-directories-first'
alias ll='eza -lah --icons --group-directories-first'
alias la='eza -a --icons --group-directories-first'
alias lt='eza --tree --icons --level=2 --group-directories-first'
alias cat='batcat --paging=never'
alias catp='batcat'
alias scat='sudo batcat --paging=never'
alias fd='fdfind'
alias usfc='sudo usfc'

if [ -x "\$(command -v fastfetch)" ]; then
    fastfetch
fi

command -v zoxide &>/dev/null && eval "\$(zoxide init bash)"
command -v starship &>/dev/null && eval "\$(starship init bash)"
# <<< vps-setup <<<
EOF
        chown "${TARGET_USER}:${TARGET_USER}" "$BASHRC"
        log_success ".bashrc обновлён"
    fi
    # Скрипт работает в собственном подпроцессе — "source ~/.bashrc" отсюда
    # никак не повлияет на твою текущую интерактивную сессию (дочерний процесс
    # не может менять окружение родительского). Поэтому не пытаемся, а прямо говорим:
    log_warn "Новые алиасы появятся только в НОВОЙ сессии — либо выполни сам:"
    log_warn "  source ~/.bashrc"
    log_warn "либо просто переподключись по SSH"
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
        log_info "Docker не установлен — сначала установи Docker (пункт 8)"
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

apply_zram() {
    local zram_active=false zram_prio="" swap_active=false swap_prio="" swap_path=""
    while read -r n t s u p; do
        case "$n" in
            /dev/zram*) zram_active=true; zram_prio="$p" ;;
            *)          swap_active=true; swap_prio="$p"; swap_path="$n" ;;
        esac
    done < <(swapon --show --noheadings --raw 2>/dev/null)

    if [ "$zram_active" = true ]; then
        if [ "$zram_prio" = "100" ]; then
            log_success "zram уже настроен (приоритет 100) — пропускаю"
        else
            log_warn "zram активен, но приоритет ${zram_prio} (в гайде — 100), похоже настраивали вручную"
            if ask_yn "Перенастроить под рекомендованные значения?" N; then
                apt-get install -y zram-tools
                printf 'ALGO=lz4\nPERCENT=75\nPRIORITY=100\n' > /etc/default/zramswap
                systemctl restart zramswap
                log_success "zram перенастроен"
            fi
        fi
    elif ask_yn "Установить и настроить zram-tools (lz4, 75% RAM, приоритет 100)?"; then
        apt-get install -y zram-tools
        printf 'ALGO=lz4\nPERCENT=75\nPRIORITY=100\n' > /etc/default/zramswap
        systemctl restart zramswap
        log_success "zram-tools установлен и настроен"
    fi

    if [ "$swap_active" = true ]; then
        if [ "$swap_prio" = "10" ]; then
            log_success "Резервный своп на диске (${swap_path}) уже настроен (приоритет 10) — пропускаю"
        else
            log_warn "Своп на диске (${swap_path}) активен, но приоритет ${swap_prio} (в гайде — 10)"
            if ask_yn "Исправить приоритет ${swap_path} в /etc/fstab на 10?" N; then
                local esc_path
                esc_path="$(printf '%s' "$swap_path" | sed 's/[.[\*^$/]/\\&/g')"
                sed -i -E "s#^(${esc_path}\s+none\s+swap\s+)sw([^,].*)?\$#\1sw,pri=10\2#" /etc/fstab
                swapoff "$swap_path" 2>/dev/null || true
                swapon -a
                log_success "Приоритет исправлен"
            fi
        fi
    elif ask_yn "Создать 1GB swapfile как резервный уровень (приоритет 10)?"; then
        fallocate -l 1G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        if grep -qE '^/swapfile\s' /etc/fstab 2>/dev/null; then
            sed -i -E 's#^(/swapfile\s+none\s+swap\s+)sw([^,].*)?$#\1sw,pri=10\2#' /etc/fstab
        else
            echo "/swapfile none swap sw,pri=10 0 0" >> /etc/fstab
        fi
        swapon -a
        log_success "swapfile создан (1GB, приоритет 10)"
    fi

    local cur_sw cur_vfs
    cur_sw="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo '?')"
    cur_vfs="$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo '?')"
    if [ "$cur_sw" = "80" ] && [ "$cur_vfs" = "50" ]; then
        log_success "sysctl уже настроен как в гайде"
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
        apt-get install -y earlyoom
        systemctl enable --now earlyoom >/dev/null
        log_success "earlyoom установлен"
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
    listening="$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un)"
    echo "$listening" | sed 's/^/      /'
    echo ""
    log_warn "Если на сервере уже крутится VPN/прокси — включение без разрешения ЕГО портов оборвёт его"
    if ! ask_yn "Включить UFW, разрешив SSH-порт (${SSH_PORT}) и все порты выше?" N; then return; fi
    apt-get install -y ufw
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
ITEM_IDS=(update basepkgs cli fastfetch starship dotfiles tmux docker nginx dockerlog fail2ban unattended zram sshhardening ufw)
ITEM_TITLES=(
    "Обновление системы"
    "Базовые пакеты (micro/curl/git/certbot/...)"
    "CLI-утилиты (eza/bat/fd/ripgrep/zoxide/ncdu)"
    "fastfetch"
    "starship"
    "fastfetch config + .bashrc"
    "tmux"
    "Docker + Compose"
    "nginx-full"
    "Docker log rotation"
    "fail2ban"
    "unattended-upgrades"
    "ZRAM + swap + sysctl + earlyoom"
    "SSH hardening"
    "UFW firewall"
)
DISABLE_SUPPORTED=(dockerlog fail2ban unattended zram ufw)

item_supports_disable() {
    local id="${1:-}" d
    for d in "${DISABLE_SUPPORTED[@]}"; do [ "$d" = "$id" ] && return 0; done
    return 1
}

pad_title() {
    local s="$1" width="$2" len pad
    len="$(python3 -c "import sys; print(len(sys.argv[1]))" "$s" 2>/dev/null || echo "${#s}")"
    pad=$((width - len))
    [ "$pad" -lt 1 ] && pad=1
    printf '%s%*s' "$s" "$pad" ""
}

show_menu() {
    show_header
    echo -e "  ${DIM}Пользователь:${NC} ${BOLD}${TARGET_USER}${NC}   ${DIM}SSH-порт:${NC} ${BOLD}${SSH_PORT}${NC}"
    echo ""
    local header_title
    header_title="$(pad_title "Пункт" 48)"
    printf "  ${BOLD}%3s  %sСтатус${NC}\n" "#" "$header_title"
    echo -e "  ${DIM}$(printf -- '─%.0s' {1..80})${NC}"
    local i=1 id
    for id in "${ITEM_IDS[@]}"; do
        case "$i" in
            1) echo -e "  ${DIM}── база ──${NC}" ;;
            4) echo -e "  ${DIM}── сервисы ──${NC}" ;;
            10) echo -e "  ${DIM}── защита и обслуживание ──${NC}" ;;
        esac
        local status_line padded_title
        status_line="$(status_"$id")"
        padded_title="$(pad_title "${ITEM_TITLES[$((i-1))]}" 48)"
        printf "  ${CYAN}%3d${NC}  %s%b\n" "$i" "$padded_title" "$status_line"
        i=$((i+1))
    done
    echo -e "  ${DIM}$(printf -- '─%.0s' {1..80})${NC}"
    echo ""
    echo -e "  ${CYAN}${BOLD}5${NC} / ${CYAN}${BOLD}1 3 5${NC} / ${CYAN}${BOLD}1,3,5${NC}   применить один пункт или сразу несколько"
    echo -e "  ${DIM}уже применённый пункт из группы «защита и обслуживание» — предложит отключить${NC}"
    echo -e "  ${CYAN}${BOLD}B${NC} / ${CYAN}${BOLD}S${NC} / ${CYAN}${BOLD}P${NC}    применить весь раздел разом (база / сервисы / защита)"
    echo -e "  ${CYAN}${BOLD}A${NC}        применить вообще всё ещё не применённое"
    echo -e "  ${CYAN}${BOLD}H${NC}        справка по алиасам (ls/ll/la/lt/cat/catp/scat/fd)"
    echo -e "  ${CYAN}${BOLD}R${NC}        показать команды отката (справочно, ничего не выполняет)"
    echo -e "  ${CYAN}${BOLD}U${NC}        удалить сам vps-setup из системы"
    echo -e "  ${CYAN}${BOLD}Q${NC}        выход"
    echo ""
}

process_item() {
    local idx="$1"
    local id="${ITEM_IDS[$((idx-1))]}"
    echo ""
    if item_supports_disable "$id"; then
        status_"$id" >/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${CYAN}${BOLD}→ Отключить: ${ITEM_TITLES[$((idx-1))]}${NC}"
            echo -e "${DIM}────────────────────────────────────────${NC}"
            "disable_${id}"
            return
        fi
    fi
    echo -e "${CYAN}${BOLD}→ ${ITEM_TITLES[$((idx-1))]}${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    "apply_${id}"
}

show_aliases_help() {
    show_header
    echo -e "  ${BOLD}Алиасы, которые ставит пункт 6 (fastfetch config + .bashrc)${NC}"
    echo ""
    printf "  ${BOLD}%-8s %-42s %s${NC}\n" "Алиас" "Реальная команда" "Что делает"
    echo -e "  ${DIM}$(printf -- '─%.0s' {1..90})${NC}"
    printf "  ${CYAN}%-8s${NC} %-42s %s\n" "ls"   "eza --icons --group-directories-first"                  "список файлов с иконками (замена ls)"
    printf "  ${CYAN}%-8s${NC} %-42s %s\n" "ll"   "eza -lah --icons --group-directories-first"              "подробный список, аналог ls -la"
    printf "  ${CYAN}%-8s${NC} %-42s %s\n" "la"   "eza -a --icons --group-directories-first"                "список вместе со скрытыми файлами"
    printf "  ${CYAN}%-8s${NC} %-42s %s\n" "lt"   "eza --tree --icons --level=2 ..."                        "дерево каталогов, 2 уровня вглубь"
    printf "  ${CYAN}%-8s${NC} %-42s %s\n" "cat"  "batcat --paging=never"                                   "вывод файла с подсветкой, без пейджера"
    printf "  ${CYAN}%-8s${NC} %-42s %s\n" "catp" "batcat"                                                  "то же, но с пейджером (для длинных файлов, поиск / внутри)"
    printf "  ${CYAN}%-8s${NC} %-42s %s\n" "scat" "sudo batcat --paging=never"                              "cat для файлов, читаемых только под root"
    printf "  ${CYAN}%-8s${NC} %-42s %s\n" "fd"   "fdfind"                                                  "быстрый поиск файлов, замена find"
    printf "  ${CYAN}%-8s${NC} %-42s %s\n" "usfc" "sudo usfc"                                                "запуск этого меню сразу с sudo"
    echo -e "  ${DIM}$(printf -- '─%.0s' {1..90})${NC}"
    echo ""
    log_info "eza/bat умеют работать и без алиасов: eza --icons -la, batcat file.txt и т.д."
    log_info "Почему у cat/ls вообще другое поведение под sudo — см. README, раздел FAQ"
    echo ""
    pause
}

show_rollback_reference() {
    show_header
    echo -e "  ${BOLD}Откат по пунктам${NC} ${DIM}— только справка, ни одна из этих команд не выполняется скриптом сама${NC}"
    echo -e "  ${DIM}Пункты 10 fail2ban / 11 unattended / 12 zram (частично) / 13 UFW уже откатываются прямо в меню —${NC}"
    echo -e "  ${DIM}выбери их номер ещё раз, скрипт сам увидит, что применено, и предложит отключить${NC}"
    echo ""
    cat <<EOF
  2  CLI-утилиты:
     sudo apt purge eza bat fd-find ripgrep zoxide ncdu

  3  Базовые пакеты (осторожно: curl/git/ca-certificates часто нужны другим программам,
     не удаляй не глядя, что реально использует их ещё):
     sudo apt purge micro certbot python3-certbot-nginx unzip htop dnsutils jq rsync

  4  Docker — УДАЛЯЕТ все контейнеры/образы/volume без возврата, сначала забэкапь данные:
     sudo systemctl stop docker
     sudo apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
     sudo rm -rf /var/lib/docker /var/lib/containerd

  5  nginx — УДАЛЯЕТ конфиги сайтов в /etc/nginx, если уже что-то настраивал поверх — забэкапь:
     sudo systemctl stop nginx
     sudo apt purge nginx-full
     sudo rm -rf /etc/nginx

  6  fastfetch:
     sudo apt purge fastfetch
     sudo add-apt-repository --remove ppa:zhangsongcui3371/fastfetch

  7  starship:
     sudo rm -f "\$(command -v starship)"

  8  fastfetch config + .bashrc-блок:
     rm -f ~/.config/fastfetch/config.jsonc
     sed -i '/# >>> vps-setup >>>/,/# <<< vps-setup <<</d' ~/.bashrc

  9  tmux:
     sudo apt purge tmux
     rm -f ~/.tmux.conf

  14 SSH hardening — возвращает вход по паролю, убедись, что есть другой способ попасть
     на сервер (консоль провайдера), прежде чем это делать:
     sudo rm -f /etc/ssh/sshd_config.d/10-hardening.conf
     sudo systemctl restart ssh
     sudo rm -f /etc/sudoers.d/${TARGET_USER}
EOF
    echo ""
    pause
}

uninstall_self() {
    echo ""
    log_warn "Это удаляет СЕБЯ (сам скрипт vps-setup) — /opt/vps-setup и команду usfc"
    log_info "Всё, что скрипт установил на систему (пакеты, Docker, nginx, SSH hardening и т.д.) —"
    log_info "этим не трогается. Для этого есть пункт R (справка по откату)"
    if ask_yn "Точно удалить vps-setup из системы?" N; then
        rm -f /usr/local/bin/usfc
        rm -rf /opt/vps-setup
        echo ""
        log_success "vps-setup удалён. Пока."
        exit 0
    fi
}

main() {
    show_header
    log_info "Пользователь: ${BOLD}${TARGET_USER}${NC} ${DIM}(${TARGET_HOME})${NC}"
    log_info "SSH-порт: ${SSH_PORT}"
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
                        B) valid+=(2 3) ;;
                        S) valid+=(4 5 6 7 8 9) ;;
                        P) valid+=(10 11 12 13 14 15) ;;
                        A) for ((i = 2; i <= ${#ITEM_IDS[@]}; i++)); do valid+=("$i"); done ;;
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
                        if ask_yn "Применить сразу?"; then
                            BULK_MODE=true
                            for num in "${pending[@]}"; do
                                process_item "$num"
                            done
                            BULK_MODE=false
                        fi
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
    log_info "Nerd Font ставится в ЛОКАЛЬНОМ терминале — это шрифт клиента, не сервера, скриптом не решается"

    # source ~/.bashrc отсюда не подействует на твою сессию — дочерний процесс не может
    # менять окружение родительского, это ограничение Unix, не обходится скриптом никак.
    log_warn "Новые алиасы/промпт появятся в НОВОЙ сессии — либо сам выполни source ~/.bashrc,"
    log_warn "либо просто переподключись по SSH"
    echo ""
}

main
