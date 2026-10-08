# Sprawozdanie - Etap 1: baza danych biura detektywistycznego noir - Radosław Dąbkowski 325683


## 1. Struktura bazy i decyzje projektowe (3NF, klucze, typy)

Schemat logiczny bazy (typy danych, klucze główne i obce, ograniczenia UNIQUE i NOT NULL oraz indeksy; tabele słownikowe są żółte, asocjacyjne fioletowe):

```{=latex}
\newpage
\newgeometry{landscape,margin=1cm}
\special{papersize=29.7cm,21cm}
```

![](diagrams/pdf/schemat_logiczny.pdf){ width=27cm }

```{=latex}
\newpage
\restoregeometry
\special{papersize=21cm,29.7cm}
```

Baza zawiera 20 tabel w schemacie `noir`:

- **słownikowe (5):** `case_status`, `case_type`, `evidence_type`, `detective_rank`, `payment_method`;
- **główne (11):** `client`, `detective`, `location`, `case_file`, `suspect`, `witness`, `informant`, `evidence`, `tip`, `invoice`, `payment`;
- **asocjacyjne (4):** `case_detective`, `case_suspect`, `case_witness`, `evidence_custody`.

Pełny skrypt tworzący schemat znajduje się na końcu dokumentu, w sekcji „Skrypt tworzący schemat bazy”.

- **3NF:** wszystkie atrybuty niekluczowe zależą od klucza głównego tabeli (w tabelach z kluczem złożonym od całego klucza głównego) i tylko od niego. Zależności przechodnie wyeliminowano słownikami (status, typ, stopień, metoda płatności) - stawka godzinowa zależy od stopnia, więc jest w `detective_rank`, nie w `detective`. Salda faktur i liczba dni sprawy **nie są przechowywane** - liczone w widokach, co usuwa redundancję. Baza nie odchodzi od 3NF. Data zamknięcia `closed_on` jest faktem biznesowym zależnym od klucza głównego sprawy (status mówi, że sprawa jest zamknięta, ale nie kiedy), więc nie da się jej wyliczyć ze statusu i nie jest to zależność przechodnia. Spójność między statusem „Closed…” a wypełnieniem `closed_on` nie jest wymuszona w schemacie: ograniczenie `ck_case_file_dates` sprawdza tylko, że `closed_on >= opened_on`, a ograniczenie `CHECK` nie może odwołać się do nazwy statusu z innej tabeli. Pilnowanie tej reguły należy do aplikacji.
- **Klucze złożone:** trzy z czterech tabel asocjacyjnych mają klucz główny złożony z dwóch kolumn (czwarta, `evidence_custody`, ma klucz zastępczy, opisany niżej). W `case_detective` kluczem jest para (`case_id`, `detective_id`), więc ten sam detektyw może być przypisany do danej sprawy tylko raz. W `case_suspect` kluczem jest para (`case_id`, `suspect_id`), więc dany podejrzany może być powiązany z daną sprawą tylko raz. W `case_witness` kluczem jest para (`case_id`, `witness_id`), więc dany świadek składa w danej sprawie jedno zeznanie.
- **Klucze zastępcze:** `INTEGER/SMALLINT GENERATED ALWAYS AS IDENTITY`; naturalne identyfikatory (`case_number`, `evidence_code`, `invoice_number`, `license_no`, `email`, `codename`) mają `UNIQUE`. Klucz zastępczy ma też `evidence_custody` (`custody_id`), bo ten sam dowód może być przekazywany wielokrotnie, a znacznik czasu przekazania da się zmienić bez zmiany klucza głównego. Regułę, że jeden dowód nie ma dwóch przekazań w tej samej chwili, zapewnia ograniczenie `UNIQUE (evidence_id, transferred_at)`.
- **Ograniczenia:** CHECK dla zakresów ocen (1-5), kwot (stawka godzinowa, kwota faktury i kwota płatności muszą być dodatnie: `> 0`, bo zero oznaczałoby pusty wpis lub pomyłkę; szacowana opłata za sprawę `fee_estimate >= 0`, bo sprawa może być bez opłaty; opłata za wskazówkę informatora `fee_per_tip >= 0`), dat (`closed_on >= opened_on`, `due_on >= issued_on`), roli (`LEAD`/`ASSISTANT`); unikalny indeks częściowy pilnuje, by sprawa miała najwyżej jednego prowadzącego (`LEAD`).
- **NULL:** dozwolony tylko tam, gdzie brak wartości ma sens, np. `closed_on`, `phone`, `alias`, `birth_date`, `statement`, `company_name`, `description`, `street`, `notes`, `last_seen_location_id`, `note` w łańcuchu dowodowym i `location_id` dowodu.
- **Typy:** `NUMERIC(10,2)` dla pieniędzy (nie `FLOAT`), `DATE` tam gdzie czas dnia nie ma znaczenia, `TIMESTAMP` dla znalezienia dowodu, przekazań i otrzymania wskazówki, `VARCHAR(n)` z rozsądnymi limitami.
- **Przenośność:** unikanie ENUM, tablic i `jsonb`.

## 2. Dane
Dane przykładowe (kod na końcu dokumentu, w sekcji „Dane przykładowe”) układają się w spójną, realistyczną opowieść w klimacie *noir*: każda tabela ma co najmniej 4 rekordy, a rekordy powiązane kluczami obcymi opisują te same sprawy od zlecenia, przez śledztwo (podejrzani, świadkowie, informatorzy, dowody z łańcuchem dowodowym), aż po rozliczenie (faktury i płatności). Dane do testu indeksów (300 000 spraw, 1 000 000 dowodów) generowane są funkcją `generate_series`/`random()` w osobnym schemacie `perf`, żeby nie mieszać ich z danymi biznesowymi.

## 3. Użytkownicy i uprawnienia
| Użytkownik | Dostęp |
|---|---|
| `noir_admin` | właściciel schematu, wszystko |
| `detective_app` | SELECT na tabelach śledztwa (w tym `client`) i widokach `v_case_overview`, `v_detective_workload`, `v_evidence_chain`, `v_client_cases`; INSERT/UPDATE na sprawach, dowodach, podejrzanych, świadkach, wskazówkach, miejscach, informatorach oraz na powiązaniach sprawa-detektyw, sprawa-podejrzany i sprawa-świadek; INSERT (bez UPDATE i DELETE) na łańcuchu dowodowym, żeby historii przekazań nie dało się zmienić; DELETE tylko na powiązaniach sprawa-podejrzany i sprawa-świadek (usuwanie pomyłek); brak usuwania spraw i dowodów; brak dostępu do finansów |
| `accountant_app` | widok `v_invoice_balance`; SELECT/INSERT/UPDATE na `invoice` (wystawianie i korekta faktur); SELECT/INSERT/UPDATE/DELETE na `payment` (rejestracja i korekta wpłat); SELECT na `payment_method`; z `case_file` tylko kolumny potrzebne do fakturowania (`case_id`, `case_number`, `title`, `client_id`, `fee_estimate`); brak dostępu do danych śledztwa; faktur nie usuwa (korekta przez UPDATE) |
| `client_portal` | wyłącznie widok `v_client_cases` |

Zasada: `client_portal` sięga do danych **tylko przez widok** (widoki wykonują się z uprawnieniami właściciela), a `accountant_app` ma bezpośredni dostęp wyłącznie do tabel finansowych i wybranych kolumn `case_file`. `PUBLIC` ma odebrany dostęp do schematu `public`.

Skrypt tworzący użytkowników i nadający uprawnienia znajduje się na końcu dokumentu, w sekcji „Użytkownicy i uprawnienia”.

**Test:** każde polecenie wykonano jako dany użytkownik wewnątrz transakcji wycofywanej na końcu (`ROLLBACK`), więc test nie zmienia danych. „DENIED" oznacza błąd `permission denied`. Wynik: 39 z 39 testów zakończonych powodzeniem.

| Użytkownik | Polecenie | Oczekiwano | Wynik | Test |
|---|---|---|---|---|
| `detective_app` | `SELECT count(*) FROM case_file` | OK | OK | PASS |
| `detective_app` | `INSERT INTO witness (first_name,last_name,reliability) VALUES ('Test','Witness',3)` | OK | OK | PASS |
| `detective_app` | `SELECT * FROM invoice` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM v_invoice_balance` | DENIED | DENIED | PASS |
| `detective_app` | `DELETE FROM evidence` | DENIED | DENIED | PASS |
| `detective_app` | `INSERT INTO evidence_custody (evidence_id,transferred_at,detective_id,note) VALUES (1,now(),1,'Test')` | OK | OK | PASS |
| `detective_app` | `UPDATE evidence_custody SET note = 'zmiana'` | DENIED | DENIED | PASS |
| `detective_app` | `DELETE FROM evidence_custody` | DENIED | DENIED | PASS |
| `detective_app` | `INSERT INTO location (name,city) VALUES ('Test','Test')` | OK | OK | PASS |
| `detective_app` | `DELETE FROM case_suspect` | OK | OK | PASS |
| `detective_app` | `DELETE FROM case_file` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM v_invoice_balance` | OK | OK | PASS |
| `accountant_app` | `SELECT * FROM case_file` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM suspect` | DENIED | DENIED | PASS |
| `accountant_app` | `INSERT INTO payment (invoice_id,method_id,paid_on,amount) VALUES (6,2,CURRENT_DATE,100)` | OK | OK | PASS |
| `accountant_app` | `SELECT * FROM payment` | OK | OK | PASS |
| `accountant_app` | `SELECT case_id, case_number, fee_estimate FROM case_file` | OK | OK | PASS |
| `accountant_app` | `INSERT INTO invoice (invoice_number,case_id,issued_on,due_on,amount) VALUES ('FV-TEST',1,CURRENT_DATE,CURRENT_DATE,100)` | OK | OK | PASS |
| `accountant_app` | `UPDATE invoice SET due_on = due_on + 14` | OK | OK | PASS |
| `accountant_app` | `DELETE FROM payment` | OK | OK | PASS |
| `accountant_app` | `DELETE FROM invoice` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT description FROM case_file` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM v_client_cases` | OK | OK | PASS |
| `client_portal` | `SELECT * FROM case_file` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM v_case_overview` | DENIED | DENIED | PASS |
| `client_portal` | `INSERT INTO client (first_name,last_name,email) VALUES ('a','b','c')` | DENIED | DENIED | PASS |
| `detective_app` | `INSERT INTO case_detective (case_id,detective_id,role,assigned_on) VALUES (1,6,'ASSISTANT',CURRENT_DATE)` | OK | OK | PASS |
| `detective_app` | `DELETE FROM case_detective` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM v_evidence_chain` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM v_detective_workload` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM v_case_overview` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM v_client_cases` | OK | OK | PASS |
| `client_portal` | `SELECT * FROM v_invoice_balance` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM v_evidence_chain` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM v_detective_workload` | DENIED | DENIED | PASS |
| `detective_app` | `UPDATE case_file SET fee_estimate = fee_estimate + 1` | OK | OK | PASS |
| `detective_app` | `UPDATE informant SET trust_level = 3` | OK | OK | PASS |
| `accountant_app` | `UPDATE payment SET amount = amount + 1` | OK | OK | PASS |
| `accountant_app` | `SELECT * FROM payment_method` | OK | OK | PASS |

