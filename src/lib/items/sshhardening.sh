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

Смена порта SSH — вопросом после hardening (и при повторном выборе пункта)
или флагом --ssh-port. Переезд в два шага: сначала sshd слушает и старый, и
новый порт (UFW и fail2ban узнают о новом заранее), вход по ключу на новый
проверяется сам. Старый порт закрывается, только когда ты подтвердишь, что
вошёл по новому снаружи: файрвол провайдера отсюда не виден. Без терминала
(usfc apply … --ssh-port N) старый порт закрывает повторный запуск той же
команды.

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

Changing the SSH port: a question after hardening (and when you pick the
item again) or the --ssh-port flag. The move takes two steps: first sshd
listens on both the old and the new port (UFW and fail2ban learn about the
new one in advance), and key login on the new port is self-tested. The old
port is closed only after you confirm you logged in on the new one from
outside: the provider firewall is invisible from here. Without a terminal
(usfc apply … --ssh-port N) running the same command again closes the old port.

Requires a separate user (item 1) — it does not work from root."


usfc_item_rollback sshhardening "sudo usfc apply sshhardening --ssh-port 22   # порт обратно на 22: дважды, второй раз закроет старый
     sudo ufw allow 22/tcp   # если удаляешь drop-in целиком, а порт менялся: без него sshd вернётся на 22
     sudo rm -f ${USFC_SSHD_DROPIN}
     sudo systemctl daemon-reload && sudo systemctl restart ssh.socket   # Ubuntu с сокетной активацией
     sudo systemctl restart ssh
     sudo rm -f /etc/sudoers.d/90-usfc-${TARGET_USER}
     sudo usfc restore       # вернуть чужие строки, которые были закомментированы (и Port тоже)
     # возвращает вход по паролю — убедись, что есть другой способ попасть на сервер" \
"sudo usfc apply sshhardening --ssh-port 22   # port back to 22: run twice, the second run closes the old one
     sudo ufw allow 22/tcp   # when removing the drop-in after a port change: sshd falls back to 22
     sudo rm -f ${USFC_SSHD_DROPIN}
     sudo systemctl daemon-reload && sudo systemctl restart ssh.socket   # Ubuntu with socket activation
     sudo systemctl restart ssh
     sudo rm -f /etc/sudoers.d/90-usfc-${TARGET_USER}
     sudo usfc restore       # bring back foreign lines that were commented out (Port too)
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

# ═══════════════════════════════════════════════════════════════
# Самопроверка входа по временному ключу
# ═══════════════════════════════════════════════════════════════
# Вынесена из apply_sshhardening: та же проверка нужна переносу порта, и там
# она ходит на конкретный порт — старый и новый, а не только на SSH_PORT.
# Временный ключ — в mktemp-каталоге, а не по предсказуемому имени в /tmp.
# Пара begin/end: end зовётся на каждом выходе, на Ctrl+C её подстраховывает
# trap. Свой trap ставится поверх общего (services.sh: спиннер и policy-rc.d),
# поэтому общий запоминаем и возвращаем, а не сбрасываем в «по умолчанию»
SSH_TEST_DIR=''; SSH_TEST_KEY=''; SSH_TEST_PUB=''; SSH_TEST_AUTH=''
SSH_TEST_GID=''; SSH_TEST_TRAPS=''

ssh_selftest_begin() {
    ensure_ssh_dir "$TARGET_USER" "$TARGET_HOME" || { log_error_t "Не удалось подготовить ~/.ssh" \
"Could not prepare ~/.ssh"; return 1; }
    SSH_TEST_AUTH="$REPLY_AUTHKEYS"
    SSH_TEST_GID="$(id -g "$TARGET_USER" 2>/dev/null)" || SSH_TEST_GID="$TARGET_USER"
    SSH_TEST_DIR="$(mktemp -d)" || { SSH_TEST_DIR=''; return 1; }
    SSH_TEST_KEY="${SSH_TEST_DIR}/key"
    if ! ssh-keygen -t ed25519 -N '' -f "$SSH_TEST_KEY" -C "usfc-selftest" -q || [ ! -s "${SSH_TEST_KEY}.pub" ]; then
        log_error_t "ssh-keygen не смог создать временный ключ для самопроверки — ничего не меняю" \
"ssh-keygen could not create a temporary key for the self-test — changing nothing"
        rm -rf "$SSH_TEST_DIR"; SSH_TEST_DIR=''
        return 1
    fi
    SSH_TEST_PUB="$(cat "${SSH_TEST_KEY}.pub")"
    SSH_TEST_TRAPS="$(trap -p INT TERM)"
    trap 'ssh_selftest_end; exit 130' INT TERM
    # authkeys_add: файл без перевода строки в конце склеил бы временный ключ
    # с настоящим, и ssh_selftest_end унёс бы их вместе
    authkeys_add "$SSH_TEST_AUTH" "$SSH_TEST_PUB"
}

# ssh_selftest [порт] — вход по временному ключу на 127.0.0.1
ssh_selftest() {
    ssh -i "$SSH_TEST_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "${1:-$SSH_PORT}" \
        "${TARGET_USER}@127.0.0.1" 'echo VPS_SETUP_KEY_OK' 2>/dev/null | grep VPS_SETUP_KEY_OK >/dev/null
}

