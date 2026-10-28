# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# Пакеты CLI-набора вынесены в переменную: их перечисляли в трёх местах
# (status_cli, apply_cli, установка), и списки уже начинали расходиться
CLI_PKGS="bat fd-find ripgrep zoxide ncdu btop"
# Версия блока алиасов в ~/.bashrc. Поднимать при КАЖДОМ изменении его
# содержимого — по ней apply_cli понимает, что блок надо переписать
# (v3: функции ports, dps, extract, myip)
CLI_BLOCK_MARK="# usfc:cli-block v4"
# eza приехал в Debian только с trixie. На bookworm его нет, и без этой ветки
# пункт вечно показывал бы «не хватает: eza» — состояние, которое пользователь
# не может исправить, потому что пакета попросту не существует
if os_is_ubuntu || os_version_at_least 13; then
    CLI_PKGS="eza ${CLI_PKGS}"
fi
# ── Пункт меню: CLI-утилиты + starship ─────────────────────────────────────────
usfc_item cli база "CLI-утилиты + starship" \
    "современные замены ls/cat/find + промпт" \
    "CLI tools + starship" \
    "modern ls/cat/find replacements plus a prompt"

usfc_item_full cli "Современные замены классических утилит: eza вместо ls с иконками, bat вместо
cat с подсветкой, fd вместо find, ripgrep для поиска по содержимому, zoxide —
«умный» cd, ncdu для разбора места на диске, btop вместо htop. Плюс промпт
starship.

Всё вместе, потому что это один и тот же слой «как выглядит и ощущается
терминал». Алиасы в .bashrc и eval-строки для zoxide/starship пишутся сразу
этим же пунктом. Список алиасов — на экране H.

Вид промпта — один из трёх пресетов в ~/.config/starship.toml: minimal
(пользователь@хост, каталог), git (плюс ветка, статус, время, длительность
команды) и powerline (цветные плашки, обычный Unicode без nerd-шрифтов).
Имя хоста показывается всегда: зелёным, а на боевом сервере (спрашивается) —
красным. Чужой starship.toml не перезаписывается.

В блок .bashrc добавлены функции: ports (слушающие порты), dps (компактный
docker ps), extract (распаковка любого архива), myip (внешний и локальные IP)." \
"Modern replacements for the classic tools: eza instead of ls with icons, bat
instead of cat with syntax highlighting, fd instead of find, ripgrep for
searching file contents, zoxide as a smarter cd, ncdu for finding what ate
the disk, btop instead of htop. Plus the starship prompt.

All in one item, because this is a single layer: how the terminal looks and
feels. Aliases in .bashrc and the eval lines for zoxide/starship are written
by the same item. The alias list is on screen H.

The prompt is one of three presets in ~/.config/starship.toml: minimal
(user@host, directory), git (plus branch, status, time, command duration) and
powerline (colored plates, plain Unicode, no nerd fonts). The hostname is
always shown: green, or red on a production server (you are asked). A
starship.toml that was not made by usfc is never overwritten.

The .bashrc block also gets functions: ports (listening ports), dps (compact
docker ps), extract (unpack any archive), myip (external and local IPs)."


usfc_item_rollback cli "sudo apt purge eza bat fd-find ripgrep zoxide ncdu btop
     sudo rm -f \"\$(command -v starship)\"   # если ставился этим же пунктом
     rm -f ~/.config/starship.toml            # пресет промпта; блок vps-setup:cli убери из ~/.bashrc" \
"sudo apt purge eza bat fd-find ripgrep zoxide ncdu btop
     sudo rm -f \"\$(command -v starship)\"   # if it was installed by this item
     rm -f ~/.config/starship.toml            # the prompt preset; remove the vps-setup:cli block from ~/.bashrc"

