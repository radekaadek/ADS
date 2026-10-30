-- DBMS-independent content fingerprint of the noir schema tables: for every table the row count and the md5 of the
-- rows (sorted binary) written in canonical form (columns separated by '|', NULL as \N, ISO dates, boolean 0/1).
-- The same algorithm works in SQL Server. Output: table|rows|md5
CREATE TEMP TABLE fp (table_name TEXT, row_count BIGINT, md5 TEXT);
DO $$
DECLARE t RECORD; expr TEXT;
BEGIN
  FOR t IN SELECT table_name FROM information_schema.tables WHERE table_schema = 'noir' AND table_type = 'BASE TABLE' ORDER BY 1 LOOP
    SELECT string_agg(
             'COALESCE(' ||
             CASE data_type
               WHEN 'boolean' THEN format('CASE WHEN %I THEN ''1'' ELSE ''0'' END', column_name)
               WHEN 'date' THEN format('to_char(%I, ''YYYY-MM-DD'')', column_name)
               WHEN 'timestamp without time zone' THEN format('to_char(%I, ''YYYY-MM-DD HH24:MI:SS.US'')', column_name)
               ELSE format('%I::text', column_name) END
             || ', ''\N'')', ' || ''|'' || ' ORDER BY ordinal_position)
      INTO expr FROM information_schema.columns WHERE table_schema = 'noir' AND table_name = t.table_name;
    EXECUTE format('INSERT INTO fp SELECT %L, COUNT(*), md5(COALESCE(string_agg(r, E''\n'' ORDER BY r COLLATE "C"), '''')) FROM (SELECT %s AS r FROM noir.%I) x',
                   t.table_name, expr, t.table_name);
  END LOOP;
END $$;
SELECT table_name || '|' || row_count || '|' || md5 FROM fp ORDER BY table_name COLLATE "C";
