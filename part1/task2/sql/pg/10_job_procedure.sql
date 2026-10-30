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
