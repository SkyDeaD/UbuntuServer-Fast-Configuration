#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  vps-setup v4.0.0
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

VERSION="4.2.0"
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

ask_yn() {
    local question="${1:-}" default="${2:-Y}" reply prompt
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
    log_info "Проверяю обновления vps-setup..."
    local remote_version
    remote_version="$(curl -fsSL --max-time 5 "${REPO_RAW_BASE}/VERSION" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$remote_version" ]; then
        log_warn "Не удалось проверить обновления (нет сети или файла VERSION в репо) — продолжаю с текущей версией"
        return
    fi
    if [ "$remote_version" = "$VERSION" ]; then
        log_success "Установлена последняя версия (${VERSION})"
        return
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
}

# ═══════════════════════════════════════════════════════════════
# STATUS-функции — только читают состояние, ничего не меняют
# ═══════════════════════════════════════════════════════════════
status_update()   { echo -e "${DIM}(действие, не отслеживается)${NC}"; return 1; }

status_cli() {
    local c
    for c in eza bat fd-find ripgrep zoxide ncdu; do
        dpkg -s "$c" &>/dev/null || { echo -e "${YELLOW}○ не всё установлено${NC}"; return 1; }
    done
    echo -e "${GREEN}✓ установлено${NC}"; return 0
}

BASE_PKGS="micro curl wget git nano certbot python3-certbot-nginx unzip htop dnsutils jq software-properties-common ca-certificates gnupg rsync"

status_basepkgs() {
    local p
    for p in $BASE_PKGS; do
        dpkg -s "$p" &>/dev/null || { echo -e "${YELLOW}○ не всё установлено${NC}"; return 1; }
    done
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
            /swapfile)  [ "$p" = "10" ] && swap_ok=true ;;
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
        apt-get install -y -qq eza bat fd-find ripgrep zoxide ncdu >/dev/null \
            && log_success "Установлено" || log_error "Установка не удалась"
    fi
}

apply_basepkgs() {
    if ask_yn "Установить базовый набор пакетов (${BASE_PKGS})?"; then
        # shellcheck disable=SC2086
        apt-get install -y -qq $BASE_PKGS >/dev/null \
            && log_success "Базовый набор установлен" || log_error "Установка не удалась"
    fi
}

apply_nginx() {
    if command -v nginx &>/dev/null; then
        log_info "nginx уже установлен"
    else
        if ! ask_yn "Установить nginx-full?"; then return; fi
        apt-get install -y -qq nginx-full >/dev/null || { log_error "Установка не удалась"; return 1; }
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
    apt-get install -y -qq ca-certificates curl >/dev/null || { log_error "Не удалось поставить зависимости"; return 1; }
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
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null \
        || { log_error "Установка Docker не удалась"; return 1; }
    systemctl enable --now docker >/dev/null
    usermod -aG docker "$TARGET_USER"
    log_success "Docker установлен: $(docker --version)"
    log_info "Пользователь ${TARGET_USER} добавлен в группу docker — перелогинься для применения без sudo"
}

apply_fastfetch() {
    if ! ask_yn "Установить/обновить fastfetch (через PPA)?"; then return; fi
    add-apt-repository -y ppa:zhangsongcui3371/fastfetch >/dev/null 2>&1
    apt-get update -qq
    apt-get install -y -qq fastfetch >/dev/null && log_success "fastfetch: $(fastfetch --version)" || log_error "Установка не удалась"
}

apply_starship() {
    if ask_yn "Установить starship?"; then
        curl -sS https://starship.rs/install.sh | sh -s -- -y >/dev/null && log_success "starship установлен" || log_error "Установка не удалась"
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
alias fd='fdfind'

if [ -x "\$(command -v fastfetch)" ]; then
    fastfetch
fi

eval "\$(zoxide init bash)"
eval "\$(starship init bash)"
# <<< vps-setup <<<
EOF
        chown "${TARGET_USER}:${TARGET_USER}" "$BASHRC"
        log_success ".bashrc обновлён"
    fi
}

