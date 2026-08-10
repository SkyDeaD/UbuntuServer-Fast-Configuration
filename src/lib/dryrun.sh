# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# ═══════════════════════════════════════════════════════════════
# Сухой прогон: подмена изменяющих команд
# ═══════════════════════════════════════════════════════════════
# Перехвата на узких местах (run_logged, apt_get, apply_service_autostart)
# оказалось мало. Живой прогон на Ubuntu 26.04 показал, что `--dry-run`
# ВСЁ РАВНО менял систему: писал /etc/apt/sources.list.d/docker.list,
# дёргал chmod и usermod. Сухой прогон, который что-то меняет, хуже, чем
# его отсутствие: ему верят.
#
# Обходить это оборачиванием каждого вызова нельзя — таких мест около сотни,
# и забытое однажды место молча вернёт ту же ложь. Поэтому подменяем сами
# команды shell-функциями: функция перебивает внешнюю команду, и одно место
# закрывает все вызовы разом, включая те, что появятся потом.
#
# Читающие вызовы (systemctl is-active, swapon --show, sed без -i) пропускаем
# наружу: без них сухой прогон врал бы уже про текущее состояние системы.
#
# Полноту этого списка проверяет не глаз, а тест: tests/test_dryrun.sh
# сверяет слепок /etc, dpkg и юнитов systemd до и после `--apply all --dry-run`.

_dry_say() { printf '  %b[сухой прогон]%b %s\n' "$DIM" "$NC" "$*"; }

# write_file <путь> — записать stdin в файл. Перенаправления (`> /etc/...`)
# функцией не перехватить, поэтому места записи в системные файлы зовут это.
write_file() {
    if [ "$USFC_DRY_RUN" = true ]; then
        _dry_say "запись в ${1}"
        cat >/dev/null
        return 0
    fi
    cat > "$1"
}

# append_file <путь> — то же, но дописать в конец
append_file() {
    if [ "$USFC_DRY_RUN" = true ]; then
        _dry_say "дозапись в ${1}"
        cat >/dev/null
        return 0
    fi
    cat >> "$1"
}

dry_run_enable() {
    [ "$USFC_DRY_RUN" = true ] || return 0

    # Безусловно изменяющие
    usermod()  { _dry_say "usermod $*"; }
    useradd()  { _dry_say "useradd $*"; }
    deluser()  { _dry_say "deluser $*"; }
    gpasswd()  { _dry_say "gpasswd $*"; }
    # shellcheck disable=SC2120  # аргументы приходят из подменённых вызовов
    chpasswd() { _dry_say "chpasswd $*"; cat >/dev/null; }
    passwd()   { _dry_say "passwd $*"; }
    install()  { _dry_say "install $*"; }
    chmod()    { _dry_say "chmod $*"; }
    chown()    { _dry_say "chown $*"; }
    mkdir()    { _dry_say "mkdir $*"; }
    ln()       { _dry_say "ln $*"; }
    mkswap()   { _dry_say "mkswap $*"; }
    fallocate(){ _dry_say "fallocate $*"; }
    dd()       { _dry_say "dd $*"; }
    ufw()      { _dry_say "ufw $*"; }
    add-apt-repository() { _dry_say "add-apt-repository $*"; }

    # rm не трогаем: он в основном убирает временные файлы, и запрет
    # оставлял бы мусор. В системные пути rm тут не ходит

    # Ниже — команды, у которых есть и читающие режимы

    systemctl() {
        case "${1:-}" in
            is-active|is-enabled|is-failed|is-system-running|show|cat|status|list-units|list-unit-files)
                command systemctl "$@" ;;
            *) _dry_say "systemctl $*" ;;
        esac
    }

    swapon() {
        case " $* " in
            *" --show"*|*" -s "*) command swapon "$@" ;;
            *) _dry_say "swapon $*" ;;
        esac
    }
    swapoff() { _dry_say "swapoff $*"; }

    sed() {
        # мутирует только с -i
        local a
        for a in "$@"; do
            case "$a" in -i|-i*|--in-place*) _dry_say "sed $*"; return 0 ;; esac
        done
        command sed "$@"
    }

    sysctl() {
        case " $* " in
            *" -w "*|*" --system"*|*" -p"*) _dry_say "sysctl $*" ;;
            *) command sysctl "$@" ;;
        esac
    }

    log_info "Сухой прогон: изменяющие команды перехвачены, система не изменится"
}
