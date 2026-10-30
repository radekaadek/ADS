USE noir;
GO
-- Users (passwords for coursework only). Nothing is granted at schema level:
-- every permission is explicit, and no GRANT means no access.
IF SUSER_ID('detective_app') IS NULL CREATE LOGIN detective_app WITH PASSWORD = 'Detective_pw1', CHECK_POLICY = OFF;
IF SUSER_ID('accountant_app') IS NULL CREATE LOGIN accountant_app WITH PASSWORD = 'Accountant_pw1', CHECK_POLICY = OFF;
IF SUSER_ID('client_portal') IS NULL CREATE LOGIN client_portal WITH PASSWORD = 'Client_pw1', CHECK_POLICY = OFF;
IF DATABASE_PRINCIPAL_ID('detective_app') IS NULL CREATE USER detective_app FOR LOGIN detective_app WITH DEFAULT_SCHEMA = noir;
IF DATABASE_PRINCIPAL_ID('accountant_app') IS NULL CREATE USER accountant_app FOR LOGIN accountant_app WITH DEFAULT_SCHEMA = noir;
IF DATABASE_PRINCIPAL_ID('client_portal') IS NULL CREATE USER client_portal FOR LOGIN client_portal WITH DEFAULT_SCHEMA = noir;
GO

-- Detective: read of investigation tables and operational views, work on cases and evidence; no finance
GRANT SELECT ON noir.case_status TO detective_app;
GRANT SELECT ON noir.case_type TO detective_app;
GRANT SELECT ON noir.evidence_type TO detective_app;
GRANT SELECT ON noir.detective_rank TO detective_app;
GRANT SELECT ON noir.client TO detective_app;
GRANT SELECT ON noir.detective TO detective_app;
GRANT SELECT ON noir.location TO detective_app;
GRANT SELECT ON noir.case_file TO detective_app;
GRANT SELECT ON noir.suspect TO detective_app;
GRANT SELECT ON noir.witness TO detective_app;
GRANT SELECT ON noir.informant TO detective_app;
GRANT SELECT ON noir.evidence TO detective_app;
GRANT SELECT ON noir.tip TO detective_app;
GRANT SELECT ON noir.case_detective TO detective_app;
GRANT SELECT ON noir.case_suspect TO detective_app;
GRANT SELECT ON noir.case_witness TO detective_app;
GRANT SELECT ON noir.evidence_custody TO detective_app;
GRANT SELECT ON noir.case_status_history TO detective_app;
GRANT SELECT ON noir.v_case_overview TO detective_app;
GRANT SELECT ON noir.v_detective_workload TO detective_app;
GRANT SELECT ON noir.v_evidence_chain TO detective_app;
GRANT SELECT ON noir.v_client_cases TO detective_app;
GRANT SELECT ON noir.v_stale_cases TO detective_app;
GRANT INSERT, UPDATE ON noir.case_file TO detective_app;
GRANT INSERT, UPDATE ON noir.evidence TO detective_app;
GRANT INSERT, UPDATE ON noir.suspect TO detective_app;
GRANT INSERT, UPDATE ON noir.witness TO detective_app;
GRANT INSERT, UPDATE ON noir.tip TO detective_app;
GRANT INSERT, UPDATE ON noir.case_detective TO detective_app;
GRANT INSERT, UPDATE ON noir.case_suspect TO detective_app;
GRANT INSERT, UPDATE ON noir.case_witness TO detective_app;
-- Chain of custody is append-only
GRANT INSERT ON noir.evidence_custody TO detective_app;
GRANT INSERT, UPDATE ON noir.location TO detective_app;
GRANT INSERT, UPDATE ON noir.informant TO detective_app;
GRANT DELETE ON noir.case_suspect TO detective_app;
GRANT DELETE ON noir.case_witness TO detective_app;
GRANT EXECUTE ON noir.sp_open_case TO detective_app;
GRANT SELECT ON noir.fn_case_timeline TO detective_app;

-- Accountant: finance views + finance tables; from the case table only the columns needed for invoicing
GRANT SELECT ON noir.v_invoice_balance TO accountant_app;
GRANT SELECT ON noir.v_case_financials TO accountant_app;
GRANT SELECT ON noir.v_client_balance TO accountant_app;
GRANT SELECT ON noir.monthly_case_stats TO accountant_app;
GRANT SELECT (case_id, case_number, title, client_id, fee_estimate) ON noir.case_file TO accountant_app;
GRANT SELECT, INSERT, UPDATE ON noir.invoice TO accountant_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON noir.payment TO accountant_app;
GRANT SELECT ON noir.payment_method TO accountant_app;
GRANT EXECUTE ON noir.sp_register_payment TO accountant_app;

-- Client: only the view of their own cases
GRANT SELECT ON noir.v_client_cases TO client_portal;
GO
