-- Users (passwords for coursework only)
CREATE ROLE detective_app LOGIN PASSWORD 'detective_pw';
CREATE ROLE accountant_app LOGIN PASSWORD 'accountant_pw';
CREATE ROLE client_portal LOGIN PASSWORD 'client_pw';

REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE noir TO detective_app, accountant_app, client_portal;
GRANT USAGE ON SCHEMA noir TO detective_app, accountant_app, client_portal;

-- Detective: full work on cases and evidence, no access to finance
GRANT SELECT ON ALL TABLES IN SCHEMA noir TO detective_app;
REVOKE ALL ON noir.invoice, noir.payment, noir.payment_method, noir.v_invoice_balance FROM detective_app;
GRANT INSERT, UPDATE ON noir.case_file, noir.evidence, noir.suspect,
      noir.witness, noir.tip, noir.case_detective, noir.case_suspect, noir.case_witness TO detective_app;
-- Chain of custody is append-only: without UPDATE and DELETE the transfer history cannot be changed
GRANT INSERT ON noir.evidence_custody TO detective_app;
-- New locations and informants appear during an investigation; mistaken links can be removed
GRANT INSERT, UPDATE ON noir.location, noir.informant TO detective_app;
GRANT DELETE ON noir.case_suspect, noir.case_witness TO detective_app;
GRANT SELECT ON noir.v_case_overview, noir.v_detective_workload, noir.v_evidence_chain TO detective_app;

-- Accountant: views + full access to finance tables; from the case table only the columns needed for invoicing
-- (no case description; SELECT granted at column level)
GRANT SELECT ON noir.v_invoice_balance TO accountant_app;
GRANT SELECT (case_id, case_number, title, client_id, fee_estimate) ON noir.case_file TO accountant_app;
GRANT SELECT, INSERT, UPDATE ON noir.invoice TO accountant_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON noir.payment TO accountant_app;
GRANT SELECT ON noir.payment_method TO accountant_app;

-- Client: only the view of their own cases
GRANT SELECT ON noir.v_client_cases TO client_portal;

ALTER ROLE detective_app  SET search_path = noir;
ALTER ROLE accountant_app SET search_path = noir;
ALTER ROLE client_portal  SET search_path = noir;
