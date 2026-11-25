#!/usr/bin/env bash
# Аудит обязан быть ЧИСТО читающим. Это его главное свойство: диагностика,
# которая что-то чинит по дороге, перестаёт быть диагностикой.
#
# Проверяем тем же слепком, что и сухой прогон, — на глаз такое не ловится.
set -uo pipefail

cert_stub_dir=""
created_le_root=false
created_le_live=false
created_cert_a=false
created_cert_b=false
cleanup() {
    [ -n "$cert_stub_dir" ] && rm -rf "$cert_stub_dir"
    [ "$created_cert_a" = true ] && rm -rf /etc/letsencrypt/live/a.example
    [ "$created_cert_b" = true ] && rm -rf /etc/letsencrypt/live/b.example
    [ "$created_le_live" = true ] && rmdir /etc/letsencrypt/live 2>/dev/null || true
    [ "$created_le_root" = true ] && rmdir /etc/letsencrypt 2>/dev/null || true
}
trap cleanup EXIT

snapshot() {
    {
        find /etc /root /home -maxdepth 4 -type f -printf '%p %s\n' 2>/dev/null | sort
        dpkg-query -W -f='${Package} ${db:Status-Status}\n' 2>/dev/null | sort
        cat /etc/passwd /etc/group 2>/dev/null
        swapon --show --noheadings --raw 2>/dev/null | sort
        ls /var/lib/apt/lists/ 2>/dev/null | sort
    } | sha256sum | cut -d' ' -f1
}

log_state() {
    if [ ! -e /var/log/usfc.log ]; then
        printf 'absent'
    else
        stat -c '%s %Y' /var/log/usfc.log 2>/dev/null
        sha256sum /var/log/usfc.log 2>/dev/null | cut -d' ' -f1
    fi
}

# Без python3 проверки JSON молча превратились бы в ничто, а тест продолжал бы
# «проходить» — ровно та деградация, из-за которой в 2.0.0 тесты раскладки
# полгода ничего не проверяли. Лучше отказаться сразу.
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 не найден — проверить JSON нечем, тест бессмыслен" >&2
    exit 2
fi

log_before="$(log_state)"
before="$(snapshot)"
usfc audit >/tmp/audit.log 2>&1
rc=$?
after="$(snapshot)"

fail=0
[ "$before" = "$after" ] || { echo "FAIL: аудит изменил систему" >&2; fail=1; }
[ "$(log_state)" = "$log_before" ] || { echo "FAIL: usfc audit создал или изменил /var/log/usfc.log" >&2; fail=1; }
# 0 — критичного нет, 1 — есть; что-то другое — аудит упал. Соответствие
# числу critical сверяется ниже по JSON
[ "$rc" -le 1 ] || { echo "FAIL: аудит вернул ${rc}" >&2; fail=1; }
grep -q 'Итог:' /tmp/audit.log || { echo "FAIL: нет итоговой строки" >&2; tail -5 /tmp/audit.log >&2; fail=1; }
# отчёт должен быть содержательным, а не пустым каркасом
[ "$(grep -cE '^\s+[✓!✗]' /tmp/audit.log)" -ge 8 ] \
    || { echo "FAIL: слишком мало проверок в отчёте" >&2; fail=1; }

# ── машинный вывод ───────────────────────────────────────────────────────────
before_json="$(snapshot)"
usfc audit --json > /tmp/audit.json 2>/tmp/audit.json.err
json_rc=$?
[ "$before_json" = "$(snapshot)" ] || { echo "FAIL: audit --json изменил систему" >&2; fail=1; }
[ "$(log_state)" = "$log_before" ] || { echo "FAIL: audit --json создал или изменил /var/log/usfc.log" >&2; fail=1; }
[ "$json_rc" -eq "$rc" ] || { echo "FAIL: audit --json вернул ${json_rc}, текстовый — ${rc}" >&2; fail=1; }
[ -s /tmp/audit.json.err ] && { echo "FAIL: audit --json написал в stderr" >&2; cat /tmp/audit.json.err >&2; fail=1; }

