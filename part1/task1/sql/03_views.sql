SET search_path = noir;

-- Przeglad spraw w czytelnej postaci (etykiety zamiast kluczy obcych)
CREATE VIEW v_case_overview AS
SELECT c.case_number,
       c.title,
       t.name  AS case_type,
       s.name  AS status,
       cl.first_name || ' ' || cl.last_name AS client,
       COALESCE(d.first_name || ' ' || d.last_name, '-- unassigned --') AS lead_detective,
       c.opened_on,
       c.closed_on,
       COALESCE(c.closed_on, CURRENT_DATE) - c.opened_on AS days_open,
       (SELECT COUNT(*) FROM evidence e WHERE e.case_id = c.case_id) AS evidence_count
FROM case_file c
JOIN case_type   t  ON t.type_id   = c.type_id
JOIN case_status s  ON s.status_id = c.status_id
JOIN client      cl ON cl.client_id = c.client_id
LEFT JOIN case_detective cd ON cd.case_id = c.case_id AND cd.role = 'LEAD'
LEFT JOIN detective d ON d.detective_id = cd.detective_id;

-- Obciazenie aktywnych detektywow: sprawy aktywne / wszystkie / prowadzone
CREATE VIEW v_detective_workload AS
SELECT d.detective_id,
       d.first_name || ' ' || d.last_name AS detective,
       r.name AS detective_rank,
       COUNT(DISTINCT CASE WHEN s.name IN ('Open','In progress') THEN cd.case_id END) AS active_cases,
       COUNT(DISTINCT cd.case_id) AS all_cases,
       COUNT(DISTINCT CASE WHEN cd.role = 'LEAD' THEN cd.case_id END) AS led_cases
FROM detective d
JOIN detective_rank r ON r.rank_id = d.rank_id
LEFT JOIN case_detective cd ON cd.detective_id = d.detective_id
LEFT JOIN case_file c ON c.case_id = cd.case_id
LEFT JOIN case_status s ON s.status_id = c.status_id
WHERE d.is_active
GROUP BY d.detective_id, d.first_name, d.last_name, r.name;

-- Faktury z saldem do zaplaty (dla ksiegowosci)
CREATE VIEW v_invoice_balance AS
SELECT i.invoice_number,
       c.case_number,
       cl.first_name || ' ' || cl.last_name AS client,
       i.issued_on,
       i.due_on,
       i.amount,
       COALESCE(SUM(p.amount), 0.00) AS paid,
       i.amount - COALESCE(SUM(p.amount), 0.00) AS balance,
       CASE
         WHEN i.amount - COALESCE(SUM(p.amount), 0.00) <= 0 THEN 'PAID'
         WHEN i.due_on < CURRENT_DATE THEN 'OVERDUE'
         ELSE 'PENDING'
       END AS payment_status
FROM invoice i
JOIN case_file c ON c.case_id = i.case_id
JOIN client cl ON cl.client_id = c.client_id
LEFT JOIN payment p ON p.invoice_id = i.invoice_id
GROUP BY i.invoice_id, i.invoice_number, c.case_number, cl.first_name, cl.last_name,
         i.issued_on, i.due_on, i.amount;

-- Widok klienta: tylko status jego spraw, bez danych wewnetrznych (podejrzani, informatorzy)
CREATE VIEW v_client_cases AS
SELECT cl.email AS client_email,
       c.case_number,
       c.title,
       s.name AS status,
       c.opened_on,
       c.closed_on
FROM case_file c
JOIN case_status s ON s.status_id = c.status_id
JOIN client cl ON cl.client_id = c.client_id;

-- Lancuch dowodowy w czytelnej postaci
CREATE VIEW v_evidence_chain AS
SELECT e.evidence_code,
       et.name AS evidence_type,
       c.case_number,
       ec.transferred_at,
       d.first_name || ' ' || d.last_name AS custodian,
       ec.note
FROM evidence_custody ec
JOIN evidence e ON e.evidence_id = ec.evidence_id
JOIN evidence_type et ON et.evidence_type_id = e.evidence_type_id
JOIN case_file c ON c.case_id = e.case_id
JOIN detective d ON d.detective_id = ec.detective_id;
