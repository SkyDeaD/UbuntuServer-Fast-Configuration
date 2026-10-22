# shellcheck shell=bash
# Модуль usfc: подключается из setup.sh, отдельно не запускается.
# Порядок загрузки — в src/MODULES.
# ── Пункт меню: SSH hardening ─────────────────────────────────────────
usfc_item sshhardening защита "SSH hardening" \
    "вход только по ключу, root-логин закрыт" \
    "SSH hardening" \
    "key-only login, root login disabled"

# ═══════════════════════════════════════════════════════════════
# Где лежит наш drop-in и почему он называется 00-…
# ═══════════════════════════════════════════════════════════════
# У sshd побеждает ПЕРВОЕ значение ключа, а drop-in'ы подключаются через
# `Include /etc/ssh/sshd_config.d/*.conf` в алфавитном порядке. До 5.0 файл
# назывался 10-hardening.conf и проигрывал любому файлу, который сортируется
# раньше: `00-provider.conf` с `PasswordAuthentication yes` молча возвращал
# вход по паролю, а self-test этого не видел — вход по ключу ведь работал.
#
# Имя 00-… уменьшает шанс проиграть, но не исключает его (`00-a.conf` всё
# равно раньше). Поэтому имя — только первая линия: вторая — sshd_conflicts,
# которая находит всех, кто окажется ДО нас, третья — проверка итогового
# конфига через sshd -T по каждому ключу.
#
# Каталог переопределяется ради tests/test_ssh_dropins.sh
SSHD_CONFIG_DIR="${SSHD_CONFIG_DIR:-/etc/ssh}"
USFC_SSHD_DROPIN="${SSHD_CONFIG_DIR}/sshd_config.d/00-usfc-hardening.conf"
USFC_SSHD_DROPIN_OLD="${SSHD_CONFIG_DIR}/sshd_config.d/10-hardening.conf"

# Ключ → значение, которое мы задаём. Ключи в нижнем регистре, как в sshd -T.
# AllowUsers сюда не входит: он не «первый побеждает», а накапливается, и
# задаётся только по отдельному согласию
declare -A USFC_SSHD_WANT=(
    [permitrootlogin]=no
    [passwordauthentication]=no
    [kbdinteractiveauthentication]=no
    [pubkeyauthentication]=yes
)

usfc_item_full sshhardening "Переводит вход только на ключ: выключает пароль (включая keyboard-interactive)
и запрещает root-логин.

Самый рискованный пункт меню, поэтому с самопроверкой. Перед тем как выключить
пароль, скрипт заводит одноразовый ключ и реально проверяет вход по нему. Если
проверка не прошла — автоматически откатывает конфиг и оставляет пароль
включённым. Текущая сессия при этом не разрывается.

Чужие настройки, которые перебили бы наши (например drop-in провайдера
00-*.conf или 50-cloud-init.conf с PasswordAuthentication yes), находятся
заранее: скрипт показывает файл и строку и с согласия комментирует их.

Ограничение входа списком пользователей (AllowUsers) — только по отдельному
вопросу: оно молча закрывает SSH всем остальным аккаунтам.

Требует отдельного пользователя (пункт 1) — из-под root не работает." \
"Switches login to keys only: disables password authentication (including
keyboard-interactive) and root login.

The riskiest item in the menu, and therefore the one with a self-test: before
turning the password off, the script creates a one-time key and actually logs
in with it. If that check fails, it rolls the config back automatically and
leaves password login enabled. Your current session is never interrupted.

Foreign settings that would override ours (say, a provider drop-in 00-*.conf
or 50-cloud-init.conf with PasswordAuthentication yes) are found up front: the
script shows the file and line and, with your consent, comments them out.

Restricting login to a list of users (AllowUsers) happens only after a
separate question: it silently locks every other account out of SSH.

Requires a separate user (item 1) — it does not work from root."