# Ни цветов, ни лишних строк вокруг документа: и то и другое ломает потребителя
grep -q $'\033\[' /tmp/audit.json && { echo "FAIL: в JSON попал ANSI-код" >&2; fail=1; }
grep -qF '\033[' /tmp/audit.json && { echo "FAIL: в JSON попал буквальный \\033[" >&2; fail=1; }

python3 - /tmp/audit.json "$json_rc" <<'PYJSON' || fail=1
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
bad = []
s = d["summary"]
if (s["crit"] > 0) != (sys.argv[2] == "1"):
    bad.append("код возврата %s при crit=%d" % (sys.argv[2], s["crit"]))
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
usfc --lang en audit --json > /tmp/audit.en.json 2>/dev/null
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

# ── фильтр --only-problems (текст и JSON) ────────────────────────────────────
# Прячет ok-строки, но сохраняет warn/crit и полные итоговые счётчики
before_prob="$(snapshot)"
usfc audit --only-problems > /tmp/audit-prob.log 2>&1
prob_rc=$?
usfc audit --only-problems --json > /tmp/audit-prob.json 2>/tmp/audit-prob.json.err
prob_json_rc=$?
[ "$before_prob" = "$(snapshot)" ] || { echo "FAIL: audit --only-problems изменил систему" >&2; fail=1; }
[ "$(log_state)" = "$log_before" ] || { echo "FAIL: audit --only-problems создал или изменил /var/log/usfc.log" >&2; fail=1; }
[ "$prob_rc" -eq "$rc" ] || { echo "FAIL: audit --only-problems вернул ${prob_rc}, обычный — ${rc}" >&2; fail=1; }
[ "$prob_json_rc" -eq "$json_rc" ] || { echo "FAIL: audit --only-problems --json вернул ${prob_json_rc}, обычный — ${json_rc}" >&2; fail=1; }
[ -s /tmp/audit-prob.json.err ] && { echo "FAIL: audit --only-problems --json написал в stderr" >&2; cat /tmp/audit-prob.json.err >&2; fail=1; }

python3 - /tmp/audit.json /tmp/audit-prob.json /tmp/audit-prob.log <<'PYPROB' || fail=1
import json, re, sys
full = json.load(open(sys.argv[1], encoding="utf-8"))
prob = json.load(open(sys.argv[2], encoding="utf-8"))
txt = open(sys.argv[3], encoding="utf-8").read()
txt_plain = re.sub(r"\x1b\[[0-9;]*m", "", txt)

bad = []
if prob["summary"] != full["summary"]:
    bad.append("summary разошёлся: %r != %r" % (prob["summary"], full["summary"]))
if any(f["level"] == "ok" for f in prob["findings"]):
    bad.append("в --only-problems --json попали ok-находки")
want = [(f["id"], f["level"], f.get("subject", "")) for f in full["findings"] if f["level"] != "ok"]
got  = [(f["id"], f["level"], f.get("subject", "")) for f in prob["findings"]]
if got != want:
    bad.append("набор проблемных находок разошёлся: %r != %r" % (got, want))

s = full["summary"]
n_prob = s["warn"] + s["crit"]
ok_lines = re.findall(r"^\s+✓\s", txt_plain, re.M)
prob_lines = re.findall(r"^\s+[!✗]\s", txt_plain, re.M)
if n_prob > 0:
    if ok_lines:
        bad.append("в текстовом --only-problems остались ✓-строки: %d" % len(ok_lines))
    if len(prob_lines) != n_prob:
        bad.append("в текстовом --only-problems строк [!✗]: %d, ждали %d" % (len(prob_lines), n_prob))
else:
    if "Замечаний нет" not in txt_plain:
        bad.append("при 0 проблемах нет строки «Замечаний нет»")

m = re.search(r"Итог:\s+в норме:\s+(\d+)\s+замечаний:\s+(\d+)\s+важных:\s+(\d+)", txt_plain)
if not m:
    bad.append("в текстовом --only-problems нет итоговой строки со счётчиками")
