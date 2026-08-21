#!/usr/bin/env bash
# Аудит обязан быть ЧИСТО читающим. Это его главное свойство: диагностика,
# которая что-то чинит по дороге, перестаёт быть диагностикой.
#
# Проверяем тем же слепком, что и сухой прогон, — на глаз такое не ловится.
set -uo pipefail

snapshot() {
    {
        find /etc /root /home -maxdepth 4 -type f -printf '%p %s\n' 2>/dev/null | sort
        dpkg-query -W -f='${Package} ${db:Status-Status}\n' 2>/dev/null | sort
        cat /etc/passwd /etc/group 2>/dev/null
        swapon --show --noheadings --raw 2>/dev/null | sort
        ls /var/lib/apt/lists/ 2>/dev/null | sort
    } | sha256sum | cut -d' ' -f1
}

before="$(snapshot)"
usfc --audit >/tmp/audit.log 2>&1
rc=$?
after="$(snapshot)"

fail=0
[ "$before" = "$after" ] || { echo "FAIL: аудит изменил систему" >&2; fail=1; }
[ "$rc" -eq 0 ] || { echo "FAIL: аудит вернул ${rc}" >&2; fail=1; }
grep -q 'Итог:' /tmp/audit.log || { echo "FAIL: нет итоговой строки" >&2; tail -5 /tmp/audit.log >&2; fail=1; }
# отчёт должен быть содержательным, а не пустым каркасом
[ "$(grep -cE '^\s+[✓!✗]' /tmp/audit.log)" -ge 8 ] \
    || { echo "FAIL: слишком мало проверок в отчёте" >&2; fail=1; }

# ── машинный вывод ───────────────────────────────────────────────────────────
before_json="$(snapshot)"
usfc --audit --json > /tmp/audit.json 2>/tmp/audit.json.err
json_rc=$?
[ "$before_json" = "$(snapshot)" ] || { echo "FAIL: --audit --json изменил систему" >&2; fail=1; }
[ "$json_rc" -eq 0 ] || { echo "FAIL: --audit --json вернул ${json_rc}" >&2; fail=1; }
[ -s /tmp/audit.json.err ] && { echo "FAIL: --audit --json написал в stderr" >&2; cat /tmp/audit.json.err >&2; fail=1; }

# Ни цветов, ни лишних строк вокруг документа: и то и другое ломает потребителя
grep -q $'\033\[' /tmp/audit.json && { echo "FAIL: в JSON попал ANSI-код" >&2; fail=1; }
grep -qF '\033[' /tmp/audit.json && { echo "FAIL: в JSON попал буквальный \\033[" >&2; fail=1; }

python3 - /tmp/audit.json <<'PYJSON' || fail=1
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
bad = []
s = d["summary"]
if len(d["findings"]) != s["total"]:
    bad.append("находок %d, total %d" % (len(d["findings"]), s["total"]))
if s["ok"] + s["warn"] + s["crit"] != s["total"]:
    bad.append("счётчики не сходятся с total")
if not d["findings"]:
    bad.append("находок нет вовсе")
seen = set()
for f in d["findings"]:
    if f["level"] not in ("ok", "warn", "crit"):
        bad.append("уровень %r" % f["level"])
    if not re.match(r"^[a-z0-9_]+(\.[a-z0-9_]+)*$", f["id"]):
        bad.append("ключ %r не машинный" % f["id"])
    # value и unit ходят только парой
    if ("value" in f) != ("unit" in f):
        bad.append("%s: value и unit не парой" % f["id"])
    if "value" in f and not isinstance(f["value"], (int, float)):
        bad.append("%s: value не число" % f["id"])
    key = (f["id"], f.get("subject", ""))
    if key in seen:
        bad.append("повтор ключа %s" % f["id"])
    seen.add(key)
for b in bad:
    print("FAIL: JSON — " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PYJSON

# Самая ценная проверка: ключи не должны выводиться из текста. Набор
# (id, level) обязан совпасть на двух языках, а тексты — различаться
usfc --audit --json --lang en > /tmp/audit.en.json 2>/dev/null
python3 - /tmp/audit.json /tmp/audit.en.json <<'PYLANG' || fail=1
import json, sys
ru = json.load(open(sys.argv[1], encoding="utf-8"))["findings"]
en = json.load(open(sys.argv[2], encoding="utf-8"))["findings"]
kr = [(f["id"], f["level"]) for f in ru]
ke = [(f["id"], f["level"]) for f in en]
ok = True
if kr != ke:
    print("FAIL: набор (id, level) разошёлся между языками", file=sys.stderr); ok = False
if [f["text"] for f in ru] == [f["text"] for f in en]:
    print("FAIL: тексты на двух языках совпали — перевод не подставился", file=sys.stderr); ok = False
sys.exit(0 if ok else 1)
PYLANG

[ "$fail" -eq 0 ] && echo "аудит: система не изменилась, отчёт содержательный, JSON валиден"
exit "$fail"
