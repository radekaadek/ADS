\set VERBOSITY terse
SET search_path = noir;
\echo '=== payments: above the invoice amount / before issue date / in the future / update to an excessive amount ==='
INSERT INTO payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, CURRENT_DATE, 2300.00);
INSERT INTO payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, '2025-01-01', 100.00);
INSERT INTO payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, CURRENT_DATE + 3, 100.00);
UPDATE payment SET amount = 4500 WHERE payment_id = 3;
\echo '=== payments: valid payment (remainder of the invoice) ==='
INSERT INTO payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, CURRENT_DATE, 2200.00);
SELECT invoice_number, amount, paid, balance, payment_status FROM v_invoice_balance WHERE invoice_number = 'INV-2025-0003';
