USE noir;
GO
-- PK and UNIQUE create indexes automatically. Foreign keys are not indexed automatically,
-- so we add a nonclustered (B-tree) index where an FK takes part in JOINs or filters.

-- case_file: a client's cases in a given status since a date (equality, equality, range) -> one multi-column index;
-- it also serves client_id alone (left prefix), so a separate index on client is unnecessary
CREATE INDEX ix_case_file_client_status_opened ON case_file (client_id, status_id, opened_on);
CREATE INDEX ix_case_file_type                 ON case_file (type_id);
-- status_id is not the first column of the multi-column index, and views join and queries filter on it
CREATE INDEX ix_case_file_status               ON case_file (status_id);

-- evidence: evidence of a given case and a filter by type within a case
CREATE INDEX ix_evidence_case_type ON evidence (case_id, evidence_type_id);
CREATE INDEX ix_evidence_location  ON evidence (location_id);
CREATE INDEX ix_evidence_type      ON evidence (evidence_type_id);

-- junction tables: PK (case_id, x) serves lookups by case_id; the reverse direction needs a second index
CREATE INDEX ix_case_detective_detective ON case_detective (detective_id);
-- at most one lead (LEAD) per case
CREATE UNIQUE INDEX uq_case_detective_lead ON case_detective (case_id) WHERE role = 'LEAD';
CREATE INDEX ix_case_suspect_suspect     ON case_suspect (suspect_id);
CREATE INDEX ix_case_witness_witness     ON case_witness (witness_id);

-- chain of custody: who holds the evidence
CREATE INDEX ix_evidence_custody_detective ON evidence_custody (detective_id);

-- finance
CREATE INDEX ix_invoice_case    ON invoice (case_id);
CREATE INDEX ix_payment_invoice ON payment (invoice_id);
CREATE INDEX ix_payment_method  ON payment (method_id);

-- overdue invoices report (range on due_on)
CREATE INDEX ix_invoice_due ON invoice (due_on);

CREATE INDEX ix_tip_informant ON tip (informant_id);
CREATE INDEX ix_tip_case      ON tip (case_id);
CREATE INDEX ix_detective_rank ON detective (rank_id);
CREATE INDEX ix_informant_handler ON informant (handler_id);
-- searching people by last name
CREATE INDEX ix_suspect_last_name ON suspect (last_name);
CREATE INDEX ix_witness_last_name ON witness (last_name);
CREATE INDEX ix_suspect_location ON suspect (last_seen_location_id);
-- client, location, evidence_custody(evidence_id): no extra indexes - primary key or UNIQUE
-- (evidence_id, transferred_at) already serves lookups; client and location have no foreign keys.
