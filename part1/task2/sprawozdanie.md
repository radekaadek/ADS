# Sprawozdanie - Etap 2: elementy programowalne, automatyzacja, kopie zapasowe i migracja bazy biura detektywistycznego noir na SQL Server - Radosław Dąbkowski 325683

## 1. Zakres i środowisko

Przedmiotem sprawozdania jest baza danych agencji detektywistycznej „Noir & Spółka": klienci, detektywi i ich stopnie, sprawy, podejrzani, świadkowie, informatorzy z wskazówkami, dowody z łańcuchem dowodowym oraz faktury i płatności. Baza działa w PostgreSQL 17 w schemacie `noir` i ma 20 tabel:

- **słownikowe (5):** `case_status`, `case_type`, `evidence_type`, `detective_rank`, `payment_method`;
- **główne (11):** `client`, `detective`, `location`, `case_file`, `suspect`, `witness`, `informant`, `evidence`, `tip`, `invoice`, `payment`;
- **asocjacyjne (4):** `case_detective`, `case_suspect`, `case_witness`, `evidence_custody`.

Do obsługi elementów programowalnych i automatyzacji dodano sześć tabel pomocniczych (razem 26 tabel):

| Tabela | Przeznaczenie |
|---------------|--------------------------------------------------------------|
| `case_status_history` | historia zmian statusu sprawy (dla spraw z danych przykładowych odtworzona, dla nowych zapisywana przez procedurę otwarcia sprawy) |
| `document_counter` | liczniki numerów: ostatnio nadany numer sprawy w danym roku (tabela przechowuje też liczniki faktur i dowodów) |
| `operation_log` | dziennik zdarzeń i błędów procedury otwarcia sprawy |
| `alert` | alerty zadania nocnego: faktura po terminie, sprawa bez aktywności; zamykane po ustaniu przyczyny |
| `monthly_case_stats` | miesięczna migawka statystyk (otwarte i zamknięte sprawy, zafakturowane i wpłacone kwoty) wg typu sprawy |
| `job_run_log` | przebiegi zadań automatycznych |

### 1.1 Środowisko Docker

Oba systemy działają w kontenerach uruchamianych jednym poleceniem `docker compose up -d`. PostgreSQL pochodzi z oficjalnego obrazu `postgres:17` rozszerzonego o pakiety `pg_cron` (harmonogram zadań) i `tds_fdw` (połączenie z SQL Server), SQL Server z obrazu `mcr.microsoft.com/mssql/server:2022-latest` z włączonym SQL Server Agent. Dane trzymane są w trwałych wolumenach; osobne wolumeny przechowują kopie zapasowe oraz pliki wymiany danych między systemami.

<!-- KOD docker-compose.yml -->
```yaml
services:
  pg:
    build: ./docker/pg
    image: noir-pg-cron:17
    container_name: noir2_pg
    command: ["postgres", "-c", "shared_preload_libraries=pg_cron", "-c", "cron.database_name=postgres"]
    environment:
      POSTGRES_USER: noir_admin
      POSTGRES_PASSWORD: noir_admin_pw   # tylko srodowisko deweloperskie / zaliczeniowe
      POSTGRES_DB: noir
    ports:
      - "5433:5432"
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./sql/pg:/docker-entrypoint-initdb.d:ro
      - ./sql/tests:/tests:ro
      - ./sql/manual:/manual:ro
      - pg_backup:/backup
      - exchange:/exchange
      - ./etl:/etl:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U noir_admin -d noir"]
      interval: 5s
      timeout: 3s
      retries: 10

  mssql:
    image: mcr.microsoft.com/mssql/server:2022-latest
    container_name: noir2_mssql
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_PID: Developer
      MSSQL_AGENT_ENABLED: "true"
      MSSQL_SA_PASSWORD: "Noir_Admin_pw1"   # tylko srodowisko deweloperskie / zaliczeniowe
    ports:
      - "1434:1433"
    volumes:
      - mssql_data:/var/opt/mssql
      - ./sql/mssql:/sql:ro
      - ./sql/tests:/tests:ro
      - ./sql/manual:/manual:ro
      - mssql_backup:/var/opt/mssql/backup
      - exchange:/exchange
      - ./etl:/etl:ro
    healthcheck:
      test: ["CMD-SHELL", "/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P \"$$MSSQL_SA_PASSWORD\" -Q \"SELECT 1\" -b"]
      interval: 5s
      timeout: 5s
      retries: 20

volumes:
  pg_data:
  mssql_data:
  pg_backup:
  mssql_backup:
  exchange:
```
<!-- /KOD -->

Obraz PostgreSQL z `pg_cron` i `tds_fdw`:

<!-- KOD docker/pg/Dockerfile -->
```dockerfile
FROM postgres:17
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-17-cron postgresql-17-tds-fdw \
 && rm -rf /var/lib/apt/lists/*
```
<!-- /KOD -->

| Składnik | Wersja |
|---------------------------|----------------------------------------------|
| PostgreSQL | 17.11 (rozszerzenia `pg_cron` 1.6 i `tds_fdw` 2.0.5) |
| SQL Server | 2022 Developer Edition, 16.0.4295.3, Linux (Ubuntu 22.04), poziom zgodności 160 |
| Apache Hop (narzędzie ETL) | 2.19.0 |

Przy pierwszym starcie na pustym wolumenie PostgreSQL automatycznie tworzy całą bazę: schemat z danymi przykładowymi, widoki, role z uprawnieniami i indeksy, a następnie tabele pomocnicze, funkcję, procedurę otwarcia sprawy, wyzwalacz, procedurę zadania nocnego i jej harmonogram w `pg_cron`. Każdy krok korzysta z obiektów utworzonych wcześniej. Po starcie dziennik PostgreSQL nie zawiera błędów. Jedyny wpis oznaczony `FATAL` (`terminating background worker "pg_cron launcher"`) pojawia się, gdy obraz `postgres` po wykonaniu skryptów wyłącza swój tymczasowy serwer startowy i zamyka przy tym proces pomocniczy rozszerzenia `pg_cron`. Jest to normalny element uruchamiania kontenera, a nie awaria bazy.

## 2. Funkcja, wyzwalacz i procedury (PostgreSQL)

### 2.1 Różnice między elementami programowalnymi

Poniżej przedstawiono po jednym przykładzie każdego elementu.

Funkcja – wywoływana w zapytaniu, zwraca wartość lub tabelę:

```sql
CREATE FUNCTION fn_case_timeline(p_case_id INTEGER)
RETURNS TABLE (event_at TIMESTAMP, event_type VARCHAR, description VARCHAR)
LANGUAGE sql STABLE SET search_path = noir AS $$
    SELECT c.opened_on::TIMESTAMP, 'CASE_OPENED'::VARCHAR, c.title::VARCHAR
    FROM case_file c WHERE c.case_id = p_case_id
    UNION ALL
    SELECT e.found_at, 'EVIDENCE'::VARCHAR, (e.evidence_code || ': ' || e.description)::VARCHAR
    FROM evidence e WHERE e.case_id = p_case_id
    -- ... the example continues
    ORDER BY 1, 2
$$;

SELECT * FROM fn_case_timeline(3);
```

Wyzwalacz – uruchamiany automatycznie przez zdarzenie:

```sql
CREATE TRIGGER trg_payment BEFORE INSERT OR UPDATE ON payment
    FOR EACH ROW EXECUTE FUNCTION fn_trg_payment();
```

Procedura – wywoływana jawnie przez `CALL`, może zmieniać wiele tabel:

```sql
CREATE PROCEDURE sp_nightly_maintenance(p_stale_days INTEGER DEFAULT 60,
                                        p_retention_days INTEGER DEFAULT 90)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = noir AS $$
BEGIN
    -- ... the example continues
END $$;

CALL sp_nightly_maintenance();
```

| | Funkcja (UDF) | Wyzwalacz (trigger) | Procedura |
|---------|-------------------------|-------------------------|-------------------------|
| Wywołanie | w zapytaniu: `SELECT fn(...)`, `FROM fn(...)` | automatycznie przez zdarzenie `INSERT`/`UPDATE`/`DELETE` (oraz `TRUNCATE` dla wyzwalaczy instrukcji) | jawnie: `CALL sp(...)` |
| Wynik | wartość skalarna lub tabela, używana w wyrażeniach i widokach; funkcja `VOLATILE` może dodatkowo zmieniać dane | brak wartości dla wywołującego; zmienia wiersz (`NEW`), pomija operację (`NULL`) albo przerywa ją błędem; może też operować na innych tabelach | brak wyniku; dane zwracają parametry `INOUT`; poza tym może operować na wielu tabelach |
| Parametry | wejściowe (`IN`), wyjściowe (`OUT`) i dwukierunkowe (`INOUT`) | argumenty z definicji wyzwalacza (`TG_ARGV`) oraz dane z `NEW`/`OLD` | wejściowe (`IN`), wyjściowe (`OUT`) i dwukierunkowe (`INOUT`) |
| Transakcja | wykonuje się w transakcji wywołującego; w ciele funkcji nie wolno użyć `COMMIT` ani `ROLLBACK` (zatwierdzić lub wycofać transakcję może dopiero wywołujący) | nie ma własnej transakcji: wykonuje się w transakcji instrukcji, która go uruchomiła, i jest zatwierdzany lub wycofywany razem z nią (błąd w wyzwalaczu wycofuje całą instrukcję); `COMMIT` ani `ROLLBACK` w jego ciele nie są dozwolone | działa w transakcji wywołującego; wywołana poza transakcją może wykonywać `COMMIT`/`ROLLBACK`, o ile nie ma `SECURITY DEFINER` ani klauzuli `SET` |
| Zastosowanie w bazie noir | obliczenia i zestawienia dla użytkownika (oś czasu sprawy) | reguły biznesowe niezależne od aplikacji (kontrola wpłat względem faktury) | dodawanie rekordów (wpłata), operacje wielotabelowe (otwarcie sprawy, zadanie nocne) |

Zasady przyjęte w implementacji elementów programowalnych:

- nazwy obiektów rozpoczynają się od: `fn_` (funkcje), `sp_` (procedury), `trg_` (wyzwalacze), `fn_trg_` (funkcje wyzwalaczy);
- procedury oraz funkcje wyzwalaczy, które zmieniają dane, działają z uprawnieniami właściciela, czyli roli, z którą zostały utworzone (`SECURITY DEFINER`), i mają na stałe ustawiony `search_path`, co chroni przed podmianą obiektów przez zmianę ścieżki wyszukiwania; reguła biznesowa jest więc egzekwowana niezależnie od uprawnień roli, która zmienia dane;
- wyniki procedur (numer dokumentu, komunikat) zwracane są parametrami `INOUT`;
- numer sprawy (`NOIR-RRRR-NNN`) nadaje `sp_open_case`: zwiększa o 1 licznik zapisany w tabeli `document_counter` (osobny dla każdego roku), więc numer nigdy się nie powtarza, także po usunięciu sprawy o najwyższym numerze; wiersz licznika jest zablokowany do końca transakcji, dzięki czemu równoległe transakcje dostają różne numery, a ograniczenie `UNIQUE` pozostaje ostatecznym zabezpieczeniem przed duplikatami;
- komunikaty błędów zawierają wartości, które naruszyły regułę.

### 2.2 Funkcja użytkownika

| Funkcja | Zwraca | Zastosowanie |
|-----------------------|--------------|--------------------------------------------------------------|
| `fn_case_timeline(case_id)` | tabelę | oś czasu sprawy z pięciu tabel (otwarcie, zmiany statusu, dowody, wskazówki, zeznania); bez danych finansowych, więc jest dostępna dla detektywa |

Definicja funkcji:

<!-- KOD sql/pg/07_functions.sql -->
```sql
SET search_path = noir;

-- ===================== TABLE FUNCTION (for users) =====================
-- Case timeline: investigation events from several tables in chronological order (no finance)
CREATE FUNCTION fn_case_timeline(p_case_id INTEGER)
RETURNS TABLE (event_at TIMESTAMP, event_type VARCHAR, description VARCHAR)
LANGUAGE sql STABLE SET search_path = noir AS $$
    -- step 1: the opening of the case (a date, converted to a timestamp so that all branches have the same type)
    SELECT c.opened_on::TIMESTAMP, 'CASE_OPENED'::VARCHAR, c.title::VARCHAR FROM case_file c WHERE c.case_id = p_case_id
    UNION ALL
    -- step 2: status changes (the first history entry, with no old status, only repeats the opening, so it is skipped)
    SELECT h.changed_at, 'STATUS'::VARCHAR, ('-> ' || s.name)::VARCHAR
    FROM case_status_history h JOIN case_status s ON s.status_id = h.new_status_id
    WHERE h.case_id = p_case_id AND h.old_status_id IS NOT NULL
    UNION ALL
    -- step 3: evidence found in the case
    SELECT e.found_at, 'EVIDENCE'::VARCHAR, (e.evidence_code || ': ' || e.description)::VARCHAR FROM evidence e WHERE e.case_id = p_case_id
    UNION ALL
    -- step 4: tips received
    SELECT t.received_at, 'TIP'::VARCHAR, t.content::VARCHAR FROM tip t WHERE t.case_id = p_case_id
    UNION ALL
    -- step 5: witness statements
    SELECT cw.statement_date::TIMESTAMP, 'STATEMENT'::VARCHAR, (w.first_name || ' ' || w.last_name)::VARCHAR
    FROM case_witness cw JOIN witness w ON w.witness_id = cw.witness_id WHERE cw.case_id = p_case_id
    -- step 6: all events together in chronological order (by time, then by type)
    ORDER BY 1, 2
$$;
```
<!-- /KOD -->

Wynik wywołania funkcji na danych przykładowych:

<!-- KOD sql/manual/20_functions_demo.sql -->
```sql
\set VERBOSITY terse
SET search_path = noir;
\echo '--- fn_case_timeline(3): timeline of the Falcon Statuette case'
SELECT * FROM fn_case_timeline(3);
```
<!-- /KOD -->

<!-- WYNIK results/pg_20_functions_demo.txt -->
```text
--- fn_case_timeline(3): timeline of the Falcon Statuette case
      event_at       | event_type  |                     description
---------------------+-------------+-----------------------------------------------------
 2025-03-25 00:00:00 | CASE_OPENED | The Falcon Statuette
 2025-04-02 00:00:00 | STATEMENT   | Harry Jones
 2025-04-02 11:45:00 | EVIDENCE    | EV-0005: Letter signed with an initial "G".
 2025-04-05 03:40:00 | TIP         | The statuette is being moved through Union Station.
 2025-04-06 04:10:00 | EVIDENCE    | EV-0004: Replica statuette with a lead core.
 2025-05-11 00:00:00 | STATEMENT   | Mona Mars
 2025-06-18 01:00:00 | STATUS      | -> Closed - solved
```
<!-- /WYNIK -->

### 2.3 Wyzwalacz

| Wyzwalacz | Tabela, zdarzenie | Reguła |
|----------------------|----------------------|--------------------------------------------------------------|
| `trg_payment` | `payment`, `BEFORE INSERT/UPDATE` | data wpłaty nie może być wcześniejsza niż data wystawienia faktury ani późniejsza niż dzisiejsza, a suma wpłat na fakturę nie może przekroczyć jej kwoty (na czas sprawdzenia wyzwalacz blokuje wiersz faktury) |

Definicja funkcji wyzwalacza i wyzwalacza:

<!-- KOD sql/pg/09_triggers.sql -->
```sql
SET search_path = noir;
-- SECURITY DEFINER: the trigger function runs with the privileges of its owner (the role it was created with), so the business rule applies regardless of the rights of the role modifying the data.

-- ===================== FINANCE =====================
-- Payment: a payment cannot be dated before the invoice is issued or in the future, and the total of all payments for an invoice cannot exceed the invoice amount.
CREATE FUNCTION fn_trg_payment() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = noir AS $$
DECLARE v_amount NUMERIC; v_issued DATE; v_paid NUMERIC;
BEGIN
    -- step 1: read the invoice amount and issue date; FOR UPDATE locks the invoice row, so two concurrent payments
    -- for the same invoice are checked one after another and cannot exceed the amount together
    SELECT amount, issued_on INTO v_amount, v_issued FROM invoice WHERE invoice_id = NEW.invoice_id FOR UPDATE;
    -- step 2: the payment must not be dated before the invoice was issued
    IF NEW.paid_on < v_issued THEN
        RAISE EXCEPTION 'Payment (%) is before invoice issue date (%)', NEW.paid_on, v_issued USING ERRCODE = 'check_violation';
    END IF;
    -- step 3: the payment must not be dated in the future
    IF NEW.paid_on > CURRENT_DATE THEN
        RAISE EXCEPTION 'Payment date is in the future (%)', NEW.paid_on USING ERRCODE = 'check_violation';
    END IF;
    -- step 4: total of the payments for the invoice: the other payments plus the new one
    -- (on UPDATE the changed row itself is excluded, so it is not counted twice)
    SELECT COALESCE(SUM(amount), 0) + NEW.amount INTO v_paid FROM payment
    WHERE invoice_id = NEW.invoice_id AND (TG_OP = 'INSERT' OR payment_id <> NEW.payment_id);
    -- step 5: the total must not exceed the invoice amount
    IF v_paid > v_amount THEN
        RAISE EXCEPTION 'Payments (total %) exceed invoice amount (%)', v_paid, v_amount USING ERRCODE = 'check_violation';
    END IF;
    -- step 6: all rules hold, the row is saved (an exception above cancels the whole statement)
    RETURN NEW;
END $$;
CREATE TRIGGER trg_payment BEFORE INSERT OR UPDATE ON payment
    FOR EACH ROW EXECUTE FUNCTION fn_trg_payment();
```
<!-- /KOD -->

Test: polecenia naruszające regułę kończą się błędem, a poprawna wpłata (reszta faktury) przechodzi i zamyka saldo:

<!-- KOD sql/manual/22_triggers_demo.sql -->
```sql
\set VERBOSITY terse
SET search_path = noir;
\echo '=== payments: above the invoice amount / before issue date / in the future / update to an excessive amount ==='
INSERT INTO payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, CURRENT_DATE, 2300.00);
INSERT INTO payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, '2025-01-01', 100.00);
INSERT INTO payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, CURRENT_DATE + 3, 100.00);
UPDATE payment SET amount = 4500 WHERE payment_id = 3;
\echo '=== payments: valid payment (remainder of the invoice) ==='
INSERT INTO payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, CURRENT_DATE, 2200.00);
SELECT invoice_number, amount, paid, balance, payment_status FROM v_invoice_balance WHERE invoice_number = 'INV-2025-0003';
```
<!-- /KOD -->

Wynik:

<!-- WYNIK results/pg_22_triggers_demo.txt -->
```text
=== payments: above the invoice amount / before issue date / in the future / update to an excessive amount ===
ERROR:  Payments (total 4300.00) exceed invoice amount (4200.00)
ERROR:  Payment (2025-01-01) is before invoice issue date (2025-06-20)
ERROR:  Payment date is in the future (2026-10-20)
ERROR:  Payments (total 4500.00) exceed invoice amount (4200.00)
=== payments: valid payment (remainder of the invoice) ===
INSERT 0 1
 invoice_number | amount  |  paid   | balance | payment_status
----------------+---------+---------+---------+----------------
 INV-2025-0003  | 4200.00 | 4200.00 |    0.00 | PAID
```
<!-- /WYNIK -->

### 2.4 Procedury

| Procedura | Działanie |
|-----------------------|--------------------------------------------------------------|
| `sp_register_payment` | dodaje wpłatę na fakturę wskazaną numerem, z metodą płatności wskazaną nazwą; zwraca identyfikator wpłaty `INOUT` |
| `sp_open_case` | otwiera nową sprawę: w jednej transakcji sprawdza klienta, typ sprawy i aktywnego detektywa, nadaje numer sprawy, zapisuje sprawę, pierwszy wpis historii statusów i przypisanie detektywa prowadzącego; przy błędzie wycofuje wszystkie zmiany; wynik (`OK:` albo `ERROR:`) zapisuje w dzienniku zdarzeń i zwraca jako komunikat `INOUT` |
| `sp_nightly_maintenance` | zadanie nocne (głębiej opisane w sekcji trzeciej) |

#### Procedura `sp_register_payment`

Procedura sprawdza istnienie faktury i metody płatności, a następnie wstawia wpłatę; regułę kwoty i dat egzekwuje wyzwalacz `trg_payment`.

Definicja procedury:

<!-- KOD sql/pg/08_procedures.sql do="CASE OPENING" -->
```sql
SET search_path = noir;

-- SECURITY DEFINER: the procedure runs with the privileges of its owner (the role it was created with), not of the caller. The application role gets EXECUTE
-- on the procedure rather than rights to tables. INOUT parameters return the result (number, message).

-- ===================== PAYMENT REGISTRATION =====================
-- Payment for an invoice identified by number, payment method by name; returns the id of the new payment.
-- The rules (amount not greater than the balance, date) are enforced by the trg_payment trigger.
CREATE PROCEDURE sp_register_payment(p_invoice_number VARCHAR, p_method_name VARCHAR, p_amount NUMERIC,
                                     p_paid_on DATE, INOUT p_payment_id INTEGER)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = noir AS $$
DECLARE v_invoice INTEGER; v_method SMALLINT;
BEGIN
    -- step 1: find the invoice by its number; an unknown number is an error
    SELECT invoice_id INTO v_invoice FROM invoice WHERE invoice_number = p_invoice_number;
    IF v_invoice IS NULL THEN
        RAISE EXCEPTION 'Invoice does not exist: %', p_invoice_number USING ERRCODE = 'foreign_key_violation';
    END IF;
    -- step 2: find the payment method by its name; an unknown name is an error
    SELECT method_id INTO v_method FROM payment_method WHERE name = p_method_name;
    IF v_method IS NULL THEN
        RAISE EXCEPTION 'Unknown payment method: %', p_method_name USING ERRCODE = 'foreign_key_violation';
    END IF;
    -- step 3: add the payment (today if no date is given) and return its id; the trigger checks amount and dates
    INSERT INTO payment (invoice_id, method_id, paid_on, amount)
    VALUES (v_invoice, v_method, COALESCE(p_paid_on, CURRENT_DATE), p_amount)
    RETURNING payment_id INTO p_payment_id;
END $$;
```
<!-- /KOD -->

#### Procedura złożona `sp_open_case`

`sp_open_case(p_client_id, p_type_name, p_title, p_description, p_fee_estimate, p_lead_detective_id, INOUT p_case_number, INOUT p_result)` dodaje do bazy nową sprawę (klient, typ, tytuł, opis, szacowana opłata, detektyw prowadzący; dwa ostatnie parametry zwracają nadany numer sprawy i komunikat) i działa na pięciu tabelach. W jednej transakcji sprawdza klienta i typ sprawy, nadaje numer z licznika (`document_counter`), wstawia sprawę w statusie `Open`, zapisuje pierwszy wpis w historii statusów (`case_status_history`), sprawdza, że detektyw prowadzący jest aktywny, i przypisuje go jako prowadzącego.

Obsługa błędów: ciało procedury jest blokiem `BEGIN ... EXCEPTION WHEN OTHERS`, czyli podtransakcją. Błąd w dowolnym kroku wycofuje wszystkie zmiany bloku. Następnie procedura zapisuje wpis w `operation_log` i zwraca w parametrze `p_result` komunikat zaczynający się od `OK:` albo `ERROR:`. Poniższe trzy scenariusze mają postać przygotowanie (`setup`), wywołanie (`act`), sprawdzenie (`check`). Najpierw zapisywana jest liczba spraw, potem następuje wywołanie procedury, a na końcu porównanie stanu z oczekiwanym; w scenariuszach z błędem sprawdzane jest, że liczba spraw się nie zmieniła i nie została żadna sprawa o wycofanym tytule (`rolled_back_rows = 0`). Parametry `INOUT` są przekazywane jako `NULL`.

Definicja procedury:

<!-- KOD sql/pg/08_procedures.sql od="CASE OPENING" -->
```sql
-- ===================== CASE OPENING =====================
-- Opening a case: number from the document counter (document_counter), case record, status history entry, lead detective.
-- The number is always greater than the last one issued, even after deleting the case with the highest number;
-- The counter is incremented by one INSERT ... ON CONFLICT DO UPDATE, which locks the row until the end of the transaction, so concurrent transactions get different numbers.
-- The BEGIN ... EXCEPTION block is a subtransaction: an error in any step rolls back all changes of the block,
-- after which the procedure records the error in operation_log and returns a message in p_result.
CREATE PROCEDURE sp_open_case(p_client_id INTEGER, p_type_name VARCHAR, p_title VARCHAR, p_description VARCHAR,
                              p_fee_estimate NUMERIC, p_lead_detective_id INTEGER,
                              INOUT p_case_number VARCHAR, INOUT p_result VARCHAR)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = noir AS $$
DECLARE v_type SMALLINT; v_status SMALLINT; v_case INTEGER; v_year INTEGER := EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER; v_value INTEGER;
BEGIN
    p_case_number := NULL;
    BEGIN
        -- step 1: the client must exist
        IF NOT EXISTS (SELECT 1 FROM client WHERE client_id = p_client_id) THEN
            RAISE EXCEPTION 'Client does not exist: id %', p_client_id;
        END IF;
        -- step 2: the case type must exist
        SELECT type_id INTO v_type FROM case_type WHERE name = p_type_name;
        IF v_type IS NULL THEN
            RAISE EXCEPTION 'Unknown case type: %', p_type_name;
        END IF;
        -- step 3: a new case always starts in the status Open
        SELECT status_id INTO v_status FROM case_status WHERE name = 'Open';
        -- step 4: next case number: the counter row for the year is created with 1 or, if it exists, increased by 1
        INSERT INTO document_counter (counter_name, counter_year, last_value) VALUES ('CASE', v_year, 1)
        ON CONFLICT (counter_name, counter_year) DO UPDATE SET last_value = document_counter.last_value + 1
        RETURNING last_value INTO v_value;
        -- step 5: build the number NOIR-<year>-<counter padded to 3 digits>
        p_case_number := 'NOIR-' || v_year || '-' || LPAD(v_value::VARCHAR, 3, '0');
        -- step 6: add the case
        INSERT INTO case_file (case_number, title, description, type_id, status_id, client_id, opened_on, fee_estimate)
        VALUES (p_case_number, p_title, p_description, v_type, v_status, p_client_id, CURRENT_DATE, COALESCE(p_fee_estimate, 0))
        RETURNING case_id INTO v_case;
        -- step 7: first status history entry (no old status)
        INSERT INTO case_status_history (case_id, old_status_id, new_status_id, changed_by)
        VALUES (v_case, NULL, v_status, CURRENT_USER);
        -- step 8: the lead detective must exist and be active; the error here rolls back steps 4-7 as well
        IF NOT EXISTS (SELECT 1 FROM detective WHERE detective_id = p_lead_detective_id AND is_active) THEN
            RAISE EXCEPTION 'Detective % does not exist or is not active', p_lead_detective_id;
        END IF;
        -- step 9: assign the lead detective
        INSERT INTO case_detective (case_id, detective_id, role, assigned_on)
        VALUES (v_case, p_lead_detective_id, 'LEAD', CURRENT_DATE);
        -- step 10: success: return the message and log it
        p_result := 'OK: case opened ' || p_case_number;
        INSERT INTO operation_log (procedure_name, severity, message) VALUES ('sp_open_case', 'INFO', p_result);
    -- on any error: all changes of the block are rolled back; return the message and log the error
    EXCEPTION WHEN OTHERS THEN
        p_case_number := NULL;
        p_result := 'ERROR: ' || SQLERRM;
        INSERT INTO operation_log (procedure_name, severity, message) VALUES ('sp_open_case', 'ERROR', LEFT(SQLERRM, 500));
    END;
END $$;
```
<!-- /KOD -->

