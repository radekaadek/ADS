SET NOCOUNT ON;
PRINT '--- 1. comparison of strings differing in letter case';
GO
SELECT CASE WHEN 'ADA@Example.com' = 'ada@example.com' THEN 'equal' ELSE 'different' END AS result;
GO
PRINT '--- 2. UNIQUE and NULL values: two rows with NULL in a UNIQUE column';
GO
CREATE TABLE #u (v INT, CONSTRAINT uq_u UNIQUE (v));
INSERT INTO #u VALUES (NULL);
GO
INSERT INTO #u VALUES (NULL);
GO
PRINT '--- 3. typ TIMESTAMP';
GO
CREATE TABLE #t (ts TIMESTAMP, label VARCHAR(10) DEFAULT 'x');
INSERT INTO #t DEFAULT VALUES;
SELECT TYPE_NAME(system_type_id) AS type_name, max_length AS bytes FROM tempdb.sys.columns WHERE object_id = OBJECT_ID('tempdb..#t') AND name = 'ts';
SELECT ts AS value FROM #t;
GO
PRINT '--- 4. concatenating text with a number using the operator +';
GO
SELECT 'Count: ' + 5 AS result;
GO
SELECT CONCAT('Count: ', 5) AS result_concat;
GO
PRINT '--- 5. date difference';
GO
SELECT DATEDIFF(DAY, '2026-01-01', '2026-10-09') AS days;
GO
PRINT '--- 6. ordered aggregate inside COALESCE';
GO
SELECT COALESCE(STRING_AGG(name, ',') WITHIN GROUP (ORDER BY name COLLATE Latin1_General_100_BIN2_UTF8), '') AS names FROM noir.case_type;
GO
SELECT ISNULL(STRING_AGG(name, ',') WITHIN GROUP (ORDER BY name COLLATE Latin1_General_100_BIN2_UTF8), '') AS names FROM noir.case_type;
GO
PRINT '--- 7. write to a table with a filtered index in a session with QUOTED_IDENTIFIER OFF';
GO
SET QUOTED_IDENTIFIER OFF;
INSERT INTO noir.alert (alert_type, case_id, invoice_id, raised_on, message) VALUES ('STALE_CASE', 1, NULL, '2026-10-09', 'test');
GO
SET QUOTED_IDENTIFIER ON;
INSERT INTO noir.alert (alert_type, case_id, invoice_id, raised_on, message) VALUES ('STALE_CASE', 1, NULL, '2026-10-09', 'test');
SELECT COUNT(*) AS rows_in_alert FROM noir.alert WHERE message = 'test';
DELETE FROM noir.alert WHERE message = 'test';
GO