# ssh_selftest_end — убрать временный ключ. grep -v отдаёт 1, когда строк не
# осталось вовсе, — это тоже успех, иначе ключ остался бы в authorized_keys
ssh_selftest_end() {
    [ -n "$SSH_TEST_DIR" ] || return 0
    if [ -n "$SSH_TEST_PUB" ] && [ -f "$SSH_TEST_AUTH" ]; then
        # -x: только строка, равная временному ключу целиком
        { grep -vxF "$SSH_TEST_PUB" "$SSH_TEST_AUTH" > "${SSH_TEST_AUTH}.tmp"; [ $? -le 1 ]; } \
            && mv "${SSH_TEST_AUTH}.tmp" "$SSH_TEST_AUTH"
        rm -f "${SSH_TEST_AUTH}.tmp"
        chown "${TARGET_USER}:${SSH_TEST_GID}" "$SSH_TEST_AUTH"
        chmod 600 "$SSH_TEST_AUTH"
    fi
    rm -rf "$SSH_TEST_DIR"
    SSH_TEST_DIR=''; SSH_TEST_PUB=''
    trap - INT TERM
    [ -n "$SSH_TEST_TRAPS" ] && eval "$SSH_TEST_TRAPS"
    SSH_TEST_TRAPS=''
    return 0
}

# ═══════════════════════════════════════════════════════════════
# Смена порта SSH
# ═══════════════════════════════════════════════════════════════
# Переезд всегда в два шага. Первый: sshd слушает ОБА порта, файрвол и
# fail2ban знают оба, вход по ключу на новый проверен с 127.0.0.1. Второй —
# закрыть старый — только когда человек вошёл по новому порту СНАРУЖИ:
# самопроверка на localhost не видит файрвола провайдера (security group),
# а именно он чаще всего и оставляет без сервера после смены порта.
#
# Директива Port у sshd аддитивна (в отличие от прочих, где побеждает первое
# значение): `Port 22` в sshd_config и `Port 2222` в drop-in — это два порта.
# Поэтому все порты задаёт ровно одно место — наш drop-in, — а чужие строки
# Port комментируются (со снимком, как конфликты hardening'а). Явный Port
# нужен и для старого порта: без единой строки Port sshd слушает 22, а с
# одной `Port 2222` — уже только её.
#
# Ubuntu 22.10+ (в том числе 24.04): ssh активируется сокетом, и порт слушает
# systemd, а не sshd. Адреса для ssh.socket пишет генератор
# sshd-socket-generator из того же sshd_config — после правки нужны
# daemon-reload и рестарт ssh.socket. Несколько Port генератор переносит в
# несколько ListenStream= (проверено на openssh-server 24.04 в контейнере).
#
# Состояние «перенос не завершён» не хранится отдельно: это наш drop-in с
# двумя и более строками Port. Последняя — куда переезжаем.

# ssh_dropin_scan [файл] — что в нашем drop-in:
#   REPLY_SSH_DROPIN_PORTS    — порты из строк Port, по порядку;
#   REPLY_SSH_DROPIN_HARDENED — true, если там выключен пароль (hardening, а
#                               не только порт)
# Без форков: зовётся из status_sshhardening на каждой перерисовке меню
REPLY_SSH_DROPIN_PORTS=()
REPLY_SSH_DROPIN_HARDENED=false
ssh_dropin_scan() {
    local f="${1:-$USFC_SSHD_DROPIN}" key val
    REPLY_SSH_DROPIN_PORTS=(); REPLY_SSH_DROPIN_HARDENED=false
    [ -r "$f" ] || return 0
    while read -r key val _ || [ -n "$key" ]; do
        case "${key,,}" in
            port) [[ "$val" =~ ^[0-9]+$ ]] && REPLY_SSH_DROPIN_PORTS+=("$val") ;;
            passwordauthentication) [ "${val,,}" = no ] && REPLY_SSH_DROPIN_HARDENED=true ;;
        esac
    done < "$f"
}

# ssh_port_pending — перенос порта начат и не завершён. Тогда
# REPLY_SSH_PORT_FROM — старые порты через пробел, REPLY_SSH_PORT_TO — новый
REPLY_SSH_PORT_FROM=''
REPLY_SSH_PORT_TO=''
ssh_port_pending() {
    ssh_dropin_scan "${1:-$USFC_SSHD_DROPIN}"
    local n="${#REPLY_SSH_DROPIN_PORTS[@]}"
    REPLY_SSH_PORT_FROM=''; REPLY_SSH_PORT_TO=''
    [ "$n" -ge 2 ] || return 1
    REPLY_SSH_PORT_TO="${REPLY_SSH_DROPIN_PORTS[$((n - 1))]}"
    REPLY_SSH_PORT_FROM="${REPLY_SSH_DROPIN_PORTS[*]:0:$((n - 1))}"
    return 0
}

# ssh_dropin_render <порт...> — новое содержимое нашего drop-in: всё, что там
# было (hardening, AllowUsers), без старых строк Port, плюс Port на каждый
# порт. Без портов — просто без строк Port. Печатает в stdout
ssh_dropin_render() {
    local line
    if [ -s "$USFC_SSHD_DROPIN" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "${line,,}" in
                port[[:space:]=]*|'# usfc: port'*) continue ;;
            esac
            printf '%s\n' "$line"
        done < "$USFC_SSHD_DROPIN"
    else
        printf '%s\n' "# usfc: SSH settings. Named 00-... so that it is read before other drop-ins"
    fi
    [ "$#" -gt 0 ] || return 0
    printf '%s\n' "# usfc: port. Port adds up across files, so Port lines elsewhere are commented out"
    printf 'Port %s\n' "$@"
}