**Scenariusz 1: poprawne otwarcie sprawy**

```sql
SELECT COUNT(*) AS cases_before FROM case_file;
CALL sp_open_case(1, 'Fraud', 'The Forged Ledger', 'Falsified books of a shipping company.', 4200, 2, NULL, NULL);
SELECT COUNT(*) AS cases_after FROM case_file;
SELECT case_number, title, fee_estimate, opened_on FROM case_file WHERE title = 'The Forged Ledger';
SELECT c.case_number, d.last_name, cd.role FROM case_detective cd JOIN case_file c USING (case_id) JOIN detective d USING (detective_id) WHERE c.title = 'The Forged Ledger';
SELECT h.old_status_id, s.name AS new_status FROM case_status_history h JOIN case_status s ON s.status_id = h.new_status_id WHERE h.case_id = (SELECT case_id FROM case_file WHERE title = 'The Forged Ledger');
```

<!-- WYNIK results/pg_21_procedures_demo.txt od="=== sp_open_case: success ===" do="=== sp_open_case: error at the first step (nonexistent client) ===" -->
```text
=== sp_open_case: success ===
 cases_before
--------------
            7

 p_case_number |           p_result
---------------+-------------------------------
 NOIR-2026-001 | OK: case opened NOIR-2026-001

 cases_after
-------------
           8

  case_number  |       title       | fee_estimate | opened_on
---------------+-------------------+--------------+------------
 NOIR-2026-001 | The Forged Ledger |      4200.00 | 2026-10-17

  case_number  | last_name | role
---------------+-----------+------
 NOIR-2026-001 | Spade     | LEAD

 old_status_id | new_status
---------------+------------
               | Open
```
<!-- /WYNIK -->

**Scenariusz 2: błąd na pierwszym kroku (nieistniejący klient, id 999)**

```sql
SELECT COUNT(*) AS cases_before FROM case_file;
CALL sp_open_case(999, 'Fraud', 'Ghost client', NULL, 100, 2, NULL, NULL);
SELECT COUNT(*) AS cases_after, COUNT(*) FILTER (WHERE title = 'Ghost client') AS rolled_back_rows FROM case_file;
```

<!-- WYNIK results/pg_21_procedures_demo.txt od="=== sp_open_case: error at the first step (nonexistent client) ===" do="=== sp_open_case: error at the last step (inactive detective) - the inserted case is rolled back ===" -->
```text
=== sp_open_case: error at the first step (nonexistent client) ===
 cases_before
--------------
            8

 p_case_number |               p_result
---------------+--------------------------------------
               | ERROR: Client does not exist: id 999

 cases_after | rolled_back_rows
-------------+------------------
           8 |                0
```
<!-- /WYNIK -->

**Scenariusz 3: błąd na ostatnim kroku (detektyw nieaktywny): wstawiona wcześniej sprawa i wpis historii zostają wycofane**

```sql
SELECT COUNT(*) AS cases_before FROM case_file;
CALL sp_open_case(1, 'Theft', 'Case that must roll back', NULL, 100, 6, NULL, NULL);
SELECT COUNT(*) AS cases_after, COUNT(*) FILTER (WHERE title = 'Case that must roll back') AS rolled_back_rows FROM case_file;
SELECT procedure_name, severity, message FROM operation_log ORDER BY log_id;
```

<!-- WYNIK results/pg_21_procedures_demo.txt od="=== sp_open_case: error at the last step (inactive detective) - the inserted case is rolled back ===" do="=== numbering: the number of a deleted case is not reused ===" -->
```text
=== sp_open_case: error at the last step (inactive detective) - the inserted case is rolled back ===
 cases_before
--------------
            8

 p_case_number |                      p_result
---------------+----------------------------------------------------
               | ERROR: Detective 6 does not exist or is not active

 cases_after | rolled_back_rows
-------------+------------------
           8 |                0

 procedure_name | severity |                   message
----------------+----------+---------------------------------------------
 sp_open_case   | INFO     | OK: case opened NOIR-2026-001
 sp_open_case   | ERROR    | Client does not exist: id 999
 sp_open_case   | ERROR    | Detective 6 does not exist or is not active
```
<!-- /WYNIK -->

Numeracja: po otwarciu sprawy `NOIR-2026-002` i jej usunięciu kolejna otwarta sprawa dostaje `NOIR-2026-003`, a nie ponownie numer 002, ponieważ licznik w `document_counter` nie cofa się razem z usuwanymi sprawami:

<!-- KOD sql/manual/21_procedures_demo.sql od="=== numbering: the number of a deleted case is not reused ===" do="=== sp_register_payment" -->
```sql
\echo '=== numbering: the number of a deleted case is not reused ==='
SELECT counter_name, counter_year, last_value FROM document_counter WHERE counter_name = 'CASE' ORDER BY counter_year;
CALL sp_open_case(1, 'Theft', 'Case to delete', NULL, 100, 4, NULL, NULL);
DELETE FROM case_status_history WHERE case_id = (SELECT case_id FROM case_file WHERE title = 'Case to delete');
DELETE FROM case_detective WHERE case_id = (SELECT case_id FROM case_file WHERE title = 'Case to delete');
DELETE FROM case_file WHERE title = 'Case to delete';
CALL sp_open_case(1, 'Theft', 'Case after delete', NULL, 100, 4, NULL, NULL);
SELECT case_number, title FROM case_file WHERE title IN ('The Forged Ledger', 'Case after delete') ORDER BY case_number;
SELECT counter_name, counter_year, last_value FROM document_counter WHERE counter_name = 'CASE' ORDER BY counter_year;
```
<!-- /KOD -->

<!-- WYNIK results/pg_21_procedures_demo.txt od="=== numbering: the number of a deleted case is not reused ===" do="=== sp_register_payment" -->
```text
=== numbering: the number of a deleted case is not reused ===
 counter_name | counter_year | last_value
--------------+--------------+------------
 CASE         |         2025 |          7
 CASE         |         2026 |          1

 p_case_number |           p_result
---------------+-------------------------------
 NOIR-2026-002 | OK: case opened NOIR-2026-002

DELETE 1
DELETE 1
DELETE 1
 p_case_number |           p_result
---------------+-------------------------------
 NOIR-2026-003 | OK: case opened NOIR-2026-003

  case_number  |       title
---------------+-------------------
 NOIR-2026-001 | The Forged Ledger
 NOIR-2026-003 | Case after delete

 counter_name | counter_year | last_value
--------------+--------------+------------
 CASE         |         2025 |          7
 CASE         |         2026 |          3
```
<!-- /WYNIK -->

Trzecia procedura, `sp_nightly_maintenance`, jest uruchamiana automatyczne; opisano ją szerzej w sekcji trzeciej. Wypełnia tabele `alert` i `monthly_case_stats` oraz usuwa stare wpisy dziennika (zmiany w wielu tabelach, transakcja, obsługa błędów).

### 2.5 Agregacje i ograniczenia

Agregacje trafiają do użytkowników przez widoki, funkcję `fn_case_timeline` oraz tabelę `monthly_case_stats` odświeżaną przez zadanie nocne. Ograniczenia wykraczające poza `CHECK`, `UNIQUE` i klucze obce:

| Reguła biznesowa | Mechanizm |
|--------------------------------------------------|----------------------------------------------|
| suma wpłat na fakturę nie może przekroczyć jej kwoty, a data wpłaty nie może być wcześniejsza niż data wystawienia faktury ani późniejsza niż dzisiejsza | wyzwalacz `trg_payment` |
| najwyżej jeden prowadzący detektyw na sprawę | unikalny indeks częściowy `uq_case_detective_lead` na `case_detective (case_id)` z warunkiem `WHERE role = 'LEAD'`: unikalność obowiązuje tylko wśród wierszy prowadzących, więc sprawa może mieć wielu detektywów pomocniczych, ale tylko jednego prowadzącego |
| najwyżej jeden otwarty alert na fakturę po terminie i jeden na nieaktywną sprawę (powtórne uruchomienie zadania nie tworzy duplikatów) | unikalne indeksy częściowe `uq_alert_open_invoice` (`alert (invoice_id)`, `WHERE resolved_on IS NULL AND invoice_id IS NOT NULL`) i `uq_alert_open_stale` (`alert (case_id)`, `WHERE resolved_on IS NULL AND alert_type = 'STALE_CASE'`): unikalność dotyczy tylko alertów otwartych, więc po zamknięciu alertu ta sama faktura lub sprawa może dostać nowy |
| numer sprawy nigdy się nie powtarza, także po usunięciu sprawy o najwyższym numerze | procedura `sp_open_case`, tabela `document_counter` i `UNIQUE` |
| nowa sprawa ma klienta, typ, aktywnego detektywa prowadzącego i wpis historii statusu | procedura `sp_open_case` |
| alerty o fakturach po terminie i nieaktywnych sprawach, statystyki miesięczne, retencja dziennika | procedura `sp_nightly_maintenance` |

Zadanie dopuszcza ograniczenie się do 10 elementów programowalnych i opisanie, co jeszcze byłoby potrzebne. Zaimplementowano 5 elementów (1 funkcja, 3 procedury, 1 wyzwalacz). W pełnym systemie byłyby potrzebne dodatkowo:

- funkcje: saldo faktury, suma wpłat i zadłużenie klienta (dziś realizują je widoki), przychód w roku z podziałem na miesiące, liczba aktywnych spraw detektywa, funkcja określająca, czy status oznacza zamknięcie sprawy;
- procedury: dodawanie klientów i detektywów (z walidacją e-maila i unikalności bez względu na wielkość liter), dodanie dowodu wraz z pierwszym wpisem łańcucha dowodowego, przekazanie dowodu, dodanie świadka z zeznaniem, przypisanie detektywa, wystawienie faktury, zamknięcie sprawy (faktura końcowa, zamknięcie alertów), nadawanie numerów faktur i dowodów, anonimizacja danych klientów (RODO), procedury raportowe dla księgowości;
- wyzwalacze: spójność statusu i daty zamknięcia sprawy (zamknięta sprawa nie wraca do otwartej), automatyczny wpis do historii statusów, niezmienny i chronologiczny łańcuch dowodowy (przekazanie do aktywnego detektywa innego niż obecny), dowód tylko do sprawy otwartej i z poprawną datą, przypisanie tylko aktywnego detektywa do sprawy niezamkniętej z limitem pięciu aktywnych spraw, kontrola kwoty faktury (nie niższa od wpłat, faktura nie zmienia sprawy), audyt zmian pozostałych tabel (podejrzani, świadkowie, informatorzy), kontrola, że wskazówka dotyczy sprawy aktywnej i prowadzonej przez opiekuna informatora;
- poza elementami programowalnymi: rozliczanie wypłat dla informatorów (`fee_per_tip`), testy współbieżności pod obciążeniem i partycjonowanie dzienników.

### 2.6 Uprawnienia do nowych elementów i testy

Funkcje i procedury domyślnie są wykonywalne dla `PUBLIC`, dlatego prawo `EXECUTE` odebrano wszystkim i nadano jawnie:

| Użytkownik | Nowe uprawnienia |
|---|---|
| `detective_app` | `EXECUTE` na `sp_open_case` i `fn_case_timeline`; `SELECT` na `case_status_history` i widoku `v_stale_cases`; brak dostępu do finansów, alertów finansowych i dzienników |
| `accountant_app` | `EXECUTE` na `sp_register_payment`; `SELECT` na `v_case_financials`, `v_client_balance`, `monthly_case_stats`; brak dostępu do danych śledztwa, alertów i dzienników |
| `client_portal` | bez zmian: wyłącznie widok `v_client_cases`; żadnych funkcji ani procedur |

Test: każde polecenie wykonano jako dany użytkownik w transakcji wycofywanej na końcu. „OK" oznacza wykonanie, „DENIED" błąd `permission denied`, „ERROR" inny błąd (np. naruszenie reguły biznesowej, która obowiązuje także role z uprawnieniami). Wynik: 67 z 67 testów zakończonych powodzeniem.

<!-- TESTY results/pg_permissions_output.txt -->
| Użytkownik | Polecenie | Oczekiwano | Wynik | Test |
|--------|----------------------------------|-----|-----|----|
| `detective_app` | `SELECT count(*) FROM noir.case_file` | OK | OK | PASS |
| `detective_app` | `INSERT INTO noir.witness (first_name,last_name,reliability) VALUES ('Test','Witness',3)` | OK | OK | PASS |
| `detective_app` | `SELECT * FROM noir.invoice` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM noir.v_invoice_balance` | DENIED | DENIED | PASS |
| `detective_app` | `DELETE FROM noir.evidence` | DENIED | DENIED | PASS |
| `detective_app` | `INSERT INTO noir.evidence_custody (evidence_id,transferred_at,detective_id,note) VALUES (1,now(),1,'Test')` | OK | OK | PASS |
| `detective_app` | `UPDATE noir.evidence_custody SET note = 'zmiana'` | DENIED | DENIED | PASS |
| `detective_app` | `DELETE FROM noir.evidence_custody` | DENIED | DENIED | PASS |
| `detective_app` | `INSERT INTO noir.location (approximate_lat,approximate_lon) VALUES (0,0)` | OK | OK | PASS |
| `detective_app` | `DELETE FROM noir.case_suspect` | OK | OK | PASS |
| `detective_app` | `DELETE FROM noir.case_file` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.v_invoice_balance` | OK | OK | PASS |
| `accountant_app` | `SELECT * FROM noir.case_file` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.suspect` | DENIED | DENIED | PASS |
| `accountant_app` | `INSERT INTO noir.payment (invoice_id,method_id,paid_on,amount) VALUES (6,2,CURRENT_DATE,100)` | OK | OK | PASS |
| `accountant_app` | `SELECT * FROM noir.payment` | OK | OK | PASS |
| `accountant_app` | `SELECT case_id, case_number, fee_estimate FROM noir.case_file` | OK | OK | PASS |
| `accountant_app` | `INSERT INTO noir.invoice (invoice_number,case_id,issued_on,due_on,amount) VALUES ('FV-TEST',1,CURRENT_DATE,CURRENT_DATE,100)` | OK | OK | PASS |
| `accountant_app` | `UPDATE noir.invoice SET due_on = due_on + 14` | OK | OK | PASS |
| `accountant_app` | `DELETE FROM noir.payment` | OK | OK | PASS |
| `accountant_app` | `DELETE FROM noir.invoice` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT description FROM noir.case_file` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.v_client_cases` | OK | OK | PASS |
| `client_portal` | `SELECT * FROM noir.case_file` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.v_case_overview` | DENIED | DENIED | PASS |
| `client_portal` | `INSERT INTO noir.client (first_name,last_name,email) VALUES ('a','b','c')` | DENIED | DENIED | PASS |
| `detective_app` | `INSERT INTO noir.case_detective (case_id,detective_id,role,assigned_on) VALUES (2,1,'ASSISTANT',CURRENT_DATE)` | OK | OK | PASS |
| `detective_app` | `DELETE FROM noir.case_detective` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.v_evidence_chain` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.v_detective_workload` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.v_case_overview` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM noir.v_client_cases` | OK | OK | PASS |
| `client_portal` | `SELECT * FROM noir.v_invoice_balance` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.v_evidence_chain` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.v_detective_workload` | DENIED | DENIED | PASS |
| `detective_app` | `UPDATE noir.case_file SET fee_estimate = fee_estimate + 1` | OK | OK | PASS |
| `detective_app` | `UPDATE noir.informant SET trust_level = 3` | OK | OK | PASS |
| `accountant_app` | `UPDATE noir.payment SET amount = amount + 1 WHERE payment_id = 3` | OK | OK | PASS |
| `accountant_app` | `SELECT * FROM noir.payment_method` | OK | OK | PASS |
| `detective_app` | `SELECT * FROM noir.fn_case_timeline(3)` | OK | OK | PASS |
| `detective_app` | `CALL noir.sp_open_case(1,'Theft','x',NULL,1,1,NULL,NULL)` | OK | OK | PASS |
| `detective_app` | `SELECT * FROM noir.v_stale_cases` | OK | OK | PASS |
| `detective_app` | `CALL noir.sp_register_payment('INV-2025-0006','Cash',10,CURRENT_DATE,NULL)` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM noir.v_case_financials` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM noir.v_client_balance` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM noir.alert` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM noir.job_run_log` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM noir.document_counter` | DENIED | DENIED | PASS |
| `detective_app` | `CALL noir.sp_nightly_maintenance()` | DENIED | DENIED | PASS |
| `accountant_app` | `CALL noir.sp_register_payment('INV-2025-0006','Cash',10,CURRENT_DATE,NULL)` | OK | OK | PASS |
| `accountant_app` | `SELECT * FROM noir.v_case_financials` | OK | OK | PASS |
| `accountant_app` | `SELECT * FROM noir.v_client_balance` | OK | OK | PASS |
| `accountant_app` | `SELECT * FROM noir.monthly_case_stats` | OK | OK | PASS |
| `accountant_app` | `CALL noir.sp_open_case(1,'Theft','x',NULL,1,1,NULL,NULL)` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.fn_case_timeline(3)` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.alert` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.v_stale_cases` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.case_status_history` | DENIED | DENIED | PASS |
| `accountant_app` | `CALL noir.sp_nightly_maintenance()` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.document_counter` | DENIED | DENIED | PASS |
| `client_portal` | `CALL noir.sp_open_case(1,'Theft','x',NULL,1,1,NULL,NULL)` | DENIED | DENIED | PASS |
| `client_portal` | `CALL noir.sp_register_payment('INV-2025-0006','Cash',10,CURRENT_DATE,NULL)` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.fn_case_timeline(3)` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.v_client_balance` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.monthly_case_stats` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.document_counter` | DENIED | DENIED | PASS |
| `accountant_app` | `INSERT INTO noir.payment (invoice_id,method_id,paid_on,amount) VALUES (1,2,CURRENT_DATE,1)` | ERROR | ERROR | PASS |
<!-- /TESTY -->

## 3. Automatyzacja: zadanie nocne (pg_cron)

Zadanie `noir_nightly_maintenance` wykonuje codziennie o 02:00 (czas serwera, UTC) procedurę `sp_nightly_maintenance`. Procedura przetwarza dane w jednej transakcji w czterech krokach i zapisuje wynik w `job_run_log`:

1. **Faktury po terminie.** Dla każdej faktury z dodatnim saldem po terminie płatności otwiera alert `OVERDUE_INVOICE` (jeden otwarty alert na fakturę); alerty faktur rozliczonych zamyka.
2. **Sprawy bez aktywności.** Dla spraw aktywnych (`Open`, `In progress`) wyznacza datę ostatniego zdarzenia (otwarcie, dowód, wskazówka, zeznanie, zmiana statusu) i otwiera alert `STALE_CASE`, gdy upłynęło więcej niż 60 dni; alerty spraw zamkniętych zamyka.
3. **Statystyki miesięczne.** Dla każdego miesiąca od otwarcia pierwszej sprawy do bieżącego i każdego typu sprawy liczy otwarte i zamknięte sprawy oraz zafakturowane i wpłacone kwoty, zapisując je w `monthly_case_stats` (wstaw lub zaktualizuj).
4. **Retencja.** Usuwa wpisy `operation_log` starsze niż 90 dni.

Błąd w dowolnym kroku wycofuje zmiany transakcji, a przebieg zostaje zapisany ze statusem `ERROR` i treścią błędu. Procedura jest idempotentna: powtórne uruchomienie nie tworzy duplikatów alertów. Rejestracja zadania w `pg_cron` (rozszerzenie działa w bazie `postgres`, zadanie wykonuje się w bazie `noir`):

```sql
SELECT cron.schedule_in_database('noir_nightly_maintenance', '0 2 * * *',
                                 'CALL noir.sp_nightly_maintenance()', 'noir');
```

Definicja procedury:

<!-- KOD sql/pg/10_job_procedure.sql -->
```sql
SET search_path = noir;

-- Nightly job: several steps in one transaction, result in job_run_log.
--  1. alerts for overdue invoices (opened) and for settled invoices (closed),
--  2. alerts for cases with no activity for p_stale_days days (opened) and for cases active again (closed),
--  3. monthly statistics snapshot (every month since the first case) split by case type (upsert),
--  4. retention: delete operation_log entries older than p_retention_days.
CREATE PROCEDURE sp_nightly_maintenance(p_stale_days INTEGER DEFAULT 60, p_retention_days INTEGER DEFAULT 90)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = noir AS $$
DECLARE
    v_run INTEGER; v_started TIMESTAMP := CURRENT_TIMESTAMP;
    v_overdue_new INTEGER; v_overdue_closed INTEGER; v_stale_new INTEGER; v_stale_closed INTEGER;
    v_stats INTEGER; v_purged INTEGER;
BEGIN
    INSERT INTO job_run_log (job_name, started_at, status) VALUES ('nightly_maintenance', v_started, 'RUNNING')
    RETURNING run_id INTO v_run;
    BEGIN
        -- 1. overdue invoices: balance = invoice amount minus payments
        WITH balance AS (
            SELECT i.invoice_id, i.amount - COALESCE(SUM(p.amount), 0) AS due
            FROM invoice i LEFT JOIN payment p ON p.invoice_id = i.invoice_id
            GROUP BY i.invoice_id
        )
        INSERT INTO alert (alert_type, case_id, invoice_id, raised_on, message)
        SELECT 'OVERDUE_INVOICE', i.case_id, i.invoice_id, CURRENT_DATE,
               'Invoice ' || i.invoice_number || ' overdue by ' || (CURRENT_DATE - i.due_on) || ' days, balance ' || b.due
        FROM invoice i JOIN balance b ON b.invoice_id = i.invoice_id
        WHERE i.due_on < CURRENT_DATE AND b.due > 0
          AND NOT EXISTS (SELECT 1 FROM alert a WHERE a.invoice_id = i.invoice_id AND a.resolved_on IS NULL);
        GET DIAGNOSTICS v_overdue_new = ROW_COUNT;
        UPDATE alert a SET resolved_on = CURRENT_DATE
        FROM (SELECT i.invoice_id, i.amount - COALESCE(SUM(p.amount), 0) AS due
              FROM invoice i LEFT JOIN payment p ON p.invoice_id = i.invoice_id
              GROUP BY i.invoice_id) b
        WHERE a.invoice_id = b.invoice_id AND a.alert_type = 'OVERDUE_INVOICE' AND a.resolved_on IS NULL AND b.due <= 0;
        GET DIAGNOSTICS v_overdue_closed = ROW_COUNT;

        -- 2. active cases with no events (evidence, tip, statement, status change) for p_stale_days days
        WITH last_activity AS (
            SELECT c.case_id, c.case_number,
                   GREATEST(c.opened_on::TIMESTAMP,
                            (SELECT MAX(found_at)    FROM evidence e WHERE e.case_id = c.case_id),
                            (SELECT MAX(received_at) FROM tip t      WHERE t.case_id = c.case_id),
                            (SELECT MAX(statement_date)::TIMESTAMP FROM case_witness w WHERE w.case_id = c.case_id),
                            (SELECT MAX(changed_at)  FROM case_status_history h WHERE h.case_id = c.case_id)
                   ) AS last_at
            FROM case_file c JOIN case_status s ON s.status_id = c.status_id
            WHERE s.name IN ('Open', 'In progress')
        )
        INSERT INTO alert (alert_type, case_id, raised_on, message)
        SELECT 'STALE_CASE', la.case_id, CURRENT_DATE,
               'Case ' || la.case_number || ' inactive for ' || (CURRENT_DATE - la.last_at::DATE) || ' days'
        FROM last_activity la
        WHERE la.last_at < CURRENT_TIMESTAMP - p_stale_days * INTERVAL '1 day'
          AND NOT EXISTS (SELECT 1 FROM alert a WHERE a.case_id = la.case_id AND a.alert_type = 'STALE_CASE' AND a.resolved_on IS NULL);
        GET DIAGNOSTICS v_stale_new = ROW_COUNT;
        UPDATE alert a SET resolved_on = CURRENT_DATE
        FROM case_file c
        WHERE a.case_id = c.case_id AND a.alert_type = 'STALE_CASE' AND a.resolved_on IS NULL
          AND EXISTS (SELECT 1 FROM case_status s WHERE s.status_id = c.status_id AND s.name LIKE 'Closed%');
        GET DIAGNOSTICS v_stale_closed = ROW_COUNT;

        -- 3. monthly statistics snapshot: every month from the first case opening to the current one
        INSERT INTO monthly_case_stats (period_start, type_id, opened_cnt, closed_cnt, invoiced, paid)
        SELECT m.period_start, t.type_id,
               (SELECT COUNT(*) FROM case_file c WHERE c.type_id = t.type_id AND DATE_TRUNC('month', c.opened_on) = m.period_start),
               (SELECT COUNT(*) FROM case_file c WHERE c.type_id = t.type_id AND DATE_TRUNC('month', c.closed_on) = m.period_start),
               COALESCE((SELECT SUM(i.amount) FROM invoice i JOIN case_file c ON c.case_id = i.case_id
                         WHERE c.type_id = t.type_id AND DATE_TRUNC('month', i.issued_on) = m.period_start), 0),
               COALESCE((SELECT SUM(p.amount) FROM payment p JOIN invoice i ON i.invoice_id = p.invoice_id
                         JOIN case_file c ON c.case_id = i.case_id
                         WHERE c.type_id = t.type_id AND DATE_TRUNC('month', p.paid_on) = m.period_start), 0)
        FROM (SELECT GENERATE_SERIES(DATE_TRUNC('month', (SELECT MIN(opened_on) FROM case_file)),
                                     DATE_TRUNC('month', CURRENT_DATE), INTERVAL '1 month')::DATE AS period_start) m
        CROSS JOIN case_type t
        ON CONFLICT (period_start, type_id) DO UPDATE
           SET opened_cnt = EXCLUDED.opened_cnt, closed_cnt = EXCLUDED.closed_cnt,
               invoiced = EXCLUDED.invoiced, paid = EXCLUDED.paid, refreshed_at = CURRENT_TIMESTAMP;
        GET DIAGNOSTICS v_stats = ROW_COUNT;

        -- 4. operation log retention
        DELETE FROM operation_log WHERE logged_at < CURRENT_TIMESTAMP - p_retention_days * INTERVAL '1 day';
        GET DIAGNOSTICS v_purged = ROW_COUNT;

        UPDATE job_run_log SET finished_at = CURRENT_TIMESTAMP, status = 'OK',
               details = 'overdue invoices: +' || v_overdue_new || '/-' || v_overdue_closed ||
                         '; inactive cases: +' || v_stale_new || '/-' || v_stale_closed ||
                         '; statistics: ' || v_stats || ' rows; purged from log: ' || v_purged
        WHERE run_id = v_run;
    EXCEPTION WHEN OTHERS THEN
        -- step failed: all changes of the block are rolled back, the run entry is kept
        UPDATE job_run_log SET finished_at = CURRENT_TIMESTAMP, status = 'ERROR', details = LEFT(SQLERRM, 500) WHERE run_id = v_run;
    END;
END $$;
```
<!-- /KOD -->