**Znane ograniczenie rozwiązania:** `v_client_cases` zwraca sprawy **wszystkich** klientów (kolumna `client_email` służy do filtrowania przez aplikację). Prawdziwa izolacja wymagałaby Row-Level Security lub osobnej roli na klienta, co jest poza zakresem projektu.

## 4. Zapytania
### Zapytanie 1: detektywi z liczbą aktywnych spraw nie większą niż średnia
Zapytanie korzysta z widoku `v_detective_workload` (opisanego w sekcji Perspektywy), który liczy aktywne sprawy aktywnych detektywów (łączenie zewnętrzne od detektywów, dzięki czemu uwzględnieni są także ci bez żadnej aktywnej sprawy, a nieaktywni są pomijani), dzięki czemu definicja „aktywnej sprawy” jest w jednym miejscu. `WITH` wybiera z widoku nazwisko i liczbę aktywnych spraw, a główne zapytanie zostawia tych, których liczba nie przekracza średniej z podzapytania. Odpowiada na pytanie, komu można przydzielić kolejne zlecenia.

```sql
-- Zapytanie 1: detektywi z liczba aktywnych spraw nie wieksza niz srednia (CTE, JOIN-y, GROUP BY, podzapytania)
WITH workload AS (
    SELECT detective, active_cases
    FROM v_detective_workload
)
SELECT detective, active_cases
FROM workload
WHERE active_cases <= (SELECT AVG(active_cases) FROM workload)
ORDER BY active_cases DESC, detective;
```

Wynik:
```
   detective    | active_cases 
----------------+--------------
 Philip Marlowe |            1
 Sam Spade      |            1
 Jake Gittes    |            0
(3 rows)
```

### Zapytanie 2: podejrzani powiązani z miejscem dowodu i występujący w kilku sprawach
Zapytanie wybiera podejrzanych, dla których w którejś z ich spraw znaleziono dowód w miejscu, gdzie byli ostatnio widziani (skorelowane `EXISTS` z łączeniem `evidence` i `case_suspect`). Wynik jest agregowany po podejrzanym, a warunek „występuje w więcej niż jednej sprawie” sprawdza `HAVING COUNT(*) > 1`; kolumna `cases_count` liczy wszystkie sprawy podejrzanego, nie tylko te, w których dowód znaleziono w miejscu ostatniego widzenia. Wskazuje powtarzających się podejrzanych powiązanych z miejscem dowodu, czyli kogo obserwować lub przesłuchać w pierwszej kolejności.

```sql
-- Zapytanie 2: podejrzani z kilku spraw, majacy powiazany dowod znaleziony w ich ostatnio widzianej lokalizacji
-- (podzapytanie skorelowane EXISTS + agregacja z HAVING)
SELECT sp.first_name || ' ' || sp.last_name AS suspect,
       COALESCE(sp.alias, '-') AS alias,
       COUNT(*) AS cases_count,
       MAX(cs.suspicion_level) AS max_suspicion,
       l.name AS last_seen
FROM suspect sp
JOIN case_suspect cs ON cs.suspect_id = sp.suspect_id
JOIN location l ON l.location_id = sp.last_seen_location_id
WHERE EXISTS (
        SELECT 1
        FROM evidence e
        JOIN case_suspect cs2 ON cs2.case_id = e.case_id
        WHERE cs2.suspect_id = sp.suspect_id
          AND e.location_id = sp.last_seen_location_id)
GROUP BY sp.suspect_id, sp.first_name, sp.last_name, sp.alias, l.name
HAVING COUNT(*) > 1
ORDER BY cases_count DESC, max_suspicion DESC;
```

Wynik:
```
   suspect   |   alias    | cases_count | max_suspicion |    last_seen     
-------------+------------+-------------+---------------+------------------
 Eddie Mars  | Mr. Mars   |           3 |             4 | Silver Moon Club
 Lash Canino | Lash       |           3 |             4 | Burbank Pier
 Lola Fenn   | The Blonde |           2 |             4 | Silver Moon Club
(3 rows)
```

## 5. Perspektywy
| Widok | Odbiorca | Treść |
|---|---|---|
| `v_case_overview` | detektyw | sprawa z etykietami: typ, status, klient, prowadzący, dni trwania, liczba dowodów |
| `v_detective_workload` | detektyw | aktywne / wszystkie / prowadzone sprawy aktywnych detektywów |
| `v_invoice_balance` | księgowy | zapłacono, saldo i status PAID/PENDING/OVERDUE |
| `v_client_cases` | klient | status spraw klientów (z adresem e-mail do filtrowania przez aplikację) bez danych wewnętrznych |
| `v_evidence_chain` | detektyw | historia przekazań dowodów z nazwiskami |

### Definicje i przykładowe wyniki
Przykładowe wyniki pochodzą z bazy z danymi przykładowymi (stan z 8.10.2026; kolumna `days_open` zależy od bieżącej daty). Widoki zamieniają klucze obce na czytelne etykiety, a kwoty i statusy płatności są liczone na bieżąco, nie przechowywane w tabelach.

#### `v_case_overview`
```sql
-- Przeglad spraw w czytelnej postaci (etykiety zamiast kluczy obcych)
CREATE VIEW v_case_overview AS
SELECT c.case_number,
       c.title,
       t.name  AS case_type,
       s.name  AS status,
       cl.first_name || ' ' || cl.last_name AS client,
       COALESCE(d.first_name || ' ' || d.last_name, '-- unassigned --') AS lead_detective,
       c.opened_on,
       c.closed_on,
       COALESCE(c.closed_on, CURRENT_DATE) - c.opened_on AS days_open,
       (SELECT COUNT(*) FROM evidence e WHERE e.case_id = c.case_id) AS evidence_count
FROM case_file c
JOIN case_type   t  ON t.type_id   = c.type_id
JOIN case_status s  ON s.status_id = c.status_id
JOIN client      cl ON cl.client_id = c.client_id
LEFT JOIN case_detective cd ON cd.case_id = c.case_id AND cd.role = 'LEAD'
LEFT JOIN detective d ON d.detective_id = cd.detective_id;
```
Zapytanie:
```sql
SELECT case_number, case_type, status, lead_detective, days_open, evidence_count
FROM v_case_overview
ORDER BY days_open, case_number;
```
Przykładowy wynik (posortowany rosnąco po `days_open`, najmłodsze sprawy na górze):
```
 case_number  |      case_type      |      status       | lead_detective | days_open | evidence_count 
---------------+---------------------+-------------------+----------------+-----------+----------------
 NOIR-2025-005 | Infidelity          | Closed - unsolved | Jake Gittes    |        23 |              0
 NOIR-2025-001 | Missing person      | Closed - solved   | Philip Marlowe |        46 |              2
 NOIR-2025-003 | Theft               | Closed - solved   | Sam Spade      |        85 |              2
 NOIR-2025-007 | Blackmail           | On hold           | Mike Hammer    |       372 |              0
 NOIR-2025-006 | Murder consultation | Open              | Philip Marlowe |       385 |              3
 NOIR-2025-004 | Fraud               | In progress       | Sam Spade      |       463 |              1
 NOIR-2025-002 | Blackmail           | In progress       | Mike Hammer    |       605 |              1
(7 rows)
```

#### `v_detective_workload`
```sql
-- Obciazenie aktywnych detektywow: sprawy aktywne / wszystkie / prowadzone
CREATE VIEW v_detective_workload AS
SELECT d.detective_id,
       d.first_name || ' ' || d.last_name AS detective,
       r.name AS detective_rank,
       COUNT(DISTINCT CASE WHEN s.name IN ('Open','In progress') THEN cd.case_id END) AS active_cases,
       COUNT(DISTINCT cd.case_id) AS all_cases,
       COUNT(DISTINCT CASE WHEN cd.role = 'LEAD' THEN cd.case_id END) AS led_cases
FROM detective d
JOIN detective_rank r ON r.rank_id = d.rank_id
LEFT JOIN case_detective cd ON cd.detective_id = d.detective_id
LEFT JOIN case_file c ON c.case_id = cd.case_id
LEFT JOIN case_status s ON s.status_id = c.status_id
WHERE d.is_active
GROUP BY d.detective_id, d.first_name, d.last_name, r.name;
```
Zapytanie:
```sql
SELECT detective, detective_rank, active_cases, all_cases, led_cases
FROM v_detective_workload
ORDER BY active_cases DESC, detective;
```
Przykładowy wynik (statusy „aktywnej” sprawy, `Open` i `In progress`, są wpisane w definicji widoku; dodanie nowego statusu aktywnego wymaga jej zmiany):
```
   detective    |   detective_rank    | active_cases | all_cases | led_cases 
----------------+---------------------+--------------+-----------+-----------
 Mike Hammer    | Investigator        |            2 |         3 |         2
 Nora Charles   | Investigator        |            2 |         2 |         0
 Philip Marlowe | Chief detective     |            1 |         3 |         2
 Sam Spade      | Senior investigator |            1 |         2 |         2
 Jake Gittes    | Rookie              |            0 |         2 |         1
(5 rows)
```

