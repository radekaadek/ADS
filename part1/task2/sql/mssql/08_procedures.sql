USE noir;
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
-- The procedure and tables belong to one owner (noir_admin): ownership chaining lets the application role,
-- which has only EXECUTE on the procedure, modify data in tables. Results are returned via OUTPUT parameters.

-- ===================== PAYMENT REGISTRATION =====================
-- Payment for an invoice identified by number, payment method by name; returns the id of the new payment.
-- The rules (amount not greater than the balance, date) are enforced by the trg_payment trigger.
CREATE PROCEDURE noir.sp_register_payment @invoice_number VARCHAR(20), @method_name VARCHAR(40),
                                          @amount NUMERIC(10,2), @paid_on DATE, @payment_id INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @m NVARCHAR(500);
    DECLARE @invoice INT, @method SMALLINT;
    -- step 1: find the invoice by its number and the payment method by its name
    SELECT @invoice = invoice_id FROM noir.invoice WHERE invoice_number = @invoice_number;
    SELECT @method = method_id FROM noir.payment_method WHERE name = @method_name;
    -- step 2: an unknown invoice or method is an error
    IF @invoice IS NULL BEGIN SET @m = CONCAT('Invoice does not exist: ', @invoice_number); THROW 50001, @m, 1; END;
    IF @method IS NULL BEGIN SET @m = CONCAT('Unknown payment method: ', @method_name); THROW 50001, @m, 1; END;
    -- step 3: add the payment (today if no date is given); the trigger checks amount and dates
    INSERT INTO noir.payment (invoice_id, method_id, paid_on, amount)
    VALUES (@invoice, @method, COALESCE(@paid_on, CAST(SYSDATETIME() AS DATE)), @amount);
    -- step 4: return the id of the new payment
    SET @payment_id = SCOPE_IDENTITY();
END;
GO

-- ===================== CASE OPENING =====================
-- Opening a case: number from the document counter (document_counter), case record, status history entry, lead detective.
-- The number is always greater than the last one issued, even after deleting the case with the highest number;
-- UPDATE of the counter locks the row until the end of the transaction, so concurrent transactions get different numbers.
-- An error in any step rolls back the transaction (CATCH), after which the procedure records the error in operation_log.
CREATE PROCEDURE noir.sp_open_case @client_id INT, @type_name VARCHAR(40), @title VARCHAR(150), @description VARCHAR(2000),
                                   @fee_estimate NUMERIC(10,2), @lead_detective_id INT,
                                   @case_number VARCHAR(20) OUTPUT, @result VARCHAR(500) OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @m NVARCHAR(500);
    DECLARE @type SMALLINT, @status SMALLINT, @case INT, @err VARCHAR(500), @value INT;
    DECLARE @year INT = YEAR(SYSDATETIME());
    SET @case_number = NULL;
    BEGIN TRY
        -- everything below is one transaction: either all steps succeed or none is saved
        BEGIN TRAN;
        -- step 1: the client must exist
        IF NOT EXISTS (SELECT 1 FROM noir.client WHERE client_id = @client_id)
            BEGIN SET @m = CONCAT('Client does not exist: id ', @client_id); THROW 50001, @m, 1; END;
        -- step 2: the case type must exist
        SELECT @type = type_id FROM noir.case_type WHERE name = @type_name;
        IF @type IS NULL
            BEGIN SET @m = CONCAT('Unknown case type: ', @type_name); THROW 50001, @m, 1; END;
        -- step 3: a new case always starts in the status Open
        SELECT @status = status_id FROM noir.case_status WHERE name = 'Open';
        -- step 4: next case number: create the counter row for the year if it is missing (the lock hints keep two
        -- concurrent transactions from creating it twice), then increase it by 1 and read the new value
        IF NOT EXISTS (SELECT 1 FROM noir.document_counter WITH (UPDLOCK, HOLDLOCK) WHERE counter_name = 'CASE' AND counter_year = @year)
            INSERT INTO noir.document_counter (counter_name, counter_year, last_value) VALUES ('CASE', @year, 0);
        UPDATE noir.document_counter SET @value = last_value = last_value + 1
        WHERE counter_name = 'CASE' AND counter_year = @year;
        -- step 5: build the number NOIR-<year>-<counter padded to 3 digits>
        SET @case_number = 'NOIR-' + CAST(@year AS VARCHAR(4)) + '-' + RIGHT('000' + CAST(@value AS VARCHAR(10)), 3);
        -- step 6: add the case
        INSERT INTO noir.case_file (case_number, title, description, type_id, status_id, client_id, opened_on, fee_estimate)
        VALUES (@case_number, @title, @description, @type, @status, @client_id, CAST(SYSDATETIME() AS DATE), COALESCE(@fee_estimate, 0));
        SET @case = SCOPE_IDENTITY();
        -- step 7: first status history entry (no old status)
        INSERT INTO noir.case_status_history (case_id, old_status_id, new_status_id, changed_by)
        VALUES (@case, NULL, @status, SUSER_SNAME());
        -- step 8: the lead detective must exist and be active; the error here rolls back steps 4-7 as well
        IF NOT EXISTS (SELECT 1 FROM noir.detective WHERE detective_id = @lead_detective_id AND is_active = 1)
            BEGIN SET @m = CONCAT('Detective ', @lead_detective_id, ' does not exist or is not active'); THROW 50001, @m, 1; END;
        -- step 9: assign the lead detective
        INSERT INTO noir.case_detective (case_id, detective_id, role, assigned_on)
        VALUES (@case, @lead_detective_id, 'LEAD', CAST(SYSDATETIME() AS DATE));
        -- step 10: save the transaction, return the message and log it
        COMMIT;
        SET @result = 'OK: case opened ' + @case_number;
        INSERT INTO noir.operation_log (procedure_name, severity, message) VALUES ('sp_open_case', 'INFO', @result);
    END TRY
    -- on any error: roll back the transaction (if still open), return the message and log the error
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        SET @case_number = NULL;
        SET @err = LEFT(ERROR_MESSAGE(), 500);
        SET @result = 'ERROR: ' + @err;
        INSERT INTO noir.operation_log (procedure_name, severity, message) VALUES ('sp_open_case', 'ERROR', @err);
    END CATCH;
END;
GO
