\set VERBOSITY terse
SET search_path = noir;
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
\echo '=== monthly snapshot (selected months) ==='
SELECT to_char(m.period_start, 'YYYY-MM') AS month, t.name AS case_type, m.opened_cnt, m.closed_cnt, m.invoiced, m.paid
FROM monthly_case_stats m JOIN case_type t USING (type_id)
WHERE m.opened_cnt > 0 OR m.closed_cnt > 0 OR m.invoiced > 0 OR m.paid > 0
ORDER BY m.period_start, t.name;
