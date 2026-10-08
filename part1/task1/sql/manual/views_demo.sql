SET search_path = noir;
\echo '-- v_case_overview'
SELECT case_number, case_type, status, lead_detective, days_open, evidence_count FROM v_case_overview ORDER BY days_open, case_number;
\echo '-- v_detective_workload'
SELECT detective, detective_rank, active_cases, all_cases, led_cases FROM v_detective_workload ORDER BY active_cases DESC, detective;
\echo '-- v_invoice_balance'
SELECT invoice_number, client, amount, paid, balance, payment_status FROM v_invoice_balance ORDER BY invoice_number;
\echo '-- v_client_cases (klient: Gutman Kasper)'
SELECT case_number, title, status FROM v_client_cases WHERE client_email = 'kasper@fatbird.example';
\echo '-- v_evidence_chain (dowod EV-0008)'
SELECT evidence_code, evidence_type, transferred_at, custodian, note FROM v_evidence_chain WHERE evidence_code = 'EV-0008' ORDER BY transferred_at;
