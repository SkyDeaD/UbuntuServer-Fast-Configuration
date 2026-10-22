#!/usr/bin/env bash
# Каталоги в домашнем каталоге пользователя: каждый уровень — его.
#
# Жалоба: btop писал «`~/.config/btop` could not be created: Permission denied».
# Причина — пункт fastfetch создавал ~/.config/fastfetch через `install -d -o
# user`, а install даёт владельца только последнему компоненту: промежуточный
# ~/.config появлялся от root, и дальше в него не мог писать никто, кроме root.
#
# Нужен настоящий root и настоящий chown, поэтому только в одноразовом
# контейнере (как test_install_args.sh).
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "нужен root (запускать в контейнере)" >&2; exit 2; }
export USFC_SOURCE_ONLY=1
# shellcheck disable=SC1090,SC1091
source "${1:-src/setup.sh}"

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
bad() { printf '  ✗ %s\n' "$1"; fail=1; }
owner() { stat -c %U "$1" 2>/dev/null; }

U="usfctest$$"
useradd -m -s /bin/bash "$U" || { echo "useradd не удался" >&2; exit 2; }
trap 'userdel -r "$U" >/dev/null 2>&1' EXIT
# shellcheck disable=SC2034  # читаются в ensure_user_dir
TARGET_USER="$U"
TARGET_HOME="/home/$U"

echo "свежий пользователь без ~/.config"
rm -rf "$TARGET_HOME/.config"
ensure_user_dir "$TARGET_HOME/.config/fastfetch"
[ "$(owner "$TARGET_HOME/.config")" = "$U" ] && ok ".config принадлежит пользователю" || bad ".config: $(owner "$TARGET_HOME/.config")"
[ "$(owner "$TARGET_HOME/.config/fastfetch")" = "$U" ] && ok ".config/fastfetch тоже" || bad "fastfetch: $(owner "$TARGET_HOME/.config/fastfetch")"
if su -s /bin/sh "$U" -c "mkdir '$TARGET_HOME/.config/btop'" 2>/dev/null; then ok "btop может создать свой каталог"; else bad "btop по-прежнему не может"; fi

echo ""
echo "машина, настроенная до 5.0: ~/.config от root"
rm -rf "$TARGET_HOME/.config"
install -d -o root -g root -m 755 "$TARGET_HOME/.config"
install -d -o "$U" -m 755 "$TARGET_HOME/.config/fastfetch"
printf 'root-owned-file\n' > "$TARGET_HOME/.config/keep-root"
ensure_user_dir "$TARGET_HOME/.config"
[ "$(owner "$TARGET_HOME/.config")" = "$U" ] && ok ".config возвращён пользователю" || bad ".config: $(owner "$TARGET_HOME/.config")"
[ "$(owner "$TARGET_HOME/.config/keep-root")" = root ] && ok "без рекурсии: чужие файлы внутри не тронуты" || bad "chown ушёл вглубь"

echo ""
echo "путь вне домашнего каталога"
ensure_user_dir "/tmp/usfc-ud-$$/x"
[ "$(owner "/tmp/usfc-ud-$$/x")" = root ] && ok "вне TARGET_HOME — обычный install -d" || bad "владелец: $(owner "/tmp/usfc-ud-$$/x")"
rm -rf "/tmp/usfc-ud-$$"

echo ""
[ "$fail" -eq 0 ] && echo "каталоги пользователя: все проверки пройдены" || echo "каталоги пользователя: ЕСТЬ ОШИБКИ"
exit "$fail"