usfc_item_rollback sshhardening "sudo rm -f ${USFC_SSHD_DROPIN}
     sudo systemctl restart ssh
     sudo rm -f /etc/sudoers.d/${TARGET_USER}
     sudo usfc restore       # вернуть чужие строки, которые были закомментированы
     # возвращает вход по паролю — убедись, что есть другой способ попасть на сервер" \
"sudo rm -f ${USFC_SSHD_DROPIN}
     sudo systemctl restart ssh
     sudo rm -f /etc/sudoers.d/${TARGET_USER}
     sudo usfc restore       # bring back foreign lines that were commented out
     # restores password login — make sure you have another way into the server"

# ── Порядок чтения конфига sshd ──────────────────────────────────────────────
# _sshd_walk <файл> — печатает директивы ГЛОБАЛЬНОЙ области в том порядке, в
# каком их читает sshd: «файл<TAB>строка<TAB>ключ<TAB>значение». Include
# разворачивается на месте. Наш drop-in вставляется в развёртку, даже если его
# ещё нет, строкой-маркером «__USFC__» — так видно, кто окажется ДО него.
# После Match идут условные блоки, они не глобальные — дальше файл не читаем.
_sshd_walk() {
    local file="$1" depth="${2:-0}" n=0 line key val pat f
    local -a pats files
    [ "$depth" -gt 4 ] && return 0
    [ -r "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in ''|'#'*) continue ;; esac
        key="${line%%[[:space:]=]*}"
        val="${line#"$key"}"
        val="${val#"${val%%[![:space:]=]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        key="${key,,}"
        case "$key" in
            match) return 0 ;;
            include)
                read -ra pats <<< "$val"
                for pat in "${pats[@]}"; do
                    [[ "$pat" = /* ]] || pat="${SSHD_CONFIG_DIR}/${pat}"
                    files=()
                    for f in $pat; do [ -e "$f" ] && files+=("$f"); done
                    # наш файл — участник развёртки, даже если его ещё нет.
                    # Каталог сверяем отдельно: в [[ == ]] звёздочка ловит и «/»,
                    # и шаблон /etc/ssh/*.conf иначе «нашёл» бы файл из подкаталога
                    # shellcheck disable=SC2053  # имя сверяется с шаблоном glob, так и задумано
                    if [ "${pat%/*}" = "${USFC_SSHD_DROPIN%/*}" ] && [[ "${USFC_SSHD_DROPIN##*/}" == ${pat##*/} ]]; then
                        files+=("$USFC_SSHD_DROPIN")
                    fi
                    [ "${#files[@]}" -gt 0 ] || continue
                    while IFS= read -r f; do
                        if [ "$f" = "$USFC_SSHD_DROPIN" ]; then
                            printf '__USFC__\n'
                        else
                            _sshd_walk "$f" $((depth + 1))
                        fi
                    done < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort -u)
                done
                ;;
            *) printf '%s\t%s\t%s\t%s\n' "$file" "$n" "$key" "$val" ;;
        esac
    done < "$file"
}

# sshd_conflicts — кто перебьёт наши ключи. Результат:
#   REPLY_SSHD_CONFLICTS — строки «файл<TAB>строка<TAB>ключ<TAB>значение»;
#   REPLY_SSHD_INCLUDED  — true, если sshd вообще читает каталог drop-in'ов.
# challengeresponseauthentication — старое имя kbdinteractiveauthentication,
# sshd понимает оба, поэтому сравниваем их как один ключ
REPLY_SSHD_CONFLICTS=()
REPLY_SSHD_INCLUDED=false
sshd_conflicts() {
    local rec file n key val want
    REPLY_SSHD_CONFLICTS=(); REPLY_SSHD_INCLUDED=false
    local -A got_key=()
    while IFS= read -r rec; do
        if [ "$rec" = "__USFC__" ]; then REPLY_SSHD_INCLUDED=true; break; fi
        IFS=$'\t' read -r file n key val <<< "$rec"
        [ "$file" = "$USFC_SSHD_DROPIN_OLD" ] && continue
        [ "$key" = challengeresponseauthentication ] && key=kbdinteractiveauthentication
        want="${USFC_SSHD_WANT[$key]:-}"
        [ -n "$want" ] || continue
        [ -n "${got_key[$key]:-}" ] && continue
        got_key[$key]=1
        [ "${val,,}" = "$want" ] && continue
        REPLY_SSHD_CONFLICTS+=("${file}"$'\t'"${n}"$'\t'"${key}"$'\t'"${val}")
    done < <(_sshd_walk "${SSHD_CONFIG_DIR}/sshd_config")
}

