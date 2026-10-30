USE noir;
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
-- ===================== ADDITIONAL VIEWS (aggregates for accounting) =====================
CREATE VIEW noir.v_case_financials AS
SELECT c.case_number,
       c.title,
       s.name AS status,
       cl.first_name + ' ' + cl.last_name AS client,
       c.fee_estimate,
       COALESCE(SUM(i.amount), 0.00) AS invoiced,
       COALESCE(SUM(pd.paid), 0.00) AS paid,
       COALESCE(SUM(i.amount), 0.00) - COALESCE(SUM(pd.paid), 0.00) AS outstanding
FROM noir.case_file c
JOIN noir.case_status s ON s.status_id = c.status_id
JOIN noir.client cl ON cl.client_id = c.client_id
LEFT JOIN noir.invoice i ON i.case_id = c.case_id
LEFT JOIN (SELECT invoice_id, SUM(amount) AS paid FROM noir.payment GROUP BY invoice_id) pd ON pd.invoice_id = i.invoice_id
GROUP BY c.case_id, c.case_number, c.title, s.name, cl.first_name, cl.last_name, c.fee_estimate;
GO

CREATE VIEW noir.v_client_balance AS
SELECT cl.client_id,
       cl.first_name + ' ' + cl.last_name AS client,
       COALESCE(cl.company_name, '-') AS company,
       COUNT(DISTINCT c.case_id) AS cases_count,
       COALESCE(SUM(i.amount), 0.00) AS invoiced,
       COALESCE(SUM(i.amount - COALESCE(pd.paid, 0)), 0.00) AS outstanding,
       COALESCE(SUM(CASE WHEN i.due_on < CAST(SYSDATETIME() AS DATE) THEN i.amount - COALESCE(pd.paid, 0) END), 0.00) AS overdue
FROM noir.client cl
LEFT JOIN noir.case_file c ON c.client_id = cl.client_id
LEFT JOIN noir.invoice i ON i.case_id = c.case_id
LEFT JOIN (SELECT invoice_id, SUM(amount) AS paid FROM noir.payment GROUP BY invoice_id) pd ON pd.invoice_id = i.invoice_id
GROUP BY cl.client_id, cl.first_name, cl.last_name, cl.company_name;
GO

-- overdue-invoice alerts contain financial data: the detective sees only alerts about inactive cases (through a view)
CREATE VIEW noir.v_stale_cases AS
SELECT c.case_number, c.title, a.raised_on, a.message
FROM noir.alert a JOIN noir.case_file c ON c.case_id = a.case_id
WHERE a.alert_type = 'STALE_CASE' AND a.resolved_on IS NULL;
GO