# ssh_foreign_ports — строки Port вне нашего drop-in и ListenAddress с явным
# портом:
#   REPLY_SSH_FOREIGN       — «файл<TAB>строка<TAB>порт»;
#   REPLY_SSH_LISTEN_PORTED — «файл:строка  значение». Порт в ListenAddress
#                             сильнее Port, и с ним перенос не сработает
# В отличие от sshd_conflicts, смотрим и ПОСЛЕ нашего файла: Port не «первый
# побеждает», а складывается
REPLY_SSH_FOREIGN=()
REPLY_SSH_LISTEN_PORTED=()
ssh_foreign_ports() {
    local rec file n key val a
    REPLY_SSH_FOREIGN=(); REPLY_SSH_LISTEN_PORTED=()
    while IFS= read -r rec; do
        [ "$rec" = "__USFC__" ] && continue
        IFS=$'\t' read -r file n key val <<< "$rec"
        case "$key" in
            port) REPLY_SSH_FOREIGN+=("${file}"$'\t'"${n}"$'\t'"${val}") ;;
            listenaddress)
                a="${val%%[[:space:]]*}"
                # [::1]:2222 или 1.2.3.4:2222; голый IPv6 (::1) порта не несёт
                if [[ "$a" == *"]:"* ]] || { [[ "$a" != \[* ]] && [[ "$a" == *:* ]] && [[ "${a#*:}" != *:* ]]; }; then
                    REPLY_SSH_LISTEN_PORTED+=("${file}:${n}  ${val}")
                fi ;;
        esac
    done < <(_sshd_walk "${SSHD_CONFIG_DIR}/sshd_config")
}

# f2b_render_port <файл> <порты через запятую> — jail.d-файл с новой строкой
# port в секции [sshd] (или добавленной, если её не было). Печатает в stdout
f2b_render_port() {
    awk -v ports="$2" '
        /^[[:space:]]*\[/ {
            if (insec && !done) { print "port = " ports; done = 1 }
            insec = ($0 ~ /^[[:space:]]*\[sshd\]/)
        }
        insec && /^[[:space:]]*port[[:space:]]*=/ {
            if (!done) { print "port = " ports; done = 1 }
            next
        }
        { print }
        END { if (insec && !done) print "port = " ports }' "$1"
}

# ufw_port_rules <порт> <вывод ufw status> → REPLY_UFW_RULES: правила
# «откуда угодно», которые открывают этот TCP-порт, в том виде, в каком их
# снимает `ufw delete allow …`: «2222/tcp», «2222» и для 22 — профиль OpenSSH.
# Строки (v6) сводим к v4: ufw delete снимает обе. Правила «с адреса X» и
# LIMIT не трогаем — их ставил человек, и снимать их ему
REPLY_UFW_RULES=()
ufw_port_rules() {
    local p="$1" line to action from
    REPLY_UFW_RULES=()
    while IFS= read -r line; do
        line="${line// (v6)/}"
        read -r to action from _ <<< "$line"
        [ "$action" = ALLOW ] && [ "$from" = Anywhere ] || continue
        case "$to" in
            "${p}/tcp"|"$p") ;;
            OpenSSH) [ "$p" = 22 ] || continue ;;
            *) continue ;;
        esac
        [[ " ${REPLY_UFW_RULES[*]} " == *" ${to} "* ]] || REPLY_UFW_RULES+=("$to")
    done <<< "$2"
}

# ssh_port_listening <порт> — кто-то слушает TCP-порт (sshd, systemd за
# ssh.socket или чужой процесс — разбираемся по SSHD_PORTS)
ssh_port_listening() {
    [ -n "$(ss -tlnH "( sport = :$1 )" 2>/dev/null)" ]
}

# Сокетная активация (Ubuntu 22.10+): порт держит ssh.socket
ssh_socket_active()  { systemctl is-active --quiet ssh.socket 2>/dev/null; }
ssh_socket_enabled() { systemctl is-enabled --quiet ssh.socket 2>/dev/null; }

# ssh_restart — перечитать порты. На сокетной активации генератор пересоздаёт
# ssh.socket.d/addresses.conf только при daemon-reload, а слушает сокет, не
# sshd: без рестарта ssh.socket новый порт не откроется. Рестарт сокета тянет
# за собой и ssh.service (RequiredBy), отдельный рестарт сервиса — для
# Debian без сокета и на всякий случай. Открытые сессии рестарт не рвёт
ssh_restart() {
    local rc=0
    if ssh_socket_active || ssh_socket_enabled; then
        systemctl daemon-reload || rc=1
        if ssh_socket_active; then
            systemctl restart ssh.socket || rc=1
        fi
    fi
    systemctl restart ssh || rc=1
    [ "$USFC_DRY_RUN" = true ] || sleep 1
    return "$rc"
}

# ── Снимки для отката переноса ───────────────────────────────────────────────
# Свои, а не из backup_file: тот хранит ПЕРВУЮ запись за прогон, и если
# hardening в этом же прогоне уже переписал drop-in, «откат порта» по такому
# снимку снёс бы и hardening
SSH_PORT_SNAP=''
SSH_PORT_SNAP_FILES=()
_ssh_snap_reset() {
    [ -n "$SSH_PORT_SNAP" ] && rm -rf "$SSH_PORT_SNAP"
    SSH_PORT_SNAP=''; SSH_PORT_SNAP_FILES=()
    [ "$USFC_DRY_RUN" = true ] && return 0
    SSH_PORT_SNAP="$(mktemp -d)" || { SSH_PORT_SNAP=''; return 1; }
}
_ssh_snap() {
    local f="$1" i
    [ -n "$SSH_PORT_SNAP" ] || return 0
    for i in "${SSH_PORT_SNAP_FILES[@]}"; do [ "$i" = "$f" ] && return 0; done
    i="${#SSH_PORT_SNAP_FILES[@]}"
    SSH_PORT_SNAP_FILES+=("$f")
    [ -f "$f" ] && cp -p "$f" "${SSH_PORT_SNAP}/${i}"
    return 0
}
# вернуть всё как было: файл из снимка, а созданный нами — удалить
_ssh_snap_restore() {
    local i f
    [ -n "$SSH_PORT_SNAP" ] || return 0
    for i in "${!SSH_PORT_SNAP_FILES[@]}"; do
        f="${SSH_PORT_SNAP_FILES[$i]}"
        if [ -f "${SSH_PORT_SNAP}/${i}" ]; then cp -p "${SSH_PORT_SNAP}/${i}" "$f"
        else rm -f "$f"; fi
    done
}