status_cli() {
    local c missing=""
    # $CLI_PKGS объявляется ниже по файлу, но присваивание верхнего уровня
    # отрабатывает до первого вызова этой функции — читать безопасно
    for c in $CLI_PKGS; do
        pkg_installed "$c" || missing="${missing}${missing:+, }${c}"
    done
    command -v starship &>/dev/null || missing="${missing}${missing:+, }starship"
    if [ -n "$missing" ]; then
        st "$DIM" "○ не хватает: ${missing}" "○ missing: ${missing}"; return 1
    fi
    if ! grep -qF "# >>> vps-setup:cli >>>" "${TARGET_HOME}/.bashrc" 2>/dev/null; then
        st "$YELLOW" "! всё стоит, алиасов в .bashrc нет" "! all installed, no aliases in .bashrc"; return 1
    fi
    # Устаревший блок — это «не применено»: иначе повторный выбор пункта
    # считался бы лишним, и новые алиасы/функции не доехали бы до машины
    if ! grep -qF "$CLI_BLOCK_MARK" "${TARGET_HOME}/.bashrc" 2>/dev/null; then
        st "$YELLOW" "! блок в .bashrc устарел — выбери пункт, чтобы обновить" "! the .bashrc block is outdated — select the item to update it"; return 1
    fi
    st "$GREEN" "✓ установлено" "✓ installed"; return 0
}

apply_cli() {
    local need_install=false p rc=0
    for p in $CLI_PKGS; do
        pkg_installed "$p" || need_install=true
    done
    command -v starship &>/dev/null || need_install=true

    if [ "$need_install" = true ]; then
        if ask_yn_t "Установить ${CLI_PKGS// /, }, starship?" "Install ${CLI_PKGS// /, }, starship?"; then
            ensure_apt_updated
            # shellcheck disable=SC2086
            snapshot_pkgs $CLI_PKGS
            # shellcheck disable=SC2086
            t "CLI-утилиты (${CLI_PKGS// /, })" "CLI tools (${CLI_PKGS// /, })"
    run_logged "$REPLY_T" apt_get install -y $CLI_PKGS
            refresh_pkg_cache
            # -f и pipefail: без них страница ошибки уходила в sh, а упавший
            # curl отдавал sh пустой ввод — и шаг рапортовал успех без starship
            if ! command -v starship &>/dev/null; then
                run_logged "starship" bash -c 'set -o pipefail; curl -fsSL --max-time 60 https://starship.rs/install.sh | sh -s -- -y'
                [ "$USFC_DRY_RUN" = true ] || command -v starship &>/dev/null || { log_error_t "starship не установился — подробности в ${USFC_LOG}" \
"starship did not install — details in ${USFC_LOG}"; rc=1; }
            fi
            # shellcheck disable=SC2086
            show_pkg_report $CLI_PKGS || rc=1
        fi
    else
        # Список берём из переменной, а не перечисляем руками: захардкоженная
        # строка уже разошлась бы с CLI_PKGS на добавлении btop
        log_success_t "${CLI_PKGS// /, } и starship уже установлены" \
"${CLI_PKGS// /, } and starship are already installed"
    fi

    # btop хранит настройки в ~/.config/btop. На машинах, настроенных до 5.0,
    # ~/.config мог остаться root-овым (см. ensure_user_dir) — чиним здесь,
    # раз уж этот пункт btop и ставит
    [ -d "${TARGET_HOME}/.config" ] && ensure_user_dir "${TARGET_HOME}/.config"
    cli_write_aliases || rc=1
    # Конфиг промпта — только если starship есть (в сухом прогоне его нет по
    # построению, но запись должна показаться)
    if [ "$USFC_DRY_RUN" = true ] || command -v starship &>/dev/null; then
        cli_write_starship || rc=1
    fi
    return "$rc"
}

