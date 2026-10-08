-- Test indeksow na duzych danych syntetycznych (osobny schemat perf, nie zasmieca danych biznesowych).
-- Uruchomienie: docker compose exec -T db psql -U noir_admin -d noir -f /manual/08_perf.sql
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
