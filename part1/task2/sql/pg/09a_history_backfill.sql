SET search_path = noir;
-- Status history for cases from the sample data:
-- case creation (status Open on the opening date) and, if the status differs, a transition on the closing (or opening) date
INSERT INTO case_status_history (case_id, old_status_id, new_status_id, changed_at, changed_by)
SELECT c.case_id, NULL, o.status_id, c.opened_on, 'migration'
FROM case_file c CROSS JOIN (SELECT status_id FROM case_status WHERE name = 'Open') o;
INSERT INTO case_status_history (case_id, old_status_id, new_status_id, changed_at, changed_by)
SELECT c.case_id, o.status_id, c.status_id, COALESCE(c.closed_on, c.opened_on) + INTERVAL '1 hour', 'migration'
FROM case_file c CROSS JOIN (SELECT status_id FROM case_status WHERE name = 'Open') o
WHERE c.status_id <> o.status_id;
