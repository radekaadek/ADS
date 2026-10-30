-- Counterpart of the PostgreSQL script (same canonical row form and the same output: table|rows|md5)
SET NOCOUNT ON;
CREATE TABLE #fp (table_name VARCHAR(100), row_count BIGINT, md5 VARCHAR(32));
DECLARE @t VARCHAR(100), @expr NVARCHAR(MAX), @sql NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT table_name FROM INFORMATION_SCHEMA.TABLES WHERE table_schema = 'noir' AND table_type = 'BASE TABLE' ORDER BY 1;
OPEN c; FETCH NEXT FROM c INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @expr = STRING_AGG(CAST(
             'COALESCE(' +
             CASE ty.name
               WHEN 'bit' THEN 'CAST(' + QUOTENAME(col.name) + ' AS VARCHAR(1))'
               WHEN 'date' THEN 'CONVERT(VARCHAR(10), ' + QUOTENAME(col.name) + ', 23)'
               WHEN 'datetime2' THEN 'CONVERT(VARCHAR(27), ' + QUOTENAME(col.name) + ', 121)'
               WHEN 'varchar' THEN 'CAST(' + QUOTENAME(col.name) + ' AS VARCHAR(MAX))'
               ELSE 'CAST(' + QUOTENAME(col.name) + ' AS VARCHAR(40))' END
             + ', ''\N'')' AS NVARCHAR(MAX)), ' + ''|'' + ') WITHIN GROUP (ORDER BY col.column_id)
      FROM sys.columns col JOIN sys.types ty ON ty.user_type_id = col.user_type_id
      WHERE col.object_id = OBJECT_ID('noir.' + @t);
    SET @sql = N'INSERT INTO #fp SELECT ''' + @t + ''', COUNT(*), LOWER(CONVERT(VARCHAR(32), HASHBYTES(''MD5'', ISNULL(STRING_AGG(CAST(r AS VARCHAR(MAX)), CHAR(10)) WITHIN GROUP (ORDER BY r COLLATE Latin1_General_100_BIN2_UTF8), '''')), 2)) FROM (SELECT ' + @expr + N' AS r FROM noir.' + QUOTENAME(@t) + N') x';
    EXEC sp_executesql @sql;
    FETCH NEXT FROM c INTO @t;
END
CLOSE c; DEALLOCATE c;
SELECT table_name + '|' + CAST(row_count AS VARCHAR(20)) + '|' + md5 FROM #fp ORDER BY table_name COLLATE Latin1_General_100_BIN2_UTF8;
