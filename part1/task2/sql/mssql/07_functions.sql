USE noir;
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
-- ===================== TABLE FUNCTION (for users) =====================
-- Case timeline: investigation events from several tables (sorting left to the caller: ORDER BY event_at, event_type)
CREATE FUNCTION noir.fn_case_timeline(@case_id INT)
RETURNS TABLE
AS
RETURN
    -- step 1: the opening of the case (a date, converted to a timestamp so that all branches have the same type)
    SELECT CAST(c.opened_on AS DATETIME2(6)) AS event_at, CAST('CASE_OPENED' AS VARCHAR(20)) AS event_type, CAST(c.title AS VARCHAR(300)) AS description
    FROM noir.case_file c WHERE c.case_id = @case_id
    UNION ALL
    -- step 2: status changes (the first history entry, with no old status, only repeats the opening, so it is skipped)
    SELECT h.changed_at, 'STATUS', '-> ' + s.name
    FROM noir.case_status_history h JOIN noir.case_status s ON s.status_id = h.new_status_id
    WHERE h.case_id = @case_id AND h.old_status_id IS NOT NULL
    UNION ALL
    -- step 3: evidence found in the case
    SELECT e.found_at, 'EVIDENCE', e.evidence_code + ': ' + e.description FROM noir.evidence e WHERE e.case_id = @case_id
    UNION ALL
    -- step 4: tips received
    SELECT t.received_at, 'TIP', t.content FROM noir.tip t WHERE t.case_id = @case_id
    UNION ALL
    -- step 5: witness statements (no ORDER BY: a function returning a table cannot sort its result)
    SELECT CAST(cw.statement_date AS DATETIME2(6)), 'STATEMENT', w.first_name + ' ' + w.last_name
    FROM noir.case_witness cw JOIN noir.witness w ON w.witness_id = cw.witness_id WHERE cw.case_id = @case_id;
GO
GO
