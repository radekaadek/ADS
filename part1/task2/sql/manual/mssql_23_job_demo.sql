SET NOCOUNT ON;
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
PRINT '=== monthly snapshot (selected months) ===';
SELECT FORMAT(m.period_start, 'yyyy-MM') AS [month], t.name AS case_type, m.opened_cnt, m.closed_cnt, m.invoiced, m.paid
FROM noir.monthly_case_stats m JOIN noir.case_type t ON t.type_id = m.type_id
WHERE m.opened_cnt > 0 OR m.closed_cnt > 0 OR m.invoiced > 0 OR m.paid > 0
ORDER BY m.period_start, t.name;
GO