#### `v_invoice_balance`
```sql
-- Faktury z saldem do zaplaty (dla ksiegowosci)
CREATE VIEW v_invoice_balance AS
SELECT i.invoice_number,
       c.case_number,
       cl.first_name || ' ' || cl.last_name AS client,
       i.issued_on,
       i.due_on,
       i.amount,
       COALESCE(SUM(p.amount), 0.00) AS paid,
       i.amount - COALESCE(SUM(p.amount), 0.00) AS balance,
       CASE
         WHEN i.amount - COALESCE(SUM(p.amount), 0.00) <= 0 THEN 'PAID'
         WHEN i.due_on < CURRENT_DATE THEN 'OVERDUE'
         ELSE 'PENDING'
       END AS payment_status
FROM invoice i
JOIN case_file c ON c.case_id = i.case_id
JOIN client cl ON cl.client_id = c.client_id
LEFT JOIN payment p ON p.invoice_id = i.invoice_id
GROUP BY i.invoice_id, i.invoice_number, c.case_number, cl.first_name, cl.last_name,
         i.issued_on, i.due_on, i.amount;
```
Zapytanie:
```sql
SELECT invoice_number, client, amount, paid, balance, payment_status
FROM v_invoice_balance
ORDER BY invoice_number;
```
Przykładowy wynik (wszystkie niezapłacone faktury mają termin w przeszłości, więc w danych przykładowych występują tylko statusy PAID i OVERDUE; status PENDING otrzymuje faktura z terminem płatności jeszcze nieprzekroczonym):
```
 invoice_number |        client        | amount  |  paid   | balance | payment_status 
----------------+----------------------+---------+---------+---------+----------------
 INV-2025-0001  | Vivian Sternwood     | 2500.00 | 2500.00 |    0.00 | PAID
 INV-2025-0002  | Gutman Kasper        | 4000.00 | 4000.00 |    0.00 | PAID
 INV-2025-0003  | Gutman Kasper        | 4200.00 | 2000.00 | 2200.00 | OVERDUE
 INV-2025-0004  | Phyllis Dietrichson  |  900.00 |  900.00 |    0.00 | PAID
 INV-2025-0005  | Walter Neff          | 2000.00 | 1000.00 | 1000.00 | OVERDUE
 INV-2025-0006  | Brigid O'Shaughnessy | 1500.00 |    0.00 | 1500.00 | OVERDUE
(6 rows)
```

#### `v_client_cases`
```sql
-- Widok klienta: tylko status jego spraw, bez danych wewnetrznych (podejrzani, informatorzy)
CREATE VIEW v_client_cases AS
SELECT cl.email AS client_email,
       c.case_number,
       c.title,
       s.name AS status,
       c.opened_on,
       c.closed_on
FROM case_file c
JOIN case_status s ON s.status_id = c.status_id
JOIN client cl ON cl.client_id = c.client_id;
```
Zapytanie:
```sql
SELECT case_number, title, status
FROM v_client_cases
WHERE client_email = 'kasper@fatbird.example';
```
Przykładowy wynik:
```
 case_number  |        title         |     status      
---------------+----------------------+-----------------
 NOIR-2025-003 | The Falcon Statuette | Closed - solved
 NOIR-2025-007 | Letters from Nowhere | On hold
(2 rows)
```

#### `v_evidence_chain`
```sql
-- Lancuch dowodowy w czytelnej postaci
CREATE VIEW v_evidence_chain AS
SELECT e.evidence_code,
       et.name AS evidence_type,
       c.case_number,
       ec.transferred_at,
       d.first_name || ' ' || d.last_name AS custodian,
       ec.note
FROM evidence_custody ec
JOIN evidence e ON e.evidence_id = ec.evidence_id
JOIN evidence_type et ON et.evidence_type_id = e.evidence_type_id
JOIN case_file c ON c.case_id = e.case_id
JOIN detective d ON d.detective_id = ec.detective_id;
```
Zapytanie:
```sql
SELECT evidence_code, evidence_type, transferred_at, custodian, note
FROM v_evidence_chain
WHERE evidence_code = 'EV-0008'
ORDER BY transferred_at;
```
Przykładowy wynik:
```
 evidence_code | evidence_type |   transferred_at    |   custodian    |     note      
---------------+---------------+---------------------+----------------+---------------
 EV-0008       | Weapon        | 2025-09-19 03:00:00 | Philip Marlowe | Collected
 EV-0008       | Weapon        | 2025-09-19 12:00:00 | Nora Charles   | To ballistics
(2 rows)
```

## 6. Indeksy
PostgreSQL automatycznie indeksuje PK i UNIQUE, ale **nie** klucze obce - dlatego dodano B-tree na kolumnach FK używanych w JOIN-ach i filtrach. Wszystkie indeksy w schemacie to B-tree: dla równości i zakresów to właściwy wybór. Hash i BRIN porównano z B-tree w teście poniżej (czas i rozmiar); GIN/GiST wymagają danych tekstowych lub przestrzennych (np. `pg_trgm`, PostGIS), których w schemacie nie ma, więc ich nie mierzono.

Definicje indeksów:
```sql
-- PK i UNIQUE tworza indeksy automatycznie. PostgreSQL NIE indeksuje kluczy obcych,
-- dlatego dodajemy B-tree tam, gdzie FK uczestniczy w JOIN-ach lub filtrach.

-- case_file: sprawy klienta w danym statusie od daty (rownosc, rownosc, zakres) -> jeden indeks zlozony;
-- obsluguje tez samo client_id (lewy prefiks), wiec osobny indeks po kliencie jest zbedny
CREATE INDEX ix_case_file_client_status_opened ON case_file (client_id, status_id, opened_on);
CREATE INDEX ix_case_file_type                 ON case_file (type_id);
-- status_id nie jest pierwsza kolumna indeksu zlozonego, a po nim laczy sie widoki i filtruje zapytania
CREATE INDEX ix_case_file_status               ON case_file (status_id);

-- evidence: dowody danej sprawy oraz filtr po typie w obrebie sprawy
CREATE INDEX ix_evidence_case_type ON evidence (case_id, evidence_type_id);
CREATE INDEX ix_evidence_location  ON evidence (location_id);
CREATE INDEX ix_evidence_type      ON evidence (evidence_type_id);

-- asocjacyjne: PK (case_id, x) obsluguje wyszukiwanie po case_id; odwrotny kierunek wymaga drugiego indeksu
CREATE INDEX ix_case_detective_detective ON case_detective (detective_id);
-- najwyzej jeden prowadzacy (LEAD) na sprawe
CREATE UNIQUE INDEX uq_case_detective_lead ON case_detective (case_id) WHERE role = 'LEAD';
CREATE INDEX ix_case_suspect_suspect     ON case_suspect (suspect_id);
CREATE INDEX ix_case_witness_witness     ON case_witness (witness_id);

-- lancuch dowodowy: kto przechowuje dowody
CREATE INDEX ix_evidence_custody_detective ON evidence_custody (detective_id);

-- finanse
CREATE INDEX ix_invoice_case    ON invoice (case_id);
CREATE INDEX ix_payment_invoice ON payment (invoice_id);
CREATE INDEX ix_payment_method  ON payment (method_id);

-- raport faktur po terminie (zakres po due_on)
CREATE INDEX ix_invoice_due ON invoice (due_on);

CREATE INDEX ix_tip_informant ON tip (informant_id);
CREATE INDEX ix_tip_case      ON tip (case_id);
CREATE INDEX ix_detective_rank ON detective (rank_id);
CREATE INDEX ix_informant_handler ON informant (handler_id);
-- wyszukiwanie osob po nazwisku
CREATE INDEX ix_suspect_last_name ON suspect (last_name);
CREATE INDEX ix_witness_last_name ON witness (last_name);
CREATE INDEX ix_suspect_location ON suspect (last_seen_location_id);
-- client, location, evidence_custody(evidence_id): bez dodatkowych indeksow - klucz glowny lub UNIQUE
-- (evidence_id, transferred_at) juz obsluguje wyszukiwanie; client i location nie maja kluczy obcych.
```