# Функции блока (ports, dps, extract, myip). Текст пишется в .bashrc как есть,
# поэтому живёт в отдельной функции: так его можно вырезать и прогнать
# `bash -n` (tests/test_cli_block.sh). Сообщения — по-английски: блок
# исполняется в чужой оболочке и не знает про язык usfc.
#
# Форма `function имя {`, а не `имя() {`: если выше в .bashrc есть
# `alias ports='netstat -tulanp'`, bash раскроет алиас в `имя() {` и получит
# синтаксическую ошибку на каждом входе. После `function` слово алиасом не
# раскрывается. unalias — чтобы функция, а не старый алиас, была тем, что
# запускается по имени
cli_block_functions() {
    cat <<'FUNCS'
unalias ports dps extract myip 2>/dev/null
# ports: слушающие TCP/UDP-порты. Без root ss не отдаёт имена чужих процессов
function ports {
    command -v ss >/dev/null 2>&1 || { echo "ports: ss not found (install iproute2)" >&2; return 1; }
    ss -tulpnH 2>/dev/null | awk '
        BEGIN { printf "%-5s %-28s %s\n", "PROTO", "LOCAL", "PROCESS" }
        {
            proc = ""
            for (i = 6; i <= NF; i++) if ($i ~ /^users:/) proc = $i
            name = ""; pid = ""
            if (match(proc, /\(\("[^"]*"/)) name = substr(proc, RSTART + 3, RLENGTH - 4)
            if (match(proc, /pid=[0-9]+/)) pid = substr(proc, RSTART + 4, RLENGTH - 4)
            if (name != "") name = name " (" pid ")"
            printf "%-5s %-28s %s\n", $1, $5, name
        }'
    [ "$(id -u)" -eq 0 ] || echo "(process names of other users need root)" >&2
}
# dps: компактный docker ps; функция есть, только если docker стоял на старте оболочки
if command -v docker >/dev/null 2>&1; then
    function dps { docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' "$@"; }
fi
# extract: распаковка по расширению
_usfc_need() { command -v "$1" >/dev/null 2>&1 || { echo "extract: '$1' is not installed (needed for $2)" >&2; return 1; }; }
function extract {
    local f
    [ $# -gt 0 ] || { echo "usage: extract <archive>..." >&2; return 2; }
    for f in "$@"; do
        [ -f "$f" ] || { echo "extract: $f: no such file" >&2; return 1; }
        case "$f" in
            *.tar.gz|*.tgz)   _usfc_need tar "$f" && tar -xzf "$f" ;;
            *.tar.xz|*.txz)   _usfc_need tar "$f" && _usfc_need xz "$f" && tar -xJf "$f" ;;
            *.tar.bz2|*.tbz2) _usfc_need tar "$f" && _usfc_need bzip2 "$f" && tar -xjf "$f" ;;
            *.tar.zst)        _usfc_need tar "$f" && _usfc_need zstd "$f" && tar --zstd -xf "$f" ;;
            *.tar)            _usfc_need tar "$f" && tar -xf "$f" ;;
            *.zip)            _usfc_need unzip "$f" && unzip -q "$f" ;;
            *.gz)             _usfc_need gunzip "$f" && gunzip -k "$f" ;;
            *.bz2)            _usfc_need bunzip2 "$f" && bunzip2 -k "$f" ;;
            *.xz)             _usfc_need unxz "$f" && unxz -k "$f" ;;
            *.zst)            _usfc_need unzstd "$f" && unzstd -q "$f" ;;
            *.7z)             if command -v 7zz >/dev/null 2>&1; then 7zz x "$f"
                              elif command -v 7z >/dev/null 2>&1; then 7z x "$f"
                              else _usfc_need 7za "$f" && 7za x "$f"; fi ;;
            *) echo "extract: $f: unknown archive type" >&2; return 1 ;;
        esac || return 1
    done
}
# myip: внешний адрес (один запрос, 3 с) и локальные адреса
function myip {
    local ext
    ext="$(curl -fsS --max-time 3 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')"
    echo "external: ${ext:-unavailable}"
    echo "local:"
    ip -br addr 2>/dev/null | sed 's/^/  /'
}
FUNCS
}

