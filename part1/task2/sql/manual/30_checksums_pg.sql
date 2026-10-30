-- Content fingerprint of every table in the noir schema: row count and md5 of the sorted rows.
-- Output: table_name|row_count|content_md5

-- Fingerprint of one table. The function is temporary (pg_temp): it lives only in this session
-- and leaves nothing in the database. The table name is only known at run time, so the query is
-- built as text and run with EXECUTE.
CREATE FUNCTION pg_temp.table_fingerprint(p_table TEXT, OUT row_count BIGINT, OUT content_md5 TEXT)
LANGUAGE plpgsql AS $$
BEGIN
  -- The query built below, step by step:
  --   t::text                      - the whole row as one text value, e.g. (1,Kowalski,2026-01-05)
  --   string_agg(..., '|' ORDER BY)- all rows sorted and joined with '|', so the physical row order
  --                                  (different after a restore) does not change the result
  --   COALESCE(..., '')            - an empty table gives '' instead of NULL, so md5 still returns a value
  --   md5(...)                     - a single short hash of the whole table content
  --   count(*)                     - the number of rows, returned next to the hash
  -- %I quotes the table name as an identifier; INTO puts the two result columns into the OUT parameters.
  EXECUTE format(
    'SELECT count(*),
            md5(COALESCE(string_agg(t::text, ''|'' ORDER BY t::text), ''''))
       FROM noir.%I t', p_table)
  INTO row_count, content_md5;
END $$;

-- For every base table of the noir schema (views are skipped) call the function once
-- and print the table name together with its row count and hash.
-- LATERAL lets the call use the table name from the current row of information_schema.tables.
SELECT t.table_name, f.row_count, f.content_md5
FROM information_schema.tables t
CROSS JOIN LATERAL pg_temp.table_fingerprint(t.table_name) f
WHERE t.table_schema = 'noir' AND t.table_type = 'BASE TABLE'
ORDER BY t.table_name;
