# Biuro detektywistyczne noir (PostgreSQL 17 w Dockerze)

Baza relacyjna dla agencji detektywistycznej. Case study i projekt: [`case_study.md`](case_study.md); sprawozdanie: [`sprawozdanie.md`](sprawozdanie.md).

## Wymagania
Docker + Docker Compose v2, opcjonalnie klient `psql`.

## Uruchomienie
```bash
cd part1/task1
docker compose up -d          # pobiera postgres:17, tworzy bazę i wykonuje sql/01..05 (tylko przy pierwszym starcie)
docker compose ps             # czekaj na status "healthy"
docker compose logs db | grep -i error   # powinno być puste
```
Skrypty z `sql/*.sql` są wykonywane automatycznie w kolejności alfabetycznej:

| Plik | Zawartość |
|---|---|
| `sql/01_schema.sql` | schemat `noir`, 20 tabel (słowniki, główne, asocjacyjne), klucze, ograniczenia |
| `sql/02_seed.sql` | dane przykładowe |
| `sql/03_views.sql` | 5 perspektyw |
| `sql/04_roles.sql` | użytkownicy i uprawnienia |
| `sql/05_indexes.sql` | indeksy |
| `sql/manual/queries.sql` | 2 złożone zapytania (uruchamiane ręcznie) |
| `sql/manual/views_demo.sql` | przykładowe wyniki widoków (ręcznie) |
| `sql/manual/08_perf.sql` | test wydajności indeksów na danych syntetycznych (ręcznie) |
| `sql/tests/permissions.sh` | test uprawnień użytkowników |

## Połączenie
```bash
docker compose exec db psql -U noir_admin -d noir                       # administrator
PGPASSWORD=detective_pw  psql -h localhost -U detective_app  -d noir     # detektyw
PGPASSWORD=accountant_pw psql -h localhost -U accountant_app -d noir     # księgowy
PGPASSWORD=client_pw     psql -h localhost -U client_portal  -d noir     # klient
```
Hasła są wyłącznie deweloperskie.

## Testy
```bash
docker compose exec -T db bash /tests/permissions.sh                                  # uprawnienia (26 testów)
docker compose exec -T db psql -U noir_admin -d noir -f /manual/queries.sql   # zapytania
docker compose exec -T db psql -U noir_admin -d noir -f /manual/08_perf.sql            # indeksy (ok. 30 s)
```
Zapisane wyniki: katalog `results/`.

## Reset od zera
```bash
docker compose down -v && docker compose up -d
```

## Diagramy
`diagrams/erd.drawio` (ERD) i `diagrams/schemat_logiczny.drawio` (schemat logiczny), eksporty PDF w `diagrams/pdf/` - otwórz w [draw.io](https://app.diagrams.net) lub rozszerzeniu VS Code *Draw.io Integration*; eksport PNG/PDF przez *File → Export as*.
Schemat logiczny jest generowany z katalogu systemowego bazy, więc zgadza się z zaimplementowanymi tabelami.

## Przenośność
Schemat używa standardowych typów (`VARCHAR`, `INTEGER`, `NUMERIC`, `DATE`, `TIMESTAMP`), `GENERATED ALWAYS AS IDENTITY`, nazwanych ograniczeń, słowników w postaci tabel (bez ENUM) i bez `jsonb`/tablic.

## Generowanie PDF
```bash
./build_pdf.sh    # wymaga dockera (obraz pandoc/latex) i pdfunite
```
Powstają samowystarczalne `pdf/case_study.pdf` i `pdf/sprawozdanie.pdf` (diagramy osadzone w treści, kod SQL w załącznikach). Diagramy pochodzą z `diagrams/pdf/` (eksport z draw.io).
