SET NOCOUNT ON;
PRINT '=== counters before ===';
SELECT (SELECT COUNT(*) FROM noir.case_file) AS cases, (SELECT COUNT(*) FROM noir.case_detective) AS assignments,
       (SELECT COUNT(*) FROM noir.case_status_history) AS status_history, (SELECT COUNT(*) FROM noir.operation_log) AS log_entries,
       (SELECT COUNT(*) FROM noir.payment) AS payments;
GO
PRINT '=== sp_open_case: success ===';
SELECT COUNT(*) AS cases_before FROM noir.case_file;
GO
DECLARE @n VARCHAR(20), @r VARCHAR(500);
EXEC noir.sp_open_case 1, 'Fraud', 'The Forged Ledger', 'Falsified books of a shipping company.', 4200, 2, @n OUTPUT, @r OUTPUT;
SELECT @n AS case_number, @r AS result;
GO
SELECT COUNT(*) AS cases_after FROM noir.case_file;
SELECT case_number, title, fee_estimate, opened_on FROM noir.case_file WHERE title = 'The Forged Ledger';
SELECT c.case_number, d.last_name, cd.role FROM noir.case_detective cd JOIN noir.case_file c ON c.case_id = cd.case_id JOIN noir.detective d ON d.detective_id = cd.detective_id WHERE c.title = 'The Forged Ledger';
SELECT h.old_status_id, s.name AS new_status FROM noir.case_status_history h JOIN noir.case_status s ON s.status_id = h.new_status_id WHERE h.case_id = (SELECT case_id FROM noir.case_file WHERE title = 'The Forged Ledger');
GO
PRINT '=== sp_open_case: error at the first step (nonexistent client) ===';
SELECT COUNT(*) AS cases_before FROM noir.case_file;
GO
DECLARE @n VARCHAR(20), @r VARCHAR(500);
EXEC noir.sp_open_case 999, 'Fraud', 'Ghost client', NULL, 100, 2, @n OUTPUT, @r OUTPUT;
SELECT @n AS case_number, @r AS result;
GO
SELECT COUNT(*) AS cases_after, SUM(CASE WHEN title = 'Ghost client' THEN 1 ELSE 0 END) AS rolled_back_rows FROM noir.case_file;
GO
PRINT '=== sp_open_case: error at the last step (inactive detective) - the inserted case is rolled back ===';
SELECT COUNT(*) AS cases_before FROM noir.case_file;
GO
DECLARE @n VARCHAR(20), @r VARCHAR(500);
EXEC noir.sp_open_case 1, 'Theft', 'Case that must roll back', NULL, 100, 6, @n OUTPUT, @r OUTPUT;
SELECT @n AS case_number, @r AS result;
GO
SELECT COUNT(*) AS cases_after, SUM(CASE WHEN title = 'Case that must roll back' THEN 1 ELSE 0 END) AS rolled_back_rows FROM noir.case_file;
SELECT procedure_name, severity, message FROM noir.operation_log ORDER BY log_id;
GO
PRINT '=== numbering: the number of a deleted case is not reused ===';
SELECT counter_name, counter_year, last_value FROM noir.document_counter WHERE counter_name = 'CASE' ORDER BY counter_year;
GO
DECLARE @n VARCHAR(20), @r VARCHAR(500); EXEC noir.sp_open_case 1, 'Theft', 'Case to delete', NULL, 100, 4, @n OUTPUT, @r OUTPUT;
GO
DELETE FROM noir.case_status_history WHERE case_id = (SELECT case_id FROM noir.case_file WHERE title = 'Case to delete');
DELETE FROM noir.case_detective WHERE case_id = (SELECT case_id FROM noir.case_file WHERE title = 'Case to delete');
DELETE FROM noir.case_file WHERE title = 'Case to delete';
GO
DECLARE @n VARCHAR(20), @r VARCHAR(500); EXEC noir.sp_open_case 1, 'Theft', 'Case after delete', NULL, 100, 4, @n OUTPUT, @r OUTPUT;
GO
SELECT case_number, title FROM noir.case_file WHERE title IN ('The Forged Ledger', 'Case after delete') ORDER BY case_number;
SELECT counter_name, counter_year, last_value FROM noir.document_counter WHERE counter_name = 'CASE' ORDER BY counter_year;
GO
PRINT '=== sp_register_payment (simple procedure): payment, payment above the balance, unknown invoice ===';
DECLARE @p INT, @d DATE = CAST(SYSDATETIME() AS DATE); EXEC noir.sp_register_payment 'INV-2025-0006', 'Bank transfer', 1000, @d, @p OUTPUT; SELECT @p AS payment_id;
GO
DECLARE @p INT, @d DATE = CAST(SYSDATETIME() AS DATE); EXEC noir.sp_register_payment 'INV-2025-0006', 'Cash', 600, @d, @p OUTPUT;
GO
DECLARE @p INT, @d DATE = CAST(SYSDATETIME() AS DATE); EXEC noir.sp_register_payment 'INV-2025-9999', 'Cash', 100, @d, @p OUTPUT;
GO
SELECT invoice_number, amount, paid, balance, payment_status FROM noir.v_invoice_balance WHERE invoice_number = 'INV-2025-0006';
GO
PRINT '=== counters after ===';
SELECT (SELECT COUNT(*) FROM noir.case_file) AS cases, (SELECT COUNT(*) FROM noir.case_detective) AS assignments,
       (SELECT COUNT(*) FROM noir.case_status_history) AS status_history, (SELECT COUNT(*) FROM noir.operation_log) AS log_entries,
       (SELECT COUNT(*) FROM noir.payment) AS payments;
GO