**Test procedury** (uruchomienie ręczne, powtórne uruchomienie oraz uruchomienie po zmianach danych):

<!-- KOD sql/manual/23_job_demo.sql od="=== before the job ===" do="=== monthly snapshot" -->
```sql
\echo '=== before the job ==='
SELECT (SELECT COUNT(*) FROM alert) AS alerts, (SELECT COUNT(*) FROM monthly_case_stats) AS stats_rows, (SELECT COUNT(*) FROM job_run_log) AS runs;
\echo '=== first run ==='
CALL sp_nightly_maintenance();
SELECT run_id, job_name, status, details FROM job_run_log ORDER BY run_id;
SELECT alert_type, COUNT(*) AS cnt, COUNT(*) FILTER (WHERE resolved_on IS NULL) AS open_cnt FROM alert GROUP BY alert_type ORDER BY 1;
SELECT alert_type, case_id, message FROM alert WHERE resolved_on IS NULL ORDER BY alert_type, case_id;
\echo '=== a repeated run is idempotent (no new alerts) ==='
CALL sp_nightly_maintenance();
SELECT run_id, status, details FROM job_run_log ORDER BY run_id;
\echo '=== payment (sp_register_payment) and case closure - the next run closes the matching alerts ==='
CALL sp_register_payment('INV-2025-0006', 'Cash', 500, CURRENT_DATE, NULL);
UPDATE case_file SET status_id = (SELECT status_id FROM case_status WHERE name = 'Closed - unsolved') WHERE case_number = 'NOIR-2025-002';
CALL sp_nightly_maintenance();
SELECT run_id, status, details FROM job_run_log ORDER BY run_id;
SELECT alert_type, case_id, message, resolved_on FROM alert ORDER BY alert_id;
```
<!-- /KOD -->

<!-- WYNIK results/pg_23_job_demo.txt od="=== before the job ===" do="=== monthly snapshot" -->
```text
=== before the job ===
 alerts | stats_rows | runs
--------+------------+------
      0 |          0 |    0

=== first run ===
CALL
 run_id |      job_name       | status |                                         details
--------+---------------------+--------+------------------------------------------------------------------------------------------
      1 | nightly_maintenance | OK     | overdue invoices: +2/-0; inactive cases: +3/-0; statistics: 132 rows; purged from log: 0

   alert_type    | cnt | open_cnt
-----------------+-----+----------
 OVERDUE_INVOICE |   2 |        2
 STALE_CASE      |   3 |        3

   alert_type    | case_id |                          message
-----------------+---------+------------------------------------------------------------
 OVERDUE_INVOICE |       4 | Invoice INV-2025-0005 overdue by 412 days, balance 1000.00
 OVERDUE_INVOICE |       6 | Invoice INV-2025-0006 overdue by 351 days, balance 500.00
 STALE_CASE      |       2 | Case NOIR-2025-002 inactive for 608 days
 STALE_CASE      |       4 | Case NOIR-2025-004 inactive for 464 days
 STALE_CASE      |       6 | Case NOIR-2025-006 inactive for 387 days

=== a repeated run is idempotent (no new alerts) ===
CALL
 run_id | status |                                         details
--------+--------+------------------------------------------------------------------------------------------
      1 | OK     | overdue invoices: +2/-0; inactive cases: +3/-0; statistics: 132 rows; purged from log: 0
      2 | OK     | overdue invoices: +0/-0; inactive cases: +0/-0; statistics: 132 rows; purged from log: 0

=== payment (sp_register_payment) and case closure - the next run closes the matching alerts ===
 p_payment_id
--------------
           15

UPDATE 1
CALL
 run_id | status |                                         details
--------+--------+------------------------------------------------------------------------------------------
      1 | OK     | overdue invoices: +2/-0; inactive cases: +3/-0; statistics: 132 rows; purged from log: 0
      2 | OK     | overdue invoices: +0/-0; inactive cases: +0/-0; statistics: 132 rows; purged from log: 0
      3 | OK     | overdue invoices: +0/-1; inactive cases: +0/-1; statistics: 132 rows; purged from log: 0

   alert_type    | case_id |                          message                           | resolved_on
-----------------+---------+------------------------------------------------------------+-------------
 OVERDUE_INVOICE |       4 | Invoice INV-2025-0005 overdue by 412 days, balance 1000.00 |
 OVERDUE_INVOICE |       6 | Invoice INV-2025-0006 overdue by 351 days, balance 500.00  | 2026-10-17
 STALE_CASE      |       6 | Case NOIR-2025-006 inactive for 387 days                   |
 STALE_CASE      |       2 | Case NOIR-2025-002 inactive for 608 days                   | 2026-10-17
 STALE_CASE      |       4 | Case NOIR-2025-004 inactive for 464 days                   |
```
<!-- /WYNIK -->

Pierwszy przebieg otworzył 2 alerty o fakturach po terminie i 3 o sprawach bez aktywności oraz zapisał 132 wiersze statystyk (22 miesiące × 6 typów spraw). Drugi przebieg nie dodał niczego. Po wpłacie na fakturę 6 (`sp_register_payment`, reszta salda 500.00) i zamknięciu sprawy 2 trzeci przebieg zamknął po jednym alercie każdego rodzaju (`-1`). Fragment migawki miesięcznej:

<!-- KOD sql/manual/23_job_demo.sql od="=== monthly snapshot" -->
```sql
\echo '=== monthly snapshot (selected months) ==='
SELECT to_char(m.period_start, 'YYYY-MM') AS month, t.name AS case_type, m.opened_cnt, m.closed_cnt, m.invoiced, m.paid
FROM monthly_case_stats m JOIN case_type t USING (type_id)
WHERE m.opened_cnt > 0 OR m.closed_cnt > 0 OR m.invoiced > 0 OR m.paid > 0
ORDER BY m.period_start, t.name;
```
<!-- /KOD -->

<!-- WYNIK results/pg_23_job_demo.txt od="=== monthly snapshot" -->
```text
=== monthly snapshot (selected months) ===
  month  |      case_type      | opened_cnt | closed_cnt | invoiced |  paid
---------+---------------------+------------+------------+----------+---------
 2025-01 | Missing person      |          1 |          0 |     0.00 |    0.00
 2025-02 | Blackmail           |          1 |          0 |     0.00 |    0.00
 2025-03 | Missing person      |          0 |          1 |  2500.00 | 2500.00
 2025-03 | Theft               |          1 |          0 |     0.00 |    0.00
 2025-04 | Theft               |          0 |          0 |  4000.00 |    0.00
 2025-05 | Theft               |          0 |          0 |     0.00 | 4000.00
 2025-06 | Theft               |          0 |          1 |  4200.00 |    0.00
 2025-07 | Fraud               |          1 |          0 |     0.00 |    0.00
 2025-07 | Theft               |          0 |          0 |     0.00 | 2000.00
 2025-08 | Fraud               |          0 |          0 |  2000.00 | 1000.00
 2025-08 | Infidelity          |          1 |          0 |     0.00 |    0.00
 2025-09 | Infidelity          |          0 |          1 |   900.00 |  900.00
 2025-09 | Murder consultation |          1 |          0 |     0.00 |    0.00
 2025-10 | Blackmail           |          1 |          0 |     0.00 |    0.00
 2025-10 | Murder consultation |          0 |          0 |  1500.00 |    0.00
 2026-10 | Fraud               |          1 |          0 |     0.00 |    0.00
 2026-10 | Murder consultation |          0 |          0 |     0.00 | 1500.00
 2026-10 | Theft               |          1 |          0 |     0.00 | 2200.00
```
<!-- /WYNIK -->

**Test harmonogramu.** Harmonogram na czas testu ustawiono na każdą minutę; `pg_cron` uruchomił zadanie samodzielnie (kolumna `status` w `cron.job_run_details`), a procedura dopisała kolejny przebieg w `job_run_log`. Następnie przywrócono harmonogram 02:00:

<!-- KOD sql/manual/24_cron_demo.sh od="P=" -->
```bash
P="psql -U noir_admin -d postgres -At -F | "
echo "--- schedule"; psql -U noir_admin -d postgres -c "SELECT jobid, jobname, schedule, database, command, active FROM cron.job"
psql -U noir_admin -d noir -qAt -c "SELECT 'przebiegow w job_run_log przed: ' || COUNT(*) FROM noir.job_run_log"
echo "--- schedule changed to every minute (for the duration of the test only)"
psql -U noir_admin -d postgres -qAt -c "SELECT cron.alter_job(1, schedule := '* * * * *')"
sleep 70
echo "--- cron.job_run_details"
psql -U noir_admin -d postgres -c "SELECT jobid, status, return_message, start_time::timestamp(0), end_time::timestamp(0) FROM cron.job_run_details ORDER BY runid"
psql -U noir_admin -d postgres -qAt -c "SELECT cron.alter_job(1, schedule := '0 2 * * *')"
echo "--- job_run_log after a run triggered by pg_cron"
psql -U noir_admin -d noir -c "SELECT run_id, job_name, status, details FROM noir.job_run_log ORDER BY run_id"
echo "--- schedule restored"; psql -U noir_admin -d postgres -c "SELECT jobname, schedule FROM cron.job"
```
<!-- /KOD -->

<!-- WYNIK results/pg_24_cron_demo.txt -->
```text
--- schedule
 jobid |         jobname          |  schedule   | database |              command               | active
-------+--------------------------+-------------+----------+------------------------------------+--------
     1 | noir_nightly_maintenance | 0 2 * * *   | noir     | CALL noir.sp_nightly_maintenance() | t
     2 | noir_partner_sync        | */5 * * * * | noir     | CALL noir.sp_sync_partner_agency() | f

przebiegow w job_run_log przed: 3
--- schedule changed to every minute (for the duration of the test only)

--- cron.job_run_details
 jobid |  status   | return_message |     start_time      |      end_time
-------+-----------+----------------+---------------------+---------------------
     1 | succeeded | CALL           | 2026-10-17 15:47:00 | 2026-10-17 15:47:01

--- job_run_log after a run triggered by pg_cron
 run_id |      job_name       | status |                                         details
--------+---------------------+--------+------------------------------------------------------------------------------------------
      1 | nightly_maintenance | OK     | overdue invoices: +2/-0; inactive cases: +3/-0; statistics: 132 rows; purged from log: 0
      2 | nightly_maintenance | OK     | overdue invoices: +0/-0; inactive cases: +0/-0; statistics: 132 rows; purged from log: 0
      3 | nightly_maintenance | OK     | overdue invoices: +0/-1; inactive cases: +0/-1; statistics: 132 rows; purged from log: 0
      4 | nightly_maintenance | OK     | overdue invoices: +0/-0; inactive cases: +0/-0; statistics: 132 rows; purged from log: 0

--- schedule restored
         jobname          |  schedule
--------------------------+-------------
 noir_partner_sync        | */5 * * * *
 noir_nightly_maintenance | 0 2 * * *
```
<!-- /WYNIK -->

## 4. Kopia zapasowa PostgreSQL

Kopia obejmuje dwie metody. Kopia logiczna zapisuje zawartość bazy jako polecenia i dane, które można wczytać do dowolnej wersji PostgreSQL, także tylko dla wybranych tabel. Kopia fizyczna kopiuje pliki całego serwera, więc jest szybsza przy dużych bazach, ale da się ją odtworzyć tylko w tej samej wersji PostgreSQL i tylko w całości.

- **logiczna** (`pg_dump -Fc`): archiwum jednej bazy w formacie własnym, skompresowane. Do niego dołączono dwa pliki tekstowe: sam schemat bazy oraz osobny zrzut ról, o którym jest napisane niżej;
- **fizyczna** (`pg_basebackup`, format zwykły, strumieniowanie WAL), sprawdzona poleceniem `pg_verifybackup` (sumy kontrolne plików i spójność WAL).

Zrzut ról jest potrzebny, bo `pg_dump` zapisuje tylko jedną bazę, a role nie należą do bazy, tylko do całego serwera PostgreSQL. Archiwum nie zawiera więc ani kont użytkowników, ani ich haseł. Gdyby odtworzyć je na nowym serwerze bez dodatkowych kroków, tabele i uprawnienia by się pojawiły, ale ról `detective_app`, `accountant_app` i `client_portal` już nie, więc nikt nie mógłby się zalogować. Role zapisuje polecenie `pg_dumpall --globals-only`. Samo `pg_dumpall` robi zrzut całego serwera, a opcja `--globals-only` ogranicza go do rzeczy wspólnych dla serwera: ról z hasłami i przynależnością do grup oraz przestrzeni tabel. Odtwarzanie przebiega w dwóch krokach: najpierw wczytuje się zrzut ról, potem archiwum bazy.

Poprawność kopii logicznej sprawdzono odtworzeniem do osobnej bazy `noir_restore` i porównaniem zawartości: dla każdej tabeli liczba wierszy i skrót md5 posortowanych wierszy w oryginale i kopii. Następnie wykonano test awarii: usunięto faktury i wpłaty, po czym odtworzono te tabele z archiwum i ponownie porównano zawartość z kopią.

Skrypt odcisku zawartości tabel, uruchamiany na bazie `noir` i na odtworzonej `noir_restore`:

<!-- KOD sql/manual/30_checksums_pg.sql -->
```sql
-- Content fingerprint of every table in the noir schema: row count and md5 of the sorted rows.
-- Output: table_name|row_count|content_md5

-- Fingerprint of one table. The function is temporary (pg_temp): it lives only in this session
-- and leaves nothing in the database. The table name is only known at run time, so the query is
-- built as text and run with EXECUTE.
CREATE FUNCTION pg_temp.table_fingerprint(p_table TEXT, OUT row_count BIGINT, OUT content_md5 TEXT)
LANGUAGE plpgsql AS $$
BEGIN
  -- The query built below, step by step:
  --   t::text                      - the whole row as one text value, e.g. (1,Kowalski,2026-01-05)
  --   string_agg(..., '|' ORDER BY)- all rows sorted and joined with '|', so the physical row order
  --                                  (different after a restore) does not change the result
  --   COALESCE(..., '')            - an empty table gives '' instead of NULL, so md5 still returns a value
  --   md5(...)                     - a single short hash of the whole table content
  --   count(*)                     - the number of rows, returned next to the hash
  -- %I quotes the table name as an identifier; INTO puts the two result columns into the OUT parameters.
  EXECUTE format(
    'SELECT count(*),
            md5(COALESCE(string_agg(t::text, ''|'' ORDER BY t::text), ''''))
       FROM noir.%I t', p_table)
  INTO row_count, content_md5;
END $$;

-- For every base table of the noir schema (views are skipped) call the function once
-- and print the table name together with its row count and hash.
-- LATERAL lets the call use the table name from the current row of information_schema.tables.
SELECT t.table_name, f.row_count, f.content_md5
FROM information_schema.tables t
CROSS JOIN LATERAL pg_temp.table_fingerprint(t.table_name) f
WHERE t.table_schema = 'noir' AND t.table_type = 'BASE TABLE'
ORDER BY t.table_name;
```
<!-- /KOD -->

Porównanie: odcisk wykonywany na obu bazach, a następnie zestawienie tabela po tabeli (liczba wierszy i md5 w oryginale oraz w kopii), gdzie `ODCISK` oznacza powyższy skrypt:

```bash
psql -U noir_admin -d noir         -qAt -f "$ODCISK" > fp_o.txt
psql -U noir_admin -d noir_restore -qAt -f "$ODCISK" > fp_r.txt
join -t'|' -j1 <(sort -t'|' -k1,1 fp_o.txt) <(sort -t'|' -k1,1 fp_r.txt) |
  awk -F'|' '{ ok = ($2==$4 && $3==$5) ? "YES" : "NO";
               printf "%-22s %-10s %-34s %-34s %s\n", $1, $2"/"$4, $3, $5, ok }'
diff -q fp_o.txt fp_r.txt && echo "RESULT: content identical in all tables"
```

Wynik uruchomienia:

<!-- KOD scripts/backup_pg.sh od="X=" -->
```bash
X="docker compose exec -T pg"
PSQL="$X psql -U noir_admin -qAt"

echo "== 1. Logical backup (pg_dump, custom format, compression) =="
$X pg_dump -U noir_admin -d noir -Fc -f /backup/noir.dump
$X pg_dump -U noir_admin -d noir --schema-only -f /backup/noir_schema.ddl
$X pg_dumpall -U noir_admin --globals-only -f /backup/globals.ddl      # role i hasla
$X ls -l /backup/noir.dump
echo "-- archive table of contents (first lines)"
$X pg_restore --list /backup/noir.dump | head -12

echo "== 2. Physical backup (pg_basebackup) and its verification (pg_verifybackup) =="
$X rm -rf /backup/base
$X pg_basebackup -U noir_admin -D /backup/base -Fp -X stream -c fast
$X pg_verifybackup /backup/base

echo "== 3. Restore of the logical backup into a separate database noir_restore =="
$PSQL -d postgres -c "DROP DATABASE IF EXISTS noir_restore"
$PSQL -d postgres -c "CREATE DATABASE noir_restore"
$X pg_restore -U noir_admin -d noir_restore --exit-on-error /backup/noir.dump
$PSQL -d noir_restore -c "SELECT 'tabel w noir_restore: ' || count(*) FROM information_schema.tables WHERE table_schema='noir' AND table_type='BASE TABLE'"

echo "== 4. Content comparison: row count and md5 of every table (original vs backup) =="
$X psql -U noir_admin -d noir -qAt -f "$ODCISK" > /tmp/fp_o.txt
$X psql -U noir_admin -d noir_restore -qAt -f "$ODCISK" > /tmp/fp_r.txt
printf '%-22s %-10s %-34s %-34s %s\n' table rows "md5 noir" "md5 noir_restore" match
join -t'|' -j1 <(sort -t'|' -k1,1 /tmp/fp_o.txt) <(sort -t'|' -k1,1 /tmp/fp_r.txt) | awk -F'|' '{ ok = ($2==$4 && $3==$5) ? "YES" : "NO"; printf "%-22s %-10s %-34s %-34s %s\n", $1, $2"/"$4, $3, $5, ok }'
if diff -q /tmp/fp_o.txt /tmp/fp_r.txt >/dev/null; then echo "RESULT: content identical in all tables"; else echo "RESULT: DIFFERENCES"; diff /tmp/fp_o.txt /tmp/fp_r.txt; fi

echo "== 5. Failure test: deleting data in noir and restoring from the backup =="
$PSQL -d noir -c "SELECT 'invoices before failure: ' || count(*) FROM noir.invoice"
$X psql -U noir_admin -d noir -qAt -c "TRUNCATE noir.payment, noir.invoice CASCADE" >/dev/null
$PSQL -d noir -c "SELECT 'invoices after failure: ' || count(*) FROM noir.invoice"
$X pg_restore -U noir_admin -d noir --data-only --disable-triggers -t invoice -t payment -t alert /backup/noir.dump
$PSQL -d noir -c "SELECT 'invoices after restore: ' || count(*) || ', payments: ' || (SELECT count(*) FROM noir.payment) FROM noir.invoice"
$X psql -U noir_admin -d noir -qAt -f "$ODCISK" > /tmp/fp_o2.txt
diff -q /tmp/fp_o2.txt /tmp/fp_r.txt >/dev/null && echo "RESULT: after the restore the content matches the backup" || diff /tmp/fp_o2.txt /tmp/fp_r.txt
```
<!-- /KOD -->

<!-- WYNIK results/pg_backup_output.txt -->
```text
== 1. Logical backup (pg_dump, custom format, compression) ==
-rw-r--r-- 1 root root 111634 Oct 17 15:47 /backup/noir.dump
-- archive table of contents (first lines)
;
; Archive created at 2026-10-17 15:47:50 UTC
;     dbname: noir
;     TOC Entries: 265
;     Compression: gzip
;     Dump Version: 1.16-0
;     Format: CUSTOM
;     Integer: 4 bytes
;     Offset: 8 bytes
;     Dumped from database version: 17.11 (Debian 17.11-1.pgdg13+2)
;     Dumped by pg_dump version: 17.11 (Debian 17.11-1.pgdg13+2)
;
== 2. Physical backup (pg_basebackup) and its verification (pg_verifybackup) ==
backup successfully verified
== 3. Restore of the logical backup into a separate database noir_restore ==
NOTICE:  database "noir_restore" does not exist, skipping
tabel w noir_restore: 27
== 4. Content comparison: row count and md5 of every table (original vs backup) ==
table                  rows       md5 noir                           md5 noir_restore                   match
alert                  5/5        47d6dcaf0510296ec39c5325ea2a2469   47d6dcaf0510296ec39c5325ea2a2469   YES
case_detective         14/14      ee088be1706bda4c61ae1feb1f6dc961   ee088be1706bda4c61ae1feb1f6dc961   YES
case_file              9/9        8465daff4fdf4d1e2b6f79ecbe68e779   8465daff4fdf4d1e2b6f79ecbe68e779   YES
case_status            5/5        0050a05e28bc92cac624fe2caa9dbc03   0050a05e28bc92cac624fe2caa9dbc03   YES
case_status_history    15/15      9f0e9bd6e38d803d1cd2fdb6cf092fda   9f0e9bd6e38d803d1cd2fdb6cf092fda   YES
case_suspect           11/11      a5cc2291c427f769c44822a42a23b431   a5cc2291c427f769c44822a42a23b431   YES
case_type              6/6        6c81c781723ffa1176bd6e024b4bb7a9   6c81c781723ffa1176bd6e024b4bb7a9   YES
case_witness           7/7        fbed276f990527c41b37b9783feb4903   fbed276f990527c41b37b9783feb4903   YES
client                 6/6        cf824ea5483515a40836e9ec8a0c6fbc   cf824ea5483515a40836e9ec8a0c6fbc   YES
detective              6/6        31da0402fecf4e2891551bdccb3d0ed9   31da0402fecf4e2891551bdccb3d0ed9   YES
detective_rank         4/4        56d699baa13c54ba627c390d119e7bc7   56d699baa13c54ba627c390d119e7bc7   YES
document_counter       4/4        8204862d92f3786b6a57da0e5e10c8a1   8204862d92f3786b6a57da0e5e10c8a1   YES
evidence               9/9        31ee13f99ecdc85df2111aaf5350cda2   31ee13f99ecdc85df2111aaf5350cda2   YES
evidence_custody       9/9        981e618b733e7fab26f5aea14e3fbca2   981e618b733e7fab26f5aea14e3fbca2   YES
evidence_type          6/6        8de659a0065e0e9acb64f3a52a59512a   8de659a0065e0e9acb64f3a52a59512a   YES
informant              4/4        63cc3e636f07fe0c5f9c64b3f213b202   63cc3e636f07fe0c5f9c64b3f213b202   YES
invoice                6/6        fbf8fe272f19baad07b4a321b1058e30   fbf8fe272f19baad07b4a321b1058e30   YES
job_run_log            4/4        e77752dc9962cf63fb6f53a6e8faea6e   e77752dc9962cf63fb6f53a6e8faea6e   YES
location               6/6        38c5a5c98a692ad012ca66e78c1be3d9   38c5a5c98a692ad012ca66e78c1be3d9   YES
monthly_case_stats     132/132    91e8df71e5993c9d0e508db0ae185cc1   91e8df71e5993c9d0e508db0ae185cc1   YES
operation_log          5/5        c60f9b07c074e9dd17e45a5b3b36fc81   c60f9b07c074e9dd17e45a5b3b36fc81   YES
partner_agency         0/0        d41d8cd98f00b204e9800998ecf8427e   d41d8cd98f00b204e9800998ecf8427e   YES
payment                8/8        3a05a944354c57d2882f4da3d87e9c7b   3a05a944354c57d2882f4da3d87e9c7b   YES
payment_method         4/4        5327bd4bbe68783f3eb73153f15b84dc   5327bd4bbe68783f3eb73153f15b84dc   YES
suspect                6/6        7f21d4293a3bf382a412bd6512f9c358   7f21d4293a3bf382a412bd6512f9c358   YES
tip                    5/5        94109a638c0d4fa4b6a7ba007c632a02   94109a638c0d4fa4b6a7ba007c632a02   YES
witness                5/5        3d2a8f67670751c150c024a7afcaa8a3   3d2a8f67670751c150c024a7afcaa8a3   YES
RESULT: content identical in all tables
== 5. Failure test: deleting data in noir and restoring from the backup ==
invoices before failure: 6
NOTICE:  truncate cascades to table "alert"
invoices after failure: 0
invoices after restore: 6, payments: 8
RESULT: after the restore the content matches the backup
```
<!-- /WYNIK -->

## 5. Drugi SZBD: Microsoft SQL Server 2022

### 5.1 Wybór

Spośród dozwolonych systemów (PostgreSQL jest już używany, MySQL odradzany w treści zadania) wybrano **Microsoft SQL Server 2022**. Uzasadnienie:

- ma własny, bogaty dialekt (T-SQL) z innym modelem transakcji, wyzwalaczy i obsługi błędów, więc migracja jest rzeczywistym sprawdzianem przenośności projektu;
- dostępny w obrazie Docker (edycja Developer jest darmowa i ma pełną funkcjonalność) i działa na Linuksie wraz z SQL Server Agent, więc zadania automatyczne i kopie zapasowe da się wykonać w tym samym środowisku;
- Oracle wymaga znacznie cięższego środowiska, a przenosiny na MySQL odradzono.

### 5.2 Konfiguracja

Usługa `mssql` (patrz konfiguracja w sekcji 1.1): `ACCEPT_EULA=Y`, `MSSQL_PID=Developer`, `MSSQL_AGENT_ENABLED=true`, hasło administratora systemu zgodne z polityką złożoności haseł (wymagane przez SQL Server). Wolumen kopii zapasowych musi być zapisywalny dla użytkownika `mssql` kontenera. Baza `noir` utworzona jest z sortowaniem (ang. collation) `Latin1_General_100_CI_AS_SC_UTF8`: kolumny `VARCHAR` przechowują UTF-8, tak jak w PostgreSQL, a porównania nie rozróżniają wielkości liter (zwykłe ustawienie SQL Server). Właścicielem schematu `noir` jest login `noir_admin` (rola `db_owner`), a trzy role aplikacyjne mają loginy i użytkowników z domyślnym schematem `noir`. Konfigurację potwierdza zapytanie:

```sql
SELECT name, compatibility_level, collation_name FROM sys.databases WHERE name = 'noir';
-- noir | 160 | Latin1_General_100_CI_AS_SC_UTF8
```

## 6. Analiza różnic dialektów i ich wpływ na bazę

Analizę przeprowadzono przed migracją danych; uwzględnia dokumentację obu systemów, a wybrane punkty zweryfikowano uruchomieniem na obu systemach (wyniki w sekcji 6.5).

### 6.1 Schemat i typy danych

| Obszar | PostgreSQL | SQL Server (T-SQL) | Konsekwencja i poprawka |
|--------------|--------------------------|--------------------------|--------------------------------------------------|
| Klucz zastępczy | `GENERATED ALWAYS AS IDENTITY` | `IDENTITY(1,1)` | zmiana składni; wstawienie jawnych kluczy podczas migracji wymaga `SET IDENTITY_INSERT ON` lub opcji `KEEPIDENTITY` |
| Wartość logiczna | `BOOLEAN`, `TRUE`/`FALSE`, warunek `WHERE is_active` | `BIT` (0/1), warunek `WHERE is_active = 1`; wyrażenie logiczne nie jest wartością (nie ma go w `SELECT`) | kolumna `detective.is_active`: typ, domyślna wartość `1`, widoki i migracja danych (`t`/`f` na `0`/`1`) |
| Czas | `TIMESTAMP` (6 cyfr ułamka) | `TIMESTAMP` oznacza `ROWVERSION` (licznik wersji wiersza, nie czas); czas to `DATETIME2(p)` | wszystkie kolumny czasu: `DATETIME2(6)` |
| Daty bieżące | `CURRENT_DATE`, `CURRENT_TIMESTAMP` | `CAST(SYSDATETIME() AS DATE)`; `CURRENT_TIMESTAMP` ma dokładność 3 ms | wartości domyślne kolumn, widoki, procedury |
| Teksty | `VARCHAR(n)`, UTF-8 w bazie | `VARCHAR(n)` z sortowaniem `_UTF8` (od 2019), w sortowaniu bez `_UTF8` znaki zależą od strony kodowej sortowania (np. 1252 dla `Latin1_General`, 1250 dla `Polish`) i nie wszystkie polskie litery się w niej mieszczą; alternatywą jest `NVARCHAR` (UTF-16) | sortowanie bazy UTF-8, brak zmian w typach |
| Wielkość liter | porównania rozróżniają wielkość liter | domyślne sortowanie nie rozróżnia wielkości liter | `UNIQUE(email)` w SQL Server traktuje `A@x` i `a@x` jako ten sam adres; kolejność wyników `ORDER BY` zależy od sortowania |
| `UNIQUE` i `NULL` | dowolna liczba wartości `NULL` w kolumnie `UNIQUE` | tylko jeden `NULL` | schemat ma `UNIQUE` wyłącznie na kolumnach `NOT NULL`, więc bez wpływu |
| Indeks częściowy | `CREATE UNIQUE INDEX ... WHERE role = 'LEAD'`, dozwolone wyrażenia w indeksie | indeks filtrowany (ta sama składnia), bez wyrażeń; wymaga `SET QUOTED_IDENTIFIER ON` w sesjach zapisujących do tabeli | `COALESCE(invoice_id, 0)` w indeksie tabeli `alert` zastąpiono dwoma indeksami filtrowanymi; klienci łączą się z `QUOTED_IDENTIFIER ON` |
| Schemat i ścieżka | schemat `noir`, `search_path` | schemat `noir`, domyślny schemat użytkownika (`DEFAULT_SCHEMA`) | obiekty tworzone przez użytkownika o domyślnym schemacie `noir` albo z nazwą kwalifikowaną |
| Ograniczenia | `PRIMARY KEY`, `UNIQUE`, `FOREIGN KEY`, `CHECK` nazwane | identyczna składnia i semantyka | bez zmian; klucze obce nie są indeksowane automatycznie w żadnym z systemów, więc indeksy pozostają |

### 6.2 Zapytania, funkcje i widoki

| Obszar | PostgreSQL | SQL Server (T-SQL) | Konsekwencja i poprawka |
|--------------|--------------------------|--------------------------|--------------------------------------------------|
| Łączenie tekstów | `a \|\| b`, `'x' \|\| 5` działa | `a + b`; `'x' + 5` zgłasza błąd konwersji, `CONCAT` działa | `+` z jawnym `CAST` albo `CONCAT` |
| Arytmetyka dat | `data - data` (liczba dni), `data + liczba` | `DATEDIFF`, `DATEADD` | zamiana na `DATEDIFF` i `DATEADD` w widokach i w procedurze zadania nocnego |
| Części daty | `EXTRACT(YEAR FROM d)`, `DATE_TRUNC('month', d)` | `YEAR(d)`, `DATEFROMPARTS(YEAR(d), MONTH(d), 1)` | początek miesiąca liczony przez `DATEFROMPARTS` w procedurze statystyk miesięcznych |
| Ciągi liczb | `generate_series` | rekurencyjne CTE (domyślny limit 100 poziomów) | lista miesięcy w procedurze statystyk miesięcznych budowana rekurencyjnym CTE |
| Formatowanie numerów | `LPAD`, `SUBSTRING(t FROM n)` | `RIGHT('000' + ..., 3)`, `SUBSTRING(t, n, długość)` | numer sprawy składany w procedurze `sp_open_case` przez `RIGHT` i `SUBSTRING` |
| Rzutowanie | `x::INTEGER` | `CAST`, `CONVERT` | każde `::` zastąpione przez `CAST` |
| Maksimum z kilku wartości | `GREATEST` | `GREATEST` dopiero od SQL Server 2022 (poziom zgodności 160) | dostępne w użytej wersji 2022; w starszych trzeba użyć `CASE` lub `VALUES` z `MAX` |
| Agregat z uporządkowaniem | `string_agg(x, ',' ORDER BY x)` | `STRING_AGG(x, ',') WITHIN GROUP (ORDER BY x)`; opakowanie w `COALESCE` zgłasza błąd 8711, działa `ISNULL` | w zapytaniach porównujących zawartość tabel używany jest `ISNULL` |
| Agregaty warunkowe | `COUNT(*) FILTER (WHERE ...)` | `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` | w skryptach testowych zamiana na `SUM(CASE ...)` |
| Funkcja tablicowa | `RETURNS TABLE`, `ORDER BY` w ciele | inline `RETURNS TABLE AS RETURN SELECT`, bez `ORDER BY` | sortowanie przenosi się do wywołującego (`fn_case_timeline`) |
| Przeciążanie, cechy | przeciążanie funkcji, `STABLE`/`IMMUTABLE` | brak przeciążania, brak klasyfikacji zmienności | nazwy funkcji są unikalne, więc przeciążanie nie jest potrzebne |
| Upsert | `INSERT ... ON CONFLICT DO UPDATE` | `MERGE` | zapis statystyk miesięcznych w procedurze zadania nocnego przez `MERGE` |

### 6.3 Procedury, transakcje i wyzwalacze

| Obszar | PostgreSQL | SQL Server (T-SQL) | Poprawka |
|--------------|--------------------------|--------------------------|--------------------------------------------------|
| Składnia | PL/pgSQL, `$$ ... $$`, parametry bez prefiksu | T-SQL, zmienne i parametry z `@`, `BEGIN ... END`, brak cudzysłowu dolarowego | pełne przepisanie elementów programowalnych |
| Wywołanie, parametry wyjściowe | `CALL sp(...)`, `INOUT` | `EXEC sp ..., @x OUTPUT` | wyniki procedur odbierane zmiennymi |
| Błąd własny | `RAISE EXCEPTION 'tekst %', x` | `THROW 50001, @komunikat, 1` (komunikat tylko jako literał lub zmienna) | komunikat budowany `CONCAT` w zmiennej |
| Obsługa błędów | blok `BEGIN ... EXCEPTION WHEN OTHERS` = podtransakcja (savepoint) | `TRY ... CATCH`, jawna transakcja `BEGIN TRAN`/`COMMIT`/`ROLLBACK`, `SET XACT_ABORT ON` | po błędzie w transakcji nie da się kontynuować (`XACT_STATE() = -1`): cała transakcja jest wycofywana, procedury złożone mają być wywoływane poza transakcją zewnętrzną |
| Odczyt nowego klucza | `INSERT ... RETURNING id INTO v` | `SCOPE_IDENTITY()` | `sp_open_case`, `sp_register_payment` i `sp_nightly_maintenance` odczytują nowy klucz przez `SCOPE_IDENTITY()` zamiast `RETURNING` |
| Blokady | `SELECT ... FOR UPDATE`, `UPDATE` licznika | `WITH (UPDLOCK, HOLDLOCK)`, `UPDATE` licznika | numeracja dokumentów blokuje wiersz licznika; procedury numerujące są opakowane w transakcję |
| Uprawnienia procedur | `SECURITY DEFINER` | brak; łańcuch własności: procedura i tabele mają jednego właściciela (`noir_admin`), więc `EXECUTE` wystarcza | wspólny właściciel schematu |
| Wyzwalacze | `BEFORE`/`AFTER`, na wiersz, funkcja wyzwalacza, `NEW`/`OLD`, `TG_OP` | tylko `AFTER` i `INSTEAD OF`, na instrukcję, pseudotabele `inserted`/`deleted`; brak `BEFORE` | walidacje zapytaniami zbiorczymi na `inserted`; wycofanie: `ROLLBACK` + `THROW` |
| Luki w numeracji kluczy | sekwencja nie cofa się po wycofaniu wstawienia | `IDENTITY` nie cofa się po wycofaniu wstawienia | w obu systemach odrzucone wstawienia zużywają numery: po wycofanych wpłatach kolejna poprawna wpłata dostała identyfikator 9, mimo że w tabeli jest 6 wpłat |

### 6.4 Uprawnienia, zadania, kopie zapasowe

| Obszar | PostgreSQL | SQL Server (T-SQL) | Poprawka |
|--------------|--------------------------|--------------------------|--------------------------------------------------|
| Użytkownik | `CREATE ROLE ... LOGIN` | `CREATE LOGIN` (serwer, wymaga uprawnień administratora systemu) + `CREATE USER` (baza) | osobny krok wykonywany przez administratora systemu |
| Nadawanie praw | `GRANT SELECT ON a, b TO r`; `GRANT ... ON ALL TABLES`; `REVOKE` | jeden obiekt na instrukcję `GRANT`; `DENY` jako zakaz; uprawnienia kolumnowe jak w PostgreSQL | każde uprawnienie jawne, bez `ON ALL TABLES` |
| Domyślne `EXECUTE` | `PUBLIC` może wykonywać funkcje | brak domyślnego prawa | `REVOKE ... FROM PUBLIC` zbędne |
| Hasła | dowolne | polityka złożoności | hasła z wielką literą, cyfrą i znakiem specjalnym |
| Zadania | rozszerzenie `pg_cron`, `cron.schedule` | SQL Server Agent: `msdb.dbo.sp_add_job`, `sp_add_jobstep`, `sp_add_schedule`, `sp_attach_schedule` | zadania zdefiniowane od nowa przez procedury z `msdb` (SQL Server Agent to osobny usługowy proces harmonogramu zadań SQL Server); w kontenerze Docker jest domyślnie wyłączony i włącza się go zmienną środowiskową `MSSQL_AGENT_ENABLED=true` |
| Kopie zapasowe | `pg_dump`/`pg_restore`, `pg_basebackup` | `BACKUP DATABASE`/`RESTORE DATABASE`, kopie pełne, różnicowe i dziennika; `RESTORE VERIFYONLY` | nowe procedury kopii; loginy należą do serwera, nie do kopii bazy |
| Klient SQL | `psql` | `sqlcmd` (`-I` włącza `QUOTED_IDENTIFIER`) | skrypty i testy |

### 6.5 Sprawdzenia na obu systemach

Wybrane różnice sprawdzono tymi samymi zapytaniami w obu systemach.

PostgreSQL:

<!-- SPRAWDZENIA sql/manual/40_dialect_checks_pg.sql results/pg_40_dialect_checks.txt -->
```text
--- 1. comparison of strings differing in letter case
SELECT CASE WHEN 'ADA@Example.com' = 'ada@example.com' THEN 'equal' ELSE 'different' END AS result;

  result
-----------
 different

--- 2. UNIQUE and NULL values: two rows with NULL in a UNIQUE column
CREATE TEMP TABLE u (v INTEGER, CONSTRAINT uq_u UNIQUE (v));
INSERT INTO u VALUES (NULL);
INSERT INTO u VALUES (NULL);
SELECT COUNT(*) AS row_count FROM u;

CREATE TABLE
INSERT 0 1
INSERT 0 1
 row_count
-----------
         2

--- 3. typ TIMESTAMP
SELECT pg_typeof(TIMESTAMP '2026-10-09 10:15:30.123456') AS type_name, TIMESTAMP '2026-10-09 10:15:30.123456' AS value;

          type_name          |           value
-----------------------------+----------------------------
 timestamp without time zone | 2026-10-09 10:15:30.123456

--- 4. concatenating text with a number using the operator ||
SELECT 'Count: ' || 5 AS result;

  result
----------
 Count: 5

--- 5. date difference
SELECT DATE '2026-10-09' - DATE '2026-01-01' AS days;

 days
------
  281

--- 6. ordered aggregate inside COALESCE
SELECT COALESCE(string_agg(name, ',' ORDER BY name COLLATE "C"), '') AS names FROM noir.case_type;

                                names
---------------------------------------------------------------------
 Blackmail,Fraud,Infidelity,Missing person,Murder consultation,Theft
```
<!-- /SPRAWDZENIA -->

SQL Server:

<!-- SPRAWDZENIA sql/manual/mssql_40_dialect_checks.sql results/mssql_40_dialect_checks.txt -->
```text
--- 1. comparison of strings differing in letter case
SELECT CASE WHEN 'ADA@Example.com' = 'ada@example.com' THEN 'equal' ELSE 'different' END AS result;

result
------
equal

--- 2. UNIQUE and NULL values: two rows with NULL in a UNIQUE column
CREATE TABLE #u (v INT, CONSTRAINT uq_u UNIQUE (v));
INSERT INTO #u VALUES (NULL);
INSERT INTO #u VALUES (NULL);

Msg 2627, Level 14, State 1, Line 1
Violation of UNIQUE KEY constraint 'uq_u'. Cannot insert duplicate key in object 'dbo.#u'. The duplicate key value is (<NULL>).
The statement has been terminated.

--- 3. typ TIMESTAMP
CREATE TABLE #t (ts TIMESTAMP, label VARCHAR(10) DEFAULT 'x');
INSERT INTO #t DEFAULT VALUES;
SELECT TYPE_NAME(system_type_id) AS type_name, max_length AS bytes FROM tempdb.sys.columns WHERE object_id = OBJECT_ID('tempdb..#t') AND name = 'ts';
SELECT ts AS value FROM #t;

type_name|bytes
---------|-----
timestamp|8
value
-----
0x00000000000008DD

--- 4. concatenating text with a number using the operator +
SELECT 'Count: ' + 5 AS result;
SELECT CONCAT('Count: ', 5) AS result_concat;

Msg 245, Level 16, State 1, Line 1
Conversion failed when converting the varchar value 'Count: ' to data type int.
result_concat
-------------
Count: 5

--- 5. date difference
SELECT DATEDIFF(DAY, '2026-01-01', '2026-10-09') AS days;

days
----
281

--- 6. ordered aggregate inside COALESCE
SELECT COALESCE(STRING_AGG(name, ',') WITHIN GROUP (ORDER BY name COLLATE Latin1_General_100_BIN2_UTF8), '') AS names FROM noir.case_type;
SELECT ISNULL(STRING_AGG(name, ',') WITHIN GROUP (ORDER BY name COLLATE Latin1_General_100_BIN2_UTF8), '') AS names FROM noir.case_type;

Msg 8711, Level 16, State 1, Line 1
Multiple ordered aggregate functions in the same scope have mutually incompatible orderings.
names
-----
Blackmail,Fraud,Infidelity,Missing person,Murder consultation,Theft

--- 7. write to a table with a filtered index in a session with QUOTED_IDENTIFIER OFF
SET QUOTED_IDENTIFIER OFF;
INSERT INTO noir.alert (alert_type, case_id, invoice_id, raised_on, message) VALUES ('STALE_CASE', 1, NULL, '2026-10-09', 'test');
SET QUOTED_IDENTIFIER ON;
INSERT INTO noir.alert (alert_type, case_id, invoice_id, raised_on, message) VALUES ('STALE_CASE', 1, NULL, '2026-10-09', 'test');
SELECT COUNT(*) AS rows_in_alert FROM noir.alert WHERE message = 'test';
DELETE FROM noir.alert WHERE message = 'test';

Msg 1934, Level 16, State 1, Line 2
INSERT failed because the following SET options have incorrect settings: 'QUOTED_IDENTIFIER'. Verify that SET options are correct for use with indexed views and/or indexes on computed columns and/or filtered indexes and/or query notifications and/or XML data type methods and/or spatial index operations.
rows_in_alert
-------------
1
```
<!-- /SPRAWDZENIA -->

Wnioski z analizy: schemat (tabele, typy, klucze, ograniczenia, indeksy) przenosi się z drobnymi zmianami typów i składni; widoki wymagają przepisania funkcji dat i tekstów; elementy programowalne trzeba napisać od nowa, a największe różnice dotyczą wyzwalacza (tylko `AFTER`, na instrukcję), obsługi błędów w transakcjach oraz uprawnień (łańcuch własności zamiast `SECURITY DEFINER`).

## 7. Narzędzia do migracji danych

| Narzędzie | Rodzaj | Czy przeniesie dane z PostgreSQL do SQL Server | Uwagi i ocena |
|----------------|--------------|--------------|--------------------------------------------------|
| **pgloader** | linia poleceń, otwarte | nie, bo ładuje dane wyłącznie do PostgreSQL (źródłem mogą być m.in. MySQL, SQL Server, SQLite, CSV), a SQL Server jako cel nie istnieje | świetne w kierunku do PostgreSQL (przenosi schemat, dane, indeksy) |
| **BULK INSERT / `bcp` + `COPY`** | polecenia SQL Server i PostgreSQL | tak, w dwóch krokach: `COPY` eksportuje tabele z PostgreSQL do plików CSV, a `BULK INSERT` lub `bcp` ładuje je do SQL Server | najszybsze i najprostsze, bez dodatkowego oprogramowania; brak transformacji (konwersje trzeba zrobić w eksporcie), `KEEPIDENTITY` zachowuje klucze |
| **Apache Hop** | graficzne środowisko ETL i uruchamianie bez GUI (`hop-run`), otwarte oprogramowanie | tak, bezpośrednio: łączy się sterownikami JDBC z obiema bazami, a potok `Table input` (odczyt z PostgreSQL) → `Table output` (zapis do SQL Server) kopiuje dane tabela po tabeli | pełny ETL z transformacjami, harmonogramem i obsługą błędów; wymaga konfiguracji sterowników i mapowania typów |
| SQL Server Migration Assistant (SSMA) | aplikacja Microsoft | nie, bo jako źródło przyjmuje tylko Oracle, MySQL, DB2, SAP ASE i Access, a PostgreSQL nie jest na tej liście | wygodne dla wspieranych systemów, dla PostgreSQL jest niedostępne |
| SSIS / Import and Export Wizard | Windows, graficzne | tak, pod warunkiem użycia sterownika PostgreSQL (ODBC lub ADO.NET) jako źródła i SQL Server jako celu | bardzo rozbudowane, ale tylko Windows |
| DBeaver (Data Transfer) | aplikacja graficzna | tak, kopiuje dane między dwoma połączeniami JDBC, sam tworzy tabele w SQL Server i mapuje typy | wygodne do jednorazowych przeniesień, słabo automatyzowalne |
| AWS DMS / Azure Database Migration Service | usługi chmurowe | tak, z PostgreSQL do SQL Server, także jako replikacja ciągła zmian | wymagają chmury i kosztów |
| Debezium + Kafka Connect | strumieniowe (CDC) | tak, pośrednio: konektor Debezium czyta zmiany z PostgreSQL do Kafki, a konektor JDBC Sink zapisuje je w SQL Server | replikacja zmian w czasie rzeczywistym; zbyt ciężkie dla jednorazowej migracji |
| Własny skrypt (np. Python: psycopg + pyodbc) | kod | tak, jeśli sami napiszemy odczyt z PostgreSQL i zapis do SQL Server | pełna kontrola, ale cały kod i testy po stronie autora |

Do migracji użyto dwóch niezależnych metod (BULK INSERT oraz Apache Hop), a poprawność każdej sprawdzono porównaniem zawartości tabel.

## 8. Migracja danych PostgreSQL → SQL Server

Schemat w SQL Server utworzono ze skryptów DDL przepisanych według analizy z sekcji 6. Dane migrowano do pustych tabel przed utworzeniem wyzwalaczy, procedur i widoków, żeby reguły biznesowe nie ingerowały w przenoszone rekordy . Weryfikacja: dla każdej tabeli liczba wierszy i skrót md5 posortowanych wierszy w postaci kanonicznej (kolumny rozdzielone `|`, `NULL` jako `\N`, daty w formacie ISO, wartości logiczne jako 0/1), policzone tym samym algorytmem w obu systemach i sprawdzono ich równość.

### 8.1 Eksport CSV i BULK INSERT

Dane eksportowane są poleceniem `\copy` do plików CSV w UTF-8, a ładowane instrukcją `BULK INSERT` z opcjami `FORMAT = 'CSV'` (cudzysłowy i przecinki w tekstach), `KEEPIDENTITY` (klucze z PostgreSQL), `KEEPNULLS`. Tabele ładowane są w kolejności zgodnej z kluczami obcymi.

Kolumny logiczne są eksportowane jako 0/1 (`CASE WHEN kolumna THEN 1 ELSE 0 END`), bo kolumna `BIT` przyjmuje tylko takie wartości. Eksport wszystkich tabel (skrypt czyta listę tabel w kolejności zgodnej z kluczami obcymi):

<!-- KOD etl/bulk/export.sh -->
```bash
#!/usr/bin/env bash
# Eksport tabel PostgreSQL do plikow CSV (UTF-8) w woluminie wymiany /exchange.
# Kolumny logiczne (BOOLEAN) zamieniane na 0/1, bo SQL Server nie rozpoznaje t/f; reszta bez zmian.
set -euo pipefail
mkdir -p /exchange/csv
while read -r t; do
  cols=$(psql -U noir_admin -d noir -qAt -c "
    SELECT string_agg(CASE WHEN data_type = 'boolean' THEN format('CASE WHEN %I THEN 1 ELSE 0 END AS %I', column_name, column_name)
                           ELSE quote_ident(column_name) END, ', ' ORDER BY ordinal_position)
    FROM information_schema.columns WHERE table_schema = 'noir' AND table_name = '$t'")
  psql -U noir_admin -d noir -qAt -c "\\copy (SELECT $cols FROM noir.$t ORDER BY 1) TO '/exchange/csv/$t.csv' WITH (FORMAT csv, ENCODING 'UTF8')"
  echo "$t: $(wc -l < /exchange/csv/$t.csv) rows"
done < /etl/tables.txt
chmod -R a+rX /exchange/csv
```
<!-- /KOD -->

Ładowanie wszystkich tabel:

<!-- KOD etl/bulk/load.sh -->
```bash
#!/usr/bin/env bash
# Zaladowanie plikow CSV do SQL Server instrukcja BULK INSERT (KEEPIDENTITY zachowuje klucze z PostgreSQL).
set -euo pipefail
SQLCMD="/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P $MSSQL_SA_PASSWORD -d noir -b -I"
while read -r t; do
  echo "== $t"
  $SQLCMD -Q "BULK INSERT noir.$t FROM '/exchange/csv/$t.csv' WITH (FORMAT = 'CSV', FIELDQUOTE = '\"', FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', KEEPIDENTITY, KEEPNULLS, TABLOCK)" < /dev/null
done < /etl/tables.txt
```
<!-- /KOD -->

Wynik ładowania:

<!-- WYNIK results/etl_bulk_load.txt -->
```text
== case_status

== case_type

== evidence_type

== detective_rank

== payment_method

== client

== detective

== location

== case_file

== suspect

== witness

== informant

== evidence

== tip

== invoice

== payment

== case_detective

== case_suspect

== case_witness

== evidence_custody

== case_status_history

== document_counter

== operation_log

== alert

== monthly_case_stats

== job_run_log
```
<!-- /WYNIK -->

**Weryfikacja (zawartość tabel po załadowaniu):**

Skrypt odcisku zawartości tabel w PostgreSQL (dla każdej tabeli liczba wierszy i md5):

<!-- KOD sql/manual/31_fingerprint_pg.sql -->
```sql
-- DBMS-independent content fingerprint of the noir schema tables: for every table the row count and the md5 of the
-- rows (sorted binary) written in canonical form (columns separated by '|', NULL as \N, ISO dates, boolean 0/1).
-- The same algorithm works in SQL Server. Output: table|rows|md5
CREATE TEMP TABLE fp (table_name TEXT, row_count BIGINT, md5 TEXT);
DO $$
DECLARE t RECORD; expr TEXT;
BEGIN
  FOR t IN SELECT table_name FROM information_schema.tables WHERE table_schema = 'noir' AND table_type = 'BASE TABLE' ORDER BY 1 LOOP
    SELECT string_agg(
             'COALESCE(' ||
             CASE data_type
               WHEN 'boolean' THEN format('CASE WHEN %I THEN ''1'' ELSE ''0'' END', column_name)
               WHEN 'date' THEN format('to_char(%I, ''YYYY-MM-DD'')', column_name)
               WHEN 'timestamp without time zone' THEN format('to_char(%I, ''YYYY-MM-DD HH24:MI:SS.US'')', column_name)
               ELSE format('%I::text', column_name) END
             || ', ''\N'')', ' || ''|'' || ' ORDER BY ordinal_position)
      INTO expr FROM information_schema.columns WHERE table_schema = 'noir' AND table_name = t.table_name;
    EXECUTE format('INSERT INTO fp SELECT %L, COUNT(*), md5(COALESCE(string_agg(r, E''\n'' ORDER BY r COLLATE "C"), '''')) FROM (SELECT %s AS r FROM noir.%I) x',
                   t.table_name, expr, t.table_name);
  END LOOP;
END $$;
SELECT table_name || '|' || row_count || '|' || md5 FROM fp ORDER BY table_name COLLATE "C";
```
<!-- /KOD -->

Skrypt odcisku w SQL Server (ta sama postać kanoniczna wierszy i ten sam format wyniku):

