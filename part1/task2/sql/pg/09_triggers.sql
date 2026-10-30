SET search_path = noir;
-- SECURITY DEFINER: the trigger function runs with the privileges of its owner (the role it was created with), so the business rule applies regardless of the rights of the role modifying the data.

-- ===================== FINANCE =====================
-- Payment: a payment cannot be dated before the invoice is issued or in the future, and the total of all payments for an invoice cannot exceed the invoice amount.
CREATE FUNCTION fn_trg_payment() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = noir AS $$
DECLARE v_amount NUMERIC; v_issued DATE; v_paid NUMERIC;
BEGIN
    -- step 1: read the invoice amount and issue date; FOR UPDATE locks the invoice row, so two concurrent payments
    -- for the same invoice are checked one after another and cannot exceed the amount together
    SELECT amount, issued_on INTO v_amount, v_issued FROM invoice WHERE invoice_id = NEW.invoice_id FOR UPDATE;
    -- step 2: the payment must not be dated before the invoice was issued
    IF NEW.paid_on < v_issued THEN
        RAISE EXCEPTION 'Payment (%) is before invoice issue date (%)', NEW.paid_on, v_issued USING ERRCODE = 'check_violation';
    END IF;
    -- step 3: the payment must not be dated in the future
    IF NEW.paid_on > CURRENT_DATE THEN
        RAISE EXCEPTION 'Payment date is in the future (%)', NEW.paid_on USING ERRCODE = 'check_violation';
    END IF;
    -- step 4: total of the payments for the invoice: the other payments plus the new one
    -- (on UPDATE the changed row itself is excluded, so it is not counted twice)
    SELECT COALESCE(SUM(amount), 0) + NEW.amount INTO v_paid FROM payment
    WHERE invoice_id = NEW.invoice_id AND (TG_OP = 'INSERT' OR payment_id <> NEW.payment_id);
    -- step 5: the total must not exceed the invoice amount
    IF v_paid > v_amount THEN
        RAISE EXCEPTION 'Payments (total %) exceed invoice amount (%)', v_paid, v_amount USING ERRCODE = 'check_violation';
    END IF;
    -- step 6: all rules hold, the row is saved (an exception above cancels the whole statement)
    RETURN NEW;
END $$;
CREATE TRIGGER trg_payment BEFORE INSERT OR UPDATE ON payment
    FOR EACH ROW EXECUTE FUNCTION fn_trg_payment();