# Запись блока алиасов в ~/.bashrc вынесена из apply_cli отдельно:
# иначе её не проверить тестом, не ставя при этом полтора десятка пакетов.
# Тест — tests/test_cli_block.sh.
cli_write_aliases() {
    # Блок пишем ВСЕГДА: ports/dps/extract/myip не зависят от установленных
    # утилит и полезны сами по себе. Алиасы же и промпт пишутся каждый только
    # если его утилита реально стоит. Прежняя проверка «нет ни eza, ни batcat»
    # пропускала смешанный случай: на Debian 12 batcat есть, а eza в
    # репозиториях нет вовсе — и alias ls='eza …' ломал ls в следующей
    # сессии. То же случалось бы на Ubuntu, если бы один пакет поставился,
    # а другой нет.
    local BASHRC="${TARGET_HOME}/.bashrc"
    # Версия блока, а не «блок вообще есть». Прежняя проверка выходила по факту
    # наличия маркера, и добавленный позже алиас не доезжал НИ ДО ОДНОЙ уже
    # настроенной машины — молча, потому что пункт при этом рапортовал успех.
    # Тот же приём уже применён для блока обёртки в lib/wrapper.sh.
    # Поднимать номер при каждом изменении содержимого блока.
    if grep -qF "# >>> vps-setup:cli >>>" "$BASHRC" 2>/dev/null; then
        if grep -qF "$CLI_BLOCK_MARK" "$BASHRC" 2>/dev/null; then
            log_info_t "Алиасы CLI-утилит в .bashrc уже есть" \
"CLI aliases are already in .bashrc"
            return
        fi
        log_info_t "Блок алиасов в .bashrc устарел — переписываю" \
"The alias block in .bashrc is outdated — rewriting it"
        remove_block "$BASHRC" vps-setup:cli || return 1
    fi
    {
        echo ""
        echo "# >>> vps-setup:cli >>>"
        echo "$CLI_BLOCK_MARK"
        if command -v eza &>/dev/null; then
            echo "alias ls='eza --icons --group-directories-first -1 --long --no-permissions --no-user --no-time'"
            echo "alias ll='eza -lah --icons --group-directories-first'"
            echo "alias la='eza -a --icons --group-directories-first -1 --long --no-permissions --no-user --no-time'"
            echo "alias lt='eza --tree --icons --level=2 --group-directories-first'"
        fi
        if command -v batcat &>/dev/null; then
            echo "alias cat='batcat --paging=never'"
            echo "alias catp='batcat'"
            echo "alias scat='sudo batcat --paging=never'"
        fi
        command -v fdfind &>/dev/null && echo "alias fd='fdfind'"
        # Ниже — проверки в момент ЗАПУСКА ОБОЛОЧКИ, а не установки: так алиас
        # не превратится в ссылку на несуществующую команду, если пакет потом
        # удалят. htop при этом остаётся установленным и доступен как \htop
        echo 'command -v btop &>/dev/null && alias htop="btop"'
        echo 'command -v zoxide &>/dev/null && eval "$(zoxide init bash)"'
        echo 'command -v starship &>/dev/null && eval "$(starship init bash)"'
        cli_block_functions
        echo "# <<< vps-setup:cli <<<"
    } | append_file "$BASHRC"
    chown -h "${TARGET_USER}:$(id -g "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$BASHRC"
    log_success_t "Алиасы и функции добавлены в .bashrc" \
"Aliases and functions added to .bashrc"
}

# ── starship: пресеты ~/.config/starship.toml ─────────────────────────────────
# Версия конфигов. Поднимать при изменении текста любого пресета: по ней
# повторный прогон понимает, что файл надо переписать
CLI_STARSHIP_VER=1

# cli_starship_toml <пресет> <Y|N> — текст конфига в stdout.
# Хост показываем ВСЕГДА (ssh_only = false): у starship по умолчанию он виден
# только в ssh-сессии, а на сервере его надо видеть и в консоли провайдера,
# и после `sudo -i`/`su` (там SSH_CONNECTION уже нет), и в tmux, поднятом
# давно. Цвет несёт роль: красный — боевой, зелёный — остальные.
# Только обычный Unicode и 16 цветов терминала: nerd-font-значки (в том числе
# git_branch.symbol по умолчанию) на сервере без шрифта превращаются в «тофу»
cli_starship_toml() {
    local preset="$1" prod="$2" hstyle hbg
    if [ "$prod" = Y ]; then hstyle="bold red"; hbg="fg:white bg:red"
    else hstyle="bold green"; hbg="fg:black bg:green"; fi
    printf '# usfc:starship v%s preset=%s prod=%s\n' "$CLI_STARSHIP_VER" "$preset" "$prod"
    # i18n-ok: комментарий в генерируемом файле, не вывод usfc
    printf '# Создано usfc. Пока эта строка на месте, usfc может обновить файл;\n'
    # i18n-ok: комментарий в генерируемом файле, не вывод usfc
    printf '# удали её, если правишь вручную, — тогда usfc файл не тронет.\n'
    case "$preset" in
    minimal)
        cat <<EOF
format = "\$username\$hostname\$directory\$character"

[username]
show_always = true
format = "[\$user](\$style)@"
style_user = "bold yellow"
style_root = "bold red"

[hostname]
ssh_only = false
format = "[\$hostname](\$style) "
style = "${hstyle}"

[directory]
truncation_length = 3
read_only = " ro"
style = "bold cyan"
format = "[\$path](\$style)[\$read_only](\$read_only_style) "

[character]
success_symbol = '[\\$](bold green)'
error_symbol = '[\\$](bold red)'
EOF
        ;;
    git)
        cat <<EOF
format = "\$username\$hostname\$directory\$git_branch\$git_status\$cmd_duration\$time\$character"

