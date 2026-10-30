SET NOCOUNT ON;
PRINT '=== payments: above the invoice amount / before issue date / in the future / update to an excessive amount ===';
INSERT INTO noir.payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, CAST(SYSDATETIME() AS DATE), 2300.00);
GO
INSERT INTO noir.payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, '2025-01-01', 100.00);
GO
INSERT INTO noir.payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, DATEADD(DAY, 3, CAST(SYSDATETIME() AS DATE)), 100.00);
GO
UPDATE noir.payment SET amount = 4500 WHERE payment_id = 3;
GO
PRINT '=== payments: valid payment (remainder of the invoice) ===';
INSERT INTO noir.payment (invoice_id, method_id, paid_on, amount) VALUES (3, 2, CAST(SYSDATETIME() AS DATE), 2200.00);
GO
SELECT invoice_number, amount, paid, balance, payment_status FROM noir.v_invoice_balance WHERE invoice_number = 'INV-2025-0003';
GO