<!-- KOD sql/manual/31_fingerprint_mssql.sql -->
```sql
-- Counterpart of the PostgreSQL script (same canonical row form and the same output: table|rows|md5)
SET NOCOUNT ON;
CREATE TABLE #fp (table_name VARCHAR(100), row_count BIGINT, md5 VARCHAR(32));
DECLARE @t VARCHAR(100), @expr NVARCHAR(MAX), @sql NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT table_name FROM INFORMATION_SCHEMA.TABLES WHERE table_schema = 'noir' AND table_type = 'BASE TABLE' ORDER BY 1;
OPEN c; FETCH NEXT FROM c INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @expr = STRING_AGG(CAST(
             'COALESCE(' +
             CASE ty.name
               WHEN 'bit' THEN 'CAST(' + QUOTENAME(col.name) + ' AS VARCHAR(1))'
               WHEN 'date' THEN 'CONVERT(VARCHAR(10), ' + QUOTENAME(col.name) + ', 23)'
               WHEN 'datetime2' THEN 'CONVERT(VARCHAR(27), ' + QUOTENAME(col.name) + ', 121)'
               WHEN 'varchar' THEN 'CAST(' + QUOTENAME(col.name) + ' AS VARCHAR(MAX))'
               ELSE 'CAST(' + QUOTENAME(col.name) + ' AS VARCHAR(40))' END
             + ', ''\N'')' AS NVARCHAR(MAX)), ' + ''|'' + ') WITHIN GROUP (ORDER BY col.column_id)
      FROM sys.columns col JOIN sys.types ty ON ty.user_type_id = col.user_type_id
      WHERE col.object_id = OBJECT_ID('noir.' + @t);
    SET @sql = N'INSERT INTO #fp SELECT ''' + @t + ''', COUNT(*), LOWER(CONVERT(VARCHAR(32), HASHBYTES(''MD5'', ISNULL(STRING_AGG(CAST(r AS VARCHAR(MAX)), CHAR(10)) WITHIN GROUP (ORDER BY r COLLATE Latin1_General_100_BIN2_UTF8), '''')), 2)) FROM (SELECT ' + @expr + N' AS r FROM noir.' + QUOTENAME(@t) + N') x';
    EXEC sp_executesql @sql;
    FETCH NEXT FROM c INTO @t;
END
CLOSE c; DEALLOCATE c;
SELECT table_name + '|' + CAST(row_count AS VARCHAR(20)) + '|' + md5 FROM #fp ORDER BY table_name COLLATE Latin1_General_100_BIN2_UTF8;
```
<!-- /KOD -->

Porównanie wyników obu skryptów:

<!-- ODCISKI results/etl_bulk_compare.txt -->
| Tabela | Wiersze PostgreSQL | Wiersze SQL Server | md5 PostgreSQL | md5 SQL Server | Zgodne |
|----------------|----|----|----------|----------|----|
| `alert` | 0 | 0 | `d41d8cd98f00` | `d41d8cd98f00` | TAK |
| `case_detective` | 12 | 12 | `dfc7c00de04f` | `dfc7c00de04f` | TAK |
| `case_file` | 7 | 7 | `9c085bd3e866` | `9c085bd3e866` | TAK |
| `case_status` | 5 | 5 | `41e630a1323f` | `41e630a1323f` | TAK |
| `case_status_history` | 13 | 13 | `8e4a303f9db0` | `8e4a303f9db0` | TAK |
| `case_suspect` | 11 | 11 | `b9964d639641` | `b9964d639641` | TAK |
| `case_type` | 6 | 6 | `52e6505e2d47` | `52e6505e2d47` | TAK |
| `case_witness` | 7 | 7 | `eaff4fb751bd` | `eaff4fb751bd` | TAK |
| `client` | 6 | 6 | `338de9a0943f` | `338de9a0943f` | TAK |
| `detective` | 6 | 6 | `1675391c57f6` | `1675391c57f6` | TAK |
| `detective_rank` | 4 | 4 | `d61310c6a857` | `d61310c6a857` | TAK |
| `document_counter` | 3 | 3 | `c87fa0642aa7` | `c87fa0642aa7` | TAK |
| `evidence` | 9 | 9 | `fd5aff101529` | `fd5aff101529` | TAK |
| `evidence_custody` | 9 | 9 | `e74bd425ae55` | `e74bd425ae55` | TAK |
| `evidence_type` | 6 | 6 | `8ebbda3b6159` | `8ebbda3b6159` | TAK |
| `informant` | 4 | 4 | `989c32c027e6` | `989c32c027e6` | TAK |
| `invoice` | 6 | 6 | `cd1c954bd4d7` | `cd1c954bd4d7` | TAK |
| `job_run_log` | 0 | 0 | `d41d8cd98f00` | `d41d8cd98f00` | TAK |
| `location` | 6 | 6 | `4142cb151524` | `4142cb151524` | TAK |
| `monthly_case_stats` | 0 | 0 | `d41d8cd98f00` | `d41d8cd98f00` | TAK |
| `operation_log` | 0 | 0 | `d41d8cd98f00` | `d41d8cd98f00` | TAK |
| `payment` | 5 | 5 | `0ba2b85c8b70` | `0ba2b85c8b70` | TAK |
| `payment_method` | 4 | 4 | `9869bed77cbe` | `9869bed77cbe` | TAK |
| `suspect` | 6 | 6 | `a747e261a59d` | `a747e261a59d` | TAK |
| `tip` | 5 | 5 | `0b79e1a3254f` | `0b79e1a3254f` | TAK |
| `witness` | 5 | 5 | `0aa0d99553af` | `0aa0d99553af` | TAK |
<!-- /ODCISKI -->

**Wynik: sukces.** Wszystkie 26 tabel zgodne co do liczby wierszy i zawartości. Po załadowaniu kolejne wstawienia dostają klucze większe od największego przeniesionego (np. nowy klient ma `client_id` = 7), czyli liczniki `IDENTITY` zostały ustawione poprawnie przez `KEEPIDENTITY`.

### 8.2 Apache Hop (ETL)

