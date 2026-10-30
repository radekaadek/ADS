-- Run as sa: SQL Server Agent jobs (require MSSQL_AGENT_ENABLED=true)
USE msdb;
GO
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'noir_nightly_maintenance') EXEC dbo.sp_delete_job @job_name = 'noir_nightly_maintenance';
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = 'noir_backup') EXEC dbo.sp_delete_job @job_name = 'noir_backup';
GO
-- daily at 02:00 (server time, UTC)
EXEC dbo.sp_add_job @job_name = 'noir_nightly_maintenance', @description = 'Alerts, monthly statistics, log retention';
EXEC dbo.sp_add_jobstep @job_name = 'noir_nightly_maintenance', @step_name = 'sp_nightly_maintenance',
     @subsystem = 'TSQL', @database_name = 'noir', @command = 'SET QUOTED_IDENTIFIER ON; EXEC noir.sp_nightly_maintenance;';
EXEC dbo.sp_add_schedule @schedule_name = 'noir_daily_0200', @freq_type = 4, @freq_interval = 1, @active_start_time = 020000;
EXEC dbo.sp_attach_schedule @job_name = 'noir_nightly_maintenance', @schedule_name = 'noir_daily_0200';
EXEC dbo.sp_add_jobserver @job_name = 'noir_nightly_maintenance';
GO

-- database backup daily at 03:00: full, compressed, with checksum (overwrites the file)
EXEC dbo.sp_add_job @job_name = 'noir_backup', @description = 'Full backup of the noir database';
EXEC dbo.sp_add_jobstep @job_name = 'noir_backup', @step_name = 'BACKUP DATABASE', @subsystem = 'TSQL', @database_name = 'master',
     @command = 'BACKUP DATABASE noir TO DISK = ''/var/opt/mssql/backup/noir_nightly.bak'' WITH INIT, COMPRESSION, CHECKSUM;';
EXEC dbo.sp_add_schedule @schedule_name = 'noir_daily_0300', @freq_type = 4, @freq_interval = 1, @active_start_time = 030000;
EXEC dbo.sp_attach_schedule @job_name = 'noir_backup', @schedule_name = 'noir_daily_0300';
EXEC dbo.sp_add_jobserver @job_name = 'noir_backup';
GO
