#!/usr/bin/env bash
# Zaladowanie plikow CSV do SQL Server instrukcja BULK INSERT (KEEPIDENTITY zachowuje klucze z PostgreSQL).
set -euo pipefail
SQLCMD="/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P $MSSQL_SA_PASSWORD -d noir -b -I"
while read -r t; do
  echo "== $t"
  $SQLCMD -Q "BULK INSERT noir.$t FROM '/exchange/csv/$t.csv' WITH (FORMAT = 'CSV', FIELDQUOTE = '\"', FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', KEEPIDENTITY, KEEPNULLS, TABLOCK)" < /dev/null
done < /etl/tables.txt
