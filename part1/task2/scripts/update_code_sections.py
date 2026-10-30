#!/usr/bin/env python3
"""Uzupelnia sprawozdanie.md tresciami ze zrodel i z zapisanych wynikow. W tekscie znaczniki HTML (niewidoczne w PDF):
   <!-- KOD sciezka od="tekst" do="tekst" -->  ... <!-- /KOD -->  blok kodu z pliku (opcjonalnie fragment: od linii z "od" do linii z "do", bez niej)
   <!-- WYNIK sciezka od="tekst" do="tekst" filtr="regex" --> ... <!-- /WYNIK -->   fragment zapisanego wyniku (od pierwszej linii z "od" do linii z "do", bez niej; "filtr" zostawia tylko pasujace linie)
   <!-- SPRAWDZENIA skrypt.sql wynik.txt -->  ... <!-- /SPRAWDZENIA -->  wynik sprawdzen z kodem polecen wstawionym pod kazdym naglowkiem "--- N. ..."
   <!-- TESTY sciezka -->    ... <!-- /TESTY -->    tabela testow uprawnien z wyniku testu
   <!-- ODCISKI sciezka -->  ... <!-- /ODCISKI -->  tabela porownania zawartosci tabel
Zawartosc miedzy znacznikami jest zastepowana. Wyniki sa oczyszczane z nazw plikow i identyfikatorow kontenera."""
import pathlib, re, shlex
root = pathlib.Path(__file__).resolve().parents[1]
md = root / "sprawozdanie.md"
LANG = {".sql": "sql", ".sh": "bash", ".yml": "yaml", ".xml": "xml", ".hpl": "xml", ".json": "json", "Dockerfile": "dockerfile"}

def clean(text):
    out = []
    for line in text.replace("\r", "").split("\n"):
        line = re.sub(r"^psql:\S+?:\d+: ", "", line)
        line = re.sub(r", Server [0-9a-f]+", "", line)
        line = re.sub(r"^\(\d+ rows?( affected)?\)$", "", line)
        if line.strip() in ("SET", "Changed database context to 'noir'.", "Changed database context to 'msdb'."):
            continue
        line = re.sub(r"(?<![\d\w])\.(\d\d)(?=[|\s]|$)", r"0.\1", line)
        out.append(line.rstrip())
    res = re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip("\n")
    return res

def sliced(text, od, do):
    lines = text.split("\n")
    start, end = 0, len(lines)
    if od:
        start = next(i for i, l in enumerate(lines) if od in l)
    if do:
        end = next(i for i, l in enumerate(lines) if i > start and do in l)
    return "\n".join(lines[start:end])

def block_kod(m):
    path, args = m.group(1), m.group(2) or ""
    kw = dict(a.split("=", 1) for a in shlex.split(args))
    src = sliced((root / path).read_text().rstrip("\n"), kw.get("od"), kw.get("do")).rstrip("\n")
    lang = LANG.get(pathlib.Path(path).suffix) or LANG.get(pathlib.Path(path).name, "")
    return f"<!-- KOD {path}{(' ' + args.strip()) if args else ''} -->\n```{lang}\n{src}\n```\n<!-- /KOD -->"

def block_wynik(m):
    path, args = m.group(1), shlex.split(m.group(2) or "")
    kw = dict(a.split("=", 1) for a in args)
    text = (root / path).read_text()
    part = sliced(text, kw.get("od"), kw.get("do"))
    if kw.get("filtr"):
        part = "\n".join(l for l in part.split("\n") if re.search(kw["filtr"], l))
    body = clean(part)
    return f"<!-- WYNIK {path}{(' ' + m.group(2).strip()) if m.group(2) else ''} -->\n```text\n{body}\n```\n<!-- /WYNIK -->"

def block_sprawdzenia(m):
    src, res = m.group(1), m.group(2)
    hdr = re.compile(r"^(?:\\echo '|PRINT ')(--- .*?)';?$")
    code, cur = {}, None
    for line in (root / src).read_text().replace("\r", "").split("\n"):
        h = hdr.match(line)
        if h:
            cur = h.group(1)
            code[cur] = []
        elif cur and line.strip() and line.strip() != "GO":
            code[cur].append(line)
    out, cur = [], None
    for line in clean((root / res).read_text()).split("\n"):
        if line.startswith("--- "):
            cur = line
            if out and out[-1]:
                out.append("")
            out.append(line)
            out.extend(code.get(line, []))
            out.append("")
        else:
            out.append(line)
    body = "\n".join(out).strip("\n")
    return f"<!-- SPRAWDZENIA {src} {res} -->\n```text\n{body}\n```\n<!-- /SPRAWDZENIA -->"

def block_testy(m):
    path = m.group(1)
    rows = []
    for line in (root / path).read_text().split("\n"):
        t = re.match(r"^(PASS|FAIL)\s+(\S+)\s+expect=(\S+)\s+got=(\S+)\s+\| (.*)$", line)
        if t:
            res, user, exp, got, sql = t.groups()
            rows.append(f"| `{user}` | `{sql.replace('|', chr(92) + '|')}` | {exp} | {got} | {res} |")
    head = "| Użytkownik | Polecenie | Oczekiwano | Wynik | Test |\n|--------|----------------------------------|-----|-----|----|"
    return f"<!-- TESTY {path} -->\n{head}\n" + "\n".join(rows) + "\n<!-- /TESTY -->"

def block_odciski(m):
    path = m.group(1)
    rows = []
    for line in (root / path).read_text().split("\n"):
        t = re.match(r"^(\S+)\s+(\d+)/(\d+)\s+([0-9a-f]{32})\s+([0-9a-f]{32})\s+(TAK|NIE)$", line)
        if t:
            tab, a, b, h1, h2, ok = t.groups()
            rows.append(f"| `{tab}` | {a} | {b} | `{h1[:12]}` | `{h2[:12]}` | {ok} |")
    head = "| Tabela | Wiersze PostgreSQL | Wiersze SQL Server | md5 PostgreSQL | md5 SQL Server | Zgodne |\n|----------------|----|----|----------|----------|----|"
    return f"<!-- ODCISKI {path} -->\n{head}\n" + "\n".join(rows) + "\n<!-- /ODCISKI -->"

text = md.read_text()
subs = [
    (re.compile(r"<!-- KOD (\S+)((?: \w+=\"[^\"]*\")*) -->\n.*?<!-- /KOD -->", re.S), block_kod),
    (re.compile(r"<!-- WYNIK (\S+)((?: \w+=\"[^\"]*\")*) -->\n.*?<!-- /WYNIK -->", re.S), block_wynik),
    (re.compile(r"<!-- SPRAWDZENIA (\S+) (\S+) -->\n.*?<!-- /SPRAWDZENIA -->", re.S), block_sprawdzenia),
    (re.compile(r"<!-- TESTY (\S+) -->\n.*?<!-- /TESTY -->", re.S), block_testy),
    (re.compile(r"<!-- ODCISKI (\S+) -->\n.*?<!-- /ODCISKI -->", re.S), block_odciski),
]
n = 0
for pat, fn in subs:
    text, k = pat.subn(fn, text)
    n += k
md.write_text(text)
print("sekcji uzupelnionych:", n)
