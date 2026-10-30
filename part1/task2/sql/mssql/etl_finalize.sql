-- Moving data from the stg schema to the noir tables preserving keys (IDENTITY_INSERT), dropping stg.
-- Tables are loaded in foreign-key order (etl/tables.txt); run as noir_admin.
USE noir;
GO
DECLARE @t SYSNAME, @cols NVARCHAR(MAX), @sql NVARCHAR(MAX), @ident BIT, @n INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT value FROM STRING_SPLIT('case_status,case_type,evidence_type,detective_rank,payment_method,client,detective,location,case_file,suspect,witness,informant,evidence,tip,invoice,payment,case_detective,case_suspect,case_witness,evidence_custody,case_status_history,document_counter,operation_log,alert,monthly_case_stats,job_run_log', ',', 1) ORDER BY ordinal;
OPEN c; FETCH NEXT FROM c INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @cols = STRING_AGG(CAST(QUOTENAME(name) AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY column_id),
           @ident = MAX(CAST(is_identity AS INT))
    FROM sys.columns WHERE object_id = OBJECT_ID('noir.' + @t);
    SET @sql = CASE WHEN @ident = 1 THEN 'SET IDENTITY_INSERT noir.' + QUOTENAME(@t) + ' ON; ' ELSE '' END +
               'INSERT INTO noir.' + QUOTENAME(@t) + ' (' + @cols + ') SELECT ' + @cols + ' FROM stg.' + QUOTENAME(@t) + '; SET @n = @@ROWCOUNT; ' +
               CASE WHEN @ident = 1 THEN 'SET IDENTITY_INSERT noir.' + QUOTENAME(@t) + ' OFF;' ELSE '' END;
    EXEC sp_executesql @sql, N'@n INT OUTPUT', @n OUTPUT;
    PRINT @t + ': ' + CAST(@n AS VARCHAR(10)) + ' wierszy';
    FETCH NEXT FROM c INTO @t;
END
CLOSE c; DEALLOCATE c;
GO
-- dropping the staging schema
DECLARE @drop NVARCHAR(MAX) = '';
SELECT @drop += 'DROP TABLE stg.' + QUOTENAME(name) + ';' FROM sys.tables WHERE schema_id = SCHEMA_ID('stg');
EXEC sp_executesql @drop;
DROP SCHEMA stg;
GO
