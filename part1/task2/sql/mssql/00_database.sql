-- Run as sa. Database with a UTF-8 collation (encoding consistent with PostgreSQL), schema owner noir_admin.
IF DB_ID('noir') IS NULL
    CREATE DATABASE noir COLLATE Latin1_General_100_CI_AS_SC_UTF8;
GO
USE noir;
GO
IF SUSER_ID('noir_admin') IS NULL
    CREATE LOGIN noir_admin WITH PASSWORD = 'Noir_Admin_pw1', CHECK_POLICY = OFF;   -- coursework environment only
CREATE USER noir_admin FOR LOGIN noir_admin;
ALTER ROLE db_owner ADD MEMBER noir_admin;
GO
CREATE SCHEMA noir AUTHORIZATION noir_admin;
GO
ALTER USER noir_admin WITH DEFAULT_SCHEMA = noir;
GO
