# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# DISABLE-функции — только для безопасно обратимых пунктов
# ═══════════════════════════════════════════════════════════════
# У пунктов «защиты» disable_* только выключает, и этого достаточно: их статус
# после выключения становится «не применено», так что повторный выбор сам уходит
# в apply_* и включает обратно.
#
# С nginx и Docker так нельзя. Их статус намеренно остаётся ЗЕЛЁНЫМ и для
# сознательно выключенного сервиса — иначе режим A предлагал бы его при каждом
# прогоне (это чинили в 2.6.0). Значит повторный выбор всегда приходит сюда,
# и включать обратно приходится тоже здесь. Поэтому обе функции ниже —
# переключатели: смотрят на текущее состояние и предлагают противоположное.
disable_nginx() {
    if service_is_up nginx; then
        if ! ask_yn "Остановить nginx и убрать из автозапуска? Сайты на :80 и :443 перестанут отвечать" N; then
            log_info "Оставляю nginx как есть"; return 0
        fi
        apply_service_autostart nginx false
    else
        if ! ask_yn "nginx выключен. Запустить и включить автозапуск?" Y; then
            log_info "Оставляю nginx выключенным"; return 0
        fi
        apply_service_autostart nginx true
    fi
}

disable_docker() {
    if service_is_up docker; then
        if ! ask_yn "Остановить Docker и убрать из автозапуска? Все запущенные контейнеры встанут" N; then
            log_info "Оставляю Docker как есть"; return 0
        fi
        apply_service_autostart docker false
    else
        if ! ask_yn "Docker выключен. Запустить и включить автозапуск?" Y; then
            log_info "Оставляю Docker выключенным"; return 0
        fi
        apply_service_autostart docker true
    fi
}

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
