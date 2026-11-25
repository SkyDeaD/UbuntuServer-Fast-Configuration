# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.

# authkeys_add <файл> <строка> — дописать ключ отдельной строкой. Если файл
# кончается без перевода строки (правили руками), новый ключ приклеился бы
# к последнему, и оба перестали бы работать
authkeys_add() {
    local f="$1" line="$2"
    if [ -s "$f" ] && [ -n "$(tail -c1 "$f" 2>/dev/null)" ]; then
        printf '\n%s\n' "$line" | append_file "$f"
    else
        printf '%s\n' "$line" | append_file "$f"
    fi
}

# Единый шаблон строки публичного ключа: поддерживает и обычные ключи,
# и записи с ведущими опциями (restrict, from="1.2.3.4", no-pty и т. п.)
SSHKEYS_LINE_RE='(^|[[:space:]])(ssh-(ed25519|rsa|dss)|ecdsa-sha2-[a-z0-9]+|sk-(ssh|ecdsa)-[^[:space:]]+)[[:space:]]+[A-Za-z0-9+/]'

# sshkeys_line_matches <строка> — строка похожа на запись authorized_keys
# (пустые строки, комментарии и многострочный ввод отвергаются)
sshkeys_line_matches() {
    local line="${1:-}"
    line="${line%$'\r'}"
    [[ "$line" == *$'\n'* ]] && return 1
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && return 1
    [[ "$line" =~ $SSHKEYS_LINE_RE ]]
}

# sshkeys_validate_line <строка> → REPLY_SSHKEY_FP
# Проверяет формат и (если доступен ssh-keygen и не сухой прогон) реальную
# криптографическую структуру ключа через ssh-keygen -lf -.
REPLY_SSHKEY_FP=''
sshkeys_validate_line() {
    local line="${1:-}" fp
    line="${line%$'\r'}"
    REPLY_SSHKEY_FP=''
    sshkeys_line_matches "$line" || return 1
    if [ "${USFC_DRY_RUN:-false}" != true ] && command -v ssh-keygen >/dev/null 2>&1; then
        fp="$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null)" || return 1
        fp="${fp%$'\r'}"
        [ -n "$fp" ] || return 1
        REPLY_SSHKEY_FP="$fp"
    fi
    return 0
}

# authkeys_count <файл> → REPLY_AUTHKEYS_COUNT — сколько в нём ключей. Ключи
# бывают и с опциями впереди (`restrict ssh-ed25519 …`), поэтому тип ключа
# ищем в любом поле, а не только в начале строки; комментарии не считаются
REPLY_AUTHKEYS_COUNT=0
authkeys_count() {
    REPLY_AUTHKEYS_COUNT="$(grep -vE '^[[:space:]]*#' "$1" 2>/dev/null \
        | grep -cE "$SSHKEYS_LINE_RE")"
    [[ "$REPLY_AUTHKEYS_COUNT" =~ ^[0-9]+$ ]] || REPLY_AUTHKEYS_COUNT=0
}

# ── sudo без пароля ──────────────────────────────────────────────────────────
# Пользователь «только по ключу» с заблокированным паролем в группе sudo
# не может sudo вовсе: правило %sudo требует пароль. Раньше NOPASSWD
# ставился только в SSH hardening и только после его успеха — пункт
# «новый пользователь» сам по себе оставлял сервер без рабочего админа.
SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"

# sudo_nopasswd_file <пользователь> → REPLY_SUDOERS. Точку в имени файла
# sudo молча пропускает (как и ~ в конце), поэтому она заменяется
REPLY_SUDOERS=''
sudo_nopasswd_file() { REPLY_SUDOERS="${SUDOERS_DIR}/90-usfc-${1//./_}"; }

# sudo_nopasswd_set <пользователь> — уже настроено (наш файл или файл до 5.0)
sudo_nopasswd_set() {
    sudo_nopasswd_file "$1"
    [ -f "$REPLY_SUDOERS" ] || [ -f "${SUDOERS_DIR}/$1" ]
}

