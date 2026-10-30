SET search_path = noir;

-- Document number counters: the next number is always greater than the last one issued, even after deleting the document
-- with the highest number (counter_year = 0 for continuous numbering, not split by year)
CREATE TABLE document_counter (
    counter_name VARCHAR(20) NOT NULL,
    counter_year INTEGER     NOT NULL,
    last_value   INTEGER     NOT NULL,
    CONSTRAINT pk_document_counter PRIMARY KEY (counter_name, counter_year),
    CONSTRAINT ck_document_counter_name CHECK (counter_name IN ('CASE', 'INVOICE', 'EVIDENCE')),
    CONSTRAINT ck_document_counter_value CHECK (last_value >= 0)
);

-- initial state from the numbers of existing documents
INSERT INTO document_counter (counter_name, counter_year, last_value)
SELECT 'CASE', SUBSTRING(case_number FROM 6 FOR 4)::INTEGER, MAX(SUBSTRING(case_number FROM 11)::INTEGER)
FROM case_file GROUP BY SUBSTRING(case_number FROM 6 FOR 4);
INSERT INTO document_counter (counter_name, counter_year, last_value)
SELECT 'INVOICE', SUBSTRING(invoice_number FROM 5 FOR 4)::INTEGER, MAX(SUBSTRING(invoice_number FROM 10)::INTEGER)
FROM invoice GROUP BY SUBSTRING(invoice_number FROM 5 FOR 4);
INSERT INTO document_counter (counter_name, counter_year, last_value)
SELECT 'EVIDENCE', 0, MAX(SUBSTRING(evidence_code FROM 4)::INTEGER) FROM evidence HAVING COUNT(*) > 0;

-- Case status change history (filled by a trigger)
CREATE TABLE case_status_history (
    history_id    INTEGER GENERATED ALWAYS AS IDENTITY,
    case_id       INTEGER NOT NULL,
    old_status_id SMALLINT,
    new_status_id SMALLINT NOT NULL,
    changed_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    changed_by    VARCHAR(60) NOT NULL DEFAULT SESSION_USER,
    CONSTRAINT pk_case_status_history PRIMARY KEY (history_id),
    CONSTRAINT fk_csh_case FOREIGN KEY (case_id)       REFERENCES case_file (case_id),
    CONSTRAINT fk_csh_old  FOREIGN KEY (old_status_id) REFERENCES case_status (status_id),
    CONSTRAINT fk_csh_new  FOREIGN KEY (new_status_id) REFERENCES case_status (status_id)
);

-- Log of errors and events of stored procedures
CREATE TABLE operation_log (
    log_id      INTEGER GENERATED ALWAYS AS IDENTITY,
    logged_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    logged_by   VARCHAR(60) NOT NULL DEFAULT SESSION_USER,
    procedure_name VARCHAR(60) NOT NULL,
    severity    VARCHAR(10) NOT NULL,
    message     VARCHAR(500) NOT NULL,
    CONSTRAINT pk_operation_log PRIMARY KEY (log_id),
    CONSTRAINT ck_operation_log_severity CHECK (severity IN ('INFO', 'ERROR'))
);

-- Alerts created by the nightly job (overdue invoice, case without activity); closed when the cause ceases
CREATE TABLE alert (
    alert_id    INTEGER GENERATED ALWAYS AS IDENTITY,
    alert_type  VARCHAR(20) NOT NULL,
    case_id     INTEGER NOT NULL,
    invoice_id  INTEGER,
    raised_on   DATE NOT NULL,
    resolved_on DATE,
    message     VARCHAR(300) NOT NULL,
    CONSTRAINT pk_alert PRIMARY KEY (alert_id),
    CONSTRAINT fk_alert_case    FOREIGN KEY (case_id)    REFERENCES case_file (case_id),
    CONSTRAINT fk_alert_invoice FOREIGN KEY (invoice_id) REFERENCES invoice (invoice_id),
    CONSTRAINT ck_alert_type CHECK (alert_type IN ('OVERDUE_INVOICE', 'STALE_CASE')),
    CONSTRAINT ck_alert_dates CHECK (resolved_on IS NULL OR resolved_on >= raised_on)
);

-- Monthly snapshot of case statistics by type (filled by the nightly job)
CREATE TABLE monthly_case_stats (
    period_start DATE     NOT NULL,
    type_id      SMALLINT NOT NULL,
    opened_cnt   INTEGER  NOT NULL,
    closed_cnt   INTEGER  NOT NULL,
    invoiced     NUMERIC(12,2) NOT NULL,
    paid         NUMERIC(12,2) NOT NULL,
    refreshed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_monthly_case_stats PRIMARY KEY (period_start, type_id),
    CONSTRAINT fk_mcs_type FOREIGN KEY (type_id) REFERENCES case_type (type_id)
);

-- Runs of automated jobs
CREATE TABLE job_run_log (
    run_id      INTEGER GENERATED ALWAYS AS IDENTITY,
    job_name    VARCHAR(60) NOT NULL,
    started_at  TIMESTAMP NOT NULL,
    finished_at TIMESTAMP,
    status      VARCHAR(10) NOT NULL,
    details     VARCHAR(500),
    CONSTRAINT pk_job_run_log PRIMARY KEY (run_id),
    CONSTRAINT ck_job_run_status CHECK (status IN ('RUNNING', 'OK', 'ERROR'))
);

CREATE INDEX ix_csh_case ON case_status_history (case_id, changed_at);
-- at most one open alert per overdue invoice and one per inactive case
CREATE UNIQUE INDEX uq_alert_open_invoice ON alert (invoice_id) WHERE resolved_on IS NULL AND invoice_id IS NOT NULL;
CREATE UNIQUE INDEX uq_alert_open_stale   ON alert (case_id)    WHERE resolved_on IS NULL AND alert_type = 'STALE_CASE';
CREATE INDEX ix_alert_case    ON alert (case_id);
CREATE INDEX ix_alert_invoice ON alert (invoice_id);
CREATE INDEX ix_operation_log_time ON operation_log (logged_at);
CREATE INDEX ix_job_run_log_job ON job_run_log (job_name, started_at);
