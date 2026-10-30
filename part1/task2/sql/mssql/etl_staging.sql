-- Staging schema stg: empty copies of the noir tables without the IDENTITY property (the ETL tool inserts explicit key values).
-- Run as noir_admin before starting the ETL pipeline.
USE noir;
GO
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
GO
DECLARE @t SYSNAME, @sql NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM sys.tables WHERE schema_id = SCHEMA_ID('noir') ORDER BY name;
OPEN c; FETCH NEXT FROM c INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @sql = 'IF OBJECT_ID(''stg.' + @t + ''') IS NOT NULL DROP TABLE stg.' + QUOTENAME(@t) + '; SELECT ' +
           STRING_AGG(CAST(CASE WHEN col.is_identity = 1 THEN 'CAST(' + QUOTENAME(col.name) + ' AS BIGINT) AS ' + QUOTENAME(col.name)   -- the expression removes IDENTITY
                                ELSE QUOTENAME(col.name) END AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY col.column_id) +
           ' INTO stg.' + QUOTENAME(@t) + ' FROM noir.' + QUOTENAME(@t) + ' WHERE 1 = 0'
    FROM sys.columns col WHERE col.object_id = OBJECT_ID('noir.' + @t);
    EXEC sp_executesql @sql;
    FETCH NEXT FROM c INTO @t;
END
CLOSE c; DEALLOCATE c;
GO
