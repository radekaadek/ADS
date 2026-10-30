\set VERBOSITY terse
SET search_path = noir;
\echo '=== counters before ==='
SELECT (SELECT COUNT(*) FROM case_file) AS cases, (SELECT COUNT(*) FROM case_detective) AS assignments,
       (SELECT COUNT(*) FROM case_status_history) AS status_history, (SELECT COUNT(*) FROM operation_log) AS log_entries,
       (SELECT COUNT(*) FROM payment) AS payments;

\echo '=== sp_open_case: success ==='
SELECT COUNT(*) AS cases_before FROM case_file;
CALL sp_open_case(1, 'Fraud', 'The Forged Ledger', 'Falsified books of a shipping company.', 4200, 2, NULL, NULL);
SELECT COUNT(*) AS cases_after FROM case_file;
SELECT case_number, title, fee_estimate, opened_on FROM case_file WHERE title = 'The Forged Ledger';
SELECT c.case_number, d.last_name, cd.role FROM case_detective cd JOIN case_file c USING (case_id) JOIN detective d USING (detective_id) WHERE c.title = 'The Forged Ledger';
SELECT h.old_status_id, s.name AS new_status FROM case_status_history h JOIN case_status s ON s.status_id = h.new_status_id WHERE h.case_id = (SELECT case_id FROM case_file WHERE title = 'The Forged Ledger');

\echo '=== sp_open_case: error at the first step (nonexistent client) ==='
SELECT COUNT(*) AS cases_before FROM case_file;
CALL sp_open_case(999, 'Fraud', 'Ghost client', NULL, 100, 2, NULL, NULL);
SELECT COUNT(*) AS cases_after, COUNT(*) FILTER (WHERE title = 'Ghost client') AS rolled_back_rows FROM case_file;

\echo '=== sp_open_case: error at the last step (inactive detective) - the inserted case is rolled back ==='
SELECT COUNT(*) AS cases_before FROM case_file;
CALL sp_open_case(1, 'Theft', 'Case that must roll back', NULL, 100, 6, NULL, NULL);
SELECT COUNT(*) AS cases_after, COUNT(*) FILTER (WHERE title = 'Case that must roll back') AS rolled_back_rows FROM case_file;
SELECT procedure_name, severity, message FROM operation_log ORDER BY log_id;

\echo '=== numbering: the number of a deleted case is not reused ==='
SELECT counter_name, counter_year, last_value FROM document_counter WHERE counter_name = 'CASE' ORDER BY counter_year;
CALL sp_open_case(1, 'Theft', 'Case to delete', NULL, 100, 4, NULL, NULL);
DELETE FROM case_status_history WHERE case_id = (SELECT case_id FROM case_file WHERE title = 'Case to delete');
DELETE FROM case_detective WHERE case_id = (SELECT case_id FROM case_file WHERE title = 'Case to delete');
DELETE FROM case_file WHERE title = 'Case to delete';
CALL sp_open_case(1, 'Theft', 'Case after delete', NULL, 100, 4, NULL, NULL);
SELECT case_number, title FROM case_file WHERE title IN ('The Forged Ledger', 'Case after delete') ORDER BY case_number;
SELECT counter_name, counter_year, last_value FROM document_counter WHERE counter_name = 'CASE' ORDER BY counter_year;

\echo '=== sp_register_payment (simple procedure): payment, payment above the balance, unknown invoice ==='
CALL sp_register_payment('INV-2025-0006', 'Bank transfer', 1000, CURRENT_DATE, NULL);
CALL sp_register_payment('INV-2025-0006', 'Cash', 600, CURRENT_DATE, NULL);
CALL sp_register_payment('INV-2025-9999', 'Cash', 100, CURRENT_DATE, NULL);
SELECT invoice_number, amount, paid, balance, payment_status FROM v_invoice_balance WHERE invoice_number = 'INV-2025-0006';

\echo '=== counters after ==='
SELECT (SELECT COUNT(*) FROM case_file) AS cases, (SELECT COUNT(*) FROM case_detective) AS assignments,
       (SELECT COUNT(*) FROM case_status_history) AS status_history, (SELECT COUNT(*) FROM operation_log) AS log_entries,
       (SELECT COUNT(*) FROM payment) AS payments;
