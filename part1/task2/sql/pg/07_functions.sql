SET search_path = noir;

-- ===================== TABLE FUNCTION (for users) =====================
-- Case timeline: investigation events from several tables in chronological order (no finance)
CREATE FUNCTION fn_case_timeline(p_case_id INTEGER)
RETURNS TABLE (event_at TIMESTAMP, event_type VARCHAR, description VARCHAR)
LANGUAGE sql STABLE SET search_path = noir AS $$
    -- step 1: the opening of the case (a date, converted to a timestamp so that all branches have the same type)
    SELECT c.opened_on::TIMESTAMP, 'CASE_OPENED'::VARCHAR, c.title::VARCHAR FROM case_file c WHERE c.case_id = p_case_id
    UNION ALL
    -- step 2: status changes (the first history entry, with no old status, only repeats the opening, so it is skipped)
    SELECT h.changed_at, 'STATUS'::VARCHAR, ('-> ' || s.name)::VARCHAR
    FROM case_status_history h JOIN case_status s ON s.status_id = h.new_status_id
    WHERE h.case_id = p_case_id AND h.old_status_id IS NOT NULL
    UNION ALL
    -- step 3: evidence found in the case
    SELECT e.found_at, 'EVIDENCE'::VARCHAR, (e.evidence_code || ': ' || e.description)::VARCHAR FROM evidence e WHERE e.case_id = p_case_id
    UNION ALL
    -- step 4: tips received
    SELECT t.received_at, 'TIP'::VARCHAR, t.content::VARCHAR FROM tip t WHERE t.case_id = p_case_id
    UNION ALL
    -- step 5: witness statements
    SELECT cw.statement_date::TIMESTAMP, 'STATEMENT'::VARCHAR, (w.first_name || ' ' || w.last_name)::VARCHAR
    FROM case_witness cw JOIN witness w ON w.witness_id = cw.witness_id WHERE cw.case_id = p_case_id
    -- step 6: all events together in chronological order (by time, then by type)
    ORDER BY 1, 2
$$;
