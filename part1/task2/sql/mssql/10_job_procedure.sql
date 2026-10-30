USE noir;
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
-- Nightly job: several steps in one transaction, result in job_run_log.
--  1. alerts for overdue invoices (opened) and for settled invoices (closed),
--  2. alerts for cases with no activity for @stale_days days (opened) and for cases active again (closed),
--  3. monthly statistics snapshot (every month since the first case) split by case type (MERGE),
--  4. retention: delete operation_log entries older than @retention_days.
CREATE PROCEDURE noir.sp_nightly_maintenance @stale_days INT = 60, @retention_days INT = 90
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @run INT, @started DATETIME2(6) = SYSDATETIME(), @today DATE = CAST(SYSDATETIME() AS DATE),
            @overdue_new INT, @overdue_closed INT, @stale_new INT, @stale_closed INT, @stats INT, @purged INT, @err VARCHAR(500);
    INSERT INTO noir.job_run_log (job_name, started_at, status) VALUES ('nightly_maintenance', @started, 'RUNNING');
    SET @run = SCOPE_IDENTITY();
    BEGIN TRY
        BEGIN TRAN;
        -- 1. overdue invoices
        INSERT INTO noir.alert (alert_type, case_id, invoice_id, raised_on, message)
        SELECT 'OVERDUE_INVOICE', i.case_id, i.invoice_id, @today,
               CONCAT('Invoice ', i.invoice_number, ' overdue by ', DATEDIFF(DAY, i.due_on, @today), ' days, balance ', (i.amount - COALESCE((SELECT SUM(p.amount) FROM noir.payment p WHERE p.invoice_id = i.invoice_id), 0)))
        FROM noir.invoice i
        WHERE i.due_on < @today AND (i.amount - COALESCE((SELECT SUM(p.amount) FROM noir.payment p WHERE p.invoice_id = i.invoice_id), 0)) > 0
          AND NOT EXISTS (SELECT 1 FROM noir.alert a WHERE a.invoice_id = i.invoice_id AND a.resolved_on IS NULL);
        SET @overdue_new = @@ROWCOUNT;
        UPDATE a SET resolved_on = @today
        FROM noir.alert a
        WHERE a.alert_type = 'OVERDUE_INVOICE' AND a.resolved_on IS NULL AND (SELECT i.amount - COALESCE((SELECT SUM(p.amount) FROM noir.payment p WHERE p.invoice_id = i.invoice_id), 0)
                                         FROM noir.invoice i WHERE i.invoice_id = a.invoice_id) <= 0;
        SET @overdue_closed = @@ROWCOUNT;

        -- 2. active cases with no events (evidence, tip, statement, status change) for @stale_days days
        ;WITH last_activity AS (
            SELECT c.case_id, c.case_number,
                   GREATEST(CAST(c.opened_on AS DATETIME2(6)),
                            COALESCE((SELECT MAX(found_at)    FROM noir.evidence e WHERE e.case_id = c.case_id), CAST(c.opened_on AS DATETIME2(6))),
                            COALESCE((SELECT MAX(received_at) FROM noir.tip t      WHERE t.case_id = c.case_id), CAST(c.opened_on AS DATETIME2(6))),
                            COALESCE((SELECT CAST(MAX(statement_date) AS DATETIME2(6)) FROM noir.case_witness w WHERE w.case_id = c.case_id), CAST(c.opened_on AS DATETIME2(6))),
                            COALESCE((SELECT MAX(changed_at)  FROM noir.case_status_history h WHERE h.case_id = c.case_id), CAST(c.opened_on AS DATETIME2(6)))
                   ) AS last_at
            FROM noir.case_file c JOIN noir.case_status s ON s.status_id = c.status_id
            WHERE s.name IN ('Open', 'In progress')
        )
        INSERT INTO noir.alert (alert_type, case_id, raised_on, message)
        SELECT 'STALE_CASE', la.case_id, @today,
               CONCAT('Case ', la.case_number, ' inactive for ', DATEDIFF(DAY, CAST(la.last_at AS DATE), @today), ' days')
        FROM last_activity la
        WHERE la.last_at < DATEADD(DAY, -@stale_days, SYSDATETIME())
          AND NOT EXISTS (SELECT 1 FROM noir.alert a WHERE a.case_id = la.case_id AND a.alert_type = 'STALE_CASE' AND a.resolved_on IS NULL);
        SET @stale_new = @@ROWCOUNT;
        UPDATE a SET resolved_on = @today
        FROM noir.alert a JOIN noir.case_file c ON c.case_id = a.case_id
        WHERE a.alert_type = 'STALE_CASE' AND a.resolved_on IS NULL AND EXISTS (SELECT 1 FROM noir.case_status WHERE status_id = c.status_id AND name LIKE 'Closed%');
        SET @stale_closed = @@ROWCOUNT;

        -- 3. monthly statistics snapshot: every month from the first case opening to the current one
        DECLARE @first_month DATE = (SELECT DATEFROMPARTS(YEAR(MIN(opened_on)), MONTH(MIN(opened_on)), 1) FROM noir.case_file);
        DECLARE @this_month DATE = DATEFROMPARTS(YEAR(@today), MONTH(@today), 1);
        ;WITH months AS (
            SELECT @first_month AS period_start
            UNION ALL
            SELECT DATEADD(MONTH, 1, period_start) FROM months WHERE period_start < @this_month
        ), src AS (
            SELECT m.period_start, t.type_id,
                   (SELECT COUNT(*) FROM noir.case_file c WHERE c.type_id = t.type_id AND DATEFROMPARTS(YEAR(c.opened_on), MONTH(c.opened_on), 1) = m.period_start) AS opened_cnt,
                   (SELECT COUNT(*) FROM noir.case_file c WHERE c.type_id = t.type_id AND c.closed_on IS NOT NULL AND DATEFROMPARTS(YEAR(c.closed_on), MONTH(c.closed_on), 1) = m.period_start) AS closed_cnt,
                   COALESCE((SELECT SUM(i.amount) FROM noir.invoice i JOIN noir.case_file c ON c.case_id = i.case_id
                             WHERE c.type_id = t.type_id AND DATEFROMPARTS(YEAR(i.issued_on), MONTH(i.issued_on), 1) = m.period_start), 0) AS invoiced,
                   COALESCE((SELECT SUM(p.amount) FROM noir.payment p JOIN noir.invoice i ON i.invoice_id = p.invoice_id
                             JOIN noir.case_file c ON c.case_id = i.case_id
                             WHERE c.type_id = t.type_id AND DATEFROMPARTS(YEAR(p.paid_on), MONTH(p.paid_on), 1) = m.period_start), 0) AS paid
            FROM months m CROSS JOIN noir.case_type t
        )
        MERGE noir.monthly_case_stats AS tgt
        USING src ON tgt.period_start = src.period_start AND tgt.type_id = src.type_id
        WHEN MATCHED THEN UPDATE SET opened_cnt = src.opened_cnt, closed_cnt = src.closed_cnt,
                                     invoiced = src.invoiced, paid = src.paid, refreshed_at = SYSDATETIME()
        WHEN NOT MATCHED THEN INSERT (period_start, type_id, opened_cnt, closed_cnt, invoiced, paid)
                              VALUES (src.period_start, src.type_id, src.opened_cnt, src.closed_cnt, src.invoiced, src.paid);
        SET @stats = @@ROWCOUNT;

        -- 4. operation log retention
        DELETE FROM noir.operation_log WHERE logged_at < DATEADD(DAY, -@retention_days, SYSDATETIME());
        SET @purged = @@ROWCOUNT;
        COMMIT;

        UPDATE noir.job_run_log SET finished_at = SYSDATETIME(), status = 'OK',
               details = CONCAT('overdue invoices: +', @overdue_new, '/-', @overdue_closed,
                                '; inactive cases: +', @stale_new, '/-', @stale_closed,
                                '; statistics: ', @stats, ' rows; purged from log: ', @purged)
        WHERE run_id = @run;
    END TRY
    BEGIN CATCH
        -- step failed: all changes are rolled back, the run entry is kept
        IF XACT_STATE() <> 0 ROLLBACK;
        SET @err = LEFT(ERROR_MESSAGE(), 500);
        UPDATE noir.job_run_log SET finished_at = SYSDATETIME(), status = 'ERROR', details = @err WHERE run_id = @run;
    END CATCH;
END;
GO
