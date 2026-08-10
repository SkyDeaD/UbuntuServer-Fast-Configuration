# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

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

# Цвет выключается, если пользователь об этом попросил или если его некому
# увидеть. Три общепринятых условия (no-color.org и clig.dev: «Disable color if
# your program is not in a terminal or the user requested it»):
#   * NO_COLOR непустая — значение неважно, важен сам факт;
#   * TERM=dumb — терминал не умеет управляющие последовательности;
#   * stdout не терминал — вывод уехал в файл или в пайп, escape-коды там мусор.
# Разметка от этого не ломается: visible_len/pad_title корректно считают длину
# при пустых цветовых переменных, это покрыто тестами.
if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ] || [ ! -t 1 ]; then
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BLUE=''; MAGENTA=''
    BOLD=''; DIM=''; NC=''
    USFC_NO_COLOR=true
else
    USFC_NO_COLOR=false
fi

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

# Состояние свопа — заполняется read_swap_state(). Объявлены здесь, чтобы
# обращение к ним до первого вызова не роняло скрипт из-за `set -u`
ZRAM_ACTIVE=false; ZRAM_PRIO=""
SWAP_ACTIVE=false; SWAP_PRIO=""; SWAP_PATH=""
SWAP_TYPE=""; SWAP_SIZE_MB=0; SWAP_USED_MB=0