# _ssh_set_ports <порт...> — оставить sshd ровно эти порты: чужие Port
# закомментировать, наши записать в drop-in. Всё со снимками
_ssh_set_ports() {
    local rec file n val content
    local -A by_file=()
    ssh_foreign_ports
    for rec in "${REPLY_SSH_FOREIGN[@]}"; do
        IFS=$'\t' read -r file n val <<< "$rec"
        by_file[$file]="${by_file[$file]:-} $n"
    done
    for file in "${!by_file[@]}"; do
        log_info_t "Комментирую Port в ${file} (строки${by_file[$file]}): порты теперь задаёт ${USFC_SSHD_DROPIN##*/}" \
"Commenting out Port in ${file} (lines${by_file[$file]}): ports now live in ${USFC_SSHD_DROPIN##*/}"
        _ssh_snap "$file"
        # shellcheck disable=SC2086  # номера строк — отдельные аргументы
        sshd_comment_lines "$file" ${by_file[$file]} || return 1
    done
    _ssh_snap "$USFC_SSHD_DROPIN"
    content="$(ssh_dropin_render "$@")" || return 1
    printf '%s\n' "$content" | write_file "$USFC_SSHD_DROPIN"
}

# _ssh_f2b_ports <порты через запятую> — порт в нашем jail fail2ban, если он есть
_ssh_f2b_ports() {
    local content
    [ -f "$FAIL2BAN_DROPIN" ] || return 0
    _ssh_snap "$FAIL2BAN_DROPIN"
    content="$(f2b_render_port "$FAIL2BAN_DROPIN" "$1")" || return 1
    printf '%s\n' "$content" | write_file "$FAIL2BAN_DROPIN"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        systemctl restart fail2ban >/dev/null 2>&1 || log_warn_t "fail2ban не перезапустился — проверь: fail2ban-client -t" \
"fail2ban did not restart — check: fail2ban-client -t"
    fi
    return 0
}

# _ssh_login_ok <порт> — порт слушается и вход по ключу на него проходит.
# В сухом прогоне не проверяем (см. комментарий в apply_sshhardening)
_ssh_login_ok() {
    [ "$USFC_DRY_RUN" = true ] && return 0
    if ! ssh_port_listening "$1"; then
        log_error_t "Порт ${1} никто не слушает" "Nothing is listening on port ${1}"
        return 1
    fi
    if ! ssh_selftest "$1"; then
        log_error_t "Вход по ключу на 127.0.0.1:${1} не проходит" "Key login to 127.0.0.1:${1} fails"
        return 1
    fi
    return 0
}

# _ssh_sshd_test — sshd -t с понятной причиной провала
_ssh_sshd_test() {
    local out
    out="$(sshd -t 2>&1)" && return 0
    log_error_t "sshd -t не принял конфиг: ${out##*$'\n'}" "sshd -t rejected the config: ${out##*$'\n'}"
    return 1
}

# _ssh_port_rollback <ufw: добавляли ли правило> <новый порт> <старый порт>
_ssh_port_rollback() {
    log_warn_t "Откатываю перенос порта" "Rolling the port change back"
    _ssh_snap_restore
    ssh_restart
    [ "$1" = true ] && _fw_ufw delete allow "${2}/tcp" >/dev/null
    systemctl is-active --quiet fail2ban 2>/dev/null && systemctl restart fail2ban >/dev/null 2>&1
    refresh_sshd_config
    if _ssh_login_ok "$3"; then
        log_info_t "Порт ${3} работает как раньше. Текущая сессия жива" \
"Port ${3} works as before. Your current session is alive"
    else
        log_error_t "После отката вход на ${3} не подтвердился — НЕ закрывай текущую сессию, проверь sshd вручную" \
"Login on ${3} is not confirmed after the rollback — do NOT close this session, check sshd by hand"
    fi
}

REPLY_SSH_IP=''
_ssh_host_ip() {
    REPLY_SSH_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$REPLY_SSH_IP" ] || REPLY_SSH_IP='<IP>'
}

# _ssh_port_howto_finish <новый порт> — как завершить перенос
_ssh_port_howto_finish() {
    _ssh_host_ip
    log_warn_t "Старый порт пока открыт: sshd слушает оба" "The old port stays open for now: sshd listens on both"
    if [ "$BULK_MODE" = true ]; then
        log_info_t "Проверь вход: ${BOLD}ssh -p ${1} ${TARGET_USER}@${REPLY_SSH_IP}${NC}, затем выполни ту же команду ещё раз: ${BOLD}sudo usfc apply sshhardening --ssh-port ${1}${NC} — старый порт будет закрыт" \
"Check the login: ${BOLD}ssh -p ${1} ${TARGET_USER}@${REPLY_SSH_IP}${NC}, then run the same command again: ${BOLD}sudo usfc apply sshhardening --ssh-port ${1}${NC} — the old port will be closed"
    else
        log_info_t "Завершить: войди ${BOLD}ssh -p ${1} ${TARGET_USER}@${REPLY_SSH_IP}${NC} и выбери пункт $(item_number sshhardening) ещё раз (или ${BOLD}sudo usfc apply sshhardening --ssh-port ${1}${NC})" \
"To finish: log in with ${BOLD}ssh -p ${1} ${TARGET_USER}@${REPLY_SSH_IP}${NC} and pick item $(item_number sshhardening) again (or ${BOLD}sudo usfc apply sshhardening --ssh-port ${1}${NC})"
    fi
    log_info_t "Не пускает снаружи — проверь файрвол провайдера (security group): ${1}/tcp должен быть открыт и там" \
"Cannot get in from outside? Check the provider firewall (security group): ${1}/tcp must be open there too"
    item_skip_t "перенос на ${1} начат, старый порт открыт" "move to ${1} started, old port still open"
}

