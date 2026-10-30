#!/usr/bin/env bash
# Eksport tabel PostgreSQL do plikow CSV (UTF-8) w woluminie wymiany /exchange.
# Kolumny logiczne (BOOLEAN) zamieniane na 0/1, bo SQL Server nie rozpoznaje t/f; reszta bez zmian.
set -euo pipefail
mkdir -p /exchange/csv
while read -r t; do
  cols=$(psql -U noir_admin -d noir -qAt -c "
    SELECT string_agg(CASE WHEN data_type = 'boolean' THEN format('CASE WHEN %I THEN 1 ELSE 0 END AS %I', column_name, column_name)
                           ELSE quote_ident(column_name) END, ', ' ORDER BY ordinal_position)
    FROM information_schema.columns WHERE table_schema = 'noir' AND table_name = '$t'")
  psql -U noir_admin -d noir -qAt -c "\\copy (SELECT $cols FROM noir.$t ORDER BY 1) TO '/exchange/csv/$t.csv' WITH (FORMAT csv, ENCODING 'UTF8')"
  echo "$t: $(wc -l < /exchange/csv/$t.csv) rows"
done < /etl/tables.txt
chmod -R a+rX /exchange/csv
