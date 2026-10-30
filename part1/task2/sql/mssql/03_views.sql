USE noir;
GO
-- Case overview in readable form (labels instead of foreign keys)
CREATE VIEW noir.v_case_overview AS
SELECT c.case_number,
       c.title,
       t.name  AS case_type,
       s.name  AS status,
       cl.first_name + ' ' + cl.last_name AS client,
       COALESCE(d.first_name + ' ' + d.last_name, '-- unassigned --') AS lead_detective,
       c.opened_on,
       c.closed_on,
       DATEDIFF(DAY, c.opened_on, COALESCE(c.closed_on, CAST(SYSDATETIME() AS DATE))) AS days_open,
       (SELECT COUNT(*) FROM noir.evidence e WHERE e.case_id = c.case_id) AS evidence_count
FROM noir.case_file c
JOIN noir.case_type   t  ON t.type_id   = c.type_id
JOIN noir.case_status s  ON s.status_id = c.status_id
JOIN noir.client      cl ON cl.client_id = c.client_id
LEFT JOIN noir.case_detective cd ON cd.case_id = c.case_id AND cd.role = 'LEAD'
LEFT JOIN noir.detective d ON d.detective_id = cd.detective_id;
GO

-- Workload of active detectives: active / all / led cases
CREATE VIEW noir.v_detective_workload AS
SELECT d.detective_id,
       d.first_name + ' ' + d.last_name AS detective,
       r.name AS detective_rank,
       COUNT(DISTINCT CASE WHEN s.name IN ('Open','In progress') THEN cd.case_id END) AS active_cases,
       COUNT(DISTINCT cd.case_id) AS all_cases,
       COUNT(DISTINCT CASE WHEN cd.role = 'LEAD' THEN cd.case_id END) AS led_cases
FROM noir.detective d
JOIN noir.detective_rank r ON r.rank_id = d.rank_id
LEFT JOIN noir.case_detective cd ON cd.detective_id = d.detective_id
LEFT JOIN noir.case_file c ON c.case_id = cd.case_id
LEFT JOIN noir.case_status s ON s.status_id = c.status_id
WHERE d.is_active = 1
GROUP BY d.detective_id, d.first_name, d.last_name, r.name;
GO

-- Invoices with outstanding balance (for accounting)
CREATE VIEW noir.v_invoice_balance AS
SELECT i.invoice_number,
       c.case_number,
       cl.first_name + ' ' + cl.last_name AS client,
       i.issued_on,
       i.due_on,
       i.amount,
       COALESCE(SUM(p.amount), 0.00) AS paid,
       i.amount - COALESCE(SUM(p.amount), 0.00) AS balance,
       CASE
         WHEN i.amount - COALESCE(SUM(p.amount), 0.00) <= 0 THEN 'PAID'
         WHEN i.due_on < CAST(SYSDATETIME() AS DATE) THEN 'OVERDUE'
         ELSE 'PENDING'
       END AS payment_status
FROM noir.invoice i
JOIN noir.case_file c ON c.case_id = i.case_id
JOIN noir.client cl ON cl.client_id = c.client_id
LEFT JOIN noir.payment p ON p.invoice_id = i.invoice_id
GROUP BY i.invoice_id, i.invoice_number, c.case_number, cl.first_name, cl.last_name,
         i.issued_on, i.due_on, i.amount;
GO

-- Client view: only the status of their cases, no internal data (suspects, informants)
CREATE VIEW noir.v_client_cases AS
SELECT cl.email AS client_email,
       c.case_number,
       c.title,
       s.name AS status,
       c.opened_on,
       c.closed_on
FROM noir.case_file c
JOIN noir.case_status s ON s.status_id = c.status_id
JOIN noir.client cl ON cl.client_id = c.client_id;
GO

-- Chain of custody in readable form
CREATE VIEW noir.v_evidence_chain AS
SELECT e.evidence_code,
       et.name AS evidence_type,
       c.case_number,
       ec.transferred_at,
       d.first_name + ' ' + d.last_name AS custodian,
       ec.note
FROM noir.evidence_custody ec
JOIN noir.evidence e ON e.evidence_id = ec.evidence_id
JOIN noir.evidence_type et ON et.evidence_type_id = e.evidence_type_id
JOIN noir.case_file c ON c.case_id = e.case_id
JOIN noir.detective d ON d.detective_id = ec.detective_id;
GO