# sudo_nopasswd <пользователь> — записать drop-in, проверив его visudo
sudo_nopasswd() {
    local user="$1" tmp rc=0
    if sudo_nopasswd_set "$user"; then
        log_info_t "sudo без пароля для ${user} уже настроен" \
"Passwordless sudo for ${user} is already set up"
        return 0
    fi
    sudo_nopasswd_file "$user"
    tmp="$(mktemp)" || return 1
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" > "$tmp"
    if ! visudo -cf "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        log_error_t "visudo отверг правило для ${user} — sudoers не трогаю" \
"visudo rejected the rule for ${user} — leaving sudoers alone"
        return 1
    fi
    # Снимок делаем до umask 0277, чтобы служебный файл снимка не стал 0400,
    # а сам sudoers создаётся сразу закрытым — без окна прав 0644
    backup_file "$REPLY_SUDOERS"
    ( umask 0277; write_file "$REPLY_SUDOERS" < "$tmp" ) || rc=$?
    rm -f "$tmp"
    [ "$rc" -eq 0 ] || return 1
    chmod 440 "$REPLY_SUDOERS"
    log_success_t "sudo без пароля для ${user}: ${REPLY_SUDOERS}" \
"Passwordless sudo for ${user}: ${REPLY_SUDOERS}"
}

# ── Общая работа с ~/.ssh ─────────────────────────────────────────────────────
# Специально без `sudo -u`: на голом root-образе (а это ровно наш сценарий, когда
# пользователя ещё не создали) sudo может быть не установлен вообще, и такие
# строки падали бы молча. install(1) умеет владельца и права сам, без подмены uid.
REPLY_AUTHKEYS=''

ensure_ssh_dir() {
    local user="$1" home="$2" dir="${2}/.ssh" gid
    gid="$(id -g "$user" 2>/dev/null)" || gid="$user"
    install -d -o "$user" -g "$gid" -m 700 "$dir" || return 1
    REPLY_AUTHKEYS="${dir}/authorized_keys"
    if [ -f "$REPLY_AUTHKEYS" ]; then
        chown "${user}:${gid}" "$REPLY_AUTHKEYS"
        chmod 600 "$REPLY_AUTHKEYS"
    else
        install -o "$user" -g "$gid" -m 600 /dev/null "$REPLY_AUTHKEYS" || return 1
    fi
}