apply_tmux() {
    if ! command -v tmux &>/dev/null; then
        if ask_yn "Установить tmux?"; then
            apt-get install -y -qq tmux >/dev/null && log_success "tmux установлен" || { log_error "Установка не удалась"; return 1; }
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
        log_info "Docker не установлен — сначала установи Docker (пункт 4)"
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
    apt-get install -y -qq fail2ban >/dev/null || { log_error "Установка не удалась"; return 1; }
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
    apt-get install -y -qq unattended-upgrades >/dev/null || { log_error "Установка не удалась"; return 1; }
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    systemctl enable --now unattended-upgrades >/dev/null
    log_success "unattended-upgrades включён"
}

apply_zram() {
    local zram_active=false zram_prio="" swap_active=false swap_prio=""
    while read -r n t s u p; do
        case "$n" in
            /dev/zram*) zram_active=true; zram_prio="$p" ;;
            /swapfile)  swap_active=true; swap_prio="$p" ;;
        esac
    done < <(swapon --show --noheadings --raw 2>/dev/null)

    if [ "$zram_active" = true ]; then
        if [ "$zram_prio" = "100" ]; then
            log_success "zram уже настроен (приоритет 100) — пропускаю"
        else
            log_warn "zram активен, но приоритет ${zram_prio} (в гайде — 100), похоже настраивали вручную"
            if ask_yn "Перенастроить под рекомендованные значения?" N; then
                apt-get install -y -qq zram-tools >/dev/null
                printf 'ALGO=lz4\nPERCENT=75\nPRIORITY=100\n' > /etc/default/zramswap
                systemctl restart zramswap
                log_success "zram перенастроен"
            fi
        fi
    elif ask_yn "Установить и настроить zram-tools (lz4, 75% RAM, приоритет 100)?"; then
        apt-get install -y -qq zram-tools >/dev/null
        printf 'ALGO=lz4\nPERCENT=75\nPRIORITY=100\n' > /etc/default/zramswap
        systemctl restart zramswap
        log_success "zram-tools установлен и настроен"
    fi

    if [ "$swap_active" = true ]; then
        if [ "$swap_prio" = "10" ]; then
            log_success "swapfile уже настроен (приоритет 10) — пропускаю"
        else
            log_warn "swapfile активен, но приоритет ${swap_prio} (в гайде — 10)"
            if ask_yn "Исправить приоритет swapfile в /etc/fstab на 10?" N; then
                sed -i -E 's#^(/swapfile\s+none\s+swap\s+)sw([^,].*)?$#\1sw,pri=10\2#' /etc/fstab
                swapoff /swapfile 2>/dev/null || true
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
        apt-get install -y -qq earlyoom >/dev/null
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
    apt-get install -y -qq ufw >/dev/null
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
ITEM_IDS=(update cli basepkgs docker nginx fastfetch starship dotfiles tmux dockerlog fail2ban unattended zram sshhardening ufw)
ITEM_TITLES=(
    "Обновление системы"
    "CLI-утилиты (eza/bat/fd/ripgrep/zoxide/ncdu)"
    "Базовые пакеты (micro/curl/git/certbot/...)"
    "Docker + Compose"
    "nginx-full"
    "fastfetch"
    "starship"
    "fastfetch config + .bashrc"
    "tmux"
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

show_menu() {
    show_header
    echo -e "  ${DIM}Пользователь:${NC} ${BOLD}${TARGET_USER}${NC}   ${DIM}SSH-порт:${NC} ${BOLD}${SSH_PORT}${NC}"
    echo ""
    local i=1 id
    for id in "${ITEM_IDS[@]}"; do
        case "$i" in
            1) echo -e "  ${DIM}── база ──────────────────────────────────────────${NC}" ;;
            4) echo -e "  ${DIM}── сервисы ───────────────────────────────────────${NC}" ;;
            10) echo -e "  ${DIM}── защита и обслуживание ────────────────────────${NC}" ;;
        esac
        local status_line
        status_line="$(status_"$id")"
        echo -e "  ${CYAN}$(printf '%2d' "$i")${NC}  ${ITEM_TITLES[$((i-1))]}  ${status_line}"
        i=$((i+1))
    done
    echo ""
    echo -e "  ${DIM}─────────────────────────────────────────────────────${NC}"
    echo -e "  ${CYAN}${BOLD}A${NC}        применить всё ещё не применённое"
    echo -e "  ${CYAN}${BOLD}d<номер>${NC} отключить (только: dockerlog/fail2ban/unattended/zram/ufw — 10,11,12,13,15)"
    echo -e "  ${CYAN}${BOLD}Q${NC}        выход"
    echo ""
}

