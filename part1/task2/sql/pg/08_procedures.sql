SET search_path = noir;

-- SECURITY DEFINER: the procedure runs with the privileges of its owner (the role it was created with), not of the caller. The application role gets EXECUTE
-- on the procedure rather than rights to tables. INOUT parameters return the result (number, message).

-- ===================== PAYMENT REGISTRATION =====================
-- Payment for an invoice identified by number, payment method by name; returns the id of the new payment.
-- The rules (amount not greater than the balance, date) are enforced by the trg_payment trigger.
CREATE PROCEDURE sp_register_payment(p_invoice_number VARCHAR, p_method_name VARCHAR, p_amount NUMERIC,
                                     p_paid_on DATE, INOUT p_payment_id INTEGER)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = noir AS $$
DECLARE v_invoice INTEGER; v_method SMALLINT;
BEGIN
    -- step 1: find the invoice by its number; an unknown number is an error
    SELECT invoice_id INTO v_invoice FROM invoice WHERE invoice_number = p_invoice_number;
    IF v_invoice IS NULL THEN
        RAISE EXCEPTION 'Invoice does not exist: %', p_invoice_number USING ERRCODE = 'foreign_key_violation';
    END IF;
    -- step 2: find the payment method by its name; an unknown name is an error
    SELECT method_id INTO v_method FROM payment_method WHERE name = p_method_name;
    IF v_method IS NULL THEN
        RAISE EXCEPTION 'Unknown payment method: %', p_method_name USING ERRCODE = 'foreign_key_violation';
    END IF;
    -- step 3: add the payment (today if no date is given) and return its id; the trigger checks amount and dates
    INSERT INTO payment (invoice_id, method_id, paid_on, amount)
    VALUES (v_invoice, v_method, COALESCE(p_paid_on, CURRENT_DATE), p_amount)
    RETURNING payment_id INTO p_payment_id;
END $$;

-- ===================== CASE OPENING =====================
-- Opening a case: number from the document counter (document_counter), case record, status history entry, lead detective.
-- The number is always greater than the last one issued, even after deleting the case with the highest number;
-- The counter is incremented by one INSERT ... ON CONFLICT DO UPDATE, which locks the row until the end of the transaction, so concurrent transactions get different numbers.
-- The BEGIN ... EXCEPTION block is a subtransaction: an error in any step rolls back all changes of the block,
-- after which the procedure records the error in operation_log and returns a message in p_result.
CREATE PROCEDURE sp_open_case(p_client_id INTEGER, p_type_name VARCHAR, p_title VARCHAR, p_description VARCHAR,
                              p_fee_estimate NUMERIC, p_lead_detective_id INTEGER,
                              INOUT p_case_number VARCHAR, INOUT p_result VARCHAR)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = noir AS $$
DECLARE v_type SMALLINT; v_status SMALLINT; v_case INTEGER; v_year INTEGER := EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER; v_value INTEGER;
BEGIN
    p_case_number := NULL;
    BEGIN
        -- step 1: the client must exist
        IF NOT EXISTS (SELECT 1 FROM client WHERE client_id = p_client_id) THEN
            RAISE EXCEPTION 'Client does not exist: id %', p_client_id;
        END IF;
        -- step 2: the case type must exist
        SELECT type_id INTO v_type FROM case_type WHERE name = p_type_name;
        IF v_type IS NULL THEN
            RAISE EXCEPTION 'Unknown case type: %', p_type_name;
        END IF;
        -- step 3: a new case always starts in the status Open
        SELECT status_id INTO v_status FROM case_status WHERE name = 'Open';
        -- step 4: next case number: the counter row for the year is created with 1 or, if it exists, increased by 1
        INSERT INTO document_counter (counter_name, counter_year, last_value) VALUES ('CASE', v_year, 1)
        ON CONFLICT (counter_name, counter_year) DO UPDATE SET last_value = document_counter.last_value + 1
        RETURNING last_value INTO v_value;
        -- step 5: build the number NOIR-<year>-<counter padded to 3 digits>
        p_case_number := 'NOIR-' || v_year || '-' || LPAD(v_value::VARCHAR, 3, '0');
        -- step 6: add the case
        INSERT INTO case_file (case_number, title, description, type_id, status_id, client_id, opened_on, fee_estimate)
        VALUES (p_case_number, p_title, p_description, v_type, v_status, p_client_id, CURRENT_DATE, COALESCE(p_fee_estimate, 0))
        RETURNING case_id INTO v_case;
        -- step 7: first status history entry (no old status)
        INSERT INTO case_status_history (case_id, old_status_id, new_status_id, changed_by)
        VALUES (v_case, NULL, v_status, CURRENT_USER);
        -- step 8: the lead detective must exist and be active; the error here rolls back steps 4-7 as well
        IF NOT EXISTS (SELECT 1 FROM detective WHERE detective_id = p_lead_detective_id AND is_active) THEN
            RAISE EXCEPTION 'Detective % does not exist or is not active', p_lead_detective_id;
        END IF;
        -- step 9: assign the lead detective
        INSERT INTO case_detective (case_id, detective_id, role, assigned_on)
        VALUES (v_case, p_lead_detective_id, 'LEAD', CURRENT_DATE);
        -- step 10: success: return the message and log it
        p_result := 'OK: case opened ' || p_case_number;
        INSERT INTO operation_log (procedure_name, severity, message) VALUES ('sp_open_case', 'INFO', p_result);
    -- on any error: all changes of the block are rolled back; return the message and log the error
    EXCEPTION WHEN OTHERS THEN
        p_case_number := NULL;
        p_result := 'ERROR: ' || SQLERRM;
        INSERT INTO operation_log (procedure_name, severity, message) VALUES ('sp_open_case', 'ERROR', LEFT(SQLERRM, 500));
    END;
END $$;
