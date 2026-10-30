SET search_path = noir;

-- ===================== ADDITIONAL VIEWS (aggregates for accounting) =====================
CREATE VIEW v_case_financials AS
SELECT c.case_number,
       c.title,
       s.name AS status,
       cl.first_name || ' ' || cl.last_name AS client,
       c.fee_estimate,
       COALESCE(SUM(i.amount), 0.00) AS invoiced,
       COALESCE(SUM(pd.paid), 0.00) AS paid,
       COALESCE(SUM(i.amount), 0.00) - COALESCE(SUM(pd.paid), 0.00) AS outstanding
FROM case_file c
JOIN case_status s ON s.status_id = c.status_id
JOIN client cl ON cl.client_id = c.client_id
LEFT JOIN invoice i ON i.case_id = c.case_id
LEFT JOIN (SELECT invoice_id, SUM(amount) AS paid FROM payment GROUP BY invoice_id) pd ON pd.invoice_id = i.invoice_id
GROUP BY c.case_id, c.case_number, c.title, s.name, cl.first_name, cl.last_name, c.fee_estimate;

CREATE VIEW v_client_balance AS
SELECT cl.client_id,
       cl.first_name || ' ' || cl.last_name AS client,
       COALESCE(cl.company_name, '-') AS company,
       COUNT(DISTINCT c.case_id) AS cases_count,
       COALESCE(SUM(i.amount), 0.00) AS invoiced,
       COALESCE(SUM(i.amount - COALESCE(pd.paid, 0)), 0.00) AS outstanding,
       COALESCE(SUM(CASE WHEN i.due_on < CURRENT_DATE THEN i.amount - COALESCE(pd.paid, 0) END), 0.00) AS overdue
FROM client cl
LEFT JOIN case_file c ON c.client_id = cl.client_id
LEFT JOIN invoice i ON i.case_id = c.case_id
LEFT JOIN (SELECT invoice_id, SUM(amount) AS paid FROM payment GROUP BY invoice_id) pd ON pd.invoice_id = i.invoice_id
GROUP BY cl.client_id, cl.first_name, cl.last_name, cl.company_name;

-- ===================== PERMISSIONS FOR NEW OBJECTS =====================
-- Functions and procedures are executable by PUBLIC by default - we revoke and grant explicitly
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA noir FROM PUBLIC;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA noir FROM PUBLIC;

-- Detective: opening cases, timeline; alerts and status history read-only
GRANT EXECUTE ON PROCEDURE sp_open_case TO detective_app;
GRANT EXECUTE ON FUNCTION fn_case_timeline(INTEGER) TO detective_app;
GRANT SELECT ON case_status_history TO detective_app;
-- overdue-invoice alerts contain financial data: the detective sees only alerts about inactive cases (through a view)
CREATE VIEW v_stale_cases AS
SELECT c.case_number, c.title, a.raised_on, a.message
FROM alert a JOIN case_file c ON c.case_id = a.case_id
WHERE a.alert_type = 'STALE_CASE' AND a.resolved_on IS NULL;
GRANT SELECT ON v_stale_cases TO detective_app;

-- Accountant: payment registration via procedure, financial aggregates
GRANT EXECUTE ON PROCEDURE sp_register_payment TO accountant_app;
GRANT SELECT ON v_case_financials, v_client_balance, monthly_case_stats TO accountant_app;

-- Client: still only v_client_cases; the detective does not see finance
REVOKE ALL ON v_case_financials, v_client_balance, monthly_case_stats, operation_log, job_run_log FROM detective_app, client_portal;
REVOKE ALL ON alert, case_status_history, operation_log, job_run_log, v_stale_cases FROM accountant_app, client_portal;

ALTER ROLE noir_admin SET search_path = noir;