# sshd_comment_lines <файл> <номер>... — закомментировать строки, сохранив
# исходный текст: «# usfc: <как было>». Через write_file, то есть со снимком
# для `usfc restore` и честным сухим прогоном. Содержимое читаем в переменную
# ДО записи: write_file обрезает файл, и чтение в том же пайпе успело бы
# прочитать уже пустой
sshd_comment_lines() {
    local file="$1"; shift
    local content
    content="$(awk -v lines=" $* " '
        index(lines, " " NR " ") { print "# usfc: " $0; next }
        { print }' "$file")" || return 1
    printf '%s\n' "$content" | write_file "$file"
}

# Пользователи, которым сейчас открыт вход по ключу: обычная оболочка и
# непустой authorized_keys. Нужны, чтобы честно показать, кого отрежет AllowUsers
REPLY_SSH_KEY_USERS=()
_ssh_key_users() {
    local name uid home shell
    REPLY_SSH_KEY_USERS=()
    while IFS=: read -r name _ uid _ _ home shell; do
        [ "$uid" -ge 1000 ] 2>/dev/null || continue
        case "$shell" in */nologin|*/false|'') continue ;; esac
        [ -s "${home}/.ssh/authorized_keys" ] && REPLY_SSH_KEY_USERS+=("$name")
    done < <(getent passwd)
}

# Расхождения итогового конфига с нашими ключами → REPLY_SSHD_MISMATCH.
# -C обязателен: без него sshd -T не применяет Match-блоки, и перебившее нас
# `Match User …` осталось бы невидимым
REPLY_SSHD_MISMATCH=''
sshd_effective_mismatch() {
    local key val
    REPLY_SSHD_MISMATCH=''
    while read -r key val _; do
        [ -n "${USFC_SSHD_WANT[$key]:-}" ] || continue
        [ "$val" = "${USFC_SSHD_WANT[$key]}" ] && continue
        REPLY_SSHD_MISMATCH="${REPLY_SSHD_MISMATCH}${REPLY_SSHD_MISMATCH:+, }${key}=${val}"
    done < <(sshd -T -C "user=${TARGET_USER},host=localhost,addr=127.0.0.1" 2>/dev/null)
    [ -z "$REPLY_SSHD_MISMATCH" ]
}

status_sshhardening() {
    if [ ! -f "$USFC_SSHD_DROPIN" ]; then
        if [ -f "$USFC_SSHD_DROPIN_OLD" ]; then
            st "$YELLOW" "! старый 10-hardening.conf — примени пункт заново" "! old 10-hardening.conf — apply the item again"; return 1
        fi
        # под прямым root пункт неприменим в принципе (нужен отдельный пользователь) —
        # честнее сказать это сразу, чем показывать «не применено» и молчать о причине
        if [ "$TARGET_USER" = "root" ]; then
            st "$DIM" "— нужен обычный пользователь" "— needs a normal user"; return 1
        fi
        st "$DIM" "○ не применено" "○ not applied"; return 1
    fi
    if [ "$SSHD_PASSWORDAUTH" != "no" ]; then
        st "$YELLOW" "! пароль не выключен (перебит другим конфигом)" "! password login still on (overridden elsewhere)"; return 1
    fi
    if [ "$SSHD_PERMITROOT" = "yes" ]; then
        st "$YELLOW" "! root-логин разрешён (перебит другим конфигом)" "! root login allowed (overridden elsewhere)"; return 1
    fi
    if [ "$SSHD_PUBKEY" = "no" ]; then
        st "$YELLOW" "! вход по ключу выключен (перебит другим конфигом)" "! key login disabled (overridden elsewhere)"; return 1
    fi
    if [ "${SSHD_KBDINTERACTIVE:-no}" != "no" ]; then
        st "$YELLOW" "! пароль возможен через keyboard-interactive" "! password possible via keyboard-interactive"; return 1
    fi
    st "$GREEN" "✓ применено (только ключи)" "✓ applied (keys only)"; return 0
}