| Tabela | Indeksy | Uzasadnienie |
|---|---|---|
| `case_file` | `(client_id, status_id, opened_on)`, `(type_id)`, `(status_id)` | sprawy klienta w danym statusie od daty (indeks złożony: dwie równości i zakres; lewy prefiks obsługuje też samo `client_id`, więc zastępuje osobny indeks po kliencie; w teście głównym nie jest mierzalnie szybszy od prostego `(client_id)`, ale to jeden indeks zamiast dwóch), JOIN po typie sprawy, JOIN i filtr po samym statusie (widoki) |
| `evidence` | `(case_id, evidence_type_id)`, `(location_id)`, `(evidence_type_id)` | dowody sprawy, filtr po typie bez sięgania do tabeli (index-only scan), JOIN po miejscu i po typie dowodu |
| `case_detective`, `case_suspect`, `case_witness` | drugi indeks po drugiej kolumnie PK; w `case_detective` dodatkowo UNIQUE `(case_id)` dla `role = 'LEAD'` | PK `(case_id, x)` obsługuje tylko kierunek od sprawy; odwrotny („sprawy tego detektywa") wymaga indeksu; indeks częściowy gwarantuje jednego prowadzącego na sprawę |
| `invoice` | `(case_id)`, `(due_on)` | faktury sprawy, raport po terminie |
| `payment`, `tip`, `informant`, `detective` | po FK (`payment`: faktura i metoda płatności) | JOIN-y i usuwanie/aktualizacja rodzica |
| `suspect`, `witness` | `(last_name)`; `suspect` także `(last_seen_location_id)` | wyszukiwanie po nazwisku, JOIN podejrzanego z miejscem ostatniego widzenia |
| `client`, `location` | tylko PK/UNIQUE | brak kluczy obcych, są wyłącznie stroną „jeden"; wyszukiwanie po kluczu głównym lub `email` (UNIQUE) |
| `evidence_custody` | `(detective_id)` oraz UNIQUE `(evidence_id, transferred_at)` | `(detective_id)`: co ma w depozycie detektyw; klucz obcy `evidence_id` obsługuje już indeks UNIQUE (jest jego pierwszą kolumną), więc dodatkowy byłby zbędny |
| słowniki | tylko PK/UNIQUE | kilka wierszy - indeks bez sensu, planner i tak robi seq scan; indeksy na kolumnach FK, które do nich prowadzą (`status_id`, `type_id`, `evidence_type_id`, `rank_id`, `method_id`), służą głównie złączeniom w widokach i kontroli klucza obcego, a nie selektywnemu filtrowaniu |

### Test wydajności (300 000 spraw, 1 000 000 dowodów)
Zapytanie testowe (dowody typu 3 w sprawach jednego klienta, w toku, otwartych od 2020; tabele w schemacie `perf`):
```sql
SELECT c.case_id, c.title, COUNT(*) AS weapons
FROM perf.case_file c
JOIN perf.evidence e ON e.case_id = c.case_id
WHERE c.client_id = 777
  AND c.status_id = 2
  AND c.opened_on >= DATE '2020-01-01'
  AND e.evidence_type_id = 3
GROUP BY c.case_id, c.title;
```

| # | Konfiguracja | Plan | Czas wykonania |
|---|---|---|---|
| 1 | brak indeksów (poza PK) | Seq Scan obu tabel + Hash Join | **31,8-36,2 ms** |
| 2 | tylko FK `evidence(case_id)` | Seq Scan `case_file` + Bitmap Scan `evidence` | 12,0-16,0 ms |
| 3 | jeden prosty `case_file(client_id)` + `evidence(case_id)` | Bitmap Index Scan po `client_id`, reszta warunków jako filtr | 0,089-0,129 ms |
| 4 | dwa proste `case_file(client_id)`, `(status_id)` + `evidence(case_id)` | jak 3 | 0,079-0,117 ms |
| 5 | **złożony** `case_file(client_id, status_id, opened_on)` + `evidence(case_id)` | wszystkie warunki `case_file` w jednym indeksie | 0,078-0,118 ms |
| 6 | złożony jak 5 + złożony `evidence(case_id, evidence_type_id)` | dodatkowo Index Only Scan na `evidence` | 0,058-0,096 ms |
| 7 | złożony w złej kolejności `case_file(opened_on, status_id, client_id)` + jak 6 | zakres na pierwszej kolumnie - przegląda szeroki przedział indeksu | 5,4-8,2 ms |
| 8 | jak 6, z `INCLUDE (title)` | jak 6, z dodatkową kolumną w indeksie | 0,058-0,081 ms |

Dane syntetyczne generuje `random()`. Skrypt ustawia stałe ziarno generatora liczb losowych używanego do generowania danych (`setseed(0.42)`), dzięki czemu każde uruchomienie tworzy dokładnie te same dane (te same wartości `client_id`, `status_id` i `opened_on` w tych samych wierszach). Bez tego każde uruchomienie dawałoby inne dane, więc zapytanie dla `client_id = 777` zwracałoby inną liczbę wierszy, a plany i czasy nie byłyby porównywalne ani odtwarzalne, zarówno między wariantami, jak i między przebiegami. Plany są więc powtarzalne, ale czasy zmieniają się między uruchomieniami (zależą od obciążenia maszyny i pamięci podręcznej). Podane zakresy (najmniejsza i największa wartość) pochodzą z ośmiu pełnych przebiegów skryptu. Warianty 3-6 zmieniają po jednym elemencie względem poprzedniego, dzięki czemu każda różnica wynika z jednej zmiany: wariant 3 dodaje indeks prosty, 4 drugi prosty, 5 zastępuje je jednym złożonym, 6 zmienia indeks na `evidence`.

**Wnioski:**
- Największy zysk daje indeks na selektywnej kolumnie filtra (`case_file.client_id`; z ok. 12 ms do ok. 0,1 ms, czyli ponad 100 razy) oraz indeks na kluczu obcym łączącym tabele (`evidence.case_id`, czyli kolumna, po której `evidence` jest łączone z `case_file`) (z ok. 32 do ok. 12 ms).
- Przy tej selektywności zapytania (kilka wierszy z 300 000) warianty 3-6 (jeden prosty, dwa proste, złożony, złożony z drugim indeksem na `evidence`) mieszczą się w tym samym przedziale 0,06-0,13 ms i ich zakresy się pokrywają. Dzieje się tak, bo sam warunek `client_id = 777` zawęża `case_file` do 19 wierszy, z których pozostałe warunki (`status_id`, `opened_on`) zostawiają 3 sprawy (2 z nich mają dowody typu 3, więc wynik zapytania to 2 wiersze), czyli niewiele już usuwają, a w wariancie z dwoma prostymi indeksami planner i tak korzysta tylko z indeksu po `client_id`. Przewagę indeksu złożonego pokazuje drugie zapytanie poniżej, w którym żadna pojedyncza kolumna nie jest selektywna. Dodatkowo jeden indeks złożony zamiast dwóch prostych oznacza mniej indeksów do aktualizacji przy `INSERT` i `UPDATE`.
- Kolejność kolumn w indeksie złożonym ma znaczenie: kolumny z równością powinny być na początku, a kolumna z zakresem na końcu. Odwrócona kolejność jest kilkadziesiąt do ponad stu razy wolniejsza od właściwej.
- Dołączenie kolumny `title` przez `INCLUDE` nie przyniosło tu zauważalnej poprawy, bo zapytanie czyta z `case_file` tylko 3 wiersze (po przefiltrowaniu 19 wierszy klienta), więc odczyt `title` z tabeli kosztuje niewiele. Taki indeks opłaca się, gdy zapytanie odczytuje bardzo wiele wierszy: wtedy wszystkie potrzebne kolumny są w samym indeksie i baza nie musi sięgać do tabeli po każdy wiersz z osobna (Index Only Scan).

### Rodzaje indeksów: czas i rozmiar
Te same dane porównano dla trzech rodzajów indeksów PostgreSQL: B-tree (domyślny), hash i BRIN. Zapytania: (a) główne zapytanie testowe (warianty 9-11, z tym samym indeksem `evidence(case_id)` co w wariancie 3), (b) zakres po samej dacie, czyli jeden miesiąc (2518 z 300 000 wierszy, warianty 12-15):
```sql
SELECT count(*)
FROM perf.case_file
WHERE opened_on >= DATE '2020-03-01'
  AND opened_on <  DATE '2020-04-01';
```
Wyniki:

| # | Zapytanie | Konfiguracja | Plan | Czas wykonania |
|---|---|---|---|---|
| 9 | główne | B-tree `case_file(client_id)` | Bitmap Index Scan | 0,091-0,123 ms |
| 10 | główne | **hash** `case_file(client_id)` | Bitmap Index Scan | 0,083-0,122 ms |
| 11 | główne | BRIN `case_file(opened_on)` | Seq Scan (planner nie używa indeksu) | 10,5-12,9 ms |
| 12 | zakres po dacie | brak indeksu | Parallel Seq Scan | 10,1-12,1 ms |
| 13 | zakres po dacie | B-tree `(opened_on)` | Index Only Scan | 0,128-0,185 ms |
| 14 | zakres po dacie | BRIN `(opened_on)`, dane w losowej kolejności | Parallel Seq Scan (BRIN pominięty) | 10,4-11,9 ms |
| 15 | zakres po dacie | BRIN `(opened_on)`, tabela fizycznie posortowana po dacie | Bitmap Index Scan + Bitmap Heap Scan | 2,15-2,28 ms |

Rozmiary (po `VACUUM ANALYZE`; tabela `case_file` zajmuje 17 MB, a `evidence` 65 MB):

| Indeks | Rodzaj | Tabela | Rozmiar |
|---|---|---|---|
| `(client_id)` | B-tree | `case_file` | 2,4 MB |
| `(client_id)` | hash | `case_file` | 8,4 MB |
| `(opened_on)` | B-tree | `case_file` | 2,0 MB |
| `(opened_on)` | BRIN | `case_file` | 24 kB |
| `(client_id, status_id, opened_on)` | B-tree, złożony | `case_file` | 9,0 MB |
| `(client_id, status_id, opened_on) INCLUDE (title)` | B-tree, pokrywający | `case_file` | 12 MB |
| `(case_id)` | B-tree | `evidence` | 13 MB |
| `(case_id, evidence_type_id)` | B-tree, złożony | `evidence` | 20 MB |

**Wnioski:**
- **Hash** dał ten sam czas co B-tree przy wyszukiwaniu po równości (zakresy się pokrywają), a zajął 3,5 raza więcej miejsca (8,4 MB wobec 2,4 MB), bo B-tree deduplikuje powtarzające się wartości. Nie obsługuje zakresów ani wielu kolumn, więc nie ma powodu go używać; B-tree jest tu lepszy.
- **BRIN** jest wyjątkowo mały (24 kB wobec 2,0 MB dla B-tree, ok. 85 razy mniej), ale działa tylko wtedy, gdy kolejność fizyczna wierszy pokrywa się z kolejnością kolumny. Dla danych w losowej kolejności planner go ignoruje i czas jest taki jak bez indeksu (ok. 10-13 ms). Po fizycznym posortowaniu tabeli po dacie zapytanie zakresowe skraca się do 2,15-2,28 ms, ale B-tree jest nadal szybszy (0,128-0,185 ms). BRIN ma sens dla bardzo dużych tabel append-only z kolumną rosnącą w czasie (logi, zdarzenia); `case_file` z datą otwarcia sprawy takim przypadkiem nie jest.
- **Rozmiar indeksów złożonych** rośnie z liczbą kolumn: indeks `(client_id, status_id, opened_on)` zajmuje 9,0 MB, czyli 3,7 raza więcej niż prosty `(client_id)`, a dołączenie `title` przez `INCLUDE` dodaje kolejne 3 MB bez poprawy czasu w tym teście. Złożony indeks `evidence(case_id, evidence_type_id)` jest o 7 MB większy od prostego `(case_id)` i daje Index Only Scan. Każdy dodatkowy indeks kosztuje miejsce oraz czas przy `INSERT`/`UPDATE`.

### Drugie zapytanie: żadna pojedyncza kolumna nie jest selektywna
Te same dane (300 000 spraw), zapytanie o sprawy w danym statusie z jednego tygodnia. Sam `status_id = 2` pasuje do ok. 1/4 wierszy (74 713), sam tydzień `opened_on` do 569 wierszy, a oba warunki razem zostawiają 142 wiersze:
```sql
SELECT case_id, title
FROM perf.case_file
WHERE status_id = 2
  AND opened_on >= DATE '2020-03-01'
  AND opened_on <  DATE '2020-03-08';
```

| # | Konfiguracja | Plan | Czas wykonania |
|---|---|---|---|
| 16 | brak indeksu | Parallel Seq Scan | 10,4-11,2 ms |
| 17 | prosty `(status_id)` | Bitmap Index Scan zwraca 74 713 wierszy, z czego odfiltrowano 74 571 | 9,1-10,9 ms |
| 18 | prosty `(opened_on)` | Bitmap Index Scan zwraca 569 wierszy, z czego odfiltrowano 427 | 0,47-0,53 ms |
| 19 | dwa proste `(status_id)`, `(opened_on)` | BitmapAnd obu indeksów (74 713 i 569 wierszy) | 1,4-1,8 ms |
| 20 | **złożony** `(status_id, opened_on)` | jeden Bitmap Index Scan zwraca dokładnie 142 wiersze | **0,15-0,16 ms** |
| 21 | złożony w odwrotnej kolejności `(opened_on, status_id)` | jeden Bitmap Index Scan zwraca 142 wiersze | 0,16-0,21 ms |

**Wnioski:**
- Indeks złożony jest tu najszybszy: ok. 3 razy szybszy od najlepszego prostego `(opened_on)`, ok. 9 razy szybszy od dwóch prostych i ok. 60 razy szybszy od prostego `(status_id)`. Znajduje szukane 142 wiersze w jednym wyszukiwaniu, podczas gdy indeksy proste zwracają setki lub dziesiątki tysięcy wierszy do odfiltrowania.
- Dwa proste indeksy są wolniejsze od jednego prostego `(opened_on)`: planner musi zbudować bitmapę z 74 713 wierszy indeksu `(status_id)` i połączyć ją z drugą (`BitmapAnd`), a to kosztuje więcej niż odfiltrowanie 427 zbędnych wierszy. Dwa indeksy proste nie zastępują więc jednego złożonego.
- W tym zapytaniu kolejność kolumn prawie nie ma znaczenia (warianty 20 i 21 mieszczą się w zbliżonym przedziale), bo zakres po `opened_on` na pierwszej kolumnie jest wąski (569 wierszy). W teście głównym (wariant 7) zakres obejmował szeroki przedział dat i odwrócona kolejność była kilkadziesiąt razy wolniejsza.

## 7. Wnioski
- Największy zysk w teście dał indeks na selektywnej kolumnie filtra (`case_file.client_id`, ponad 100 razy), a w drugiej kolejności indeks na kluczu obcym łączącym tabele (`evidence.case_id`, ok. 3 razy). PostgreSQL nie tworzy indeksów na kluczach obcych samodzielnie (zakłada je tylko dla kluczy głównych i ograniczeń `UNIQUE`), więc trzeba je dodać jawnie.
- O przydatności indeksu decyduje selektywność warunku. Indeks na kolumnie o małej selektywności (np. słownikowej) nie przyspiesza filtrowania (wariant 17), a każdy dodatkowy indeks zajmuje miejsce i spowalnia `INSERT` i `UPDATE`; w schemacie takie indeksy są na kolumnach FK do słowników, bo wspierają złączenia w widokach i kontrolę kluczy obcych, ale nie należy oczekiwać po nich korzyści przy filtrowaniu. Indeks złożony ma sens, gdy żadna pojedyncza kolumna nie zawęża wyniku wystarczająco (drugie zapytanie), a kolejność jego kolumn (równość przed zakresem) ma duże znaczenie. W schemacie indeks `(client_id, status_id, opened_on)` zastępuje osobny indeks po kliencie; w teście głównym nie był mierzalnie szybszy od prostego `(client_id)`, bo sam `client_id` zawęża wynik do kilkunastu wierszy.
- Wybór rodzaju indeksu zależy od zapytań i danych: B-tree jest uniwersalny, hash nie daje przewagi nad nim, a BRIN działa tylko na danych ułożonych fizycznie zgodnie z kolejnością kolumny.
- `GRANT SELECT ON ALL TABLES` obejmuje także widoki, więc dostęp do tych, których dana rola nie powinna widzieć (np. finansów dla detektywa), trzeba jawnie odebrać przez `REVOKE`. Uprawnienia warto weryfikować testami, bo ich błędy nie dają żadnych komunikatów.

\newpage
## Skrypt tworzący schemat bazy
```sql
-- Baza "Biuro detektywistyczne noir" (PostgreSQL 17)
-- Konwencje: snake_case, IDENTITY zamiast serial, brak ENUM/tablic/jsonb,
-- slowniki jako tabele, nazwane ograniczenia, typy standardowe.

CREATE SCHEMA noir AUTHORIZATION noir_admin;
SET search_path = noir;

-- ===================== SLOWNIKI =====================
CREATE TABLE case_status (
    status_id   SMALLINT GENERATED ALWAYS AS IDENTITY,
    name        VARCHAR(30) NOT NULL,
    CONSTRAINT pk_case_status PRIMARY KEY (status_id),
    CONSTRAINT uq_case_status_name UNIQUE (name)
);

CREATE TABLE case_type (
    type_id     SMALLINT GENERATED ALWAYS AS IDENTITY,
    name        VARCHAR(40) NOT NULL,
    CONSTRAINT pk_case_type PRIMARY KEY (type_id),
    CONSTRAINT uq_case_type_name UNIQUE (name)
);

CREATE TABLE evidence_type (
    evidence_type_id SMALLINT GENERATED ALWAYS AS IDENTITY,
    name             VARCHAR(40) NOT NULL,
    CONSTRAINT pk_evidence_type PRIMARY KEY (evidence_type_id),
    CONSTRAINT uq_evidence_type_name UNIQUE (name)
);

CREATE TABLE detective_rank (
    rank_id     SMALLINT GENERATED ALWAYS AS IDENTITY,
    name        VARCHAR(40) NOT NULL,
    hourly_rate NUMERIC(8,2) NOT NULL,
    CONSTRAINT pk_detective_rank PRIMARY KEY (rank_id),
    CONSTRAINT uq_detective_rank_name UNIQUE (name),
    CONSTRAINT ck_detective_rank_rate CHECK (hourly_rate > 0)
);

CREATE TABLE payment_method (
    method_id   SMALLINT GENERATED ALWAYS AS IDENTITY,
    name        VARCHAR(30) NOT NULL,
    CONSTRAINT pk_payment_method PRIMARY KEY (method_id),
    CONSTRAINT uq_payment_method_name UNIQUE (name)
);

-- ===================== TABELE GLOWNE =====================
CREATE TABLE client (
    client_id    INTEGER GENERATED ALWAYS AS IDENTITY,
    first_name   VARCHAR(50)  NOT NULL,
    last_name    VARCHAR(80)  NOT NULL,
    email        VARCHAR(120) NOT NULL,
    phone        VARCHAR(20),
    company_name VARCHAR(120),
    registered_on DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_client PRIMARY KEY (client_id),
    CONSTRAINT uq_client_email UNIQUE (email)
);

CREATE TABLE detective (
    detective_id INTEGER GENERATED ALWAYS AS IDENTITY,
    rank_id      SMALLINT NOT NULL,
    first_name   VARCHAR(50) NOT NULL,
    last_name    VARCHAR(80) NOT NULL,
    license_no   VARCHAR(20) NOT NULL,
    hired_on     DATE NOT NULL,
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT pk_detective PRIMARY KEY (detective_id),
    CONSTRAINT uq_detective_license UNIQUE (license_no),
    CONSTRAINT fk_detective_rank FOREIGN KEY (rank_id) REFERENCES detective_rank (rank_id)
);

CREATE TABLE location (
    location_id INTEGER GENERATED ALWAYS AS IDENTITY,
    name        VARCHAR(100) NOT NULL,
    street      VARCHAR(120),
    city        VARCHAR(60) NOT NULL,
    notes       VARCHAR(300),
    CONSTRAINT pk_location PRIMARY KEY (location_id)
);

CREATE TABLE case_file (
    case_id      INTEGER GENERATED ALWAYS AS IDENTITY,
    case_number  VARCHAR(20) NOT NULL,
    title        VARCHAR(150) NOT NULL,
    description  VARCHAR(2000),
    type_id      SMALLINT NOT NULL,
    status_id    SMALLINT NOT NULL,
    client_id    INTEGER  NOT NULL,
    opened_on    DATE NOT NULL,
    closed_on    DATE,
    fee_estimate NUMERIC(10,2) NOT NULL DEFAULT 0,
    CONSTRAINT pk_case_file PRIMARY KEY (case_id),
    CONSTRAINT uq_case_file_number UNIQUE (case_number),
    CONSTRAINT fk_case_file_type   FOREIGN KEY (type_id)   REFERENCES case_type (type_id),
    CONSTRAINT fk_case_file_status FOREIGN KEY (status_id) REFERENCES case_status (status_id),
    CONSTRAINT fk_case_file_client FOREIGN KEY (client_id) REFERENCES client (client_id),
    CONSTRAINT ck_case_file_dates  CHECK (closed_on IS NULL OR closed_on >= opened_on),
    CONSTRAINT ck_case_file_fee    CHECK (fee_estimate >= 0)
);

CREATE TABLE suspect (
    suspect_id  INTEGER GENERATED ALWAYS AS IDENTITY,
    first_name  VARCHAR(50) NOT NULL,
    last_name   VARCHAR(80) NOT NULL,
    alias       VARCHAR(60),
    birth_date  DATE,
    last_seen_location_id INTEGER,
    CONSTRAINT pk_suspect PRIMARY KEY (suspect_id),
    CONSTRAINT fk_suspect_location FOREIGN KEY (last_seen_location_id) REFERENCES location (location_id)
);

CREATE TABLE witness (
    witness_id  INTEGER GENERATED ALWAYS AS IDENTITY,
    first_name  VARCHAR(50) NOT NULL,
    last_name   VARCHAR(80) NOT NULL,
    phone       VARCHAR(20),
    reliability SMALLINT NOT NULL,
    CONSTRAINT pk_witness PRIMARY KEY (witness_id),
    CONSTRAINT ck_witness_reliability CHECK (reliability BETWEEN 1 AND 5)
);

CREATE TABLE informant (
    informant_id INTEGER GENERATED ALWAYS AS IDENTITY,
    codename     VARCHAR(40) NOT NULL,
    handler_id   INTEGER NOT NULL,
    trust_level  SMALLINT NOT NULL,
    fee_per_tip  NUMERIC(8,2) NOT NULL DEFAULT 0,
    CONSTRAINT pk_informant PRIMARY KEY (informant_id),
    CONSTRAINT uq_informant_codename UNIQUE (codename),
    CONSTRAINT fk_informant_handler FOREIGN KEY (handler_id) REFERENCES detective (detective_id),
    CONSTRAINT ck_informant_trust CHECK (trust_level BETWEEN 1 AND 5),
    CONSTRAINT ck_informant_fee   CHECK (fee_per_tip >= 0)
);

CREATE TABLE evidence (
    evidence_id      INTEGER GENERATED ALWAYS AS IDENTITY,
    evidence_code    VARCHAR(20) NOT NULL,
    case_id          INTEGER  NOT NULL,
    evidence_type_id SMALLINT NOT NULL,
    location_id      INTEGER,
    description      VARCHAR(500) NOT NULL,
    found_at         TIMESTAMP NOT NULL,
    CONSTRAINT pk_evidence PRIMARY KEY (evidence_id),
    CONSTRAINT uq_evidence_code UNIQUE (evidence_code),
    CONSTRAINT fk_evidence_case     FOREIGN KEY (case_id)          REFERENCES case_file (case_id),
    CONSTRAINT fk_evidence_type     FOREIGN KEY (evidence_type_id) REFERENCES evidence_type (evidence_type_id),
    CONSTRAINT fk_evidence_location FOREIGN KEY (location_id)      REFERENCES location (location_id)
);

CREATE TABLE tip (
    tip_id       INTEGER GENERATED ALWAYS AS IDENTITY,
    informant_id INTEGER NOT NULL,
    case_id      INTEGER NOT NULL,
    received_at  TIMESTAMP NOT NULL,
    content      VARCHAR(1000) NOT NULL,
    CONSTRAINT pk_tip PRIMARY KEY (tip_id),
    CONSTRAINT fk_tip_informant FOREIGN KEY (informant_id) REFERENCES informant (informant_id),
    CONSTRAINT fk_tip_case      FOREIGN KEY (case_id)      REFERENCES case_file (case_id)
);

CREATE TABLE invoice (
    invoice_id     INTEGER GENERATED ALWAYS AS IDENTITY,
    invoice_number VARCHAR(20) NOT NULL,
    case_id        INTEGER NOT NULL,
    issued_on      DATE NOT NULL,
    due_on         DATE NOT NULL,
    amount         NUMERIC(10,2) NOT NULL,
    CONSTRAINT pk_invoice PRIMARY KEY (invoice_id),
    CONSTRAINT uq_invoice_number UNIQUE (invoice_number),
    CONSTRAINT fk_invoice_case FOREIGN KEY (case_id) REFERENCES case_file (case_id),
    CONSTRAINT ck_invoice_amount CHECK (amount > 0),
    CONSTRAINT ck_invoice_dates  CHECK (due_on >= issued_on)
);

CREATE TABLE payment (
    payment_id  INTEGER GENERATED ALWAYS AS IDENTITY,
    invoice_id  INTEGER NOT NULL,
    method_id   SMALLINT NOT NULL,
    paid_on     DATE NOT NULL,
    amount      NUMERIC(10,2) NOT NULL,
    CONSTRAINT pk_payment PRIMARY KEY (payment_id),
    CONSTRAINT fk_payment_invoice FOREIGN KEY (invoice_id) REFERENCES invoice (invoice_id),
    CONSTRAINT fk_payment_method  FOREIGN KEY (method_id)  REFERENCES payment_method (method_id),
    CONSTRAINT ck_payment_amount  CHECK (amount > 0)
);

-- ===================== TABELE ASOCJACYJNE (klucze zlozone; evidence_custody ma klucz zastepczy) =====================
CREATE TABLE case_detective (
    case_id      INTEGER NOT NULL,
    detective_id INTEGER NOT NULL,
    role         VARCHAR(10) NOT NULL DEFAULT 'ASSISTANT',
    assigned_on  DATE NOT NULL,
    CONSTRAINT pk_case_detective PRIMARY KEY (case_id, detective_id),
    CONSTRAINT fk_cd_case      FOREIGN KEY (case_id)      REFERENCES case_file (case_id),
    CONSTRAINT fk_cd_detective FOREIGN KEY (detective_id) REFERENCES detective (detective_id),
    CONSTRAINT ck_cd_role CHECK (role IN ('LEAD', 'ASSISTANT'))
);

CREATE TABLE case_suspect (
    case_id         INTEGER NOT NULL,
    suspect_id      INTEGER NOT NULL,
    suspicion_level SMALLINT NOT NULL,
    CONSTRAINT pk_case_suspect PRIMARY KEY (case_id, suspect_id),
    CONSTRAINT fk_cs_case    FOREIGN KEY (case_id)    REFERENCES case_file (case_id),
    CONSTRAINT fk_cs_suspect FOREIGN KEY (suspect_id) REFERENCES suspect (suspect_id),
    CONSTRAINT ck_cs_level CHECK (suspicion_level BETWEEN 1 AND 5)
);

CREATE TABLE case_witness (
    case_id        INTEGER NOT NULL,
    witness_id     INTEGER NOT NULL,
    statement_date DATE NOT NULL,
    statement      VARCHAR(1500),
    CONSTRAINT pk_case_witness PRIMARY KEY (case_id, witness_id),
    CONSTRAINT fk_cw_case    FOREIGN KEY (case_id)    REFERENCES case_file (case_id),
    CONSTRAINT fk_cw_witness FOREIGN KEY (witness_id) REFERENCES witness (witness_id)
);

-- lancuch dowodowy: kto i kiedy przejal dowod (klucz zastepczy; ten sam dowod nie moze miec dwoch przekazan w tej samej chwili)
CREATE TABLE evidence_custody (
    custody_id     INTEGER GENERATED ALWAYS AS IDENTITY,
    evidence_id    INTEGER NOT NULL,
    transferred_at TIMESTAMP NOT NULL,
    detective_id   INTEGER NOT NULL,
    note           VARCHAR(200),
    CONSTRAINT pk_evidence_custody PRIMARY KEY (custody_id),
    CONSTRAINT uq_evidence_custody_time UNIQUE (evidence_id, transferred_at),
    CONSTRAINT fk_ec_evidence  FOREIGN KEY (evidence_id)  REFERENCES evidence (evidence_id),
    CONSTRAINT fk_ec_detective FOREIGN KEY (detective_id) REFERENCES detective (detective_id)
);
```

\newpage
## Użytkownicy i uprawnienia
```sql
-- Uzytkownicy (hasla tylko do celow zaliczeniowych)
CREATE ROLE detective_app LOGIN PASSWORD 'detective_pw';
CREATE ROLE accountant_app LOGIN PASSWORD 'accountant_pw';
CREATE ROLE client_portal LOGIN PASSWORD 'client_pw';

REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE noir TO detective_app, accountant_app, client_portal;
GRANT USAGE ON SCHEMA noir TO detective_app, accountant_app, client_portal;

-- Detektyw: pelna praca na sprawach i dowodach, brak dostepu do finansow
GRANT SELECT ON ALL TABLES IN SCHEMA noir TO detective_app;
REVOKE ALL ON noir.invoice, noir.payment, noir.payment_method, noir.v_invoice_balance FROM detective_app;
GRANT INSERT, UPDATE ON noir.case_file, noir.evidence, noir.suspect,
      noir.witness, noir.tip, noir.case_detective, noir.case_suspect, noir.case_witness TO detective_app;
-- Lancuch dowodowy tylko dopisywany: bez UPDATE i DELETE nie da sie zmienic historii przekazan
GRANT INSERT ON noir.evidence_custody TO detective_app;
-- Nowe miejsca i informatorzy pojawiaja sie w trakcie sledztwa; pomylkowe powiazania mozna usunac
GRANT INSERT, UPDATE ON noir.location, noir.informant TO detective_app;
GRANT DELETE ON noir.case_suspect, noir.case_witness TO detective_app;
GRANT SELECT ON noir.v_case_overview, noir.v_detective_workload, noir.v_evidence_chain TO detective_app;

-- Ksiegowy: widoki + pelna obsluga tabel finansowych; z tabeli spraw tylko kolumny potrzebne do fakturowania
-- (bez opisu sprawy; uprawnienie SELECT nadane na poziomie kolumn)
GRANT SELECT ON noir.v_invoice_balance TO accountant_app;
GRANT SELECT (case_id, case_number, title, client_id, fee_estimate) ON noir.case_file TO accountant_app;
GRANT SELECT, INSERT, UPDATE ON noir.invoice TO accountant_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON noir.payment TO accountant_app;
GRANT SELECT ON noir.payment_method TO accountant_app;

-- Klient: wylacznie widok swoich spraw
GRANT SELECT ON noir.v_client_cases TO client_portal;

ALTER ROLE detective_app  SET search_path = noir;
ALTER ROLE accountant_app SET search_path = noir;
ALTER ROLE client_portal  SET search_path = noir;
```

\newpage
## Dane przykładowe
```sql
SET search_path = noir;

INSERT INTO case_status (name) VALUES ('Open'), ('In progress'), ('On hold'), ('Closed - solved'), ('Closed - unsolved');
INSERT INTO case_type (name) VALUES ('Missing person'), ('Infidelity'), ('Fraud'), ('Theft'), ('Blackmail'), ('Murder consultation');
INSERT INTO evidence_type (name) VALUES ('Photograph'), ('Document'), ('Weapon'), ('Recording'), ('Physical trace'), ('Letter');
INSERT INTO detective_rank (name, hourly_rate) VALUES ('Rookie', 40.00), ('Investigator', 65.00), ('Senior investigator', 95.00), ('Chief detective', 140.00);
INSERT INTO payment_method (name) VALUES ('Cash'), ('Bank transfer'), ('Cheque'), ('Card');

INSERT INTO client (first_name, last_name, email, phone, company_name, registered_on) VALUES
 ('Vivian',  'Sternwood', 'vivian@sternwood.example',   '555-0101', NULL,                    '2025-01-12'),
 ('Carmen',  'Regan',     'carmen.regan@example.com',   '555-0102', NULL,                    '2025-02-03'),
 ('Gutman',  'Kasper',    'kasper@fatbird.example',     '555-0103', 'Fat Bird Imports',      '2025-03-21'),
 ('Brigid',  'O''Shaughnessy', 'brigid@example.com',    '555-0104', NULL,                    '2025-05-09'),
 ('Walter',  'Neff',      'wneff@pacific-ins.example',  '555-0105', 'Pacific All Risk Ins.', '2025-06-30'),
 ('Phyllis', 'Dietrichson','phyllis@example.com',       '555-0106', NULL,                    '2025-08-14');

INSERT INTO detective (rank_id, first_name, last_name, license_no, hired_on, is_active) VALUES
 (4, 'Philip',  'Marlowe', 'LIC-0001', '2018-03-01', TRUE),
 (3, 'Sam',     'Spade',   'LIC-0002', '2019-07-15', TRUE),
 (2, 'Mike',    'Hammer',  'LIC-0003', '2021-01-10', TRUE),
 (2, 'Nora',    'Charles', 'LIC-0004', '2022-09-05', TRUE),
 (1, 'Jake',    'Gittes',  'LIC-0005', '2025-01-10', TRUE),
 (3, 'Lew',     'Archer',  'LIC-0006', '2017-11-30', FALSE);

INSERT INTO location (name, street, city, notes) VALUES
 ('Sternwood Mansion',      '3765 Alta Brea Crescent', 'Los Angeles', 'Greenhouse in the back'),
 ('Hotel Belvedere',        '12 Sutter Street',        'San Francisco', 'Room 12'),
 ('Burbank Pier',           'Pier 4',                  'Los Angeles', 'Abandoned warehouse nearby'),
 ('Silver Moon Club',       '88 Ocean Avenue',         'Santa Monica', 'Back door to the alley'),
 ('Hollywood Hills Garage', '14 Mulholland Drive',     'Los Angeles', NULL),
 ('Union Station',          '800 N Alameda Street',    'Los Angeles', 'Locker 117');

INSERT INTO case_file (case_number, title, description, type_id, status_id, client_id, opened_on, closed_on, fee_estimate) VALUES
 ('NOIR-2025-001', 'The Missing Chauffeur',      'Chauffeur of the Sternwood family vanished after a night out.', 1, 4, 1, '2025-01-15', '2025-03-02', 2500.00),
 ('NOIR-2025-002', 'Compromising Photographs',   'A client is being blackmailed over photographs.',               5, 2, 2, '2025-02-10', NULL,         3200.00),
 ('NOIR-2025-003', 'The Falcon Statuette',       'Search for a stolen black bird statuette.',                    4, 4, 3, '2025-03-25', '2025-06-18', 8000.00),
 ('NOIR-2025-004', 'Fraudulent Policy',          'Suspected insurance fraud on a double-indemnity policy.',      3, 2, 5, '2025-07-02', NULL,         5400.00),
 ('NOIR-2025-005', 'Unfaithful Husband',         'Surveillance of spouse across three nights.',                  2, 5, 6, '2025-08-20', '2025-09-12', 900.00),
 ('NOIR-2025-006', 'Shadows at the Silver Moon', 'Inquiry into a death at the Silver Moon club.',                6, 1, 4, '2025-09-18', NULL,         6100.00),
 ('NOIR-2025-007', 'Letters from Nowhere',       'Anonymous letters threatening a company owner.',               5, 3, 3, '2025-10-01', NULL,         1800.00);

INSERT INTO case_detective (case_id, detective_id, role, assigned_on) VALUES
 (1, 1, 'LEAD', '2025-01-15'), (1, 5, 'ASSISTANT', '2025-01-20'),
 (2, 3, 'LEAD', '2025-02-10'), (2, 4, 'ASSISTANT', '2025-02-12'),
 (3, 2, 'LEAD', '2025-03-25'), (3, 1, 'ASSISTANT', '2025-04-01'),
 (4, 2, 'LEAD', '2025-07-02'), (4, 3, 'ASSISTANT', '2025-07-05'),
 (5, 5, 'LEAD', '2025-08-20'),
 (6, 1, 'LEAD', '2025-09-18'), (6, 4, 'ASSISTANT', '2025-09-19'),
 (7, 3, 'LEAD', '2025-10-01');

INSERT INTO suspect (first_name, last_name, alias, birth_date, last_seen_location_id) VALUES
 ('Joel',     'Cairo',    'The Levantine',  '1902-04-11', 2),
 ('Eddie',    'Mars',     'Mr. Mars',       '1898-09-02', 4),
 ('Lash',     'Canino',   'Lash',           '1910-01-23', 3),
 ('Norton',   'Dietrichson', NULL,          '1895-06-17', 5),
 ('Arthur',   'Geiger',   'Gig',            '1899-12-05', 1),
 ('Lola',     'Fenn',     'The Blonde',     NULL,         4);

INSERT INTO case_suspect (case_id, suspect_id, suspicion_level) VALUES
 (1, 2, 4), (1, 3, 3),
 (2, 5, 5), (2, 2, 2),
 (3, 1, 5), (3, 3, 4), (3, 6, 2),
 (4, 4, 5),
 (6, 2, 3), (6, 6, 4), (6, 3, 2);

INSERT INTO witness (first_name, last_name, phone, reliability) VALUES
 ('Agnes',  'Lozelle',  '555-0201', 3),
 ('Harry',  'Jones',    '555-0202', 2),
 ('Norris', 'Butler',   '555-0203', 5),
 ('Mona',   'Mars',     NULL,       4),
 ('Owen',   'Taylor',   '555-0205', 1);

INSERT INTO case_witness (case_id, witness_id, statement_date, statement) VALUES
 (1, 3, '2025-01-18', 'Saw the chauffeur leave in the grey sedan around midnight.'),
 (1, 5, '2025-01-22', 'Claims the car was parked at the pier.'),
 (2, 1, '2025-02-14', 'Delivered a package to Geiger''s shop on the 9th.'),
 (3, 2, '2025-04-02', 'Overheard a conversation about a black bird in the hotel lobby.'),
 (3, 4, '2025-05-11', 'Remembers a man with a cane near the docks.'),
 (6, 4, '2025-09-21', 'Was at the bar when the lights went out.'),
 (6, 1, '2025-09-25', NULL);

INSERT INTO informant (codename, handler_id, trust_level, fee_per_tip) VALUES
 ('Whistler',  1, 4, 25.00),
 ('Shadow',    2, 5, 50.00),
 ('Newsboy',   3, 2, 5.00),
 ('Barkeep',   1, 3, 15.00);

INSERT INTO tip (informant_id, case_id, received_at, content) VALUES
 (1, 1, '2025-01-17 22:10', 'The grey sedan was seen near Burbank Pier.'),
 (2, 3, '2025-04-05 03:40', 'The statuette is being moved through Union Station.'),
 (3, 2, '2025-02-15 09:00', 'Geiger''s shop has a hidden darkroom.'),
 (4, 6, '2025-09-20 01:30', 'Mars''s men were seen leaving by the back door.'),
 (2, 4, '2025-07-10 18:20', 'Dietrichson signed the policy while travelling.');

INSERT INTO evidence (evidence_code, case_id, evidence_type_id, location_id, description, found_at) VALUES
 ('EV-0001', 1, 5, 3, 'Tyre tracks matching a grey sedan.',               '2025-01-19 08:30'),
 ('EV-0002', 1, 2, 1, 'Unsigned note found in the chauffeur''s room.',    '2025-01-16 14:00'),
 ('EV-0003', 2, 1, 2, 'Negatives of compromising photographs.',           '2025-02-16 21:15'),
 ('EV-0004', 3, 3, 6, 'Replica statuette with a lead core.',              '2025-04-06 04:10'),
 ('EV-0005', 3, 6, 2, 'Letter signed with an initial "G".',               '2025-04-02 11:45'),
 ('EV-0006', 4, 2, 5, 'Insurance policy with a forged-looking signature.','2025-07-08 10:00'),
 ('EV-0007', 6, 4, 4, 'Recording of an argument from the club office.',   '2025-09-22 23:55'),
 ('EV-0008', 6, 3, 4, '.38 revolver, one round fired.',                   '2025-09-19 02:20'),
 ('EV-0009', 6, 5, 4, 'Lipstick smear on a glass.',                       '2025-09-19 02:45');

INSERT INTO evidence_custody (evidence_id, transferred_at, detective_id, note) VALUES
 (1, '2025-01-19 09:00', 1, 'Collected'),
 (1, '2025-01-20 10:00', 5, 'Handed over for analysis'),
 (3, '2025-02-16 22:00', 3, 'Collected'),
 (4, '2025-04-06 05:00', 2, 'Collected'),
 (4, '2025-04-07 09:30', 1, 'Second opinion'),
 (7, '2025-09-23 08:00', 1, 'Collected'),
 (8, '2025-09-19 03:00', 1, 'Collected'),
 (8, '2025-09-19 12:00', 4, 'To ballistics'),
 (9, '2025-09-19 03:10', 4, 'Collected');

INSERT INTO invoice (invoice_number, case_id, issued_on, due_on, amount) VALUES
 ('INV-2025-0001', 1, '2025-03-03', '2025-04-02', 2500.00),
 ('INV-2025-0002', 3, '2025-04-30', '2025-05-30', 4000.00),
 ('INV-2025-0003', 3, '2025-06-20', '2025-07-20', 4200.00),
 ('INV-2025-0004', 5, '2025-09-13', '2025-10-13', 900.00),
 ('INV-2025-0005', 4, '2025-08-01', '2025-08-31', 2000.00),
 ('INV-2025-0006', 6, '2025-10-01', '2025-10-31', 1500.00);

INSERT INTO payment (invoice_id, method_id, paid_on, amount) VALUES
 (1, 2, '2025-03-20', 2500.00),
 (2, 3, '2025-05-10', 4000.00),
 (3, 2, '2025-07-01', 2000.00),
 (4, 1, '2025-09-20', 900.00),
 (5, 4, '2025-08-15', 1000.00);
```

\newpage
## Skrypt testu wydajności indeksów
Skrypt generuje dane syntetyczne w osobnym schemacie `perf` i porównuje plany wykonania dla kolejnych konfiguracji indeksów (polecenia `\echo`, `\set` i `:Q` są składnią klienta `psql`).
```sql
-- Test indeksow na duzych danych syntetycznych (osobny schemat perf, nie zasmieca danych biznesowych).
-- Czesc generujaca uzywa generate_series / random().
\timing off
DROP SCHEMA IF EXISTS perf CASCADE;
CREATE SCHEMA perf;
SET search_path = perf;

CREATE TABLE case_file (
    case_id INTEGER PRIMARY KEY, status_id SMALLINT NOT NULL, client_id INTEGER NOT NULL,
    opened_on DATE NOT NULL, title VARCHAR(100) NOT NULL);
CREATE TABLE evidence (
    evidence_id INTEGER PRIMARY KEY, case_id INTEGER NOT NULL, evidence_type_id SMALLINT NOT NULL,
    found_at TIMESTAMP NOT NULL, description VARCHAR(100) NOT NULL);

-- Stale ziarno: kazde uruchomienie generuje te same dane, wiec plany i czasy sa porownywalne miedzy wariantami i przebiegami
SELECT setseed(0.42);
INSERT INTO case_file
SELECT g, 1 + (random()*4)::int, 1 + (random()*20000)::int,
       DATE '2015-01-01' + (random()*3650)::int, 'Case ' || g
FROM generate_series(1, 300000) g;

INSERT INTO evidence
SELECT g, 1 + (random()*299999)::int, 1 + (random()*5)::int,
       TIMESTAMP '2015-01-01' + random() * INTERVAL '3650 days', 'Evidence ' || g
FROM generate_series(1, 1000000) g;
ANALYZE;

-- Zapytanie testowe: dowody typu 3 (bron) w sprawach jednego klienta, w toku, otwartych od 2020
\set Q 'SELECT c.case_id, c.title, COUNT(*) AS weapons FROM perf.case_file c JOIN perf.evidence e ON e.case_id = c.case_id WHERE c.client_id = 777 AND c.status_id = 2 AND c.opened_on >= DATE ''2020-01-01'' AND e.evidence_type_id = 3 GROUP BY c.case_id, c.title'

\echo '=== 1. BRAK INDEKSOW (poza PK) ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :Q;

\echo '=== 2. TYLKO INDEKS FK evidence(case_id) ==='
CREATE INDEX p_ev_case ON evidence (case_id);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :Q;

\echo '=== 3. JEDEN PROSTY na case_file (client_id) + evidence(case_id) ==='
CREATE INDEX p_client ON case_file (client_id);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :Q;

\echo '=== 4. DWA PROSTE na case_file (client_id), (status_id) + evidence(case_id) ==='
CREATE INDEX p_status ON case_file (status_id);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :Q;

\echo '=== 5. ZLOZONY na case_file (client_id, status_id, opened_on) + evidence(case_id) ==='
DROP INDEX p_client, p_status;
CREATE INDEX p_cs_opened ON case_file (client_id, status_id, opened_on);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :Q;

\echo '=== 6. ZLOZONY na case_file + ZLOZONY evidence(case_id, evidence_type_id) ==='
DROP INDEX p_ev_case;
CREATE INDEX p_ev_case_type ON evidence (case_id, evidence_type_id);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :Q;

\echo '=== 7. ODWROCONA KOLEJNOSC (opened_on, status_id, client_id) -- zakres na pierwszej kolumnie ==='
DROP INDEX p_cs_opened;
CREATE INDEX p_opened_first ON case_file (opened_on, status_id, client_id);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :Q;

\echo '=== 8. POKRYWAJACY (client_id, status_id, opened_on) INCLUDE (title) ==='
DROP INDEX p_opened_first;
CREATE INDEX p_cs_opened_cov ON case_file (client_id, status_id, opened_on) INCLUDE (title);
VACUUM ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :Q;

-- ===================== RODZAJE INDEKSOW (typy fizyczne) =====================
-- Porownanie na tym samym zapytaniu Q, z tym samym indeksem evidence(case_id) co w wariancie 3.
DROP INDEX p_cs_opened_cov, p_ev_case_type;
CREATE INDEX p_ev_case ON evidence (case_id);

\echo '=== 9. B-TREE case_file(client_id) -- punkt odniesienia (jak wariant 3) ==='
CREATE INDEX p_client ON case_file (client_id);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :Q;

\echo '=== 10. HASH case_file(client_id) ==='
DROP INDEX p_client;
CREATE INDEX p_client_hash ON case_file USING hash (client_id);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :Q;

\echo '=== 11. BRIN case_file(opened_on) -- dane w losowej kolejnosci fizycznej ==='
DROP INDEX p_client_hash;
CREATE INDEX p_opened_brin ON case_file USING brin (opened_on);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :Q;
DROP INDEX p_opened_brin;

-- Zapytanie zakresowe po samej dacie (do porownania B-tree, BRIN i hash)
\set R 'SELECT count(*) FROM perf.case_file WHERE opened_on >= DATE ''2020-03-01'' AND opened_on < DATE ''2020-04-01'''

\echo '=== 12. ZAKRES opened_on: brak indeksu ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :R;

\echo '=== 13. ZAKRES opened_on: B-TREE ==='
CREATE INDEX p_opened_btree ON case_file (opened_on);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :R;
DROP INDEX p_opened_btree;

\echo '=== 14. ZAKRES opened_on: BRIN, dane w losowej kolejnosci fizycznej ==='
CREATE INDEX p_opened_brin ON case_file USING brin (opened_on);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :R;
DROP INDEX p_opened_brin;

\echo '=== 15. ZAKRES opened_on: BRIN po fizycznym uporzadkowaniu tabeli wg opened_on ==='
CREATE TABLE case_file_sorted AS SELECT * FROM case_file ORDER BY opened_on;
ANALYZE case_file_sorted;
CREATE INDEX p_sorted_brin ON case_file_sorted USING brin (opened_on);
ANALYZE case_file_sorted;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT count(*) FROM perf.case_file_sorted WHERE opened_on >= DATE '2020-03-01' AND opened_on < DATE '2020-04-01';

-- ===================== DRUGIE ZAPYTANIE: ZADNA POJEDYNCZA KOLUMNA NIE JEST SELEKTYWNA =====================
-- status_id pasuje do ok. 1/4 wierszy, tydzien opened_on do ok. 0,2% wierszy; dopiero oba warunki razem daja maly wynik.
\set S 'SELECT case_id, title FROM perf.case_file WHERE status_id = 2 AND opened_on >= DATE ''2020-03-01'' AND opened_on < DATE ''2020-03-08'''

\echo '=== 16. S: brak indeksu ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :S;

\echo '=== 17. S: prosty (status_id) ==='
CREATE INDEX q_status ON case_file (status_id);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :S;

\echo '=== 18. S: prosty (opened_on) ==='
DROP INDEX q_status;
CREATE INDEX q_opened ON case_file (opened_on);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :S;

\echo '=== 19. S: dwa proste (status_id), (opened_on) ==='
CREATE INDEX q_status ON case_file (status_id);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :S;

\echo '=== 20. S: ZLOZONY (status_id, opened_on) ==='
DROP INDEX q_status, q_opened;
CREATE INDEX q_composite ON case_file (status_id, opened_on);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :S;

\echo '=== 21. S: ZLOZONY w odwrotnej kolejnosci (opened_on, status_id) ==='
DROP INDEX q_composite;
CREATE INDEX q_composite_rev ON case_file (opened_on, status_id);
ANALYZE;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) :S;
DROP INDEX q_composite_rev;

-- ===================== ROZMIARY =====================
\echo '=== 22. ROZMIARY INDEKSOW I TABEL ==='
CREATE INDEX s_client_btree  ON case_file (client_id);
CREATE INDEX s_client_hash   ON case_file USING hash (client_id);
CREATE INDEX s_opened_btree  ON case_file (opened_on);
CREATE INDEX s_opened_brin   ON case_file USING brin (opened_on);
CREATE INDEX s_composite     ON case_file (client_id, status_id, opened_on);
CREATE INDEX s_composite_inc ON case_file (client_id, status_id, opened_on) INCLUDE (title);
CREATE INDEX s_ev_case       ON evidence (case_id);
CREATE INDEX s_ev_case_type  ON evidence (case_id, evidence_type_id);
VACUUM ANALYZE;
SELECT c.relname AS obiekt,
       CASE c.relkind WHEN 'r' THEN 'tabela' ELSE am.amname END AS rodzaj,
       pg_relation_size(c.oid) AS bajty,
       pg_size_pretty(pg_relation_size(c.oid)) AS rozmiar
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'perf'
LEFT JOIN pg_am am ON am.oid = c.relam
WHERE c.relkind IN ('r', 'i') AND (c.relkind = 'r' OR c.relname LIKE 's\_%')
  AND c.relname NOT LIKE '%pkey' AND c.relname <> 'case_file_sorted'
ORDER BY c.relkind DESC, pg_relation_size(c.oid) DESC;
```
