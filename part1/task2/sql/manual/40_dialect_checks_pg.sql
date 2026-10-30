\set VERBOSITY terse
\echo '--- 1. comparison of strings differing in letter case'
SELECT CASE WHEN 'ADA@Example.com' = 'ada@example.com' THEN 'equal' ELSE 'different' END AS result;
\echo '--- 2. UNIQUE and NULL values: two rows with NULL in a UNIQUE column'
CREATE TEMP TABLE u (v INTEGER, CONSTRAINT uq_u UNIQUE (v));
INSERT INTO u VALUES (NULL);
INSERT INTO u VALUES (NULL);
SELECT COUNT(*) AS row_count FROM u;
\echo '--- 3. typ TIMESTAMP'
SELECT pg_typeof(TIMESTAMP '2026-10-09 10:15:30.123456') AS type_name, TIMESTAMP '2026-10-09 10:15:30.123456' AS value;
\echo '--- 4. concatenating text with a number using the operator ||'
SELECT 'Count: ' || 5 AS result;
\echo '--- 5. date difference'
SELECT DATE '2026-10-09' - DATE '2026-01-01' AS days;
\echo '--- 6. ordered aggregate inside COALESCE'
SELECT COALESCE(string_agg(name, ',' ORDER BY name COLLATE "C"), '') AS names FROM noir.case_type;