apply_sshhardening() {
    if [ "$TARGET_USER" = "root" ]; then
        log_warn_t "Скрипт запущен напрямую под root — hardening требует отдельного пользователя" \
"Running directly as root — hardening needs a separate user"
        log_warn_t "Создай его (adduser <имя> && usermod -aG sudo <имя>) и перезайди под ним" \
"Create one (adduser <name> && usermod -aG sudo <name>) and log back in as them"
        return
    fi
    if [ "$BULK_MODE" = true ]; then
        log_warn_t "SSH hardening требует явного подтверждения — пропущено в пакетном режиме. Настройте отдельно пунктом $(item_number sshhardening)." \
"SSH hardening needs explicit confirmation — skipped in batch mode. Set it up separately via item $(item_number sshhardening)."
        return
    fi
    if ! ask_yn_t "Настроить SSH hardening для ${TARGET_USER} (ключи вместо пароля, запрет root-логина)?" "Set up SSH hardening for ${TARGET_USER} (keys instead of password, root login disabled)?" N; then return; fi

    # Файлы, которые мы тронули помимо своего drop-in: при откате они
    # возвращаются из снимка (restore_touched ниже)
    local -a touched=()

    # Конфликты ищем ДО всего остального, в том числе до сухого прогона:
    # поиск только читает, а показать его в предпросмотре — самое полезное,
    # что предпросмотр вообще может сказать про этот пункт
    if [ ! -f "${SSHD_CONFIG_DIR}/sshd_config" ]; then
        # openssh-server не стоит (бывает в контейнерах и минимальных образах).
        # В сухом прогоне это не повод падать: показываем, что было бы дальше
        if [ "$USFC_DRY_RUN" != true ]; then
            log_error_t "Нет ${SSHD_CONFIG_DIR}/sshd_config — openssh-server не установлен?" \
"No ${SSHD_CONFIG_DIR}/sshd_config — is openssh-server installed?"
            return 1
        fi
        t "нет ${SSHD_CONFIG_DIR}/sshd_config — на живой машине пункт остановился бы здесь" \
          "no ${SSHD_CONFIG_DIR}/sshd_config — on a live machine the item would stop here"; _dry_say "$REPLY_T"
        return 0
    fi
    sshd_conflicts
    if [ "$REPLY_SSHD_INCLUDED" != true ]; then
        log_warn_t "${SSHD_CONFIG_DIR}/sshd_config не подключает sshd_config.d/*.conf — наш drop-in не прочитается" \
"${SSHD_CONFIG_DIR}/sshd_config does not include sshd_config.d/*.conf — our drop-in would never be read"
        if ! ask_yn_t "Добавить 'Include ${SSHD_CONFIG_DIR}/sshd_config.d/*.conf' в начало sshd_config?" "Add 'Include ${SSHD_CONFIG_DIR}/sshd_config.d/*.conf' to the top of sshd_config?" N; then
            log_info_t "Без Include hardening бессмысленен — ничего не меняю" \
"Without the Include, hardening is pointless — changing nothing"
            return 1
        fi
        local main_cfg
        main_cfg="$(cat "${SSHD_CONFIG_DIR}/sshd_config")" || return 1
        printf 'Include %s/sshd_config.d/*.conf\n%s\n' "$SSHD_CONFIG_DIR" "$main_cfg" | write_file "${SSHD_CONFIG_DIR}/sshd_config"
        touched+=("${SSHD_CONFIG_DIR}/sshd_config")
        [ "$USFC_DRY_RUN" = true ] || sshd_conflicts
    fi

    if [ "${#REPLY_SSHD_CONFLICTS[@]}" -gt 0 ]; then
        log_warn_t "Эти строки читаются раньше нашего конфига и перебили бы его:" \
"These lines are read before our config and would override it:"
        local rec file n key val
        local -A by_file=()
        for rec in "${REPLY_SSHD_CONFLICTS[@]}"; do
            IFS=$'\t' read -r file n key val <<< "$rec"
            printf '      %b%s:%s%b  %s %s\n' "$DIM" "$file" "$n" "$NC" "$key" "$val"
            by_file[$file]="${by_file[$file]:-} $n"
        done
        if ! ask_yn_t "Закомментировать их (копия сохранится, вернуть — usfc restore)?" "Comment them out (a copy is kept, undo with usfc restore)?"; then
            log_info_t "Оставляю как есть — с ними hardening не подействует, поэтому не применяю" \
"Leaving them alone — with them in place hardening would not take effect, so not applying"
            return 1
        fi
        for file in "${!by_file[@]}"; do
            # shellcheck disable=SC2086  # номера строк — отдельные аргументы
            sshd_comment_lines "$file" ${by_file[$file]} || {
                log_error_t "Не удалось изменить ${file}" "Could not modify ${file}"; return 1; }
            touched+=("$file")
        done
    fi

    # AllowUsers — только по согласию и с честным списком тех, кого он отрежет
    local allow_users=""
    _ssh_key_users
    local others=() u
    for u in "${REPLY_SSH_KEY_USERS[@]}"; do [ "$u" = "$TARGET_USER" ] || others+=("$u"); done
    if [ "${#others[@]}" -gt 0 ]; then
        log_info_t "Ключи для входа есть и у других пользователей: ${others[*]}" \
"Other users also have login keys: ${others[*]}"
    fi
    if ask_yn_t "Разрешить вход по SSH ТОЛЬКО пользователю ${TARGET_USER} (AllowUsers; остальные потеряют доступ)?" "Allow SSH login ONLY for ${TARGET_USER} (AllowUsers; everyone else loses access)?" N; then
        allow_users="$TARGET_USER"
    fi

    # Сухой прогон здесь заканчивается описанием, а не имитацией. Пункт держится
    # на самопроверке: он заводит временный ключ, кладёт его в authorized_keys
    # и реально ходит по ssh на localhost. С заглушенным ssh-keygen проверка
    # провалилась бы и сообщила «вход по ключу не проходит даже сейчас» —
    # то есть соврала бы про исправную машину. Пугать таким в режиме, который
    # обещает ничего не менять, нельзя.
    if [ "$USFC_DRY_RUN" = true ]; then
        t "ssh-keygen: временный ключ для самопроверки входа" \
          "ssh-keygen: a temporary key for the login self-check"; _dry_say "$REPLY_T"
        t "запись ${USFC_SSHD_DROPIN}" \
          "writing ${USFC_SSHD_DROPIN}"; _dry_say "$REPLY_T"
        t "systemctl restart ssh и повторная самопроверка входа по ключу" \
          "systemctl restart ssh and a second key-login self-check"; _dry_say "$REPLY_T"
        log_info_t "Самопроверку входа в сухом прогоне не делаю: она требует настоящего ssh на localhost" \
"Not running the login self-check in a dry run: it needs a real ssh to localhost"
        return 0
    fi

    ensure_ssh_dir "$TARGET_USER" "$TARGET_HOME" || { log_error_t "Не удалось подготовить ~/.ssh" \
"Could not prepare ~/.ssh"; return 1; }
    local AUTH_KEYS="$REPLY_AUTHKEYS" key_gid
    key_gid="$(id -g "$TARGET_USER" 2>/dev/null)" || key_gid="$TARGET_USER"

    # Ключи бывают и с опциями впереди (`restrict ssh-ed25519 …`), поэтому
    # ищем тип ключа в любом поле, а не только в начале строки
    local key_count
    key_count="$(grep -cE '(^|[[:space:]])(ssh-(ed25519|rsa|dss)|ecdsa-sha2-[a-z0-9]+|sk-(ssh|ecdsa)-[^[:space:]]+)[[:space:]]' "$AUTH_KEYS" 2>/dev/null)"
    if [ "${key_count:-0}" -gt 0 ]; then
        log_info_t "В authorized_keys уже есть ${key_count} ключ(ей)" \
"authorized_keys already holds ${key_count} key(s)"
    else
        log_info_t "authorized_keys пока пуст" \
"authorized_keys is empty so far"
    fi

    if ask_yn_t "Добавить новый публичный ключ (вставить содержимое .pub со своей машины)?" "Add a new public key (paste the contents of your .pub file)?"; then
        add_pubkey_interactive "$AUTH_KEYS"
    fi

    if [ ! -s "$AUTH_KEYS" ]; then
        log_error_t "authorized_keys пуст — отключать пароль нельзя. Hardening прерван." \
"authorized_keys is empty — disabling the password is not safe. Hardening aborted."
        return 1
    fi

    # Временный ключ — в mktemp-каталоге, а не по предсказуемому имени в /tmp.
    # Очистка вызывается на каждом выходе из функции ниже; на Ctrl+C её
    # подстраховывает trap, снимаемый сразу после
    local TEST_DIR TEST_KEY TEST_PUB
    TEST_DIR="$(mktemp -d)" || return 1
    TEST_KEY="${TEST_DIR}/key"
    if ! ssh-keygen -t ed25519 -N '' -f "$TEST_KEY" -C "usfc-selftest" -q; then
        log_error_t "ssh-keygen не смог создать временный ключ — hardening не запускаю" \
"ssh-keygen could not create a temporary key — not starting hardening"
        rm -rf "$TEST_DIR"; return 1
    fi
    TEST_PUB="$(cat "${TEST_KEY}.pub")"
    echo "$TEST_PUB" | append_file "$AUTH_KEYS"

    ssh_selftest() {
        ssh -i "$TEST_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "$SSH_PORT" \
            "${TARGET_USER}@127.0.0.1" 'echo VPS_SETUP_KEY_OK' 2>/dev/null | grep VPS_SETUP_KEY_OK >/dev/null
    }
    # Свой trap ставится поверх общего (services.sh: спиннер и policy-rc.d),
    # поэтому общий запоминаем и возвращаем, а не сбрасываем в «по умолчанию»
    local saved_traps
    saved_traps="$(trap -p INT TERM)"
    cleanup_test_key() {
        grep -vF "$TEST_PUB" "$AUTH_KEYS" > "${AUTH_KEYS}.tmp" 2>/dev/null && mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
        chown "${TARGET_USER}:${key_gid}" "$AUTH_KEYS"
        chmod 600 "$AUTH_KEYS"
        rm -rf "$TEST_DIR"
        trap - INT TERM
        [ -n "$saved_traps" ] && eval "$saved_traps"
    }
    trap 'cleanup_test_key; exit 130' INT TERM

    # Вернуть закомментированные чужие строки из снимка — при любом откате
    restore_touched() {
        local f snap
        for f in "${touched[@]}"; do
            snap="${USFC_BACKUP_DIR}${f}"
            [ -f "$snap" ] && cp -p "$snap" "$f"
        done
    }

    log_info_t "Проверяю базовый вход по ключу (до изменений конфига)..." \
"Checking that key login works at all (before touching the config)..."
    if ! ssh_selftest; then
        log_error_t "Вход по ключу на 127.0.0.1:${SSH_PORT} не проходит даже сейчас — hardening не запускаю" \
"Key login to 127.0.0.1:${SSH_PORT} does not work even now — not starting hardening"
        if sshd -T 2>/dev/null | awk '$1=="listenaddress"{print $2}' | grep -vE '^(0\.0\.0\.0|\[?::\]?|127\.0\.0\.1)(:|$)' >/dev/null; then
            log_info_t "sshd слушает не все адреса (ListenAddress) — самопроверке нужен 127.0.0.1" \
"sshd does not listen on every address (ListenAddress) — the self-test needs 127.0.0.1"
        fi
        restore_touched
        cleanup_test_key
        return 1
    fi
    log_success_t "Базовый вход по ключу подтверждён" \
"Key login confirmed"

    {
        echo "# usfc: SSH hardening. Named 00-... so that it is read before other drop-ins"
        echo "PermitRootLogin no"
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
        echo "PubkeyAuthentication yes"
        [ -n "$allow_users" ] && echo "AllowUsers ${allow_users}"
    } | write_file "$USFC_SSHD_DROPIN"
    # старое имя: оставленный рядом файл продолжал бы действовать
    if [ -f "$USFC_SSHD_DROPIN_OLD" ]; then
        backup_file "$USFC_SSHD_DROPIN_OLD"
        rm -f "$USFC_SSHD_DROPIN_OLD"
        touched+=("$USFC_SSHD_DROPIN_OLD")   # при откате вернётся из снимка
    fi

    rollback_dropin() {
        rm -f "$USFC_SSHD_DROPIN"
        restore_touched
    }

    if ! sshd -t 2>/dev/null; then
        log_error_t "sshd -t не прошёл — откатываю" \
"sshd -t failed — rolling back"
        rollback_dropin
        cleanup_test_key
        return 1
    fi

    systemctl restart ssh
    sleep 1
    log_info_t "Проверяю вход по ключу ПОСЛЕ применения hardening..." \
"Checking key login AFTER applying hardening..."
    if ! ssh_selftest; then
        log_error_t "После рестарта sshd вход по ключу НЕ проходит — АВАРИЙНЫЙ ОТКАТ" \
"Key login does NOT work after restarting sshd — EMERGENCY ROLLBACK"
        rollback_dropin
        systemctl restart ssh
        refresh_sshd_config
        cleanup_test_key
        log_error_t "Конфиг откачен. Текущая сессия жива — ничего не сломано." \
"Config rolled back. Your session is alive — nothing is broken."
        return 1
    fi

    # Вход по ключу подтверждает только то, что ключевая аутентификация жива.
    # Что пароль и root действительно выключены — видно лишь в итоговом конфиге
    if ! sshd_effective_mismatch; then
        log_error_t "Вход по ключу работает, но итоговый конфиг расходится с нашим: ${REPLY_SSHD_MISMATCH}" \
"Key login works, but the effective config disagrees with ours: ${REPLY_SSHD_MISMATCH}"
        log_error_t "Его перебивает то, что заранее не видно (например Match-блок в sshd_config). Откатываю" \
"Something not visible up front overrides it (a Match block in sshd_config, say). Rolling back"
        rollback_dropin
        systemctl restart ssh
        refresh_sshd_config
        cleanup_test_key
        return 1
    fi
    refresh_sshd_config

    log_success_t "SSH hardening применён: root-логин выключен, вход только по ключу" \
"SSH hardening applied: root login disabled, key-only login"
    log_info_t "Текущая сессия не разрывалась — рестарт sshd не убивает открытые соединения" \
"Your current session was not dropped — restarting sshd does not kill open connections"
    cleanup_test_key
    if ask_yn_t "Настроить passwordless sudo для ${TARGET_USER}?" "Set up passwordless sudo for ${TARGET_USER}?"; then
        local SUDOERS_FILE="/etc/sudoers.d/${TARGET_USER}"
        echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > "${SUDOERS_FILE}.tmp"
        if visudo -c -f "${SUDOERS_FILE}.tmp" >/dev/null 2>&1; then
            mv "${SUDOERS_FILE}.tmp" "$SUDOERS_FILE"
            chmod 440 "$SUDOERS_FILE"
            log_success_t "Passwordless sudo настроен" \
"Passwordless sudo configured"
        else
            log_error_t "Синтаксическая ошибка в sudoers — не применяю" \
"Syntax error in sudoers — not applying it"
            rm -f "${SUDOERS_FILE}.tmp"
        fi
    fi
}
