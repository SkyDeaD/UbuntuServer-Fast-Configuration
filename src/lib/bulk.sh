# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# Пакетный режим задаёт те же вопросы, что ручной, — только заранее
# ═══════════════════════════════════════════════════════════════
# В пакетном прогоне (раздел целиком, список пунктов, мастер, `usfc apply`)
# вопросы по ходу не задаются: ask_yn молча возвращает дефолт. До 5.0
# предзапрос жил здесь одним case на четыре пункта, а всё остальное тихо
# становилось дефолтом — TLS-заготовки certbot, автозапуск nginx/Docker,
# если они стоят, но не запущены, UFW, перезапуск Docker под ротацию логов.
# Раздел S поэтому применялся не так, как те же пункты, выбранные руками.
#
# Теперь предзапрос — часть пункта, как status_/apply_: пункт объявляет
# preask_<id>, и вопросы, которые он задаёт в apply_<id>, лежат рядом с ним.
# Ответы кладутся в *_BULK-переменные (их же наполняет файл ответов), а
# apply_<id> читает их через ask_bulk_yn. Забыть пару теперь можно только в
# одном файле, и это ловит tests/test_bulk_parity.sh.

# preask_bulk_answers <id пунктов...> — задать заранее все вопросы, которые
# в пакетном прогоне иначе молча стали бы дефолтами
# USFC_PREASK_IDS — весь выбранный список: предзапросу certbot надо знать,
# поставится ли nginx в этом же прогоне
USFC_PREASK_IDS=''
preask_bulk_answers() {
    local pid
    USFC_PREASK_IDS=" $* "
    for pid in "$@"; do
        declare -F "preask_${pid}" >/dev/null && "preask_${pid}"
    done
    return 0
}

# Заготовленные ответы живут ровно один прогон: иначе следующий пакетный
# запуск молча унаследовал бы токен и проценты от предыдущего.
# Список имён — единственный: его же обнуляет reset и проверяет тест
USFC_BULK_VARS=(
    ZRAM_BULK_PERCENT ZRAM_RECONF_BULK SWAP_BULK_MB SYSCTL_BULK
    NGINX_AUTOSTART DOCKER_AUTOSTART DOCKER_RESTART_BULK
    CERTBOT_CF_BULK CF_TOKEN_BULK CERTBOT_TLS_BULK
    UFW_BULK UFW_ALLOW_BULK UFW_FROM_BULK UFW_PING_BULK UFW_DOCKER_BULK
)
reset_bulk_answers() {
    local v
    for v in "${USFC_BULK_VARS[@]}"; do printf -v "$v" '%s' ''; done
}
reset_bulk_answers