[username]
show_always = true
format = "[\$user](\$style)@"
style_user = "bold yellow"
style_root = "bold red"

[hostname]
ssh_only = false
format = "[\$hostname](\$style) "
style = "${hstyle}"

[directory]
truncation_length = 3
read_only = " ro"
style = "bold cyan"
format = "[\$path](\$style)[\$read_only](\$read_only_style) "

[git_branch]
symbol = ""
format = "on [\$branch](\$style) "
style = "bold purple"

[git_status]
format = "([\$all_status\$ahead_behind](\$style) )"
style = "bold red"

[cmd_duration]
min_time = 2000
format = "took [\$duration](\$style) "
style = "bold yellow"

[time]
disabled = false
time_format = "%H:%M"
format = "[\$time](\$style) "
style = "dimmed white"

[character]
success_symbol = '[\\$](bold green)'
error_symbol = '[\\$](bold red)'
EOF
        ;;
    powerline)
        cat <<EOF
format = "\$username\$hostname\$directory\$git_branch\$git_status\$cmd_duration\$time\$character"

[username]
show_always = true
format = "[ \$user](\$style)"
style_user = "fg:black bg:white"
style_root = "fg:white bg:red"

[hostname]
ssh_only = false
format = "[@\$hostname ](\$style)"
style = "${hbg}"

[directory]
truncation_length = 3
read_only = " ro"
style = "fg:white bg:blue"
format = "[ \$path\$read_only ](\$style)"

[git_branch]
symbol = ""
format = "[ \$branch ](\$style)"
style = "fg:black bg:yellow"

[git_status]
format = "([\$all_status\$ahead_behind ](\$style))"
style = "fg:black bg:yellow"

[cmd_duration]
min_time = 2000
format = "[ \$duration ](\$style)"
style = "fg:white bg:purple"

[time]
disabled = false
time_format = "%H:%M"
format = "[ \$time ](\$style)"
style = "fg:white bg:bright-black"

[character]
format = " \$symbol "
success_symbol = '[\\$](bold green)'
error_symbol = '[\\$](bold red)'
EOF
        ;;
    esac
}

# cli_starship_foreign — 0, если starship.toml есть и он НЕ наш (без маркера)
cli_starship_foreign() {
    local cfg="${TARGET_HOME}/.config/starship.toml"
    [ -f "$cfg" ] || return 1
    ! grep '^# usfc:starship ' "$cfg" >/dev/null 2>&1
}

# cli_starship_current → REPLY_T: пресет из маркера нашего файла (пусто, если нет)
cli_starship_current() {
    local line
    REPLY_T=''
    line="$(grep -m1 '^# usfc:starship ' "${TARGET_HOME}/.config/starship.toml" 2>/dev/null)" || return 0
    [[ "$line" =~ preset=([a-z]+) ]] && REPLY_T="${BASH_REMATCH[1]}"
    return 0
}

# cli_starship_norm <ввод> → REPLY_T: имя пресета или пусто. Принимает имя и 1/2/3
cli_starship_norm() {
    local v="${1,,}"
    case "$v" in
        1) v=minimal ;; 2) v=git ;; 3) v=powerline ;;
        minimal|git|powerline) ;;
        *) v='' ;;
    esac
    REPLY_T="$v"
}

# cli_ask_starship_preset → CLI_STARSHIP_PRESET. Дефолт: ответ из флага/файла,
# затем пресет из маркера уже записанного файла, затем minimal. В пакете
# ask_text_t сам возвращает дефолт, так что флаг --starship работает без вопроса
cli_ask_starship_preset() {
    local def tries=0
    cli_starship_norm "${STARSHIP_PRESET_BULK:-}"; def="$REPLY_T"
    if [ -z "$def" ]; then cli_starship_current; cli_starship_norm "$REPLY_T"; def="$REPLY_T"; fi
    [ -n "$def" ] || def=minimal
    if [ "$BULK_MODE" != true ]; then
        echo ""
        log_info_t "Вид промпта starship:" "Starship prompt style:"
        log_info_t "  1) minimal   — пользователь@хост, каталог, символ" \
"  1) minimal   — user@host, directory, symbol"
        log_info_t "  2) git       — плюс git-ветка и статус, время, длительность команды" \
"  2) git       — plus git branch and status, time, command duration"
        log_info_t "  3) powerline — цветные плашки (обычный Unicode, без nerd-шрифтов)" \
"  3) powerline — colored plates (plain Unicode, no nerd fonts)"
    fi
    while :; do
        ask_text_t "Пресет (имя или номер 1/2/3)" "Preset (name or number 1/2/3)" "$def"
        cli_starship_norm "$REPLY_TEXT"
        [ -n "$REPLY_T" ] && break
        tries=$((tries + 1))
        if [ "$tries" -ge 3 ] || [ "$BULK_MODE" = true ]; then
            log_warn_t "Не понял «${REPLY_TEXT}» — беру ${def}" "Did not understand \"${REPLY_TEXT}\" — using ${def}"
            REPLY_T="$def"; break
        fi
        log_warn_t "Нужно minimal, git, powerline или 1/2/3" "Expected minimal, git, powerline or 1/2/3"
    done
    CLI_STARSHIP_PRESET="$REPLY_T"
}