run_item() {
    local idx="${1:-}"
    if [[ -z "$idx" || ! "$idx" =~ ^[0-9]+$ ]]; then
        log_error "Внутренняя ошибка: run_item вызван без корректного номера пункта"
        pause
        return 1
    fi
    local id="${ITEM_IDS[$((idx-1))]}"
    echo ""
    echo -e "${CYAN}${BOLD}→ ${ITEM_TITLES[$((idx-1))]}${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    "apply_${id}"
    pause
}

disable_item() {
    local idx="${1:-}"
    if [[ -z "$idx" || ! "$idx" =~ ^[0-9]+$ ]]; then
        log_error "Внутренняя ошибка: disable_item вызван без корректного номера пункта"
        pause
        return 1
    fi
    local id="${ITEM_IDS[$((idx-1))]}"
    if ! item_supports_disable "$id"; then
        echo ""
        log_warn "Автоматическая отмена для «${ITEM_TITLES[$((idx-1))]}» не поддерживается скриптом"
        log_info "Это либо установка пакета (просто не мешает системе), либо шаг с реальным риском"
        log_info "при неосторожном автоматическом откате (Docker, SSH hardening) — делай вручную"
        pause
        return
    fi
    echo ""
    echo -e "${CYAN}${BOLD}→ Отключить: ${ITEM_TITLES[$((idx-1))]}${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    "disable_${id}"
    pause
}

apply_all_pending() {
    local i=1 id
    for id in "${ITEM_IDS[@]}"; do
        if [ "$id" != "update" ]; then
            status_"$id" >/dev/null
            if [ $? -ne 0 ]; then
                run_item "$i"
            fi
        fi
        i=$((i+1))
    done
}

main() {
    show_header
    log_info "Пользователь: ${BOLD}${TARGET_USER}${NC} ${DIM}(${TARGET_HOME})${NC}"
    log_info "SSH-порт: ${SSH_PORT}"
    check_for_update
    pause

    while true; do
        show_menu
        echo -en "  ${BOLD}Выбор:${NC} "
        local choice
        read -r choice </dev/tty
        case "$choice" in
            [Qq]) echo ""; log_info "Пока. Повторный запуск: sudo vps-setup"; break ;;
            [Aa]) apply_all_pending ;;
            d[0-9]|d[0-9][0-9])
                local n="${choice#d}"
                if [ "$n" -ge 1 ] && [ "$n" -le "${#ITEM_IDS[@]}" ] 2>/dev/null; then
                    disable_item "$n"
                else
                    log_error "Нет такого пункта"; sleep 1
                fi
                ;;
            ''|*[!0-9]*)
                log_error "Не понял ввод — номер пункта, A, d<номер> или Q"; sleep 1
                ;;
            *)
                if [ "$choice" -ge 1 ] && [ "$choice" -le "${#ITEM_IDS[@]}" ] 2>/dev/null; then
                    run_item "$choice"
                else
                    log_error "Нет такого пункта"; sleep 1
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
    echo ""
}

main
