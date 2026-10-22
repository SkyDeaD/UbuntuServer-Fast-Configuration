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

# Вопросы пакетного режима (см. lib/bulk.sh)
preask_dockerlog() {
    # перезапуск имеет смысл, только если Docker уже работает: свежий
    # Docker из этого же прогона прочитает daemon.json при старте сам
    service_is_up docker || return 0
    echo ""
    log_info_t "Лимит логов Docker применится после перезапуска демона — а с ним перезапустятся ВСЕ контейнеры" \
"The Docker log limit takes effect after the daemon restarts — and EVERY container restarts with it"
    ask_yn_t "Перезапустить Docker сразу после настройки?" "Restart Docker right after configuring it?" N \
        && DOCKER_RESTART_BULK=Y || DOCKER_RESTART_BULK=N
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
    # JSON собирает python, а пишет write_file: раньше python писал файл сам,
    # мимо снимка для отката и мимо сухого прогона. Битый daemon.json не
    # затираем молча пустым — Docker с ним всё равно не стартует, и чинить
    # его надо руками, зная, что там было
    local merged
    if ! merged="$(python3 - /etc/docker/daemon.json <<'PYEOF'
import json, sys, os
path = sys.argv[1]
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        sys.exit(3)
data["log-driver"] = "json-file"
data.setdefault("log-opts", {})
data["log-opts"]["max-size"] = "10m"
data["log-opts"]["max-file"] = "3"
print(json.dumps(data, indent=2))
PYEOF
)"; then
        log_error_t "/etc/docker/daemon.json — не JSON, не трогаю. Поправь его руками и повтори" \
"/etc/docker/daemon.json is not valid JSON — leaving it alone. Fix it by hand and retry"
        return 1
    fi
    printf '%s\n' "$merged" | write_file /etc/docker/daemon.json
    log_success_t "daemon.json обновлён" \
"daemon.json updated"
    # Перезапуск Docker роняет ВСЕ контейнеры, поэтому в пакетном режиме он
    # только по явному ответу — и --yes его не включает
    local restart=false
    if [ "$BULK_MODE" = true ]; then
        [ "$DOCKER_RESTART_BULK" = Y ] && restart=true
    # bulk-ok: пакетная ветка — строкой выше
    elif ask_yn_t "Перезапустить Docker сейчас? ВСЕ контейнеры перезапустятся вместе с демоном" "Restart Docker now? EVERY container restarts together with the daemon" N; then
        restart=true
    fi
    if [ "$restart" = true ]; then
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
        local stripped
        if ! stripped="$(python3 - /etc/docker/daemon.json <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception:
    sys.exit(3)
data.pop("log-opts", None)
if data.get("log-driver") == "json-file":
    data.pop("log-driver", None)
print(json.dumps(data, indent=2))
PYEOF
)"; then
            log_error_t "/etc/docker/daemon.json — не JSON, не трогаю" \
"/etc/docker/daemon.json is not valid JSON — leaving it alone"
            return 1
        fi
        printf '%s\n' "$stripped" | write_file /etc/docker/daemon.json
        log_success_t "Лимиты убраны из daemon.json" \
"Limits removed from daemon.json"
        ask_yn_t "Перезапустить Docker сейчас?" "Restart Docker now?" N && { systemctl restart docker && log_success_t "Docker перезапущен" \
"Docker restarted"; }
    fi
}