# Вопросы пакетного режима (см. lib/bulk.sh). Роль и пресет спрашиваем заранее,
# если их не задали флагом/файлом; чужой starship.toml не трогаем — и не спрашиваем
preask_cli() {
    cli_starship_foreign && return 0
    if [ -z "${STARSHIP_PRESET_BULK:-}" ]; then
        cli_ask_starship_preset
        STARSHIP_PRESET_BULK="$CLI_STARSHIP_PRESET"
    fi
    if [ -z "${STARSHIP_PROD_BULK:-}" ]; then
        ask_yn_t "Это боевой сервер (имя хоста в промпте красным)?" "Is this a production server (hostname in red in the prompt)?" N \
            && STARSHIP_PROD_BULK=Y || STARSHIP_PROD_BULK=N
    fi
}

# cli_write_starship — пресет в ~/.config/starship.toml
cli_write_starship() {
    local cfg="${TARGET_HOME}/.config/starship.toml" preset prod want tmp gid
    if cli_starship_foreign; then
        log_warn_t "${cfg} уже есть и создан не usfc — не перезаписываю. Убери файл или добавь первой строкой «# usfc:starship», чтобы отдать его usfc" \
"${cfg} already exists and was not made by usfc — not overwriting it. Remove the file or add a first line \"# usfc:starship\" to hand it over to usfc"
        return 0
    fi
    if [ -L "$cfg" ] && [ ! -e "$cfg" ]; then
        # запись через висячую ссылку создала бы файл по чужому пути
        log_warn_t "${cfg} — висячая ссылка, не пишу через неё. Убери ссылку и повтори" \
"${cfg} is a dangling symlink — not writing through it. Remove the link and retry"
        return 0
    fi
    cli_ask_starship_preset; preset="$CLI_STARSHIP_PRESET"
    # Роль «боевой» без явного ответа в пакете — НЕТ: --yes не должен молча
    # красить каждый сервер в красный (ask_bulk_yn под --yes отвечает «да»)
    if [ "$BULK_MODE" = true ] && [ -z "${STARSHIP_PROD_BULK:-}" ]; then
        prod=N
    elif ask_bulk_yn STARSHIP_PROD_BULK "Это боевой сервер (имя хоста в промпте красным)?" "Is this a production server (hostname in red in the prompt)?" N; then
        prod=Y
    else
        prod=N
    fi
    want="# usfc:starship v${CLI_STARSHIP_VER} preset=${preset} prod=${prod}"
    if [ -f "$cfg" ] && [ "$(head -n1 "$cfg")" = "$want" ]; then
        log_info_t "starship.toml уже настроен (пресет ${preset})" "starship.toml is already set up (preset ${preset})"
        return 0
    fi
    ensure_user_dir "${TARGET_HOME}/.config" || return 1
    tmp="$(mktemp)" || return 1
    cli_starship_toml "$preset" "$prod" > "$tmp"
    write_file "$cfg" < "$tmp"
    rm -f "$tmp"
    gid="$(id -g "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
    chown -h "${TARGET_USER}:${gid}" "$cfg"
    if [ "$prod" = Y ]; then
        log_success_t "starship: пресет ${preset}, боевой сервер (хост красным) → ${cfg}" \
"starship: preset ${preset}, production server (red host) → ${cfg}"
    else
        log_success_t "starship: пресет ${preset} (хост зелёным) → ${cfg}" \
"starship: preset ${preset} (green host) → ${cfg}"
    fi
}
