#!/usr/bin/env python3
"""Сторож двуязычности: ищет пользовательский текст без английской пары.

Интерфейс двуязычный с 4.0.0, но перевод живёт РЯДОМ С ВЫЗОВОМ (см. шапку
src/lib/i18n.sh). Забытый второй вариант ничем себя не выдаёт: по-русски всё
выглядит правильно, и дыру видит только англоязычный пользователь.

Инвариант: строка исходника с кириллицей вне комментария обязана быть вызовом
семейства t() с ДВУМЯ строковыми аргументами подряд. Требование «две строки
подряд» ловит и второй класс ошибок — `t "Что-то"` без английской пары.

Грепом это не сделать: мешают продолжения через \\, многострочные
usfc_item_full и тела heredoc. Отсюда отдельный разборщик.

Осознанное исключение помечается комментарием `i18n-ok` прямо на строке, и
рядом же пишется причина. Список исключений внутри теста разъехался бы с кодом,
а комментарий у строки — нет.

Запуск: python3 tests/i18n_scan.py <файлы...>
Печатает по строке на находку, код возврата 1 при непустом результате.
"""
import re, sys

CYR      = re.compile(r'[А-Яа-яЁё]')
CYR_WORD = re.compile(r'[А-Яа-яЁё][А-Яа-яЁё-]*')
T_CALL   = re.compile(r'\b(?:t|st|log_(?:info|success|warn|error)_t|ask_yn_t|ask_value_t|resolve_autostart_t'
                      r'|_audit_t|_audit_section_t|usfc_item|usfc_item_full|usfc_item_rollback)\b')
TWO_STR  = re.compile(r'"(?:[^"\\]|\\.)*"\s*"(?:[^"\\]|\\.)*"', re.S)
# внутренние ключи разделов: это не пользовательский текст, а имена веток case
KEYS     = {"система", "база", "сервисы", "защита"}
HEREDOC  = re.compile(r"<<-?\s*'?\"?([A-Za-z_][A-Za-z0-9_]*)'?\"?")

def strip_comment(s):
    """убрать хвостовой комментарий, не тронув # внутри кавычек"""
    out, q, i = [], None, 0
    while i < len(s):
        c = s[i]
        if q:
            if c == '\\' and i + 1 < len(s): out.append(c); i += 1; c = s[i]
            elif c == q: q = None
        elif c in '"\'': q = c
        elif c == '#' and (not out or out[-1] in ' \t;&|()'):
            break
        out.append(c); i += 1
    return ''.join(out)

def logical_lines(path):
    """склеиваем продолжения, открытые строки и пропускаем тела heredoc"""
    raw = open(path, encoding='utf-8').read().splitlines()
    i, n = 0, len(raw)
    while i < n:
        start, buf = i, raw[i]
        m = HEREDOC.search(strip_comment(buf))
        if m:                                  # тело heredoc — не код
            delim = m.group(1); i += 1
            while i < n and raw[i].strip() != delim: i += 1
            i += 1
            yield start + 1, buf
            continue
        while True:
            cont = buf.rstrip().endswith('\\')
            odd  = (len(re.findall(r'(?<!\\)"', buf)) % 2) == 1
            if not (cont or odd) or i + 1 >= n: break
            i += 1
            buf = buf.rstrip()[:-1] + ' ' + raw[i] if cont else buf + '\n' + raw[i]
        yield start + 1, buf
        i += 1

def scan(paths):
    bad = []
    for p in paths:
        skip_until = None
        if p.endswith('src/setup.sh') or p.endswith('lib/ident.sh'):
            continue                            # печатают до того, как есть t()
        for ln, text in logical_lines(p):
            code = strip_comment(text)
            if skip_until is not None:
                if code.strip() == skip_until: skip_until = None
                continue
            if 'i18n-ok' in text:               # явное исключение с причиной рядом
                # Пометка на открытии блока накрывает блок целиком: иначе карту
                # описаний пакетов пришлось бы метить построчно, все два десятка
                if code.rstrip().endswith('=('): skip_until = ')'
                continue
            if not CYR.search(code): continue
            if T_CALL.search(code) and TWO_STR.search(code): continue
            if all(w.lower() in KEYS for w in CYR_WORD.findall(code)): continue
            first = code.strip().splitlines()[0]
            bad.append((p, ln, first[:88]))
    return bad


if __name__ == '__main__':
    hits = scan(sys.argv[1:])
    for path, line, text in hits:
        print("%s:%s: %s" % (path, line, text))
    sys.exit(1 if hits else 0)
