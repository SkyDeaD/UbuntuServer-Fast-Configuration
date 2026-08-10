# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# dnsutils в Ubuntu 26.04 — виртуальный пакет (алиас), apt install его резолвит,
# но в списке установленных его нет; реальное имя пакета — bind9-dnsutils.
# certbot и python3-certbot-nginx отсюда сознательно убраны: TLS — это сервис со
# своими плагинами и секретами, ему выделен отдельный пункт меню (apply_certbot)
BASE_PKGS="micro curl wget git nano unzip htop bind9-dnsutils jq ca-certificates gnupg rsync"
# software-properties-common нужен только ради add-apt-repository, то есть
# только под PPA fastfetch, то есть только на Ubuntu. В Debian 13 такого пакета
# в репозиториях нет вовсе, и он делал бы пункт вечно «не применённым»
os_is_ubuntu && BASE_PKGS="${BASE_PKGS} software-properties-common"

# ── Пункт меню: Базовые пакеты ─────────────────────────────────────────
usfc_item basepkgs база "Базовые пакеты" \
    "micro, curl, git, htop, jq и прочая база" \
    "Base packages" \
    "micro, curl, git, htop, jq and the usual basics"

usfc_item_full basepkgs "micro, curl, wget, git, nano, unzip, htop, jq, rsync и ещё несколько вещей,
которые обычно ставишь в первую же минуту на любом сервере. В том числе
software-properties-common, без которого не заработает add-apt-repository,
нужный дальше для PPA fastfetch.

После установки выводится список: что приехало сейчас, что уже стояло,
и коротко — зачем каждый пакет нужен."


usfc_item_rollback basepkgs "sudo apt purge micro unzip htop bind9-dnsutils jq rsync
     (осторожно: curl/git/ca-certificates часто нужны другим программам — не удаляй не глядя)"

status_basepkgs() {
    local p missing=""
    for p in $BASE_PKGS; do
        pkg_installed "$p" || missing="${missing}${missing:+, }${p}"
    done
    if [ -n "$missing" ]; then
        echo -e "${DIM}○ не хватает: ${missing}${NC}"; return 1
    fi
    echo -e "${GREEN}✓ установлено${NC}"; return 0
}

apply_basepkgs() {
    if ask_yn "Установить базовый набор пакетов (${BASE_PKGS})?"; then
        ensure_apt_updated
        # shellcheck disable=SC2086
        snapshot_pkgs $BASE_PKGS
        # shellcheck disable=SC2086
        run_logged "Базовый набор пакетов" apt_get install -y $BASE_PKGS
        refresh_pkg_cache
        # shellcheck disable=SC2086
        show_pkg_report $BASE_PKGS
    fi
}