[Apache Hop](https://hop.apache.org/) to narzędzie klasy ETL i program służący do przenoszenia danych między systemami. Przepływ danych projektuje się w nim graficznie jako **potok** (*pipeline*): jego schemat jest złożony z **transformacji**, z których każdy wykonuje jedną czynność na strumieniu wierszy, np. odczyt z bazy, zmianę wartości albo zapis do bazy. Kroki łączą strzałki (*hops*), którymi wiersze przepływają od jednego kroku do następnego. Definicja potoku jest zapisana jako plik XML, więc potok można uruchomić także bez interfejsu graficznego.

W tym projekcie potok `pg_to_staging` przenosi zawartość wszystkich 26 tabel z PostgreSQL do SQL Server. Dla każdej tabeli składa się z dwóch połączonych kroków:

1. `Table input` wykonuje zapytanie `SELECT` w PostgreSQL i wysyła wynik wiersz po wierszu do następnego kroku; kolumny logiczne są w nim zamieniane na 0/1 (`CASE WHEN ... THEN 1 ELSE 0 END`), bo `BIT` w SQL Server przyjmuje tylko takie wartości;
2. `Table output` zapisuje otrzymane wiersze do tabeli w SQL Server (partiami po 1000 wierszy, z uprzednim opróżnieniem tabeli docelowej).

Dostęp do obu baz opisują **połączenia** zapisane jako metadane projektu Hop: `pg_noir` (typ `PostgreSQL`) i `mssql_noir`. Kroki odwołują się do nich po nazwie, więc dane logowania nie są wpisane w sam potok. Uruchomienie bez GUI polega na wywołaniu polecenia `hop-run` w kontenerze `apache/hop`, które wykonuje potok i wypisuje statystyki każdego kroku. Fragment definicji potoku dla tabeli `detective` (para kroków odczytu i zapisu):

```xml
<transform>
  <name>read detective</name>
  <type>TableInput</type>
  <connection>pg_noir</connection>
  <sql>SELECT detective_id, rank_id, first_name, last_name, license_no, hired_on,
       CASE WHEN is_active THEN 1 ELSE 0 END AS is_active FROM noir.detective</sql>
</transform>
<transform>
  <name>write detective</name>
  <type>TableOutput</type>
  <connection>mssql_noir</connection>
  <schema>stg</schema><table>detective</table>
  <commit>1000</commit><truncate>Y</truncate><use_batch>Y</use_batch>
</transform>
```

Krok `Table output` nie potrafi włączyć `IDENTITY_INSERT`, więc potok zapisuje dane nie do właściwych tabel, lecz do schematu pośredniego `stg`, zawierającego kopie tabel bez własności `IDENTITY`. Drugi etap to skrypt T-SQL, który przenosi dane ze schematu `stg` do właściwych tabel w kolejności zgodnej z kluczami obcymi, z `SET IDENTITY_INSERT ON` (żeby zachować klucze z PostgreSQL), a na końcu usuwa schemat `stg`. Poniżej znajdują się statystyki wykonania potoku: dla każdego kroku zapisu liczba wierszy przeczytanych (`R`) i zapisanych (`W`) oraz błędy (`E`):

<!-- KOD etl/hop/run_hop.sh od="docker run" -->
```bash
docker run --rm --network task2_default -v "$PWD/etl/hop:/project:ro" --entrypoint bash apache/hop:latest -c '
cp -r /project /tmp/noir-etl
/opt/hop/hop-conf.sh --project-create --project noir-etl --project-home /tmp/noir-etl >/dev/null 2>&1
/opt/hop/hop-run.sh -j noir-etl -f /tmp/noir-etl/pg_to_staging.hpl -r local -l Basic'
```
<!-- /KOD -->

<!-- WYNIK results/etl_hop_run.txt filtr="write .*Finished processing|Pipeline duration|rows" -->
```text
2026/10/17 15:44:39 - write document_counter.0 - Finished processing (I=0, O=3, R=3, W=3, U=0, E=0)
2026/10/17 15:44:39 - write tip.0 - Finished processing (I=0, O=5, R=5, W=5, U=0, E=0)
2026/10/17 15:44:39 - write case_type.0 - Finished processing (I=0, O=6, R=6, W=6, U=0, E=0)
2026/10/17 15:44:39 - write invoice.0 - Finished processing (I=0, O=6, R=6, W=6, U=0, E=0)
2026/10/17 15:44:39 - write location.0 - Finished processing (I=0, O=6, R=6, W=6, U=0, E=0)
2026/10/17 15:44:39 - write payment_method.0 - Finished processing (I=0, O=4, R=4, W=4, U=0, E=0)
2026/10/17 15:44:39 - write case_file.0 - Finished processing (I=0, O=7, R=7, W=7, U=0, E=0)
2026/10/17 15:44:39 - write informant.0 - Finished processing (I=0, O=4, R=4, W=4, U=0, E=0)
2026/10/17 15:44:39 - write witness.0 - Finished processing (I=0, O=5, R=5, W=5, U=0, E=0)
2026/10/17 15:44:39 - write evidence_type.0 - Finished processing (I=0, O=6, R=6, W=6, U=0, E=0)
2026/10/17 15:44:39 - write detective.0 - Finished processing (I=0, O=6, R=6, W=6, U=0, E=0)
2026/10/17 15:44:39 - write detective_rank.0 - Finished processing (I=0, O=4, R=4, W=4, U=0, E=0)
2026/10/17 15:44:39 - write suspect.0 - Finished processing (I=0, O=6, R=6, W=6, U=0, E=0)
2026/10/17 15:44:39 - write case_suspect.0 - Finished processing (I=0, O=11, R=11, W=11, U=0, E=0)
2026/10/17 15:44:39 - write client.0 - Finished processing (I=0, O=6, R=6, W=6, U=0, E=0)
2026/10/17 15:44:39 - write payment.0 - Finished processing (I=0, O=5, R=5, W=5, U=0, E=0)
2026/10/17 15:44:39 - write case_detective.0 - Finished processing (I=0, O=12, R=12, W=12, U=0, E=0)
2026/10/17 15:44:39 - write evidence_custody.0 - Finished processing (I=0, O=9, R=9, W=9, U=0, E=0)
2026/10/17 15:44:39 - write case_status.0 - Finished processing (I=0, O=5, R=5, W=5, U=0, E=0)
2026/10/17 15:44:39 - write case_status_history.0 - Finished processing (I=0, O=13, R=13, W=13, U=0, E=0)
2026/10/17 15:44:39 - write case_witness.0 - Finished processing (I=0, O=7, R=7, W=7, U=0, E=0)
2026/10/17 15:44:39 - write evidence.0 - Finished processing (I=0, O=9, R=9, W=9, U=0, E=0)
2026/10/17 15:44:39 - pg_to_staging - Pipeline duration : 0.811 seconds [  0.811" ]
```
<!-- /WYNIK -->

**Weryfikacja (zawartość tabel po załadowaniu):**

<!-- ODCISKI results/etl_hop_compare.txt -->
| Tabela | Wiersze PostgreSQL | Wiersze SQL Server | md5 PostgreSQL | md5 SQL Server | Zgodne |
|----------------|----|----|----------|----------|----|
| `alert` | 0 | 0 | `d41d8cd98f00` | `d41d8cd98f00` | TAK |
| `case_detective` | 12 | 12 | `dfc7c00de04f` | `dfc7c00de04f` | TAK |
| `case_file` | 7 | 7 | `9c085bd3e866` | `9c085bd3e866` | TAK |
| `case_status` | 5 | 5 | `41e630a1323f` | `41e630a1323f` | TAK |
| `case_status_history` | 13 | 13 | `8e4a303f9db0` | `8e4a303f9db0` | TAK |
| `case_suspect` | 11 | 11 | `b9964d639641` | `b9964d639641` | TAK |
| `case_type` | 6 | 6 | `52e6505e2d47` | `52e6505e2d47` | TAK |
| `case_witness` | 7 | 7 | `eaff4fb751bd` | `eaff4fb751bd` | TAK |
| `client` | 6 | 6 | `338de9a0943f` | `338de9a0943f` | TAK |
| `detective` | 6 | 6 | `1675391c57f6` | `1675391c57f6` | TAK |
| `detective_rank` | 4 | 4 | `d61310c6a857` | `d61310c6a857` | TAK |
| `document_counter` | 3 | 3 | `c87fa0642aa7` | `c87fa0642aa7` | TAK |
| `evidence` | 9 | 9 | `fd5aff101529` | `fd5aff101529` | TAK |
| `evidence_custody` | 9 | 9 | `e74bd425ae55` | `e74bd425ae55` | TAK |
| `evidence_type` | 6 | 6 | `8ebbda3b6159` | `8ebbda3b6159` | TAK |
| `informant` | 4 | 4 | `989c32c027e6` | `989c32c027e6` | TAK |
| `invoice` | 6 | 6 | `cd1c954bd4d7` | `cd1c954bd4d7` | TAK |
| `job_run_log` | 0 | 0 | `d41d8cd98f00` | `d41d8cd98f00` | TAK |
| `location` | 6 | 6 | `4142cb151524` | `4142cb151524` | TAK |
| `monthly_case_stats` | 0 | 0 | `d41d8cd98f00` | `d41d8cd98f00` | TAK |
| `operation_log` | 0 | 0 | `d41d8cd98f00` | `d41d8cd98f00` | TAK |
| `payment` | 5 | 5 | `0ba2b85c8b70` | `0ba2b85c8b70` | TAK |
| `payment_method` | 4 | 4 | `9869bed77cbe` | `9869bed77cbe` | TAK |
| `suspect` | 6 | 6 | `a747e261a59d` | `a747e261a59d` | TAK |
| `tip` | 5 | 5 | `0b79e1a3254f` | `0b79e1a3254f` | TAK |
| `witness` | 5 | 5 | `0aa0d99553af` | `0aa0d99553af` | TAK |
<!-- /ODCISKI -->

**Wynik: sukces.** Wszystkie 26 tabel zgodne. Różnice względem BULK INSERT: dwuetapowość (zapis do schematu pośredniego i przeniesienie) wynikająca z `IDENTITY`, konieczność zapisu wartości logicznych jako 0/1 oraz czas startu maszyny wirtualnej Javy; w zamian narzędzie daje graficzny edytor potoków, transformacje po drodze i obsługę błędów wierszy.

### 8.3 Porównanie metod

| | BULK INSERT (CSV) | Apache Hop |
|---------------|----------------------|----------------------|
| Kroki | eksport CSV, ładowanie | zapis do `stg`, przeniesienie do tabel |
| Klucze `IDENTITY` | `KEEPIDENTITY` | `IDENTITY_INSERT` w skrypcie przenoszącym |
| Wartości logiczne | konwersja w zapytaniu eksportu | konwersja w zapytaniu `Table input` |
| Dodatkowe oprogramowanie | brak | kontener Hop, sterowniki JDBC |
| Transformacje w locie | tylko w zapytaniu eksportu | tak (kroki potoku) |
| Wynik | wszystkie tabele zgodne | wszystkie tabele zgodne |

## 9. Działanie bazy na SQL Server

Po migracji danych utworzono na SQL Server widoki, funkcję, wyzwalacz, procedury, uprawnienia i zadania i powtórzono wszystkie testy. W wynikach wartość `0.00` jest wypisywana przez `sqlcmd` jako `.00`; w tabelach poniżej zapisano ją jako `0.00`.

### 9.1 Funkcja

To samo wywołanie co w PostgreSQL daje ten sam wynik; różni się oś czasu sprawy, bo `fn_case_timeline` zwraca wiersze bez sortowania (sortuje wywołujący).

Definicja funkcji:

<!-- KOD sql/mssql/07_functions.sql -->
```sql
USE noir;
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
-- ===================== TABLE FUNCTION (for users) =====================
-- Case timeline: investigation events from several tables (sorting left to the caller: ORDER BY event_at, event_type)
CREATE FUNCTION noir.fn_case_timeline(@case_id INT)
RETURNS TABLE
AS
RETURN
    -- step 1: the opening of the case (a date, converted to a timestamp so that all branches have the same type)
    SELECT CAST(c.opened_on AS DATETIME2(6)) AS event_at, CAST('CASE_OPENED' AS VARCHAR(20)) AS event_type, CAST(c.title AS VARCHAR(300)) AS description
    FROM noir.case_file c WHERE c.case_id = @case_id
    UNION ALL
    -- step 2: status changes (the first history entry, with no old status, only repeats the opening, so it is skipped)
    SELECT h.changed_at, 'STATUS', '-> ' + s.name
    FROM noir.case_status_history h JOIN noir.case_status s ON s.status_id = h.new_status_id
    WHERE h.case_id = @case_id AND h.old_status_id IS NOT NULL
    UNION ALL
    -- step 3: evidence found in the case
    SELECT e.found_at, 'EVIDENCE', e.evidence_code + ': ' + e.description FROM noir.evidence e WHERE e.case_id = @case_id
    UNION ALL
    -- step 4: tips received
    SELECT t.received_at, 'TIP', t.content FROM noir.tip t WHERE t.case_id = @case_id
    UNION ALL
    -- step 5: witness statements (no ORDER BY: a function returning a table cannot sort its result)
    SELECT CAST(cw.statement_date AS DATETIME2(6)), 'STATEMENT', w.first_name + ' ' + w.last_name
    FROM noir.case_witness cw JOIN noir.witness w ON w.witness_id = cw.witness_id WHERE cw.case_id = @case_id;
GO
GO
```
<!-- /KOD -->

Wynik wywołania:

<!-- KOD sql/manual/mssql_20_functions_demo.sql -->
```sql
SET NOCOUNT ON;
PRINT '--- fn_case_timeline(3): timeline of the Falcon Statuette case';
SELECT * FROM noir.fn_case_timeline(3) ORDER BY event_at, event_type;
GO
```
<!-- /KOD -->

<!-- WYNIK results/mssql_20_functions_demo.txt -->
```text
--- fn_case_timeline(3): timeline of the Falcon Statuette case
event_at|event_type|description
--------|----------|-----------
2025-03-25 00:00:00.000000|CASE_OPENED|The Falcon Statuette
2025-04-02 00:00:00.000000|STATEMENT|Harry Jones
2025-04-02 11:45:00.000000|EVIDENCE|EV-0005: Letter signed with an initial "G".
2025-04-05 03:40:00.000000|TIP|The statuette is being moved through Union Station.
2025-04-06 04:10:00.000000|EVIDENCE|EV-0004: Replica statuette with a lead core.
2025-05-11 00:00:00.000000|STATEMENT|Mona Mars
2025-06-18 01:00:00.000000|STATUS|-> Closed - solved
```
<!-- /WYNIK -->

### 9.2 Wyzwalacz

Wyzwalacz `trg_payment` w SQL Server jest typu `AFTER` na instrukcję; naruszenie reguły wycofuje instrukcję (`ROLLBACK` + `THROW`). Reguła z sekcji 2.3 działa tak samo, z takimi samymi komunikatami.

Definicja wyzwalacza:

<!-- KOD sql/mssql/09_triggers.sql -->
```sql
USE noir;
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
-- SQL Server triggers are statement-level AFTER triggers (the inserted / deleted tables contain all
-- modified rows). Rule violation: ROLLBACK + THROW, so the DML statement is rolled back entirely.
-- Triggers rely on ownership chaining (objects belong to noir_admin), so the rule applies regardless of the role's rights.

-- ===================== FINANCE =====================
-- Payment: a payment cannot be dated before the invoice is issued or in the future, and the total of all payments for an invoice cannot exceed the invoice amount.
CREATE TRIGGER noir.trg_payment ON noir.payment AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @m NVARCHAR(500);
    -- step 1: payments dated before the invoice was issued; UPDLOCK locks the invoice row, so two concurrent payments
    -- for the same invoice are checked one after another; the trigger sees all rows of the statement in 'inserted'
    SELECT TOP 1 @m = CONCAT('Payment (', CONVERT(VARCHAR(10), i.paid_on, 23), ') is before invoice issue date (', CONVERT(VARCHAR(10), v.issued_on, 23), ')')
    FROM inserted i JOIN noir.invoice v WITH (UPDLOCK) ON v.invoice_id = i.invoice_id WHERE i.paid_on < v.issued_on;
    -- if a rule is broken: cancel the whole statement (ROLLBACK) and report the message (THROW)
    IF @m IS NOT NULL BEGIN IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; THROW 50001, @m, 1; END;
    -- step 2: payments dated in the future
    SELECT TOP 1 @m = CONCAT('Payment date is in the future (', CONVERT(VARCHAR(10), i.paid_on, 23), ')')
    FROM inserted i WHERE i.paid_on > CAST(SYSDATETIME() AS DATE);
    IF @m IS NOT NULL BEGIN IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; THROW 50001, @m, 1; END;
    -- step 3: for every invoice touched by the statement, the total of all its payments (the new row is already in the
    -- table in an AFTER trigger) must not exceed the invoice amount
    SELECT TOP 1 @m = CONCAT('Payments (total ', t.total, ') exceed invoice amount (', v.amount, ')')
    FROM (SELECT DISTINCT invoice_id FROM inserted) i
    JOIN noir.invoice v ON v.invoice_id = i.invoice_id
    CROSS APPLY (SELECT SUM(p.amount) AS total FROM noir.payment p WHERE p.invoice_id = i.invoice_id) t
    WHERE t.total > v.amount;
    IF @m IS NOT NULL BEGIN IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; THROW 50001, @m, 1; END;
END;
GO

GO
```
<!-- /KOD -->

Wynik testów wyzwalacza:

<!-- KOD sql/manual/mssql_22_triggers_demo.sql -->
```sql
SET NOCOUNT ON;
PRINT '=== payments: above the invoice amount / before issue date / in the future / update to an excessive amount ===';
INSERT INTO noir.payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, CAST(SYSDATETIME() AS DATE), 2300.00);
GO
INSERT INTO noir.payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, '2025-01-01', 100.00);
GO
INSERT INTO noir.payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, DATEADD(DAY, 3, CAST(SYSDATETIME() AS DATE)), 100.00);
GO
UPDATE noir.payment SET amount = 4500 WHERE payment_id = 3;
GO
PRINT '=== payments: valid payment (remainder of the invoice) ===';
INSERT INTO noir.payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, CAST(SYSDATETIME() AS DATE), 2200.00);
GO
SELECT invoice_number, amount, paid, balance, payment_status FROM noir.v_invoice_balance WHERE invoice_number = 'INV-2025-0003';
GO
```
<!-- /KOD -->

<!-- WYNIK results/mssql_22_triggers_demo.txt -->
```text
=== payments: above the invoice amount / before issue date / in the future / update to an excessive amount ===
Msg 50001, Level 16, State 1, Procedure trg_payment, Line 28
Payments (total 4300.00) exceed invoice amount (4200.00)
Msg 50001, Level 16, State 1, Procedure trg_payment, Line 16
Payment (2025-01-01) is before invoice issue date (2025-06-20)
Msg 50001, Level 16, State 1, Procedure trg_payment, Line 20
Payment date is in the future (2026-10-20)
Msg 50001, Level 16, State 1, Procedure trg_payment, Line 28
Payments (total 4500.00) exceed invoice amount (4200.00)
=== payments: valid payment (remainder of the invoice) ===
invoice_number|amount|paid|balance|payment_status
--------------|------|----|-------|--------------
INV-2025-0003|4200.00|4200.00|0.00|PAID
```
<!-- /WYNIK -->

### 9.3 Procedury

Procedura prosta `sp_register_payment` i złożona `sp_open_case` dają te same wyniki co w PostgreSQL. `sp_open_case` działa na pięciu tabelach w transakcji `BEGIN TRAN ... COMMIT`, a błędy obsługuje `TRY ... CATCH` z `ROLLBACK`.

Definicje procedur:

<!-- KOD sql/mssql/08_procedures.sql -->
```sql
USE noir;
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
-- The procedure and tables belong to one owner (noir_admin): ownership chaining lets the application role,
-- which has only EXECUTE on the procedure, modify data in tables. Results are returned via OUTPUT parameters.

-- ===================== PAYMENT REGISTRATION =====================
-- Payment for an invoice identified by number, payment method by name; returns the id of the new payment.
-- The rules (amount not greater than the balance, date) are enforced by the trg_payment trigger.
CREATE PROCEDURE noir.sp_register_payment @invoice_number VARCHAR(20), @method_name VARCHAR(40),
                                          @amount NUMERIC(10,2), @paid_on DATE, @payment_id INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @m NVARCHAR(500);
    DECLARE @invoice INT, @method SMALLINT;
    -- step 1: find the invoice by its number and the payment method by its name
    SELECT @invoice = invoice_id FROM noir.invoice WHERE invoice_number = @invoice_number;
    SELECT @method = method_id FROM noir.payment_method WHERE name = @method_name;
    -- step 2: an unknown invoice or method is an error
    IF @invoice IS NULL BEGIN SET @m = CONCAT('Invoice does not exist: ', @invoice_number); THROW 50001, @m, 1; END;
    IF @method IS NULL BEGIN SET @m = CONCAT('Unknown payment method: ', @method_name); THROW 50001, @m, 1; END;
    -- step 3: add the payment (today if no date is given); the trigger checks amount and dates
    INSERT INTO noir.payment (invoice_id, method_id, paid_on, amount)
    VALUES (@invoice, @method, COALESCE(@paid_on, CAST(SYSDATETIME() AS DATE)), @amount);
    -- step 4: return the id of the new payment
    SET @payment_id = SCOPE_IDENTITY();
END;
GO

-- ===================== CASE OPENING =====================
-- Opening a case: number from the document counter (document_counter), case record, status history entry, lead detective.
-- The number is always greater than the last one issued, even after deleting the case with the highest number;
-- UPDATE of the counter locks the row until the end of the transaction, so concurrent transactions get different numbers.
-- An error in any step rolls back the transaction (CATCH), after which the procedure records the error in operation_log.
CREATE PROCEDURE noir.sp_open_case @client_id INT, @type_name VARCHAR(40), @title VARCHAR(150), @description VARCHAR(2000),
                                   @fee_estimate NUMERIC(10,2), @lead_detective_id INT,
                                   @case_number VARCHAR(20) OUTPUT, @result VARCHAR(500) OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @m NVARCHAR(500);
    DECLARE @type SMALLINT, @status SMALLINT, @case INT, @err VARCHAR(500), @value INT;
    DECLARE @year INT = YEAR(SYSDATETIME());
    SET @case_number = NULL;
    BEGIN TRY
        -- everything below is one transaction: either all steps succeed or none is saved
        BEGIN TRAN;
        -- step 1: the client must exist
        IF NOT EXISTS (SELECT 1 FROM noir.client WHERE client_id = @client_id)
            BEGIN SET @m = CONCAT('Client does not exist: id ', @client_id); THROW 50001, @m, 1; END;
        -- step 2: the case type must exist
        SELECT @type = type_id FROM noir.case_type WHERE name = @type_name;
        IF @type IS NULL
            BEGIN SET @m = CONCAT('Unknown case type: ', @type_name); THROW 50001, @m, 1; END;
        -- step 3: a new case always starts in the status Open
        SELECT @status = status_id FROM noir.case_status WHERE name = 'Open';
        -- step 4: next case number: create the counter row for the year if it is missing (the lock hints keep two
        -- concurrent transactions from creating it twice), then increase it by 1 and read the new value
        IF NOT EXISTS (SELECT 1 FROM noir.document_counter WITH (UPDLOCK, HOLDLOCK) WHERE counter_name = 'CASE' AND counter_year = @year)
            INSERT INTO noir.document_counter (counter_name, counter_year, last_value) VALUES ('CASE', @year, 0);
        UPDATE noir.document_counter SET @value = last_value = last_value + 1
        WHERE counter_name = 'CASE' AND counter_year = @year;
        -- step 5: build the number NOIR-<year>-<counter padded to 3 digits>
        SET @case_number = 'NOIR-' + CAST(@year AS VARCHAR(4)) + '-' + RIGHT('000' + CAST(@value AS VARCHAR(10)), 3);
        -- step 6: add the case
        INSERT INTO noir.case_file (case_number, title, description, type_id, status_id, client_id, opened_on, fee_estimate)
        VALUES (@case_number, @title, @description, @type, @status, @client_id, CAST(SYSDATETIME() AS DATE), COALESCE(@fee_estimate, 0));
        SET @case = SCOPE_IDENTITY();
        -- step 7: first status history entry (no old status)
        INSERT INTO noir.case_status_history (case_id, old_status_id, new_status_id, changed_by)
        VALUES (@case, NULL, @status, SUSER_SNAME());
        -- step 8: the lead detective must exist and be active; the error here rolls back steps 4-7 as well
        IF NOT EXISTS (SELECT 1 FROM noir.detective WHERE detective_id = @lead_detective_id AND is_active = 1)
            BEGIN SET @m = CONCAT('Detective ', @lead_detective_id, ' does not exist or is not active'); THROW 50001, @m, 1; END;
        -- step 9: assign the lead detective
        INSERT INTO noir.case_detective (case_id, detective_id, role, assigned_on)
        VALUES (@case, @lead_detective_id, 'LEAD', CAST(SYSDATETIME() AS DATE));
        -- step 10: save the transaction, return the message and log it
        COMMIT;
        SET @result = 'OK: case opened ' + @case_number;
        INSERT INTO noir.operation_log (procedure_name, severity, message) VALUES ('sp_open_case', 'INFO', @result);
    END TRY
    -- on any error: roll back the transaction (if still open), return the message and log the error
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        SET @case_number = NULL;
        SET @err = LEFT(ERROR_MESSAGE(), 500);
        SET @result = 'ERROR: ' + @err;
        INSERT INTO noir.operation_log (procedure_name, severity, message) VALUES ('sp_open_case', 'ERROR', @err);
    END CATCH;
END;
GO
```
<!-- /KOD -->

Poniższe scenariusze mają tę samą postać `setup`, `act`, `check` co w PostgreSQL; parametry wyjściowe są odbierane w zmiennych `@n` i `@r`.

**Scenariusz 1: poprawne otwarcie sprawy**

```sql
SELECT COUNT(*) AS cases_before FROM noir.case_file;
DECLARE @n VARCHAR(20), @r VARCHAR(500);
EXEC noir.sp_open_case 1, 'Fraud', 'The Forged Ledger', 'Falsified books of a shipping company.', 4200, 2, @n OUTPUT, @r OUTPUT;
SELECT @n AS case_number, @r AS result;
SELECT COUNT(*) AS cases_after FROM noir.case_file;
SELECT case_number, title, fee_estimate, opened_on FROM noir.case_file WHERE title = 'The Forged Ledger';
SELECT c.case_number, d.last_name, cd.role FROM noir.case_detective cd JOIN noir.case_file c ON c.case_id = cd.case_id JOIN noir.detective d ON d.detective_id = cd.detective_id WHERE c.title = 'The Forged Ledger';
SELECT h.old_status_id, s.name AS new_status FROM noir.case_status_history h JOIN noir.case_status s ON s.status_id = h.new_status_id WHERE h.case_id = (SELECT case_id FROM noir.case_file WHERE title = 'The Forged Ledger');
```

<!-- WYNIK results/mssql_21_procedures_demo.txt od="=== sp_open_case: success ===" do="=== sp_open_case: error at the first step (nonexistent client) ===" -->
```text
=== sp_open_case: success ===
cases_before
------------
7
case_number|result
-----------|------
NOIR-2026-001|OK: case opened NOIR-2026-001
cases_after
-----------
8
case_number|title|fee_estimate|opened_on
-----------|-----|------------|---------
NOIR-2026-001|The Forged Ledger|4200.00|2026-10-17
case_number|last_name|role
-----------|---------|----
NOIR-2026-001|Spade|LEAD
old_status_id|new_status
-------------|----------
NULL|Open
```
<!-- /WYNIK -->

**Scenariusz 2: błąd na pierwszym kroku (nieistniejący klient, id 999)**

```sql
SELECT COUNT(*) AS cases_before FROM noir.case_file;
DECLARE @n VARCHAR(20), @r VARCHAR(500);
EXEC noir.sp_open_case 999, 'Fraud', 'Ghost client', NULL, 100, 2, @n OUTPUT, @r OUTPUT;
SELECT @n AS case_number, @r AS result;
SELECT COUNT(*) AS cases_after, SUM(CASE WHEN title = 'Ghost client' THEN 1 ELSE 0 END) AS rolled_back_rows FROM noir.case_file;
```

<!-- WYNIK results/mssql_21_procedures_demo.txt od="=== sp_open_case: error at the first step (nonexistent client) ===" do="=== sp_open_case: error at the last step (inactive detective) - the inserted case is rolled back ===" -->
```text
=== sp_open_case: error at the first step (nonexistent client) ===
cases_before
------------
8
case_number|result
-----------|------
NULL|ERROR: Client does not exist: id 999
cases_after|rolled_back_rows
-----------|----------------
8|0
```
<!-- /WYNIK -->

**Scenariusz 3: błąd na ostatnim kroku (detektyw nieaktywny): wstawiona wcześniej sprawa i wpis historii zostają wycofane**

```sql
SELECT COUNT(*) AS cases_before FROM noir.case_file;
DECLARE @n VARCHAR(20), @r VARCHAR(500);
EXEC noir.sp_open_case 1, 'Theft', 'Case that must roll back', NULL, 100, 6, @n OUTPUT, @r OUTPUT;
SELECT @n AS case_number, @r AS result;
SELECT COUNT(*) AS cases_after, SUM(CASE WHEN title = 'Case that must roll back' THEN 1 ELSE 0 END) AS rolled_back_rows FROM noir.case_file;
SELECT procedure_name, severity, message FROM noir.operation_log ORDER BY log_id;
```

<!-- WYNIK results/mssql_21_procedures_demo.txt od="=== sp_open_case: error at the last step (inactive detective) - the inserted case is rolled back ===" do="=== numbering: the number of a deleted case is not reused ===" -->
```text
=== sp_open_case: error at the last step (inactive detective) - the inserted case is rolled back ===
cases_before
------------
8
case_number|result
-----------|------
NULL|ERROR: Detective 6 does not exist or is not active
cases_after|rolled_back_rows
-----------|----------------
8|0
procedure_name|severity|message
--------------|--------|-------
sp_open_case|INFO|OK: case opened NOIR-2026-001
sp_open_case|ERROR|Client does not exist: id 999
sp_open_case|ERROR|Detective 6 does not exist or is not active
```
<!-- /WYNIK -->

Numeracja po usunięciu sprawy (numer nie wraca) oraz pozostałe wyniki skryptu:

<!-- KOD sql/manual/mssql_21_procedures_demo.sql od="=== numbering: the number of a deleted case is not reused ===" -->
```sql
PRINT '=== numbering: the number of a deleted case is not reused ===';
SELECT counter_name, counter_year, last_value FROM noir.document_counter WHERE counter_name = 'CASE' ORDER BY counter_year;
GO
DECLARE @n VARCHAR(20), @r VARCHAR(500); EXEC noir.sp_open_case 1, 'Theft', 'Case to delete', NULL, 100, 4, @n OUTPUT, @r OUTPUT;
GO
DELETE FROM noir.case_status_history WHERE case_id = (SELECT case_id FROM noir.case_file WHERE title = 'Case to delete');
DELETE FROM noir.case_detective WHERE case_id = (SELECT case_id FROM noir.case_file WHERE title = 'Case to delete');
DELETE FROM noir.case_file WHERE title = 'Case to delete';
GO
DECLARE @n VARCHAR(20), @r VARCHAR(500); EXEC noir.sp_open_case 1, 'Theft', 'Case after delete', NULL, 100, 4, @n OUTPUT, @r OUTPUT;
GO
SELECT case_number, title FROM noir.case_file WHERE title IN ('The Forged Ledger', 'Case after delete') ORDER BY case_number;
SELECT counter_name, counter_year, last_value FROM noir.document_counter WHERE counter_name = 'CASE' ORDER BY counter_year;
GO
PRINT '=== sp_register_payment (simple procedure): payment, payment above the balance, unknown invoice ===';
DECLARE @p INT, @d DATE = CAST(SYSDATETIME() AS DATE); EXEC noir.sp_register_payment 'INV-2025-0006', 'Bank transfer', 1000, @d, @p OUTPUT; SELECT @p AS payment_id;
GO
DECLARE @p INT, @d DATE = CAST(SYSDATETIME() AS DATE); EXEC noir.sp_register_payment 'INV-2025-0006', 'Cash', 600, @d, @p OUTPUT;
GO
DECLARE @p INT, @d DATE = CAST(SYSDATETIME() AS DATE); EXEC noir.sp_register_payment 'INV-2025-9999', 'Cash', 100, @d, @p OUTPUT;
GO
SELECT invoice_number, amount, paid, balance, payment_status FROM noir.v_invoice_balance WHERE invoice_number = 'INV-2025-0006';
GO
PRINT '=== counters after ===';
SELECT (SELECT COUNT(*) FROM noir.case_file) AS cases, (SELECT COUNT(*) FROM noir.case_detective) AS assignments,
       (SELECT COUNT(*) FROM noir.case_status_history) AS status_history, (SELECT COUNT(*) FROM noir.operation_log) AS log_entries,
       (SELECT COUNT(*) FROM noir.payment) AS payments;
GO
```
<!-- /KOD -->

<!-- WYNIK results/mssql_21_procedures_demo.txt od="=== numbering: the number of a deleted case is not reused ===" -->
```text
=== numbering: the number of a deleted case is not reused ===
counter_name|counter_year|last_value
------------|------------|----------
CASE|2025|7
CASE|2026|1
case_number|title
-----------|-----
NOIR-2026-001|The Forged Ledger
NOIR-2026-003|Case after delete
counter_name|counter_year|last_value
------------|------------|----------
CASE|2025|7
CASE|2026|3
=== sp_register_payment (simple procedure): payment, payment above the balance, unknown invoice ===
payment_id
----------
9
Msg 50001, Level 16, State 1, Procedure trg_payment, Line 28
Payments (total 1600.00) exceed invoice amount (1500.00)
Msg 50001, Level 16, State 1, Procedure noir.sp_register_payment, Line 18
Invoice does not exist: INV-2025-9999
invoice_number|amount|paid|balance|payment_status
--------------|------|----|-------|--------------
INV-2025-0006|1500.00|1000.00|500.00|OVERDUE
=== counters after ===
cases|assignments|status_history|log_entries|payments
-----|-----------|--------------|-----------|--------
9|14|15|5|6
```
<!-- /WYNIK -->

Drugą procedurą jest `sp_nightly_maintenance`, uruchamiana przez zadanie automatyczne (sekcja 9.4).

### 9.4 Zadanie automatyczne (SQL Server Agent)

Zadanie `noir_nightly_maintenance` (krok T-SQL `EXEC noir.sp_nightly_maintenance`, harmonogram codzienny o 02:00) wykonuje tę samą procedurę co w PostgreSQL, przepisaną na T-SQL (`MERGE` zamiast `ON CONFLICT`, rekurencyjne CTE zamiast `generate_series`). Dodatkowo zadanie `noir_backup` wykonuje codziennie o 03:00 pełną kopię zapasową. Wynik ręcznego uruchomienia i powtórzeń oraz fragment migawki miesięcznej (te same liczby co w PostgreSQL: 2 + 3 alerty, 132 wiersze statystyk, po zmianach `-1`/`-1`):

<!-- KOD sql/manual/mssql_23_job_demo.sql od="=== before the job ===" do="=== monthly snapshot" -->
```sql
PRINT '=== before the job ===';
SELECT (SELECT COUNT(*) FROM noir.alert) AS alerts, (SELECT COUNT(*) FROM noir.monthly_case_stats) AS stats_rows, (SELECT COUNT(*) FROM noir.job_run_log) AS runs;
GO
PRINT '=== first run ===';
EXEC noir.sp_nightly_maintenance;
GO
SELECT run_id, job_name, status, details FROM noir.job_run_log ORDER BY run_id;
SELECT alert_type, COUNT(*) AS cnt, SUM(CASE WHEN resolved_on IS NULL THEN 1 ELSE 0 END) AS open_cnt FROM noir.alert GROUP BY alert_type ORDER BY 1;
SELECT alert_type, case_id, message FROM noir.alert WHERE resolved_on IS NULL ORDER BY alert_type, case_id;
GO
PRINT '=== a repeated run is idempotent (no new alerts) ===';
EXEC noir.sp_nightly_maintenance;
GO
SELECT run_id, status, details FROM noir.job_run_log ORDER BY run_id;
GO
PRINT '=== payment (sp_register_payment) and case closure - the next run closes the matching alerts ===';
DECLARE @p INT, @d DATE = CAST(SYSDATETIME() AS DATE); EXEC noir.sp_register_payment 'INV-2025-0006', 'Cash', 500, @d, @p OUTPUT;
GO
UPDATE noir.case_file SET status_id = (SELECT status_id FROM noir.case_status WHERE name = 'Closed - unsolved') WHERE case_number = 'NOIR-2025-002';
GO
EXEC noir.sp_nightly_maintenance;
GO
SELECT run_id, status, details FROM noir.job_run_log ORDER BY run_id;
SELECT alert_type, case_id, message, resolved_on FROM noir.alert ORDER BY alert_id;
GO
```
<!-- /KOD -->

<!-- WYNIK results/mssql_23_job_demo.txt od="=== before the job ===" do="=== monthly snapshot" -->
```text
=== before the job ===
alerts|stats_rows|runs
------|----------|----
0|0|0
=== first run ===
run_id|job_name|status|details
------|--------|------|-------
1|nightly_maintenance|OK|overdue invoices: +2/-0; inactive cases: +3/-0; statistics: 132 rows; purged from log: 0
alert_type|cnt|open_cnt
----------|---|--------
OVERDUE_INVOICE|2|2
STALE_CASE|3|3
alert_type|case_id|message
----------|-------|-------
OVERDUE_INVOICE|4|Invoice INV-2025-0005 overdue by 412 days, balance 1000.00
OVERDUE_INVOICE|6|Invoice INV-2025-0006 overdue by 351 days, balance 500.00
STALE_CASE|2|Case NOIR-2025-002 inactive for 608 days
STALE_CASE|4|Case NOIR-2025-004 inactive for 464 days
STALE_CASE|6|Case NOIR-2025-006 inactive for 387 days
=== a repeated run is idempotent (no new alerts) ===
run_id|status|details
------|------|-------
1|OK|overdue invoices: +2/-0; inactive cases: +3/-0; statistics: 132 rows; purged from log: 0
2|OK|overdue invoices: +0/-0; inactive cases: +0/-0; statistics: 132 rows; purged from log: 0
=== payment (sp_register_payment) and case closure - the next run closes the matching alerts ===
run_id|status|details
------|------|-------
1|OK|overdue invoices: +2/-0; inactive cases: +3/-0; statistics: 132 rows; purged from log: 0
2|OK|overdue invoices: +0/-0; inactive cases: +0/-0; statistics: 132 rows; purged from log: 0
3|OK|overdue invoices: +0/-1; inactive cases: +0/-1; statistics: 132 rows; purged from log: 0
alert_type|case_id|message|resolved_on
----------|-------|-------|-----------
OVERDUE_INVOICE|4|Invoice INV-2025-0005 overdue by 412 days, balance 1000.00|NULL
OVERDUE_INVOICE|6|Invoice INV-2025-0006 overdue by 351 days, balance 500.00|2026-10-17
STALE_CASE|2|Case NOIR-2025-002 inactive for 608 days|2026-10-17
STALE_CASE|4|Case NOIR-2025-004 inactive for 464 days|NULL
STALE_CASE|6|Case NOIR-2025-006 inactive for 387 days|NULL
```
<!-- /WYNIK -->

Zadanie uruchomione przez SQL Server Agent (ręcznie przez `sp_start_job`, a następnie przez harmonogram ustawiony na czas testu na co minutę; harmonogram przywrócono na 02:00):

<!-- KOD sql/manual/mssql_24_agent_demo.sh od="Q()" -->
```bash
Q() { /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -I -W -s "|" "$@"; }
echo "--- zadania i scheduley"
Q -d msdb -Q "SET NOCOUNT ON; SELECT j.name AS job, s.name AS schedule, s.freq_type, s.active_start_time, j.enabled FROM dbo.sysjobs j JOIN dbo.sysjobschedules js ON js.job_id = j.job_id JOIN dbo.sysschedules s ON s.schedule_id = js.schedule_id ORDER BY j.name"
echo "--- manual job start (sp_start_job)"
Q -d msdb -Q "SET NOCOUNT ON; EXEC dbo.sp_start_job 'noir_nightly_maintenance'"
sleep 8
echo "--- schedule changed to every minute (for the duration of the test only)"
Q -d msdb -Q "SET NOCOUNT ON; EXEC dbo.sp_update_schedule @name = 'noir_daily_0200', @freq_subday_type = 4, @freq_subday_interval = 1"
sleep 75
Q -d msdb -Q "SET NOCOUNT ON; EXEC dbo.sp_update_schedule @name = 'noir_daily_0200', @freq_subday_type = 1, @freq_subday_interval = 0, @active_start_time = 20000"
echo "--- job history in msdb (step 1 = step result, step 0 = job result)"
Q -d msdb -Q "SET NOCOUNT ON; SELECT h.step_id, CASE h.run_status WHEN 1 THEN 'Succeeded' WHEN 0 THEN 'Failed' ELSE CAST(h.run_status AS VARCHAR(5)) END AS run_status,
  STUFF(STUFF(RIGHT('000000' + CAST(h.run_time AS VARCHAR(6)), 6), 5, 0, ':'), 3, 0, ':') AS run_time, h.run_duration, LEFT(h.message, 90) AS message
  FROM dbo.sysjobhistory h JOIN dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = 'noir_nightly_maintenance' ORDER BY h.instance_id"
echo "--- job_run_log after runs triggered by the Agent"
Q -d noir -Q "SET NOCOUNT ON; SELECT run_id, job_name, status, details FROM noir.job_run_log ORDER BY run_id"
echo "--- schedule restored"
Q -d msdb -Q "SET NOCOUNT ON; SELECT s.name, s.freq_type, s.freq_subday_type, s.active_start_time FROM dbo.sysschedules s WHERE s.name = 'noir_daily_0200'"
```
<!-- /KOD -->

<!-- WYNIK results/mssql_24_agent_demo.txt -->
```text
--- zadania i scheduley
job|schedule|freq_type|active_start_time|enabled
---|--------|---------|-----------------|-------
noir_backup|noir_daily_0300|4|30000|1
noir_nightly_maintenance|noir_daily_0200|4|20000|1
--- manual job start (sp_start_job)
Job 'noir_nightly_maintenance' started successfully.
--- schedule changed to every minute (for the duration of the test only)
--- job history in msdb (step 1 = step result, step 0 = job result)
step_id|run_status|run_time|run_duration|message
-------|----------|--------|------------|-------
1|Succeeded|15:45:12|0|Executed as user: NT AUTHORITY\NETWORK SERVICE. The step succeeded.
0|Succeeded|15:45:12|0|The job succeeded.  The Job was invoked by User sa.  The last step to run was step 1 (sp_n
1|Succeeded|15:46:00|0|Executed as user: NT AUTHORITY\NETWORK SERVICE. The step succeeded.
0|Succeeded|15:46:00|0|The job succeeded.  The Job was invoked by Schedule 8 (noir_daily_0200).  The last step to
--- job_run_log after runs triggered by the Agent
run_id|job_name|status|details
------|--------|------|-------
1|nightly_maintenance|OK|overdue invoices: +2/-0; inactive cases: +3/-0; statistics: 132 rows; purged from log: 0
2|nightly_maintenance|OK|overdue invoices: +0/-0; inactive cases: +0/-0; statistics: 132 rows; purged from log: 0
3|nightly_maintenance|OK|overdue invoices: +0/-1; inactive cases: +0/-1; statistics: 132 rows; purged from log: 0
4|nightly_maintenance|OK|overdue invoices: +0/-0; inactive cases: +0/-0; statistics: 132 rows; purged from log: 0
5|nightly_maintenance|OK|overdue invoices: +0/-0; inactive cases: +0/-0; statistics: 132 rows; purged from log: 0
--- schedule restored
name|freq_type|freq_subday_type|active_start_time
----|---------|----------------|-----------------
noir_daily_0200|4|1|20000
```
<!-- /WYNIK -->

### 9.5 Uprawnienia

Testy uprawnień z sekcji 2.6 przepisano na T-SQL (procedura z parametrami `OUTPUT`, `DATEADD` zamiast dodawania do daty) i wykonano jako loginy `detective_app`, `accountant_app`, `client_portal`. Oczekiwane wyniki są identyczne z PostgreSQL: 67 z 67 testów zakończonych powodzeniem. Procedury wykonują się z uprawnieniami właściciela dzięki łańcuchowi własności, więc rola z samym `EXECUTE` zmienia dane, a bezpośredni dostęp do tabel pozostaje zamknięty.

<!-- TESTY results/mssql_permissions_output.txt -->
| Użytkownik | Polecenie | Oczekiwano | Wynik | Test |
|--------|----------------------------------|-----|-----|----|
| `detective_app` | `SELECT count(*) FROM noir.case_file` | OK | OK | PASS |
| `detective_app` | `INSERT INTO noir.witness (first_name,last_name,reliability) VALUES ('Test','Witness',3)` | OK | OK | PASS |
| `detective_app` | `SELECT * FROM noir.invoice` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM noir.v_invoice_balance` | DENIED | DENIED | PASS |
| `detective_app` | `DELETE FROM noir.evidence` | DENIED | DENIED | PASS |
| `detective_app` | `INSERT INTO noir.evidence_custody (evidence_id,transferred_at,detective_id,note) VALUES (1,SYSDATETIME(),1,'Test')` | OK | OK | PASS |
| `detective_app` | `UPDATE noir.evidence_custody SET note = 'zmiana'` | DENIED | DENIED | PASS |
| `detective_app` | `DELETE FROM noir.evidence_custody` | DENIED | DENIED | PASS |
| `detective_app` | `INSERT INTO noir.location (approximate_lat,approximate_lon) VALUES (0,0)` | OK | OK | PASS |
| `detective_app` | `DELETE FROM noir.case_suspect` | OK | OK | PASS |
| `detective_app` | `DELETE FROM noir.case_file` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.v_invoice_balance` | OK | OK | PASS |
| `accountant_app` | `SELECT * FROM noir.case_file` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.suspect` | DENIED | DENIED | PASS |
| `accountant_app` | `INSERT INTO noir.payment (invoice_id,method_id,paid_on,amount) VALUES (6,2,CAST(SYSDATETIME() AS DATE),100)` | OK | OK | PASS |
| `accountant_app` | `SELECT * FROM noir.payment` | OK | OK | PASS |
| `accountant_app` | `SELECT case_id, case_number, fee_estimate FROM noir.case_file` | OK | OK | PASS |
| `accountant_app` | `INSERT INTO noir.invoice (invoice_number,case_id,issued_on,due_on,amount) VALUES ('FV-TEST',1,CAST(SYSDATETIME() AS DATE),CAST(SYSDATETIME() AS DATE),100)` | OK | OK | PASS |
| `accountant_app` | `UPDATE noir.invoice SET due_on = DATEADD(DAY,14,due_on)` | OK | OK | PASS |
| `accountant_app` | `DELETE FROM noir.payment` | OK | OK | PASS |
| `accountant_app` | `DELETE FROM noir.invoice` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT description FROM noir.case_file` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.v_client_cases` | OK | OK | PASS |
| `client_portal` | `SELECT * FROM noir.case_file` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.v_case_overview` | DENIED | DENIED | PASS |
| `client_portal` | `INSERT INTO noir.client (first_name,last_name,email) VALUES ('a','b','c')` | DENIED | DENIED | PASS |
| `detective_app` | `INSERT INTO noir.case_detective (case_id,detective_id,role,assigned_on) VALUES (2,1,'ASSISTANT',CAST(SYSDATETIME() AS DATE))` | OK | OK | PASS |
| `detective_app` | `DELETE FROM noir.case_detective` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.v_evidence_chain` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.v_detective_workload` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.v_case_overview` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM noir.v_client_cases` | OK | OK | PASS |
| `client_portal` | `SELECT * FROM noir.v_invoice_balance` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.v_evidence_chain` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.v_detective_workload` | DENIED | DENIED | PASS |
| `detective_app` | `UPDATE noir.case_file SET fee_estimate = fee_estimate + 1` | OK | OK | PASS |
| `detective_app` | `UPDATE noir.informant SET trust_level = 3` | OK | OK | PASS |
| `accountant_app` | `UPDATE noir.payment SET amount = amount + 1 WHERE payment_id = 3` | OK | OK | PASS |
| `accountant_app` | `SELECT * FROM noir.payment_method` | OK | OK | PASS |
| `detective_app` | `SELECT * FROM noir.fn_case_timeline(3)` | OK | OK | PASS |
| `detective_app` | `DECLARE @n VARCHAR(20), @r VARCHAR(500); EXEC noir.sp_open_case 1,'Theft','x',NULL,1,1,@n OUTPUT,@r OUTPUT` | OK | OK | PASS |
| `detective_app` | `SELECT * FROM noir.v_stale_cases` | OK | OK | PASS |
| `detective_app` | `DECLARE @p INT, @d DATE = CAST(SYSDATETIME() AS DATE); EXEC noir.sp_register_payment 'INV-2025-0006','Cash',10,@d,@p OUTPUT` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM noir.v_case_financials` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM noir.v_client_balance` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM noir.alert` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM noir.job_run_log` | DENIED | DENIED | PASS |
| `detective_app` | `SELECT * FROM noir.document_counter` | DENIED | DENIED | PASS |
| `detective_app` | `EXEC noir.sp_nightly_maintenance` | DENIED | DENIED | PASS |
| `accountant_app` | `DECLARE @p INT, @d DATE = CAST(SYSDATETIME() AS DATE); EXEC noir.sp_register_payment 'INV-2025-0006','Cash',10,@d,@p OUTPUT` | OK | OK | PASS |
| `accountant_app` | `SELECT * FROM noir.v_case_financials` | OK | OK | PASS |
| `accountant_app` | `SELECT * FROM noir.v_client_balance` | OK | OK | PASS |
| `accountant_app` | `SELECT * FROM noir.monthly_case_stats` | OK | OK | PASS |
| `accountant_app` | `DECLARE @n VARCHAR(20), @r VARCHAR(500); EXEC noir.sp_open_case 1,'Theft','x',NULL,1,1,@n OUTPUT,@r OUTPUT` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.fn_case_timeline(3)` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.alert` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.v_stale_cases` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.case_status_history` | DENIED | DENIED | PASS |
| `accountant_app` | `EXEC noir.sp_nightly_maintenance` | DENIED | DENIED | PASS |
| `accountant_app` | `SELECT * FROM noir.document_counter` | DENIED | DENIED | PASS |
| `client_portal` | `DECLARE @n VARCHAR(20), @r VARCHAR(500); EXEC noir.sp_open_case 1,'Theft','x',NULL,1,1,@n OUTPUT,@r OUTPUT` | DENIED | DENIED | PASS |
| `client_portal` | `DECLARE @p INT, @d DATE = CAST(SYSDATETIME() AS DATE); EXEC noir.sp_register_payment 'INV-2025-0006','Cash',10,@d,@p OUTPUT` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.fn_case_timeline(3)` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.v_client_balance` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.monthly_case_stats` | DENIED | DENIED | PASS |
| `client_portal` | `SELECT * FROM noir.document_counter` | DENIED | DENIED | PASS |
| `accountant_app` | `INSERT INTO noir.payment (invoice_id,method_id,paid_on,amount) VALUES (1,2,CAST(SYSDATETIME() AS DATE),1)` | ERROR | ERROR | PASS |
<!-- /TESTY -->

### 9.6 Kopia zapasowa SQL Server

Kopię wykonano w modelu odtwarzania `FULL`: pełna (`BACKUP DATABASE ... WITH COMPRESSION, CHECKSUM`), po zmianie danych różnicowa (`DIFFERENTIAL`). Poprawność sprawdzono trzema sposobami: `RESTORE VERIFYONLY ... WITH CHECKSUM` (czytelność i suma kontrolna), odtworzeniem łańcucha (pełna `NORECOVERY` + różnicowa `RECOVERY`) do osobnej bazy `noir_restore` z porównaniem zawartości wszystkich tabel oraz testem awarii (usunięcie faktur i wpłat, odtworzenie bazy `WITH REPLACE` i ponowne porównanie). Loginy należą do serwera, nie do kopii bazy, dlatego przy odtwarzaniu na innym serwerze trzeba je odtworzyć osobno.

<!-- KOD sql/manual/mssql_30_backup.sql -->
```sql
USE noir;
GO
SET NOCOUNT ON;
PRINT '== 1. FULL recovery model and full backup (compression, checksum) ==';
ALTER DATABASE noir SET RECOVERY FULL;
BACKUP DATABASE noir TO DISK = '/var/opt/mssql/backup/noir_full.bak' WITH INIT, COMPRESSION, CHECKSUM, NAME = 'noir full';
GO
PRINT '== 2. Data change after the full backup, then a differential backup ==';
DELETE FROM noir.client WHERE email = 'backup.test@example.com';
INSERT INTO noir.client (first_name, last_name, email) VALUES ('Backup', 'Test', 'backup.test@example.com');
GO
BACKUP DATABASE noir TO DISK = '/var/opt/mssql/backup/noir_diff.bak' WITH INIT, DIFFERENTIAL, COMPRESSION, CHECKSUM, NAME = 'noir differential';
GO
PRINT '== 3. Backup verification without restoring (RESTORE VERIFYONLY checks the checksum and readability) ==';
RESTORE VERIFYONLY FROM DISK = '/var/opt/mssql/backup/noir_full.bak' WITH CHECKSUM;
RESTORE VERIFYONLY FROM DISK = '/var/opt/mssql/backup/noir_diff.bak' WITH CHECKSUM;
GO
PRINT '== 4. Files in the full backup and backup sets registered in msdb ==';
SELECT bf.logical_name, bf.file_type, bf.file_size, bf.backup_size
FROM msdb.dbo.backupfile bf JOIN msdb.dbo.backupset bs ON bs.backup_set_id = bf.backup_set_id
WHERE bs.database_name = 'noir' AND bs.type = 'D' ORDER BY bf.file_number;
SELECT bs.name, CASE bs.type WHEN 'D' THEN 'full' WHEN 'I' THEN 'differential' ELSE bs.type END AS backup_type,
       bs.backup_size, bs.compressed_backup_size, bs.has_backup_checksums, bs.recovery_model
FROM msdb.dbo.backupset bs WHERE bs.database_name = 'noir' ORDER BY bs.backup_finish_date;
GO
PRINT '== 5. Restore of the chain (full NORECOVERY + differential RECOVERY) into a separate database noir_restore ==';
IF DB_ID('noir_restore') IS NOT NULL DROP DATABASE noir_restore;
RESTORE DATABASE noir_restore FROM DISK = '/var/opt/mssql/backup/noir_full.bak'
    WITH MOVE 'noir' TO '/var/opt/mssql/data/noir_restore.mdf', MOVE 'noir_log' TO '/var/opt/mssql/data/noir_restore.ldf', NORECOVERY, STATS = 100;
RESTORE DATABASE noir_restore FROM DISK = '/var/opt/mssql/backup/noir_diff.bak' WITH RECOVERY, STATS = 100;
GO
SELECT (SELECT COUNT(*) FROM noir.client) AS clients_in_noir, (SELECT COUNT(*) FROM noir_restore.noir.client) AS clients_in_restore;
GO
```
<!-- /KOD -->

<!-- WYNIK results/mssql_backup_output.txt -->
```text
== 1. FULL recovery model and full backup (compression, checksum) ==
Processed 1208 pages for database 'noir', file 'noir' on file 1.
Processed 2 pages for database 'noir', file 'noir_log' on file 1.
BACKUP DATABASE successfully processed 1210 pages in 0.107 seconds (88.310 MB/sec).
== 2. Data change after the full backup, then a differential backup ==
Processed 136 pages for database 'noir', file 'noir' on file 1.
Processed 2 pages for database 'noir', file 'noir_log' on file 1.
BACKUP DATABASE WITH DIFFERENTIAL successfully processed 138 pages in 0.063 seconds (17.051 MB/sec).
== 3. Backup verification without restoring (RESTORE VERIFYONLY checks the checksum and readability) ==
The backup set on file 1 is valid.
The backup set on file 1 is valid.
== 4. Files in the full backup and backup sets registered in msdb ==
logical_name file_type file_size backup_size
------------ --------- --------- -----------
noir D 75497472 131072
noir_log L 8388608 12288
name backup_type backup_size compressed_backup_size has_backup_checksums recovery_model
---- ----------- ----------- ---------------------- -------------------- --------------
noir full full 11624448 811240 1 FULL
noir differential differential 2187264 133850 1 FULL
== 5. Restore of the chain (full NORECOVERY + differential RECOVERY) into a separate database noir_restore ==
100 percent processed.
Processed 1208 pages for database 'noir_restore', file 'noir' on file 1.
Processed 2 pages for database 'noir_restore', file 'noir_log' on file 1.
RESTORE DATABASE successfully processed 1210 pages in 0.278 seconds (33.989 MB/sec).
100 percent processed.
Processed 136 pages for database 'noir_restore', file 'noir' on file 1.
Processed 2 pages for database 'noir_restore', file 'noir_log' on file 1.
RESTORE DATABASE successfully processed 138 pages in 0.101 seconds (10.635 MB/sec).
clients_in_noir clients_in_restore
--------------- ------------------
7 7
== 6. Content comparison: table fingerprints of noir and noir_restore ==
table                  rows       md5 noir                           md5 noir_restore                   match
alert                  5/5        feb8d837c6f92259b6a5b28e6dad7f0b   feb8d837c6f92259b6a5b28e6dad7f0b   YES
case_detective         14/14      12bd58cfb5f4b6aee75cad774625c3d0   12bd58cfb5f4b6aee75cad774625c3d0   YES
case_file              9/9        4921e3b40cfed5e3dfdc909c14c0f9a6   4921e3b40cfed5e3dfdc909c14c0f9a6   YES
case_status            5/5        41e630a1323fb4ee789dbb4fa884dd22   41e630a1323fb4ee789dbb4fa884dd22   YES
case_status_history    15/15      1c19b550d29e21b900bc9acdb83e9bed   1c19b550d29e21b900bc9acdb83e9bed   YES
case_suspect           11/11      b9964d63964147168f5fb22e02079a85   b9964d63964147168f5fb22e02079a85   YES
case_type              6/6        52e6505e2d47cd8b4c89148e9d04667f   52e6505e2d47cd8b4c89148e9d04667f   YES
case_witness           7/7        eaff4fb751bd00248a4b4bd022388830   eaff4fb751bd00248a4b4bd022388830   YES
client                 7/7        b4f32d3dc548056ba97f252649c01cf6   b4f32d3dc548056ba97f252649c01cf6   YES
detective              6/6        1675391c57f6c973ea9e130de0bfb508   1675391c57f6c973ea9e130de0bfb508   YES
detective_rank         4/4        d61310c6a857c684d59d68506986a6ee   d61310c6a857c684d59d68506986a6ee   YES
document_counter       4/4        e9ea2d29e96452b32454682eda1e12ba   e9ea2d29e96452b32454682eda1e12ba   YES
evidence               9/9        fd5aff1015296f1820caa98f3b43ba69   fd5aff1015296f1820caa98f3b43ba69   YES
evidence_custody       9/9        e74bd425ae556de552d31a9919f747cc   e74bd425ae556de552d31a9919f747cc   YES
evidence_type          6/6        8ebbda3b615945e1df9c948b88451f7e   8ebbda3b615945e1df9c948b88451f7e   YES
informant              4/4        989c32c027e6993ffba5bc5f9b1a866d   989c32c027e6993ffba5bc5f9b1a866d   YES
invoice                6/6        cd1c954bd4d7f0c26adc2dc9d6ec5715   cd1c954bd4d7f0c26adc2dc9d6ec5715   YES
job_run_log            5/5        6b3e43a880798e3114c75332802eb1f9   6b3e43a880798e3114c75332802eb1f9   YES
location               6/6        4142cb151524efeb76b2d3c605b9469e   4142cb151524efeb76b2d3c605b9469e   YES
monthly_case_stats     132/132    69ed0da62bfd9f1b15b1d768135f3d21   69ed0da62bfd9f1b15b1d768135f3d21   YES
operation_log          5/5        bf1913fdbd20ae810f328f68b365748f   bf1913fdbd20ae810f328f68b365748f   YES
partner_agency         0/0        d41d8cd98f00b204e9800998ecf8427e   d41d8cd98f00b204e9800998ecf8427e   YES
payment                8/8        372ac1b962da7ecf0152f09396a91e33   372ac1b962da7ecf0152f09396a91e33   YES
payment_method         4/4        9869bed77cbe7795c6785f37a0ebc33f   9869bed77cbe7795c6785f37a0ebc33f   YES
suspect                6/6        a747e261a59d5bcc470ae6e895e9ad96   a747e261a59d5bcc470ae6e895e9ad96   YES
tip                    5/5        0b79e1a3254f83f2246dd2a9878105e2   0b79e1a3254f83f2246dd2a9878105e2   YES
witness                5/5        0aa0d99553afcfd741726a5244cbb935   0aa0d99553afcfd741726a5244cbb935   YES
RESULT: content identical in all tables
== 7. Failure test: deleting financial data in noir and restoring the database from the backup (WITH REPLACE) ==
invoices after failure: 0
invoices after restore: 6, payments: 8
RESULT: after the restore the content matches the backup
```
<!-- /WYNIK -->

### 9.7 Porównanie z PostgreSQL

| Funkcjonalność | PostgreSQL | SQL Server |
|-------------------------|--------------------------|--------------------------|
| Funkcja użytkownika | Zwraca oś czasu sprawy. | Zwraca ten sam wynik; jedyna różnica polega na tym, że wywołujący sam sortuje oś czasu. |
| Procedura z transakcją | Wycofuje zmiany dzięki podtransakcji w bloku `EXCEPTION`. | Wycofuje zmiany instrukcją `ROLLBACK` w bloku `TRY ... CATCH`; z zewnątrz działa tak samo. |
| Wyzwalacz kontrolujący wpłaty | Uruchamia się przed zapisem każdego wiersza (`BEFORE`). | Uruchamia się po wykonaniu całej instrukcji (`AFTER`) i odrzuca te same wpłaty. |
| Zadanie nocne | Uruchamia je `pg_cron` według harmonogramu. | Uruchamia je SQL Server Agent, ręcznie i według harmonogramu; liczby w wynikach są takie same. |
| Kopia zapasowa | Wykonują ją `pg_dump` i `pg_basebackup`; odtworzenie zostało sprawdzone testem. | Wykonuje się kopię pełną i różnicową, sprawdza ją poleceniem `VERIFYONLY` i odtwarza w teście. |

## 10. Problemy napotkane przy migracji i porcie oraz ich rozwiązania

| Dotyczy | Problem | Przyczyna | Rozwiązanie |
|--------------|------------------------|--------------------------|--------------------------------------------------|
| SQL Server (`BULK INSERT`) | `BULK INSERT` odrzuca opcję `CODEPAGE` (błąd 16202) | opcja nie jest obsługiwana na platformie Linux | plik CSV w UTF-8 i baza z sortowaniem UTF-8 zamiast jawnej strony kodowej |
| PostgreSQL → SQL Server (`BULK INSERT`) | Błąd konwersji kolumny `BIT` przy `BULK INSERT` | PostgreSQL eksportuje `t`/`f` | eksport kolumn logicznych jako 0/1 |
| Apache Hop | Apache Hop: nie znaleziono sterownika `net.sourceforge.jtds.jdbc.Driver` | typ połączenia „MS SQL Server" używa sterownika jTDS, którego obraz nie zawiera | typ połączenia `MS SQL Server (Native)` (sterownik Microsoft JDBC) |
| Apache Hop | Apache Hop: błąd szyfrowanego połączenia z SQL Server | sterownik Microsoft domyślnie wymaga zaufanego certyfikatu | adres JDBC z `encrypt=true;trustServerCertificate=true` |
| Apache Hop | Apache Hop: `Conversion failed when converting the nvarchar value 'Y' to data type bit` | Hop zapisuje wartość logiczną do systemu bez typu `BOOLEAN` jako tekst `Y`/`N` | zapytanie `Table input` zamienia kolumny logiczne na 0/1 |
| Apache Hop + SQL Server | Brak możliwości wstawienia jawnych kluczy `IDENTITY` przez Hop | `Table output` nie ustawia `IDENTITY_INSERT` | utworzono schemat pośredni `stg` bez `IDENTITY` i przeniesienie skryptem T-SQL z `IDENTITY_INSERT ON` |
| SQL Server + `sqlcmd` | `INSERT` do tabeli z indeksem filtrowanym kończy się błędem w sesji `sqlcmd` | indeks filtrowany wymaga `QUOTED_IDENTIFIER ON`, a `sqlcmd` domyślnie ma `OFF` | `sqlcmd -I`; opcję trzeba ustawić we wszystkich klientach |
| SQL Server (wyzwalacze) | Wyzwalacze nie mogą być typu `BEFORE` | SQL Server ma tylko `AFTER` i `INSTEAD OF` | walidacja po zdarzeniu z `ROLLBACK` + `THROW` |
| SQL Server (T-SQL) | Błąd 8711 przy `COALESCE(STRING_AGG(...) WITHIN GROUP (...), '')` | `COALESCE` rozwija się do wyrażenia `CASE`, w którym agregat uporządkowany występuje dwukrotnie | `ISNULL` w miejsce `COALESCE` |
| SQL Server (T-SQL) | `THROW` nie przyjmuje wyrażeń jako komunikatu | składnia `THROW` dopuszcza tylko literał lub zmienną | komunikat budowany funkcją `CONCAT`, zapisywany w zmiennej i dopiero ta zmienna przekazywana do `THROW` |
| SQL Server (uprawnienia) | `GRANT SELECT ON a, b` odrzucone | `GRANT` przyjmuje jeden obiekt | osobna instrukcja na obiekt |
| SQL Server (uprawnienia) | `CREATE LOGIN` odrzucone dla `noir_admin` | loginy są obiektami serwera | wykonanie skryptu ról przez administratora systemu |
| SQL Server + `sqlcmd` | Tabele utworzone w schemacie `dbo` zamiast `noir` | domyślnym schematem administratora systemu jest `dbo` | skrypty bazy wykonuje `noir_admin` z domyślnym schematem `noir` |
| SQL Server w Dockerze (kopie zapasowe) | `BACKUP DATABASE` kończy się błędem 3201 (brak dostępu) | wolumen kopii należy do `root`, a SQL Server działa jako `mssql` | zmiana właściciela katalogu kopii na `mssql` |
| `sqlcmd` (skrypty powłoki) | `sqlcmd` w pętli czyta listę tabel ze standardowego wejścia | `sqlcmd` pobiera dane ze stdin przekierowanego do pętli | przekierowanie `< /dev/null` w wywołaniu |
| `sqlcmd` (wyświetlanie) | Wyniki `sqlcmd` pokazują `.00` zamiast `0.00` | sposób wypisywania liczb dziesiętnych przez `sqlcmd` | tylko formatowanie wyświetlania; wartości w bazie są poprawne |

## 11. Połączenie baz i synchronizacja danych (zawartość dodatkowa)

Ta część to zadanie dodatkowe. Wymaga trzech rzeczy:

1. Skonfigurowania połączenia bazodanowgo między dwoma SZBD.
2. Wykorzystania harmonogramu zadań, aby automatycznie synchronizować dane między tymi systemami.
3. Pokazania, że synchronizacja działa po wprowadzeniu zmian w obu systemach.

Celem jest to, aby dwie osobne bazy, w których użytkownicy zmieniają dane niezależnie, po pewnym czasie zawierały te same informacje. Bez synchronizacji każda baza zawierałaby tylko własne zmiany i oba biura widziałyby różne dane.

### 11.1 Założenia

Oba systemy działają równolegle i w obu można zmieniać dane. Do pokazu demonstracji wykorzystano rejestr agencji partnerskich. Agencja partnerska to zewnętrzne biuro detektywistyczne, z którym współpracują oba biura, na przykład przy sprawach prowadzonych w innym mieście. Rejestr to lista takich agencji. Każda agencja ma w nim jeden wiersz z kodem (np. `WAW`), nazwą, miastem, telefonem i znacznikiem, czy współpraca trwa. Obie strony potrzebują tej samej listy, a każda może ją uzupełniać i poprawiać. Rejestr nie ma powiązań z resztą schematu, dlatego synchronizacja nie dotyka innych tabel.

Tabela `partner_agency` jest 27. tabelą bazy. Istnieje w obu systemach, ale nie jest przenoszona w migracji z sekcji 8, ponieważ wypełnia ją dopiero synchronizacja. Ma kolumnę `updated_at` z czasem ostatniej zmiany wiersza w UTC. Synchronizacja stosuje cztery zasady:

- Gdy ta sama agencja (ten sam kod) różni się w obu systemach, zostaje wersja z późniejszym `updated_at`. Wiersze z równym czasem są identyczne, więc synchronizacja je pomija.
- Zmianę wprowadzoną przez użytkownika oznacza bieżącym czasem wyzwalacz (`BEFORE UPDATE` w PostgreSQL, `AFTER UPDATE` w SQL Server). Synchronizacja zapisuje zmianę z czasem wiersza źródłowego. Dzięki temu drugi system nie uznaje jej za nową zmianę i nie odsyła jej z powrotem, więc synchronizacja się nie zapętla.
- Rekordów się nie usuwa. Wycofaną agencję oznacza się przez `is_active = 0`. To także zwykła zmiana, więc również podlega synchronizacji.
- Oba systemy korzystają z jednego zegara, bo kontenery działają na jednym hoście. Gdyby systemy działały na osobnych serwerach, trzeba by zsynchronizować ich zegary, ponieważ od nich zależy rozstrzyganie konfliktów.

### 11.2 Połączenie (database link) i harmonogram

Połączenie z PostgreSQL do SQL Server zapewnia rozszerzenie `tds_fdw`. Tworzą je trzy elementy: serwer zewnętrzny `mssql_noir`, mapowanie użytkownika na login `sync_link` w SQL Server oraz tabele zewnętrzne. Login `sync_link` ma minimalne uprawnienia: `SELECT` na rejestrze i `EXECUTE` na jednej procedurze.

Rozszerzenie `tds_fdw` potrafi tylko czytać dane, dlatego odczyt i zapis wykonuje się na dwa sposoby:

- Odczyt to zwykłe zapytanie do tabeli zewnętrznej. Czas zmiany wiersza jest przesyłany jako tekst w formacie ISO 8601, bo rozszerzenie nie obsługuje typów daty i czasu z SQL Server.
- Zapis to wywołanie procedury `sp_apply_partner_agency` w SQL Server. Tabela zewnętrzna `mssql_call` dostaje tekst zapytania `EXEC ...`, a jej odczyt uruchamia tę procedurę po stronie SQL Server. Procedura zapisuje wiersz tylko wtedy, gdy jest nowszy od istniejącego albo gdy jeszcze go nie ma (instrukcja `MERGE`). Powtórne wywołanie z tymi samymi danymi niczego więc nie zmienia.

Jeden przebieg synchronizacji wykonuje procedura `sp_sync_partner_agency` w PostgreSQL. Robi to w trzech krokach:

1. Pobiera cały rejestr z SQL Server jednym zapytaniem.
2. Zapisuje w PostgreSQL wiersze, których tu brakuje albo które są nowsze w SQL Server (`INSERT ... ON CONFLICT DO UPDATE ... WHERE`).
3. Wysyła do SQL Server wiersze, których tam brakuje albo które są nowsze w PostgreSQL.

Wynik przebiegu trafia do tabeli `job_run_log`. Gdy SQL Server jest niedostępny, przebieg kończy się wpisem `ERROR`, ale harmonogram nie zostaje zatrzymany. Następny przebieg nadrabia zmiany. Harmonogram obsługuje `pg_cron`: zadanie `noir_partner_sync` uruchamia się co 5 minut. Na czas pokazu skrócono ten odstęp do 10 sekund. Zadanie jest nieaktywne, dopóki ktoś nie włączy połączenia.

Kod po stronie PostgreSQL:

<!-- KOD sql/pg/13_sync.sql -->
```sql
SET search_path = noir;

-- Database link to SQL Server (tds_fdw) and two-way synchronization of the partner agency register.
-- The register is kept in both systems; every row carries the time of its last change (UTC), and the newer version wins.
CREATE TABLE partner_agency (
    agency_code VARCHAR(10)  NOT NULL,
    name        VARCHAR(100) NOT NULL,
    city        VARCHAR(60)  NOT NULL,
    phone       VARCHAR(20),
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    updated_at  TIMESTAMP(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'UTC'),
    CONSTRAINT pk_partner_agency PRIMARY KEY (agency_code)
);

-- A change made by a user gets the current time; a change made by the synchronization carries the time of the source row,
-- so it is not treated as a new change and does not return to the other system.
CREATE FUNCTION fn_trg_partner_agency_touch() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at THEN
        NEW.updated_at := CURRENT_TIMESTAMP AT TIME ZONE 'UTC';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_partner_agency_touch BEFORE UPDATE ON partner_agency
    FOR EACH ROW EXECUTE FUNCTION fn_trg_partner_agency_touch();

-- Database link: foreign server and a user mapped to a SQL Server login with rights to this one table only
CREATE EXTENSION IF NOT EXISTS tds_fdw;
CREATE SERVER mssql_noir FOREIGN DATA WRAPPER tds_fdw
    OPTIONS (servername 'mssql', port '1433', database 'noir', tds_version '7.4', msg_handler 'notice');
CREATE USER MAPPING FOR noir_admin SERVER mssql_noir OPTIONS (username 'sync_link', password 'Agency_Link_pw1');
CREATE FOREIGN TABLE mssql_partner_agency (
    agency_code VARCHAR(10) OPTIONS (key 'true') NOT NULL,
    name        VARCHAR(100) NOT NULL,
    city        VARCHAR(60)  NOT NULL,
    phone       VARCHAR(20),
    is_active   BOOLEAN      NOT NULL,
    updated_at  VARCHAR(30)  NOT NULL
) SERVER mssql_noir OPTIONS (query 'SELECT agency_code, name, city, phone, is_active, CONVERT(VARCHAR(30), updated_at, 126) AS updated_at FROM noir.partner_agency');
-- the wrapper does not parse SQL Server date and time values, so the time is passed as ISO 8601 text and converted here

-- The wrapper is read-only, so rows are written to SQL Server by calling a procedure there: a foreign table with a fixed
-- "query" option is re-pointed to the T-SQL batch to run, and reading it executes the batch on SQL Server
-- (the wrapper reads the first result set, which the procedure returns as one confirmation row).
CREATE FOREIGN TABLE mssql_call (done INTEGER) SERVER mssql_noir OPTIONS (query 'SELECT 1 AS done');

-- T-SQL string literal (Unicode) or NULL
CREATE FUNCTION fn_tsql_str(p_value TEXT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE('N''' || REPLACE(p_value, '''', '''''') || '''', 'NULL')
$$;

CREATE FUNCTION fn_mssql_apply_partner_agency(p_row partner_agency) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = noir AS $$
BEGIN
    EXECUTE format('ALTER FOREIGN TABLE mssql_call OPTIONS (SET query %L)',
        'EXEC noir.sp_apply_partner_agency @agency_code = ' || fn_tsql_str(p_row.agency_code)
        || ', @name = ' || fn_tsql_str(p_row.name) || ', @city = ' || fn_tsql_str(p_row.city)
        || ', @phone = ' || fn_tsql_str(p_row.phone) || ', @is_active = ' || CASE WHEN p_row.is_active THEN 1 ELSE 0 END
        || ', @updated_at = ''' || TO_CHAR(p_row.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS.MS') || '''');
    PERFORM * FROM mssql_call;
END $$;

-- Synchronization: one pass in both directions, result in job_run_log.
--  1. read the SQL Server register once (a single remote query),
--  2. rows missing locally or newer in SQL Server are written here,
--  3. rows missing in SQL Server or newer here are written to SQL Server (through the procedure on the SQL Server side).
-- Rows with equal time are identical and are skipped. Records are not deleted: a withdrawn agency gets is_active = FALSE.
-- A failure (e.g. SQL Server unavailable) is recorded in the log and the next run tries again.
CREATE PROCEDURE sp_sync_partner_agency()
LANGUAGE plpgsql SECURITY DEFINER SET search_path = noir AS $$
DECLARE v_run INTEGER; v_pulled INTEGER; v_pushed_new INTEGER; v_pushed_upd INTEGER; r partner_agency%ROWTYPE;
BEGIN
    INSERT INTO job_run_log (job_name, started_at, status) VALUES ('partner_sync', CURRENT_TIMESTAMP, 'RUNNING')
    RETURNING run_id INTO v_run;
    BEGIN
        CREATE TEMP TABLE remote_snapshot ON COMMIT DROP AS
            SELECT agency_code, name, city, phone, is_active, updated_at::TIMESTAMP(3) AS updated_at FROM mssql_partner_agency;

        -- from SQL Server to PostgreSQL
        INSERT INTO partner_agency AS l (agency_code, name, city, phone, is_active, updated_at)
        SELECT agency_code, name, city, phone, is_active, updated_at FROM remote_snapshot
        ON CONFLICT (agency_code) DO UPDATE
            SET name = EXCLUDED.name, city = EXCLUDED.city, phone = EXCLUDED.phone,
                is_active = EXCLUDED.is_active, updated_at = EXCLUDED.updated_at
            WHERE EXCLUDED.updated_at > l.updated_at;
        GET DIAGNOSTICS v_pulled = ROW_COUNT;

        -- from PostgreSQL to SQL Server (only rows that were not just taken from there)
        v_pushed_new := 0; v_pushed_upd := 0;
        FOR r IN SELECT l.* FROM partner_agency l LEFT JOIN remote_snapshot s ON s.agency_code = l.agency_code
                 WHERE s.agency_code IS NULL OR l.updated_at > s.updated_at
        LOOP
            PERFORM fn_mssql_apply_partner_agency(r);
            IF EXISTS (SELECT 1 FROM remote_snapshot s WHERE s.agency_code = r.agency_code) THEN
                v_pushed_upd := v_pushed_upd + 1;
            ELSE
                v_pushed_new := v_pushed_new + 1;
            END IF;
        END LOOP;

        UPDATE job_run_log SET finished_at = CURRENT_TIMESTAMP, status = 'OK',
               details = 'from SQL Server: ' || v_pulled || ', to SQL Server: ' || v_pushed_new || ' new, ' || v_pushed_upd || ' changed'
        WHERE run_id = v_run;
    EXCEPTION WHEN OTHERS THEN
        UPDATE job_run_log SET finished_at = CURRENT_TIMESTAMP, status = 'ERROR', details = LEFT(SQLERRM, 500) WHERE run_id = v_run;
    END;
END $$;

-- Automation: pg_cron job every 5 minutes (inactive until the link is configured on the SQL Server side)
\connect postgres
SELECT cron.alter_job(cron.schedule_in_database('noir_partner_sync', '*/5 * * * *', 'CALL noir.sp_sync_partner_agency()', 'noir'), active := false);
\connect noir
```
<!-- /KOD -->

Kod po stronie SQL Server (tabela, wyzwalacz, procedura wejściowa i login połączenia):

<!-- KOD sql/mssql/13_sync.sql -->
```sql
-- Run as sa: partner agency register synchronized with PostgreSQL (the database link and the schedule are on the PostgreSQL side)
USE noir;
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
CREATE TABLE noir.partner_agency (
    agency_code VARCHAR(10)  NOT NULL,
    name        VARCHAR(100) NOT NULL,
    city        VARCHAR(60)  NOT NULL,
    phone       VARCHAR(20),
    is_active   BIT          NOT NULL CONSTRAINT df_partner_agency_active DEFAULT 1,
    updated_at  DATETIME2(3) NOT NULL CONSTRAINT df_partner_agency_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_partner_agency PRIMARY KEY (agency_code)
);
GO
-- A change made by a user gets the current time; a change made by the synchronization sets updated_at itself, so it is kept.
CREATE TRIGGER noir.trg_partner_agency_touch ON noir.partner_agency AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(updated_at)
        UPDATE a SET updated_at = SYSUTCDATETIME() FROM noir.partner_agency a JOIN inserted i ON i.agency_code = a.agency_code;
END;
GO
-- Entry point for the database link: stores a row received from PostgreSQL if it is newer than the local one (or missing);
-- repeating the call with the same data changes nothing.
CREATE PROCEDURE noir.sp_apply_partner_agency
    @agency_code VARCHAR(10), @name VARCHAR(100), @city VARCHAR(60), @phone VARCHAR(20), @is_active BIT, @updated_at DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    MERGE noir.partner_agency AS t
    USING (SELECT @agency_code AS agency_code) AS s ON t.agency_code = s.agency_code
    WHEN MATCHED AND @updated_at > t.updated_at THEN
        UPDATE SET name = @name, city = @city, phone = @phone, is_active = @is_active, updated_at = @updated_at
    WHEN NOT MATCHED THEN
        INSERT (agency_code, name, city, phone, is_active, updated_at) VALUES (@agency_code, @name, @city, @phone, @is_active, @updated_at);
    SELECT 1 AS done;   -- the result row confirms to the caller that the batch was run
END;
GO
-- Login used by the database link: it can read the register and call the procedure above, nothing else
IF SUSER_ID('sync_link') IS NULL CREATE LOGIN sync_link WITH PASSWORD = 'Agency_Link_pw1', DEFAULT_DATABASE = noir, CHECK_POLICY = ON;
IF USER_ID('sync_link') IS NULL CREATE USER sync_link FOR LOGIN sync_link;
GRANT SELECT ON noir.partner_agency TO sync_link;
GRANT EXECUTE ON noir.sp_apply_partner_agency TO sync_link;
GO
```
<!-- /KOD -->

### 11.3 Działanie

Pokaz składa się z ośmiu kroków:

1. Sprawdzenie połączenia z SQL Server.
2. Sprawdzenie harmonogramu i skrócenie go do 10 sekund.
3. Dodanie rekordów w obu systemach.
4. Zmiana rekordów po obu stronach, w tym wycofanie agencji.
5. Konflikt: ta sama agencja zmieniona w obu systemach.
6. Odczyt dziennika przebiegów.
7. Wyłączenie SQL Server, a po jego powrocie nadrobienie zmian.
8. Przywrócenie harmonogramu co 5 minut.

Skrypt pokazu:

<!-- KOD sql/manual/25_sync_demo.sh od="pg()" -->
```bash
pg()   { docker compose exec -T pg psql -U noir_admin -d noir -X -q "$@" 2>&1 | grep -v -e "^NOTICE:  DB-Library" -e "^NOTICE:  tds_fdw" -e "^WARNING:  Table definition mismatch"; }
pgc()  { docker compose exec -T pg psql -U noir_admin -d postgres -X -q "$@"; }
ms()   { docker compose exec -T mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U noir_admin -P Noir_Admin_pw1 -d noir -I -W -s "|" -Q "SET NOCOUNT ON; $1"; }
SHOW_PG="SELECT agency_code, name, city, phone, is_active, updated_at FROM noir.partner_agency ORDER BY agency_code"
SHOW_MS="SELECT agency_code, name, city, phone, is_active, updated_at FROM noir.partner_agency ORDER BY agency_code"
both() { echo "PostgreSQL:"; pg -c "$SHOW_PG"; echo "SQL Server:"; ms "$SHOW_MS"; }
wait_cycles() { sleep 25; }

echo "--- 1. Polaczenie (link) z PostgreSQL do SQL Server: tabela zewnetrzna widzi rejestr w SQL Server"
pg -c "SELECT srvname, srvoptions FROM pg_foreign_server" -c "SELECT COUNT(*) AS wierszy_w_sql_server FROM noir.mssql_partner_agency"
echo "--- 2. Harmonogram pg_cron (zadanie nieaktywne do czasu uruchomienia) - na czas pokazu co 10 sekund"
pgc -c "SELECT jobid, jobname, schedule, database, command, active FROM cron.job WHERE jobname = 'noir_partner_sync'"
pgc -qAt -c "SELECT cron.alter_job(jobid, schedule := '10 seconds', active := true) FROM cron.job WHERE jobname = 'noir_partner_sync'" >/dev/null

echo "--- 3. Zmiany w obu systemach: PostgreSQL dodaje WAW i KRK, SQL Server dodaje BER"
pg -c "INSERT INTO noir.partner_agency (agency_code, name, city, phone) VALUES ('WAW', 'Warszawska Agencja Detektywow', 'Warszawa', '+48 22 555 01 01'), ('KRK', 'Krakowskie Biuro Sledcze', 'Krakow', '+48 12 555 02 02')"
ms "INSERT INTO noir.partner_agency (agency_code, name, city, phone) VALUES ('BER', N'Berliner Detektei', 'Berlin', '+49 30 555 03 03')"
echo "przed synchronizacja:"; both
wait_cycles
echo "po synchronizacji (pg_cron):"; both

echo "--- 4. Modyfikacje: PostgreSQL zmienia telefon WAW, SQL Server zmienia miasto KRK i wycofuje BER"
pg -c "UPDATE noir.partner_agency SET phone = '+48 22 555 99 99' WHERE agency_code = 'WAW'"
ms "UPDATE noir.partner_agency SET city = 'Krakow-Nowa Huta' WHERE agency_code = 'KRK'; UPDATE noir.partner_agency SET is_active = 0 WHERE agency_code = 'BER'"
wait_cycles
echo "po synchronizacji:"; both

echo "--- 5. Konflikt: ta sama agencja (WAW) zmieniona w obu systemach, pozniejsza zmiana (SQL Server) wygrywa"
pg -c "UPDATE noir.partner_agency SET name = 'WAW - wersja z PostgreSQL' WHERE agency_code = 'WAW'"
sleep 2
ms "UPDATE noir.partner_agency SET name = N'WAW - wersja z SQL Server' WHERE agency_code = 'WAW'"
wait_cycles
echo "po synchronizacji:"; both

echo "--- 6. Dziennik synchronizacji (job_run_log) i historia pg_cron"
pg -c "SELECT status, COUNT(*) AS przebiegow FROM noir.job_run_log WHERE job_name = 'partner_sync' GROUP BY status"
pg -c "SELECT run_id, status, details FROM noir.job_run_log WHERE job_name = 'partner_sync' AND details NOT LIKE 'from SQL Server: 0, to SQL Server: 0 new, 0 changed' ORDER BY run_id"
pgc -c "SELECT status, COUNT(*) AS przebiegow FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE j.jobname = 'noir_partner_sync' GROUP BY status"

echo "--- 7. Awaria SQL Server: przebieg konczy sie wpisem ERROR, po powrocie synchronizacja nadrabia zmiany"
docker compose stop mssql >/dev/null 2>&1
pg -c "UPDATE noir.partner_agency SET phone = '+48 12 555 77 77' WHERE agency_code = 'KRK'"
sleep 15
pg -c "SELECT status, LEFT(details, 90) AS details FROM noir.job_run_log WHERE job_name = 'partner_sync' ORDER BY run_id DESC LIMIT 1"
docker compose start mssql >/dev/null 2>&1
until [ "$(docker inspect -f '{{.State.Health.Status}}' noir2_mssql)" = healthy ]; do sleep 3; done
sleep 25
echo "po powrocie SQL Server:"; both

echo "--- 8. Przywrocenie harmonogramu (co 5 minut, zadanie nieaktywne)"
pgc -qAt -c "SELECT cron.alter_job(jobid, schedule := '*/5 * * * *', active := false) FROM cron.job WHERE jobname = 'noir_partner_sync'" >/dev/null
pgc -c "SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'noir_partner_sync'"
```
<!-- /KOD -->

Wynik (czas `updated_at` w UTC):

<!-- WYNIK results/sync_demo.txt -->
```text
--- 1. Polaczenie (link) z PostgreSQL do SQL Server: tabela zewnetrzna widzi rejestr w SQL Server
  srvname   |                                  srvoptions
------------+-------------------------------------------------------------------------------
 mssql_noir | {servername=mssql,port=1433,database=noir,tds_version=7.4,msg_handler=notice}

 wierszy_w_sql_server
----------------------
                    0

--- 2. Harmonogram pg_cron (zadanie nieaktywne do czasu uruchomienia) - na czas pokazu co 10 sekund
 jobid |      jobname      |  schedule   | database |              command               | active
-------+-------------------+-------------+----------+------------------------------------+--------
     2 | noir_partner_sync | */5 * * * * | noir     | CALL noir.sp_sync_partner_agency() | f

--- 3. Zmiany w obu systemach: PostgreSQL dodaje WAW i KRK, SQL Server dodaje BER
przed synchronizacja:
PostgreSQL:
 agency_code |             name              |   city   |      phone       | is_active |       updated_at
-------------+-------------------------------+----------+------------------+-----------+-------------------------
 KRK         | Krakowskie Biuro Sledcze      | Krakow   | +48 12 555 02 02 | t         | 2026-10-17 15:47:59.331
 WAW         | Warszawska Agencja Detektywow | Warszawa | +48 22 555 01 01 | t         | 2026-10-17 15:47:59.331

SQL Server:
agency_code|name|city|phone|is_active|updated_at
-----------|----|----|-----|---------|----------
BER|Berliner Detektei|Berlin|+49 30 555 03 03|1|2026-10-17 15:47:59.419
po synchronizacji (pg_cron):
PostgreSQL:
 agency_code |             name              |   city   |      phone       | is_active |       updated_at
-------------+-------------------------------+----------+------------------+-----------+-------------------------
 BER         | Berliner Detektei             | Berlin   | +49 30 555 03 03 | t         | 2026-10-17 15:47:59.419
 KRK         | Krakowskie Biuro Sledcze      | Krakow   | +48 12 555 02 02 | t         | 2026-10-17 15:47:59.331
 WAW         | Warszawska Agencja Detektywow | Warszawa | +48 22 555 01 01 | t         | 2026-10-17 15:47:59.331

SQL Server:
agency_code|name|city|phone|is_active|updated_at
-----------|----|----|-----|---------|----------
BER|Berliner Detektei|Berlin|+49 30 555 03 03|1|2026-10-17 15:47:59.419
KRK|Krakowskie Biuro Sledcze|Krakow|+48 12 555 02 02|1|2026-10-17 15:47:59.331
WAW|Warszawska Agencja Detektywow|Warszawa|+48 22 555 01 01|1|2026-10-17 15:47:59.331
--- 4. Modyfikacje: PostgreSQL zmienia telefon WAW, SQL Server zmienia miasto KRK i wycofuje BER
po synchronizacji:
PostgreSQL:
 agency_code |             name              |       city       |      phone       | is_active |       updated_at
-------------+-------------------------------+------------------+------------------+-----------+-------------------------
 BER         | Berliner Detektei             | Berlin           | +49 30 555 03 03 | f         | 2026-10-17 15:48:25.02
 KRK         | Krakowskie Biuro Sledcze      | Krakow-Nowa Huta | +48 12 555 02 02 | t         | 2026-10-17 15:48:25.02
 WAW         | Warszawska Agencja Detektywow | Warszawa         | +48 22 555 99 99 | t         | 2026-10-17 15:48:24.918

SQL Server:
agency_code|name|city|phone|is_active|updated_at
-----------|----|----|-----|---------|----------
BER|Berliner Detektei|Berlin|+49 30 555 03 03|0|2026-10-17 15:48:25.020
KRK|Krakowskie Biuro Sledcze|Krakow-Nowa Huta|+48 12 555 02 02|1|2026-10-17 15:48:25.020
WAW|Warszawska Agencja Detektywow|Warszawa|+48 22 555 99 99|1|2026-10-17 15:48:24.918
--- 5. Konflikt: ta sama agencja (WAW) zmieniona w obu systemach, pozniejsza zmiana (SQL Server) wygrywa
po synchronizacji:
PostgreSQL:
 agency_code |           name            |       city       |      phone       | is_active |       updated_at
-------------+---------------------------+------------------+------------------+-----------+-------------------------
 BER         | Berliner Detektei         | Berlin           | +49 30 555 03 03 | f         | 2026-10-17 15:48:25.02
 KRK         | Krakowskie Biuro Sledcze  | Krakow-Nowa Huta | +48 12 555 02 02 | t         | 2026-10-17 15:48:25.02
 WAW         | WAW - wersja z SQL Server | Warszawa         | +48 22 555 99 99 | t         | 2026-10-17 15:48:52.432

SQL Server:
agency_code|name|city|phone|is_active|updated_at
-----------|----|----|-----|---------|----------
BER|Berliner Detektei|Berlin|+49 30 555 03 03|0|2026-10-17 15:48:25.020
KRK|Krakowskie Biuro Sledcze|Krakow-Nowa Huta|+48 12 555 02 02|1|2026-10-17 15:48:25.020
WAW|WAW - wersja z SQL Server|Warszawa|+48 22 555 99 99|1|2026-10-17 15:48:52.432
--- 6. Dziennik synchronizacji (job_run_log) i historia pg_cron
 status | przebiegow
--------+------------
 OK     |          7

 run_id | status |                       details
--------+--------+-----------------------------------------------------
      5 | OK     | from SQL Server: 1, to SQL Server: 2 new, 0 changed
      7 | OK     | from SQL Server: 2, to SQL Server: 0 new, 1 changed
     10 | OK     | from SQL Server: 1, to SQL Server: 0 new, 0 changed

  status   | przebiegow
-----------+------------
 succeeded |          7

--- 7. Awaria SQL Server: przebieg konczy sie wpisem ERROR, po powrocie synchronizacja nadrabia zmiany
 status |                                          details
--------+--------------------------------------------------------------------------------------------
 ERROR  | DB-Library error: DB #: 20013, DB Msg: Unknown host machine name (mssql), OS #: 0, OS Msg:

po powrocie SQL Server:
PostgreSQL:
 agency_code |           name            |       city       |      phone       | is_active |       updated_at
-------------+---------------------------+------------------+------------------+-----------+-------------------------
 BER         | Berliner Detektei         | Berlin           | +49 30 555 03 03 | f         | 2026-10-17 15:48:25.02
 KRK         | Krakowskie Biuro Sledcze  | Krakow-Nowa Huta | +48 12 555 77 77 | t         | 2026-10-17 15:49:28.682
 WAW         | WAW - wersja z SQL Server | Warszawa         | +48 22 555 99 99 | t         | 2026-10-17 15:48:52.432

SQL Server:
agency_code|name|city|phone|is_active|updated_at
-----------|----|----|-----|---------|----------
BER|Berliner Detektei|Berlin|+49 30 555 03 03|0|2026-10-17 15:48:25.020
KRK|Krakowskie Biuro Sledcze|Krakow-Nowa Huta|+48 12 555 77 77|1|2026-10-17 15:49:28.682
WAW|WAW - wersja z SQL Server|Warszawa|+48 22 555 99 99|1|2026-10-17 15:48:52.432
--- 8. Przywrocenie harmonogramu (co 5 minut, zadanie nieaktywne)
      jobname      |  schedule   | active
-------------------+-------------+--------
 noir_partner_sync | */5 * * * * | f
```
<!-- /WYNIK -->

Co pokazują wyniki:

- Krok 3: rekord dodany w jednym systemie pojawia się w drugim po przebiegu `pg_cron`.
- Krok 4: zmiany w obu kierunkach oraz wycofanie agencji trafiają do drugiego systemu.
- Krok 5: przy konflikcie wygrywa późniejsza zmiana, czyli ta z SQL Server. Wcześniejsza zmiana z PostgreSQL zostaje nadpisana w obu systemach.
- Krok 6: wszystkie przebiegi zakończyły się statusem `OK`.
- Krok 7: gdy SQL Server jest wyłączony, przebieg kończy się wpisem `ERROR`. Po jego ponownym uruchomieniu synchronizacja przenosi zmianę wykonaną podczas awarii.

Rozwiązanie ma cztery ograniczenia:

- Zmiana dociera do drugiego systemu z opóźnieniem.
- Konflikt rozstrzyga się dla całego wiersza. Jeśli w obu systemach zmieniono różne kolumny tej samej agencji, zostaje tylko jedna wersja wiersza.
- Fizyczne usunięcie wiersza nie jest przenoszone. Zamiast usuwania używa się znacznika `is_active`.
- Poprawność zależy od zgodności zegarów obu systemów.

Przy większej liczbie tabel porównywanie całych rejestrów byłoby zbyt kosztowne. Wtedy każdy system powinien zapisywać zmiany w osobnej tabeli zmian, a synchronizacja przenosiłaby tylko te zapisy.

## 12. Wnioski

1. **Transakcje i błędy.** Blok `BEGIN ... EXCEPTION` w PostgreSQL i `TRY ... CATCH` z jawną transakcją w SQL Server dają ten sam efekt widoczny dla użytkownika: błąd w dowolnym kroku wycofuje wszystkie zmiany (potwierdzone przy `sp_open_case`), a błąd jest zapisywany w dzienniku. Różnica jest w modelu: PostgreSQL pozwala wycofać część transakcji (podtransakcja), SQL Server wycofuje całość, więc procedury złożone należy wywoływać poza transakcją zewnętrzną.
2. **Wyzwalacze.** Wyzwalacz na wiersz (`BEFORE`) w PostgreSQL jest prostszy do napisania; w SQL Server trzeba pisać zapytania zbiorcze na tabelach `inserted` i wycofywać instrukcję po zdarzeniu. Za to wyzwalacz obowiązuje także właściciela schematu i nie da się go ominąć uprawnieniami.
3. **Automatyzacja.** Zadanie nocne łączy kilka kroków (alerty, migawka statystyk, retencja) w jednej transakcji z dziennikiem przebiegów. `pg_cron` jest lekkim rozszerzeniem, ale harmonogram i dziennik wykonań mieszczą się w bazie `postgres`, a nie w `noir`; SQL Server Agent daje pełniejsze narzędzia (kroki, historia, alerty), ale wymaga osobnego procesu.
4. **Kopie zapasowe.** Kopia jest wiarygodna dopiero po sprawdzeniu: w obu systemach nie poprzestano na wykonaniu kopii, lecz odtworzono ją do osobnej bazy i porównano zawartość tabel (md5 wierszy), a dodatkowo wykonano test awarii. Role i loginy trzeba kopiować osobno.
5. **Migracja.** Różnice dialektów dotknęły głównie warstwy programowalnej, nie schematu; schemat zmienił się tylko w typach (`BOOLEAN` → `BIT`, `TIMESTAMP` → `DATETIME2`), składni `IDENTITY` oraz indeksach filtrowanych. Dane przeniesiono dwiema metodami z identycznym wynikiem; analiza z sekcji 6 przewidziała większość napotkanych problemów (typy logiczne, `IDENTITY`, `QUOTED_IDENTIFIER`), a pozostałe wyszły dopiero przy uruchomieniu (brak `CODEPAGE` na Linuksie, sterownik jTDS w Hop, błąd 8711), co potwierdza, że przeczytanie dokumentacji nie zastępuje testów.
6. **Narzędzia.** Dla jednorazowej migracji małej bazy najlepsze są polecenia wbudowane w SZBD (`COPY` + `BULK INSERT`): szybkie, bez zależności, ale bez transformacji. Narzędzia ETL (Apache Hop) opłacają się, gdy dane trzeba przekształcać, łączyć z innymi źródłami albo migrację powtarzać.
7. **Przenośność.** Decyzje z projektu schematu (standardowe typy, słowniki jako tabele zamiast `ENUM`, nazwane ograniczenia, brak tablic i `jsonb`) sprawiły, że schemat dało się przenieść bez zmian koncepcyjnych. Wnioski z tego punktu różnią się od założeń przed migracją w jednym miejscu: największym problemem okazały się nie typy danych, lecz przepisanie wyzwalacza i procedur oraz uprawnień, bo te elementy nie mają odpowiedników 1:1.

## Wykorzystanie narzędzi AI

Przy pisaniu pracy wspomagano się modelem AI Claude Sonnet 5.5 do wygenerowania kodu SQL, testów, konfiguracji Docker Compose i skryptów powłoki. Model wykorzystano też do migracji danych z PostgreSQL na SQL Server oraz do pomocy przy pisaniu tekstu. Wszystkie obszary gdzie wykorzystano AI były weryfikowane oraz poprawiane przez autora.

AI wykorzystano do przygotowania szkiców funkcji, wyzwalaczy i procedur, które następnie były poprawiane i edytowane przez autora we współpracy z AI. Wkładem autora do elementów programowalnych są między innymi komentarze pomagające w zrozumieniu działania elementów. Autor korzystał z AI przy tworzeniu przypadków testowych. Autor wspomagał się użyciem AI przy tworzeniu ról i uprawnień oraz ich weryfikacji.

Narzędzia AI wykorzystano przy pomocy migracji SZBD, do rozwiązania problemów podczas migracji i do pomocy przy wykorzystaniu Apache Hop.

AI wykorzystano też przy porównaniu różnic między SZBD oraz do weryfikacji poprawności migracji poprzez test hashy MD5 i testy elementów programowalnych.

Przy wykonaniu zadania dodatkowego autor wspomagał się AI przy ustanowienu połączenia między bazami oraz przy pisaniu skryptów SQL do testów.
