USE noir;
GO
SET NOCOUNT ON;
PRINT '== 1. FULL recovery model and full backup (compression, checksum) ==';
ALTER DATABASE noir SET RECOVERY FULL;
BACKUP DATABASE noir TO DISK = '/var/opt/mssql/backup/noir_full.bak' WITH INIT, COMPRESSION, CHECKSUM, NAME = 'noir full';
GO
PRINT '== 2. Data change after the full backup, then a differential backup ==';
DELETE FROM noir.client WHERE email = 'backup.test@example.com';
INSERT INTO noir.client (first_name, last_name, email) VALUES ('Backup', 'Test', 'backup.test@example.com');
GO
BACKUP DATABASE noir TO DISK = '/var/opt/mssql/backup/noir_diff.bak' WITH INIT, DIFFERENTIAL, COMPRESSION, CHECKSUM, NAME = 'noir differential';
GO
PRINT '== 3. Backup verification without restoring (RESTORE VERIFYONLY checks the checksum and readability) ==';
RESTORE VERIFYONLY FROM DISK = '/var/opt/mssql/backup/noir_full.bak' WITH CHECKSUM;
RESTORE VERIFYONLY FROM DISK = '/var/opt/mssql/backup/noir_diff.bak' WITH CHECKSUM;
GO
PRINT '== 4. Files in the full backup and backup sets registered in msdb ==';
SELECT bf.logical_name, bf.file_type, bf.file_size, bf.backup_size
FROM msdb.dbo.backupfile bf JOIN msdb.dbo.backupset bs ON bs.backup_set_id = bf.backup_set_id
WHERE bs.database_name = 'noir' AND bs.type = 'D' ORDER BY bf.file_number;
SELECT bs.name, CASE bs.type WHEN 'D' THEN 'full' WHEN 'I' THEN 'differential' ELSE bs.type END AS backup_type,
       bs.backup_size, bs.compressed_backup_size, bs.has_backup_checksums, bs.recovery_model
FROM msdb.dbo.backupset bs WHERE bs.database_name = 'noir' ORDER BY bs.backup_finish_date;
GO
PRINT '== 5. Restore of the chain (full NORECOVERY + differential RECOVERY) into a separate database noir_restore ==';
IF DB_ID('noir_restore') IS NOT NULL DROP DATABASE noir_restore;
RESTORE DATABASE noir_restore FROM DISK = '/var/opt/mssql/backup/noir_full.bak'
    WITH MOVE 'noir' TO '/var/opt/mssql/data/noir_restore.mdf', MOVE 'noir_log' TO '/var/opt/mssql/data/noir_restore.ldf', NORECOVERY, STATS = 100;
RESTORE DATABASE noir_restore FROM DISK = '/var/opt/mssql/backup/noir_diff.bak' WITH RECOVERY, STATS = 100;
GO
SELECT (SELECT COUNT(*) FROM noir.client) AS clients_in_noir, (SELECT COUNT(*) FROM noir_restore.noir.client) AS clients_in_restore;
GO
