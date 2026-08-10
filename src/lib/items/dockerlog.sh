# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: Docker log rotation ─────────────────────────────────────────
usfc_item dockerlog защита "Docker log rotation" \
    "ограничивает логи контейнеров, чтобы не съели диск" \
    "Docker log rotation" \
    "caps container logs so they cannot eat the disk"
usfc_item_toggle dockerlog

usfc_item_full dockerlog "Ограничивает логи контейнеров: 10 МБ на файл, 3 файла.

Без этого логи Docker ничем не ограничены и со временем способны забить весь
диск — на маленькой VPS это вопрос недель. Настройка пишется в
/etc/docker/daemon.json, существующий файл дополняется, а не перезаписывается." \
"Container logs grow without limit by default, and on a small VPS they are
the most common reason the disk fills up: one chatty container can produce
gigabytes in a week.

Sets max-size=10m and max-file=3 in /etc/docker/daemon.json. An existing
daemon.json is extended, not overwritten. The change takes effect after the
Docker daemon restarts — the item offers to do that, warning that every
container restarts with it."


usfc_item_rollback dockerlog "sudo rm -f /etc/docker/daemon.json      # если в файле больше ничего нет
     sudo systemctl restart docker           # контейнеры при этом встанут и поднимутся заново" \
"sudo rm -f /etc/docker/daemon.json      # if nothing else is left in the file
     sudo systemctl restart docker           # containers stop and come back up in the process"

status_dockerlog() {
    if ! command -v docker &>/dev/null; then
        st "$DIM" "— (нужен Docker)" "— (needs Docker)"; return 1
    fi
    if [ -f /etc/docker/daemon.json ] && python3 -c "
import json,sys
try:
    d=json.load(open('/etc/docker/daemon.json'))
    sys.exit(0 if d.get('log-opts',{}).get('max-size')=='10m' else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
        st "$GREEN" "✓ настроено (max-size=10m)" "✓ configured (max-size=10m)"; return 0
    else
        st "$DIM" "○ не настроено" "○ not configured"; return 1
    fi
}

apply_dockerlog() {
    if ! command -v docker &>/dev/null; then
        log_info_t "Docker не установлен — сначала установи Docker (пункт $(item_number docker))" \
"Docker is not installed — install Docker first (item $(item_number docker))"
        return
    fi
    [ -f /etc/docker/daemon.json ] && log_warn_t "daemon.json уже существует, будет дополнен (не перезаписан целиком)" \
"daemon.json already exists and will be extended, not overwritten"
    if ! ask_yn_t "Ограничить логи контейнеров (max-size=10m, max-file=3)?" "Cap container logs (max-size=10m, max-file=3)?"; then return; fi
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
    log_success_t "daemon.json обновлён" \
"daemon.json updated"
    if ask_yn_t "Перезапустить Docker сейчас? ВСЕ контейнеры перезапустятся вместе с демоном" "Restart Docker now? EVERY container restarts together with the daemon" N; then
        systemctl restart docker && log_success_t "Docker перезапущен" \
"Docker restarted"
    else
        log_info_t "Применится при следующем перезапуске Docker/сервера" \
"It will take effect the next time Docker or the server restarts"
    fi
}

disable_dockerlog() {
    if [ ! -f /etc/docker/daemon.json ]; then log_info_t "daemon.json нет — нечего отключать" \
"There is no daemon.json — nothing to turn off"; return; fi
    if ask_yn_t "Убрать лимиты логов из daemon.json?" "Remove the log limits from daemon.json?" N; then
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
        log_success_t "Лимиты убраны из daemon.json" \
"Limits removed from daemon.json"
        ask_yn_t "Перезапустить Docker сейчас?" "Restart Docker now?" N && { systemctl restart docker && log_success_t "Docker перезапущен" \
"Docker restarted"; }
    fi
}
