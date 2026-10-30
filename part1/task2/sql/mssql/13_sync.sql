-- Run as sa: partner agency register synchronized with PostgreSQL (the database link and the schedule are on the PostgreSQL side)
USE noir;
GO
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO
CREATE TABLE noir.partner_agency (
    agency_code VARCHAR(10)  NOT NULL,
    name        VARCHAR(100) NOT NULL,
    city        VARCHAR(60)  NOT NULL,
    phone       VARCHAR(20),
    is_active   BIT          NOT NULL CONSTRAINT df_partner_agency_active DEFAULT 1,
    updated_at  DATETIME2(3) NOT NULL CONSTRAINT df_partner_agency_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_partner_agency PRIMARY KEY (agency_code)
);
GO
-- A change made by a user gets the current time; a change made by the synchronization sets updated_at itself, so it is kept.
CREATE TRIGGER noir.trg_partner_agency_touch ON noir.partner_agency AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(updated_at)
        UPDATE a SET updated_at = SYSUTCDATETIME() FROM noir.partner_agency a JOIN inserted i ON i.agency_code = a.agency_code;
END;
GO
-- Entry point for the database link: stores a row received from PostgreSQL if it is newer than the local one (or missing);
-- repeating the call with the same data changes nothing.
CREATE PROCEDURE noir.sp_apply_partner_agency
    @agency_code VARCHAR(10), @name VARCHAR(100), @city VARCHAR(60), @phone VARCHAR(20), @is_active BIT, @updated_at DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    MERGE noir.partner_agency AS t
    USING (SELECT @agency_code AS agency_code) AS s ON t.agency_code = s.agency_code
    WHEN MATCHED AND @updated_at > t.updated_at THEN
        UPDATE SET name = @name, city = @city, phone = @phone, is_active = @is_active, updated_at = @updated_at
    WHEN NOT MATCHED THEN
        INSERT (agency_code, name, city, phone, is_active, updated_at) VALUES (@agency_code, @name, @city, @phone, @is_active, @updated_at);
    SELECT 1 AS done;   -- the result row confirms to the caller that the batch was run
END;
GO
-- Login used by the database link: it can read the register and call the procedure above, nothing else
IF SUSER_ID('sync_link') IS NULL CREATE LOGIN sync_link WITH PASSWORD = 'Agency_Link_pw1', DEFAULT_DATABASE = noir, CHECK_POLICY = ON;
IF USER_ID('sync_link') IS NULL CREATE USER sync_link FOR LOGIN sync_link;
GRANT SELECT ON noir.partner_agency TO sync_link;
GRANT EXECUTE ON noir.sp_apply_partner_agency TO sync_link;
GO