# _ssh_port_open <новый> <старый...> — шаг 1: слушать и старые, и новый
_ssh_port_open() {
    local new="$1" ufw_added=false; shift
    local -a old=("$@")
    local f2b_list
    f2b_list="$(IFS=,; printf '%s' "${old[*]}"),${new}"
    log_info_t "Шаг 1 из 2: sshd будет слушать и старый порт (${old[*]}), и новый (${new})" \
"Step 1 of 2: sshd will listen on both the old port (${old[*]}) and the new one (${new})"
    # Вход должен работать ДО изменений — иначе провал после ничего не докажет
    if ! _ssh_login_ok "${old[0]}"; then
        log_error_t "Вход по ключу не проходит даже сейчас — порт не трогаю" \
"Key login does not work even now — leaving the port alone"
        return 1
    fi
    if ufw_active; then
        ufw_port_rules "$new" "$(ufw status 2>/dev/null)"
        if [ "${#REPLY_UFW_RULES[@]}" -eq 0 ]; then
            if ! _fw_ufw allow "${new}/tcp"; then
                log_error_t "UFW не открыл ${new}/tcp — порт не переношу" \
"UFW did not open ${new}/tcp — not moving the port"
                return 1
            fi
            ufw_added=true
            log_success_t "UFW: ${new}/tcp разрешён" "UFW: ${new}/tcp allowed"
        fi
    fi
    _ssh_snap_reset || return 1
    if ! _ssh_f2b_ports "$f2b_list" || ! _ssh_set_ports "${old[@]}" "$new" || ! _ssh_sshd_test; then
        _ssh_port_rollback "$ufw_added" "$new" "${old[0]}"
        return 1
    fi
    ssh_restart
    log_info_t "Проверяю вход по ключу на новый порт ${new} и на старый ${old[0]}..." \
"Checking key login on the new port ${new} and the old one ${old[0]}..."
    if ! _ssh_login_ok "$new" || ! _ssh_login_ok "${old[0]}"; then
        if ssh_socket_active; then
            log_info_t "ssh.socket активен: порты держит systemd — см. systemctl cat ssh.socket" \
"ssh.socket is active: systemd owns the ports — see systemctl cat ssh.socket"
        fi
        _ssh_port_rollback "$ufw_added" "$new" "${old[0]}"
        return 1
    fi
    refresh_sshd_config
    log_success_t "sshd слушает ${old[*]} и ${new}; вход по ключу на ${new} проверен с 127.0.0.1" \
"sshd listens on ${old[*]} and ${new}; key login on ${new} verified from 127.0.0.1"
    return 0
}

# _ssh_port_close <новый> <старый...> — шаг 2: оставить только новый
_ssh_port_close() {
    local new="$1" p r ufw_added=false st_out; shift
    local -a old=("$@")
    log_info_t "Шаг 2 из 2: закрываю старый порт ${old[*]}" "Step 2 of 2: closing the old port ${old[*]}"
    # UFW могли включить уже после шага 1 — тогда он открыл только старый порт
    if ufw_active; then
        ufw_port_rules "$new" "$(ufw status 2>/dev/null)"
        if [ "${#REPLY_UFW_RULES[@]}" -eq 0 ]; then
            _fw_ufw allow "${new}/tcp" || { log_error_t "UFW не открыл ${new}/tcp — старый порт не закрываю" \
"UFW did not open ${new}/tcp — not closing the old port"; return 1; }
            ufw_added=true
        fi
    fi
    _ssh_snap_reset || return 1
    if ! _ssh_set_ports "$new" || ! _ssh_sshd_test; then
        _ssh_port_rollback "$ufw_added" "$new" "${old[0]}"
        return 1
    fi
    ssh_restart
    if ! _ssh_login_ok "$new"; then
        _ssh_port_rollback "$ufw_added" "$new" "${old[0]}"
        return 1
    fi
    # Файрвол — только после того, как sshd ушёл со старого порта и вход на
    # новый подтверждён. Уже открытые соединения UFW не рвёт (ESTABLISHED)
    if ufw_active; then
        st_out="$(ufw status 2>/dev/null)"
        for p in "${old[@]}"; do
            ufw_port_rules "$p" "$st_out"
            for r in "${REPLY_UFW_RULES[@]}"; do
                _fw_ufw delete allow "$r" >/dev/null && log_success_t "UFW: правило ${r} снято" "UFW: rule ${r} removed"
            done
        done
    fi
    _ssh_f2b_ports "$new"
    _ssh_snap_reset
    refresh_sshd_config
    log_success_t "SSH перенесён на порт ${new}, старый порт (${old[*]}) закрыт" \
"SSH moved to port ${new}, the old port (${old[*]}) is closed"
    log_info_t "Текущая сессия жива: открытые соединения не рвутся. Новые — только ssh -p ${new}" \
"Your current session is alive: open connections are not dropped. New ones need ssh -p ${new}"
    ITEM_DONE=true
    return 0
}