# ensure_user_dir <путь внутри TARGET_HOME> — создать каталог так, чтобы КАЖДЫЙ
# уровень принадлежал пользователю.
#
# `install -d -o user …/.config/fastfetch` даёт владельца только последнему
# компоненту: промежуточный ~/.config создавался от root, и btop потом не мог
# завести ~/.config/btop («could not be created: Permission denied … config
# changes are not persistent»). Здесь каждый уровень создаётся отдельно, а
# уже существующий, но root-овый каталог внутри домашнего — машины, настроенные
# до 5.0, — возвращается пользователю. Рекурсивного chown нет: чинится ровно
# путь, который мы сами и испортили
ensure_user_dir() {
    local target="$1" gid cur part
    local -a parts
    case "$target" in
        "$TARGET_HOME"/*) ;;
        *) install -d -m 755 "$target"; return ;;
    esac
    gid="$(id -g "$TARGET_USER" 2>/dev/null)" || gid="$TARGET_USER"
    IFS='/' read -ra parts <<< "${target#"$TARGET_HOME"/}"
    cur="$TARGET_HOME"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        cur="${cur}/${part}"
        if [ ! -d "$cur" ]; then
            install -d -o "$TARGET_USER" -g "$gid" -m 755 "$cur" || return 1
        elif [ "$TARGET_USER" != root ] && [ "$(stat -c %u "$cur" 2>/dev/null)" = 0 ]; then
            chown "${TARGET_USER}:${gid}" "$cur"
        fi
    done
}

# sshkeys_import_spec <auth_keys> <spec> — добавляет ключи в authorized_keys.
# Поддерживает:
#   gh:<user> — скачивает https://github.com/<user>.keys
#   gl:<user> — скачивает https://gitlab.com/<user>.keys
#   одиночный публичный ключ одной строкой
# Возвращает 0, только если хотя бы один корректный ключ добавлен или уже был.
sshkeys_import_spec() {
    local auth_keys="$1" spec="${2:-}"
    spec="${spec%$'\r'}"
    spec="${spec#"${spec%%[![:space:]]*}"}"
    spec="${spec%"${spec##*[![:space:]]}"}"
    if [ -z "$spec" ]; then
        log_info_t "Пусто — ключ не добавлен" \
"Empty — no key added"
        return 1
    fi
    case "$spec" in
        gh:*|gl:*)
            local provider="${spec%%:*}" user="${spec#*:}" url body line added=0 skipped=0 invalid=0
            if [[ ! "$user" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,38}$ ]] || [[ "$user" == *..* ]]; then
                log_error_t "Недопустимое имя пользователя «${user}» для ${provider}:" \
"Invalid username \"${user}\" for ${provider}:"
                return 1
            fi
            if [ "$provider" = gh ]; then
                url="https://github.com/${user}.keys"
            else
                url="https://gitlab.com/${user}.keys"
            fi
            if [ "${USFC_DRY_RUN:-false}" = true ]; then
                t "импорт SSH-ключей из ${url} в ${auth_keys}" \
                  "import SSH keys from ${url} to ${auth_keys}"
                _dry_say "$REPLY_T"
                return 0
            fi
            if ! command -v curl >/dev/null 2>&1; then
                log_error_t "Не найден curl — не могу скачать ключи из ${url}" \
"curl not found — cannot download keys from ${url}"
                return 1
            fi
            log_info_t "Скачиваю публичные ключи: ${url}" \
"Downloading public keys: ${url}"
            if ! body="$(curl -fsSL --proto '=https' --max-time 15 "$url" 2>/dev/null)"; then
                log_error_t "Не удалось скачать ключи из ${url}" \
"Could not download keys from ${url}"
                return 1
            fi
            while IFS= read -r line || [ -n "$line" ]; do
                line="${line%$'\r'}"
                [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
                if ! sshkeys_validate_line "$line"; then
                    invalid=$((invalid + 1))
                    continue
                fi
                if grep -qxF -- "$line" "$auth_keys" 2>/dev/null; then
                    skipped=$((skipped + 1))
                    continue
                fi
                authkeys_add "$auth_keys" "$line" || return 1
                added=$((added + 1))
                if [ -n "$REPLY_SSHKEY_FP" ]; then
                    log_info_t "Добавлен ключ: ${REPLY_SSHKEY_FP}" \
"Added key: ${REPLY_SSHKEY_FP}"
                fi
            done <<< "$body"
            if [ "$invalid" -gt 0 ]; then
                log_warn_t "Пропущено некорректных строк: ${invalid}" \
"Skipped invalid lines: ${invalid}"
            fi
            if [ "$added" -gt 0 ]; then
                log_success_t "Импортировано ключей из ${spec}: ${added}" \
"Imported keys from ${spec}: ${added}"
                return 0
            fi
            if [ "$skipped" -gt 0 ]; then
                log_info_t "Все ключи из ${spec} уже есть (${skipped})" \
"All keys from ${spec} are already there (${skipped})"
                return 0
            fi
            log_error_t "По адресу ${url} не найдено корректных публичных SSH-ключей" \
"No valid SSH public keys found at ${url}"
            return 1
            ;;
        *)
            if ! sshkeys_validate_line "$spec"; then
                log_error_t "Не похоже на корректный публичный SSH-ключ — не добавляю" \
"Does not look like a valid SSH public key — not adding it"
                return 1
            fi
            if grep -qxF -- "$spec" "$auth_keys" 2>/dev/null; then
                log_info_t "Такой ключ уже есть" \
"That key is already there"
                return 0
            fi
            authkeys_add "$auth_keys" "$spec" || return 1
            if [ -n "$REPLY_SSHKEY_FP" ]; then
                log_success_t "Ключ добавлен (${REPLY_SSHKEY_FP})" \
"Key added (${REPLY_SSHKEY_FP})"
            else
                log_success_t "Ключ добавлен" \
"Key added"
            fi
            return 0
            ;;
    esac
}

# просит вставить публичный ключ (или gh:<user> / gl:<user>) и дописывает
# его в authorized_keys. Возвращает 0, только если ключ реально добавлен
# (или уже был) — на это опирается apply_newuser, решая, можно ли оставить
# пользователя без пароля
add_pubkey_interactive() {
    local auth_keys="$1" pubkey_line prompt_q prompt_h
    t "Публичный SSH-ключ или импорт" "SSH public key or import"; prompt_q="$REPLY_T"
    t "ключ одной строкой, gh:<user> или gl:<user>" "one-line key, gh:<user>, or gl:<user>"; prompt_h="$REPLY_T"
    ui_prompt "$prompt_q" "$prompt_h"
    read -r pubkey_line </dev/tty || pubkey_line=""
    sshkeys_import_spec "$auth_keys" "$pubkey_line"
}
