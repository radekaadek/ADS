SET search_path = noir;

-- Database link to SQL Server (tds_fdw) and two-way synchronization of the partner agency register.
-- The register is kept in both systems; every row carries the time of its last change (UTC), and the newer version wins.
CREATE TABLE partner_agency (
    agency_code VARCHAR(10)  NOT NULL,
    name        VARCHAR(100) NOT NULL,
    city        VARCHAR(60)  NOT NULL,
    phone       VARCHAR(20),
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    updated_at  TIMESTAMP(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'UTC'),
    CONSTRAINT pk_partner_agency PRIMARY KEY (agency_code)
);

-- A change made by a user gets the current time; a change made by the synchronization carries the time of the source row,
-- so it is not treated as a new change and does not return to the other system.
CREATE FUNCTION fn_trg_partner_agency_touch() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at THEN
        NEW.updated_at := CURRENT_TIMESTAMP AT TIME ZONE 'UTC';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_partner_agency_touch BEFORE UPDATE ON partner_agency
    FOR EACH ROW EXECUTE FUNCTION fn_trg_partner_agency_touch();

-- Database link: foreign server and a user mapped to a SQL Server login with rights to this one table only
CREATE EXTENSION IF NOT EXISTS tds_fdw;
CREATE SERVER mssql_noir FOREIGN DATA WRAPPER tds_fdw
    OPTIONS (servername 'mssql', port '1433', database 'noir', tds_version '7.4', msg_handler 'notice');
CREATE USER MAPPING FOR noir_admin SERVER mssql_noir OPTIONS (username 'sync_link', password 'Agency_Link_pw1');
CREATE FOREIGN TABLE mssql_partner_agency (
    agency_code VARCHAR(10) OPTIONS (key 'true') NOT NULL,
    name        VARCHAR(100) NOT NULL,
    city        VARCHAR(60)  NOT NULL,
    phone       VARCHAR(20),
    is_active   BOOLEAN      NOT NULL,
    updated_at  VARCHAR(30)  NOT NULL
) SERVER mssql_noir OPTIONS (query 'SELECT agency_code, name, city, phone, is_active, CONVERT(VARCHAR(30), updated_at, 126) AS updated_at FROM noir.partner_agency');
-- the wrapper does not parse SQL Server date and time values, so the time is passed as ISO 8601 text and converted here

-- The wrapper is read-only, so rows are written to SQL Server by calling a procedure there: a foreign table with a fixed
-- "query" option is re-pointed to the T-SQL batch to run, and reading it executes the batch on SQL Server
-- (the wrapper reads the first result set, which the procedure returns as one confirmation row).
CREATE FOREIGN TABLE mssql_call (done INTEGER) SERVER mssql_noir OPTIONS (query 'SELECT 1 AS done');

-- T-SQL string literal (Unicode) or NULL
CREATE FUNCTION fn_tsql_str(p_value TEXT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE('N''' || REPLACE(p_value, '''', '''''') || '''', 'NULL')
$$;

CREATE FUNCTION fn_mssql_apply_partner_agency(p_row partner_agency) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = noir AS $$
BEGIN
    EXECUTE format('ALTER FOREIGN TABLE mssql_call OPTIONS (SET query %L)',
        'EXEC noir.sp_apply_partner_agency @agency_code = ' || fn_tsql_str(p_row.agency_code)
        || ', @name = ' || fn_tsql_str(p_row.name) || ', @city = ' || fn_tsql_str(p_row.city)
        || ', @phone = ' || fn_tsql_str(p_row.phone) || ', @is_active = ' || CASE WHEN p_row.is_active THEN 1 ELSE 0 END
        || ', @updated_at = ''' || TO_CHAR(p_row.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS.MS') || '''');
    PERFORM * FROM mssql_call;
END $$;

-- Synchronization: one pass in both directions, result in job_run_log.
--  1. read the SQL Server register once (a single remote query),
--  2. rows missing locally or newer in SQL Server are written here,
--  3. rows missing in SQL Server or newer here are written to SQL Server (through the procedure on the SQL Server side).
-- Rows with equal time are identical and are skipped. Records are not deleted: a withdrawn agency gets is_active = FALSE.
-- A failure (e.g. SQL Server unavailable) is recorded in the log and the next run tries again.
CREATE PROCEDURE sp_sync_partner_agency()
LANGUAGE plpgsql SECURITY DEFINER SET search_path = noir AS $$
DECLARE v_run INTEGER; v_pulled INTEGER; v_pushed_new INTEGER; v_pushed_upd INTEGER; r partner_agency%ROWTYPE;
BEGIN
    INSERT INTO job_run_log (job_name, started_at, status) VALUES ('partner_sync', CURRENT_TIMESTAMP, 'RUNNING')
    RETURNING run_id INTO v_run;
    BEGIN
        CREATE TEMP TABLE remote_snapshot ON COMMIT DROP AS
            SELECT agency_code, name, city, phone, is_active, updated_at::TIMESTAMP(3) AS updated_at FROM mssql_partner_agency;

        -- from SQL Server to PostgreSQL
        INSERT INTO partner_agency AS l (agency_code, name, city, phone, is_active, updated_at)
        SELECT agency_code, name, city, phone, is_active, updated_at FROM remote_snapshot
        ON CONFLICT (agency_code) DO UPDATE
            SET name = EXCLUDED.name, city = EXCLUDED.city, phone = EXCLUDED.phone,
                is_active = EXCLUDED.is_active, updated_at = EXCLUDED.updated_at
            WHERE EXCLUDED.updated_at > l.updated_at;
        GET DIAGNOSTICS v_pulled = ROW_COUNT;

        -- from PostgreSQL to SQL Server (only rows that were not just taken from there)
        v_pushed_new := 0; v_pushed_upd := 0;
        FOR r IN SELECT l.* FROM partner_agency l LEFT JOIN remote_snapshot s ON s.agency_code = l.agency_code
                 WHERE s.agency_code IS NULL OR l.updated_at > s.updated_at
        LOOP
            PERFORM fn_mssql_apply_partner_agency(r);
            IF EXISTS (SELECT 1 FROM remote_snapshot s WHERE s.agency_code = r.agency_code) THEN
                v_pushed_upd := v_pushed_upd + 1;
            ELSE
                v_pushed_new := v_pushed_new + 1;
            END IF;
        END LOOP;

        UPDATE job_run_log SET finished_at = CURRENT_TIMESTAMP, status = 'OK',
               details = 'from SQL Server: ' || v_pulled || ', to SQL Server: ' || v_pushed_new || ' new, ' || v_pushed_upd || ' changed'
        WHERE run_id = v_run;
    EXCEPTION WHEN OTHERS THEN
        UPDATE job_run_log SET finished_at = CURRENT_TIMESTAMP, status = 'ERROR', details = LEFT(SQLERRM, 500) WHERE run_id = v_run;
    END;
END $$;

-- Automation: pg_cron job every 5 minutes (inactive until the link is configured on the SQL Server side)
\connect postgres
SELECT cron.alter_job(cron.schedule_in_database('noir_partner_sync', '*/5 * * * *', 'CALL noir.sp_sync_partner_agency()', 'noir'), active := false);
\connect noir
