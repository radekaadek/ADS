USE noir;
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
-- SQL Server triggers are statement-level AFTER triggers (the inserted / deleted tables contain all
-- modified rows). Rule violation: ROLLBACK + THROW, so the DML statement is rolled back entirely.
-- Triggers rely on ownership chaining (objects belong to noir_admin), so the rule applies regardless of the role's rights.

-- ===================== FINANCE =====================
-- Payment: a payment cannot be dated before the invoice is issued or in the future, and the total of all payments for an invoice cannot exceed the invoice amount.
CREATE TRIGGER noir.trg_payment ON noir.payment AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @m NVARCHAR(500);
    -- step 1: payments dated before the invoice was issued; UPDLOCK locks the invoice row, so two concurrent payments
    -- for the same invoice are checked one after another; the trigger sees all rows of the statement in 'inserted'
    SELECT TOP 1 @m = CONCAT('Payment (', CONVERT(VARCHAR(10), i.paid_on, 23), ') is before invoice issue date (', CONVERT(VARCHAR(10), v.issued_on, 23), ')')
    FROM inserted i JOIN noir.invoice v WITH (UPDLOCK) ON v.invoice_id = i.invoice_id WHERE i.paid_on < v.issued_on;
    -- if a rule is broken: cancel the whole statement (ROLLBACK) and report the message (THROW)
    IF @m IS NOT NULL BEGIN IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; THROW 50001, @m, 1; END;
    -- step 2: payments dated in the future
    SELECT TOP 1 @m = CONCAT('Payment date is in the future (', CONVERT(VARCHAR(10), i.paid_on, 23), ')')
    FROM inserted i WHERE i.paid_on > CAST(SYSDATETIME() AS DATE);
    IF @m IS NOT NULL BEGIN IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; THROW 50001, @m, 1; END;
    -- step 3: for every invoice touched by the statement, the total of all its payments (the new row is already in the
    -- table in an AFTER trigger) must not exceed the invoice amount
    SELECT TOP 1 @m = CONCAT('Payments (total ', t.total, ') exceed invoice amount (', v.amount, ')')
    FROM (SELECT DISTINCT invoice_id FROM inserted) i
    JOIN noir.invoice v ON v.invoice_id = i.invoice_id
    CROSS APPLY (SELECT SUM(p.amount) AS total FROM noir.payment p WHERE p.invoice_id = i.invoice_id) t
    WHERE t.total > v.amount;
    IF @m IS NOT NULL BEGIN IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; THROW 50001, @m, 1; END;
END;
GO

GO