# ssh_port_change <порт> — перенести SSH на порт. Какой это шаг, решает
# состояние, а не флаг, поэтому повторный запуск той же команды безопасен:
#   порт уже единственный               → «уже на порту N», ничего не делаем;
#   порт новый                          → шаг 1, затем (в меню) вопрос и шаг 2;
#   порт уже слушается рядом со старым  → шаг 2 (в меню — после вопроса).
# Без терминала (BULK_MODE) шаг 2 делается только при повторном запуске:
# подтверждение, что вход снаружи работает, — это и есть второй запуск
ssh_port_change() {
    local new="$1" p phase rc
    if ! valid_ssh_port "$new"; then
        log_error_t "Порт «${new}» не подходит: нужен 22 или 1024..65535" \
"Port \"${new}\" is not valid: use 22 or 1024..65535"
        return 1
    fi
    new=$((10#$new))
    refresh_sshd_config
    local -a cur old=()
    read -ra cur <<< "$SSHD_PORTS"
    for p in "${cur[@]}"; do [ "$p" = "$new" ] || old+=("$p"); done
    if [ "${#old[@]}" -eq 0 ]; then
        log_success_t "SSH уже на порту ${new} — менять нечего" "SSH is already on port ${new} — nothing to change"
        ITEM_DONE=true
        return 0
    fi
    if [ "${#old[@]}" -eq "${#cur[@]}" ]; then phase=open; else phase=close; fi

    if [ ! -f "${SSHD_CONFIG_DIR}/sshd_config" ]; then
        log_error_t "Нет ${SSHD_CONFIG_DIR}/sshd_config — openssh-server не установлен?" \
"No ${SSHD_CONFIG_DIR}/sshd_config — is openssh-server installed?"
        return 1
    fi
    sshd_conflicts
    if [ "$REPLY_SSHD_INCLUDED" != true ]; then
        log_error_t "${SSHD_CONFIG_DIR}/sshd_config не подключает sshd_config.d/*.conf — порт из нашего drop-in не прочитается. Порт не переношу" \
"${SSHD_CONFIG_DIR}/sshd_config does not include sshd_config.d/*.conf — the port in our drop-in would never be read. Not moving the port"
        return 1
    fi
    ssh_foreign_ports
    if [ "${#REPLY_SSH_LISTEN_PORTED[@]}" -gt 0 ]; then
        log_error_t "ListenAddress с явным портом сильнее Port — перенос не сработает. Убери порт из этих строк:" \
"ListenAddress with an explicit port overrides Port — the move would not work. Drop the port from these lines:"
        printf '      %s\n' "${REPLY_SSH_LISTEN_PORTED[@]}"
        return 1
    fi
    if [ "$phase" = open ] && ssh_port_listening "$new"; then
        log_error_t "Порт ${new} уже занят другим процессом (ss -tlnp 'sport = :${new}') — выбери другой" \
"Port ${new} is already taken by another process (ss -tlnp 'sport = :${new}') — pick another one"
        return 1
    fi

    if [ "$USFC_DRY_RUN" != true ]; then
        ssh_selftest_begin || return 1
    fi
    if [ "$phase" = open ]; then
        _ssh_port_open "$new" "${old[@]}" || { ssh_selftest_end; return 1; }
        if [ "$USFC_DRY_RUN" = true ]; then
            log_info_t "Самопроверку входа в сухом прогоне не делаю, и на этом шаге остановлюсь: старый порт закрывается только после проверки входа" \
"Not running the login self-check in a dry run, and stopping here: the old port is closed only after the login is checked"
            return 0
        fi
        if [ "$BULK_MODE" = true ]; then
            _ssh_port_howto_finish "$new"
            ssh_selftest_end
            return 0
        fi
    else
        log_info_t "Перенос на ${new} уже начат: sshd слушает ${cur[*]}" \
"The move to ${new} has already started: sshd listens on ${cur[*]}"
        if ! _ssh_login_ok "$new"; then
            log_error_t "Новый порт не отвечает — старый не закрываю" "The new port does not answer — not closing the old one"
            ssh_selftest_end
            return 1
        fi
    fi

    # Шаг 2 в меню — только после того, как человек вошёл снаружи сам
    if [ "$BULK_MODE" != true ] && [ "$USFC_DRY_RUN" != true ]; then
        _ssh_host_ip
        echo ""
        log_warn_t "Не закрывая это окно, открой НОВОЕ и войди: ${BOLD}ssh -p ${new} ${TARGET_USER}@${REPLY_SSH_IP}${NC}" \
"Without closing this window, open a NEW one and log in: ${BOLD}ssh -p ${new} ${TARGET_USER}@${REPLY_SSH_IP}${NC}"
        # bulk-ok: только в меню — в пакетном режиме сюда не попадаем (условие выше)
        if ! ask_yn_t "Получилось войти по порту ${new}? (да — закрою старый порт)" "Did the login on port ${new} work? (yes closes the old port)" N; then
            _ssh_port_howto_finish "$new"
            ssh_selftest_end
            return 0
        fi
    fi
    _ssh_port_close "$new" "${old[@]}"; rc=$?
    ssh_selftest_end
    return "$rc"
}

# _ssh_port_offer — вопрос «сменить порт?» в меню. Enter оставляет как есть;
# при незавершённом переносе по умолчанию предлагается его цель
_ssh_port_offer() {
    local def new tries=0 cur_label
    refresh_sshd_config
    if ssh_port_pending; then
        def="$REPLY_SSH_PORT_TO"
        log_warn_t "Перенос порта не завершён: открыты ${REPLY_SSH_PORT_FROM} и ${REPLY_SSH_PORT_TO}" \
"The port move is not finished: ${REPLY_SSH_PORT_FROM} and ${REPLY_SSH_PORT_TO} are both open"
    else
        def="$SSH_PORT"
    fi
    cur_label="${SSHD_PORTS// /, }"
    while :; do
        new="$(ask_value_t "Сменить порт SSH? Сейчас ${cur_label}. Новый порт (22 или 1024..65535)" \
"Change the SSH port? Now ${cur_label}. New port (22 or 1024..65535)" "$def")"
        valid_ssh_port "$new" && break
        log_warn_t "Нужен порт 22 или 1024..65535" "Use port 22 or 1024..65535"
        tries=$((tries + 1))
        [ "$tries" -lt 3 ] || return 1
    done
    new=$((10#$new))
    # тот же порт и переносить нечего — ничего не делаем
    [ "$new" = "$SSH_PORT" ] && [ "$SSHD_PORTS" = "$SSH_PORT" ] && return 0
    ssh_port_change "$new"
}

# Hardening на месте: наш drop-in с выключенным паролем, и итоговый конфиг
# с ним согласен. Порт сюда не входит
_ssh_hardening_ok() {
    [ -f "$USFC_SSHD_DROPIN" ] || return 1
    ssh_dropin_scan
    [ "$REPLY_SSH_DROPIN_HARDENED" = true ] || return 1
    [ "$SSHD_PASSWORDAUTH" = no ] && [ "$SSHD_PERMITROOT" != yes ] \
        && [ "$SSHD_PUBKEY" != no ] && [ "${SSHD_KBDINTERACTIVE:-no}" = no ]
}

status_sshhardening() {
    # Незавершённый перенос порта — первым: пока открыты оба порта, старый
    # остаётся открытым наружу, и об этом надо помнить при любом hardening
    if ssh_port_pending; then
        st "$YELLOW" "! порт: перенос ${REPLY_SSH_PORT_FROM// /,} → ${REPLY_SSH_PORT_TO} не завершён" \
                     "! port: move ${REPLY_SSH_PORT_FROM// /,} → ${REPLY_SSH_PORT_TO} not finished"; return 1
    fi
    if [ ! -f "$USFC_SSHD_DROPIN" ] || [ "$REPLY_SSH_DROPIN_HARDENED" != true ]; then
        if [ -f "$USFC_SSHD_DROPIN_OLD" ]; then
            st "$YELLOW" "! старый 10-hardening.conf — примени пункт заново" "! old 10-hardening.conf — apply the item again"; return 1
        fi
        # под прямым root пункт неприменим в принципе (нужен отдельный пользователь) —
        # честнее сказать это сразу, чем показывать «не применено» и молчать о причине
        if [ "$TARGET_USER" = "root" ]; then
            if [ "$SSH_PORT" != 22 ]; then
                st "$DIM" "— нужен обычный пользователь · порт ${SSH_PORT}" "— needs a normal user · port ${SSH_PORT}"; return 1
            fi
            st "$DIM" "— нужен обычный пользователь" "— needs a normal user"; return 1
        fi
        # drop-in может быть и без hardening — только с портом (usfc apply … --ssh-port)
        if [ "$SSH_PORT" != 22 ]; then
            st "$DIM" "○ не применено · порт ${SSH_PORT}" "○ not applied · port ${SSH_PORT}"; return 1
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
    if [ "$SSH_PORT" != 22 ]; then
        st "$GREEN" "✓ только ключи · порт ${SSH_PORT}" "✓ keys only · port ${SSH_PORT}"; return 0
    fi
    st "$GREEN" "✓ применено (только ключи)" "✓ applied (keys only)"; return 0
}

apply_sshhardening() {
    if [ "$TARGET_USER" = "root" ]; then
        # Перенос порта отдельного пользователя не требует: самопроверка входит
        # ключом root (PermitRootLogin prohibit-password по умолчанию это
        # разрешает, а если нет — проверка не пройдёт и всё откатится). Это
        # главный сценарий «curl … | sudo bash -s -- apply … --ssh-port» на
        # свежем сервере, где кроме root никого нет
        if [ "$BULK_MODE" = true ] && [ -n "$SSH_PORT_NEW_BULK" ]; then
            ssh_port_change "$SSH_PORT_NEW_BULK"
            return
        fi
        log_warn_t "Скрипт запущен напрямую под root — hardening требует отдельного пользователя" \
"Running directly as root — hardening needs a separate user"
        log_warn_t "Создай его (adduser <имя> && usermod -aG sudo <имя>) и перезайди под ним" \
"Create one (adduser <name> && usermod -aG sudo <name>) and log back in as them"
        if [ "$BULK_MODE" != true ]; then
            _ssh_port_offer
            return
        fi
        item_skip_t "нужен отдельный пользователь" "needs a separate user"
        return
    fi
    if [ "$BULK_MODE" = true ]; then
        # Явный --ssh-port (SSH_PORT_NEW) — согласие ровно на перенос порта.
        # Ключи и пароль без человека у терминала не трогаем по-прежнему
        if [ -n "$SSH_PORT_NEW_BULK" ]; then
            log_info_t "Пакетный режим: только перенос порта SSH на ${SSH_PORT_NEW_BULK}, вход по паролю и root-логин не трогаю" \
"Batch mode: only moving the SSH port to ${SSH_PORT_NEW_BULK}, password and root login are left alone"
            ssh_port_change "$SSH_PORT_NEW_BULK"
            return
        fi
        log_warn_t "SSH hardening требует явного подтверждения — пропущено в пакетном режиме. Настройте отдельно пунктом $(item_number sshhardening)." \
"SSH hardening needs explicit confirmation — skipped in batch mode. Set it up separately via item $(item_number sshhardening)."
        item_skip_t "только вручную, пункт $(item_number sshhardening)" "manual only, item $(item_number sshhardening)"
        return
    fi
    # Повторный выбор пункта на уже защищённом сервере — не «настроить ещё
    # раз», а то, что осталось: смена порта
    if _ssh_hardening_ok; then
        log_success_t "SSH hardening уже применён: вход только по ключу, root-логин закрыт" \
"SSH hardening is already in place: key-only login, root login disabled"
        _ssh_port_offer
        return
    fi
    # bulk-ok: пункт целиком пропускается в пакете
    if ! ask_yn_t "Настроить SSH hardening для ${TARGET_USER} (ключи вместо пароля, запрет root-логина)?" "Set up SSH hardening for ${TARGET_USER} (keys instead of password, root login disabled)?" N; then
        # незавершённый перенос порта можно довести и без hardening
        if ssh_port_pending; then _ssh_port_offer; return; fi
        return
    fi

    # Файлы, которые мы тронули помимо своего drop-in: при откате они
    # возвращаются из снимка (restore_touched ниже)
    local -a touched=()
    # Вернуть закомментированные чужие строки и sshd_config из снимка — на
    # любом выходе после их правки, включая ранние (нет ключа, самопроверка
    # не прошла): иначе правка дождалась бы ближайшего рестарта sshd без нас
    restore_touched() {
        local f snap
        for f in "${touched[@]}"; do
            snap="${USFC_BACKUP_DIR}${f}"
            [ -f "$snap" ] && cp -p "$snap" "$f"
        done
    }

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
        # bulk-ok: пункт целиком пропускается в пакете
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
    # bulk-ok: пункт целиком пропускается в пакете
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
        _ssh_port_offer
        return
    fi

    ensure_ssh_dir "$TARGET_USER" "$TARGET_HOME" || { log_error_t "Не удалось подготовить ~/.ssh" \
"Could not prepare ~/.ssh"; restore_touched; return 1; }
    local AUTH_KEYS="$REPLY_AUTHKEYS"

    local key_count
    authkeys_count "$AUTH_KEYS"; key_count="$REPLY_AUTHKEYS_COUNT"
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

    # Считаем ключи, а не размер файла: в файле из одних комментариев
    # самопроверка пройдёт временным ключом, а после неё войти будет нечем
    authkeys_count "$AUTH_KEYS"
    if [ "$REPLY_AUTHKEYS_COUNT" -eq 0 ]; then
        log_error_t "В authorized_keys нет ни одного ключа — отключать пароль нельзя. Hardening прерван." \
"authorized_keys holds no keys — disabling the password is not safe. Hardening aborted."
        restore_touched
        return 1
    fi

    # Временный ключ для самопроверки — см. ssh_selftest_begin
    ssh_selftest_begin || { restore_touched; return 1; }

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
        ssh_selftest_end
        return 1
    fi
    log_success_t "Базовый вход по ключу подтверждён" \
"Key login confirmed"

    # Прежний drop-in (повторное применение) помним целиком: в нём могут быть
    # строки Port после переноса порта, и откат удалением файла вернул бы
    # sshd на 22 — мимо файрвола, то есть закрыл бы сервер
    local had_dropin=false prev_dropin=''
    if [ -f "$USFC_SSHD_DROPIN" ]; then
        had_dropin=true
        prev_dropin="$(cat "$USFC_SSHD_DROPIN")"
    fi
    ssh_dropin_scan
    local -a keep_ports=("${REPLY_SSH_DROPIN_PORTS[@]}")
    {
        echo "# usfc: SSH hardening. Named 00-... so that it is read before other drop-ins"
        echo "PermitRootLogin no"
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
        echo "PubkeyAuthentication yes"
        [ -n "$allow_users" ] && echo "AllowUsers ${allow_users}"
        if [ "${#keep_ports[@]}" -gt 0 ]; then
            echo "# usfc: port. Port adds up across files, so Port lines elsewhere are commented out"
            printf 'Port %s\n' "${keep_ports[@]}"
        fi
    } | write_file "$USFC_SSHD_DROPIN"
    # старое имя: оставленный рядом файл продолжал бы действовать
    if [ -f "$USFC_SSHD_DROPIN_OLD" ]; then
        remove_file "$USFC_SSHD_DROPIN_OLD"
        touched+=("$USFC_SSHD_DROPIN_OLD")   # при откате вернётся из снимка
    fi

    rollback_dropin() {
        if [ "$had_dropin" = true ]; then
            printf '%s\n' "$prev_dropin" | write_file "$USFC_SSHD_DROPIN"
        else
            rm -f "$USFC_SSHD_DROPIN"
        fi
        restore_touched
    }

    if ! sshd -t 2>/dev/null; then
        log_error_t "sshd -t не прошёл — откатываю" \
"sshd -t failed — rolling back"
        rollback_dropin
        ssh_selftest_end
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
        ssh_selftest_end
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
        ssh_selftest_end
        return 1
    fi
    refresh_sshd_config

    log_success_t "SSH hardening применён: root-логин выключен, вход только по ключу" \
"SSH hardening applied: root login disabled, key-only login"
    log_info_t "Текущая сессия не разрывалась — рестарт sshd не убивает открытые соединения" \
"Your current session was not dropped — restarting sshd does not kill open connections"
    ssh_selftest_end
    if ! sudo_nopasswd_set "$TARGET_USER" \
       && ask_yn_t "Настроить passwordless sudo для ${TARGET_USER}?" "Set up passwordless sudo for ${TARGET_USER}?"; then
        sudo_nopasswd "$TARGET_USER"
    fi
    _ssh_port_offer
}