else:
    counts = tuple(int(x) for x in m.groups())
    if counts != (s["ok"], s["warn"], s["crit"]):
        bad.append("итоговые счётчики в тексте %r != %r" % (counts, (s["ok"], s["warn"], s["crit"])))

for b in bad:
    print("FAIL: --only-problems — " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PYPROB

# ── сертификаты (audit_certs): разные subject и value/unit=days в JSON ───────
# Выполняется ПОСЛЕ всех проверок слепком выше; временные каталоги и shim
# openssl убираются в trap EXIT.
[ -d /etc/letsencrypt ] || { mkdir -p /etc/letsencrypt; created_le_root=true; }
[ -d /etc/letsencrypt/live ] || { mkdir -p /etc/letsencrypt/live; created_le_live=true; }
if [ ! -e /etc/letsencrypt/live/a.example ]; then
    mkdir -p /etc/letsencrypt/live/a.example
    printf 'DUMMY CERT A\n' > /etc/letsencrypt/live/a.example/cert.pem
    created_cert_a=true
fi
if [ ! -e /etc/letsencrypt/live/b.example ]; then
    mkdir -p /etc/letsencrypt/live/b.example
    printf 'DUMMY CERT B\n' > /etc/letsencrypt/live/b.example/cert.pem
    created_cert_b=true
fi

cert_stub_dir="$(mktemp -d)"
cat > "${cert_stub_dir}/openssl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *a.example*) printf 'notAfter=%s\n' "$(date -u -d '+60 days' '+%b %e %H:%M:%S %Y GMT')" ;;
    *b.example*) printf 'notAfter=%s\n' "$(date -u -d '+10 days' '+%b %e %H:%M:%S %Y GMT')" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "${cert_stub_dir}/openssl"

PATH="${cert_stub_dir}:${PATH}" usfc audit --json > /tmp/audit-certs.json 2>/tmp/audit-certs.err
certs_rc=$?
[ "$certs_rc" -eq 1 ] || { echo "FAIL: audit_certs с crit-сертификатом вернул ${certs_rc}, ждали 1" >&2; fail=1; }
[ -s /tmp/audit-certs.err ] && { echo "FAIL: audit_certs написал в stderr" >&2; cat /tmp/audit-certs.err >&2; fail=1; }
[ "$(log_state)" = "$log_before" ] || { echo "FAIL: audit_certs создал или изменил /var/log/usfc.log" >&2; fail=1; }

python3 - /tmp/audit-certs.json <<'PYCERTS' || fail=1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
bad = []
findings = d["findings"]
seen = set()
certs = {}
for f in findings:
    key = (f["id"], f.get("subject", ""))
    if key in seen:
        bad.append("повтор ключа %r" % (key,))
    seen.add(key)
    if f["id"] == "cert.expiry":
        subj = f.get("subject", "")
        if not subj:
            bad.append("у cert.expiry пустой subject")
        else:
            certs[subj] = f
    elif f.get("subject") in ("a.example", "b.example"):
        bad.append("subject %r утёк в чужую находку %s" % (f.get("subject"), f["id"]))

for dom, exp_lvl, lo, hi in (("a.example", "ok", 55, 61), ("b.example", "crit", 8, 11)):
    f = certs.get(dom)
    if not f:
        bad.append("нет cert.expiry для %s" % dom)
        continue
    if f.get("level") != exp_lvl:
        bad.append("%s: level=%r, ждали %r" % (dom, f.get("level"), exp_lvl))
    if f.get("unit") != "days":
        bad.append("%s: unit=%r, ждали 'days'" % (dom, f.get("unit")))
    val = f.get("value")
    if not isinstance(val, int) or not (lo <= val <= hi):
        bad.append("%s: value=%r вне [%d, %d]" % (dom, val, lo, hi))

if d["summary"]["total"] != len(findings):
    bad.append("summary.total=%d != len(findings)=%d" % (d["summary"]["total"], len(findings)))

for b in bad:
    print("FAIL: audit_certs — " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PYCERTS

[ "$fail" -eq 0 ] && echo "аудит: система не изменилась, отчёт содержательный, JSON валиден"
exit "$fail"
