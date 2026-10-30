#!/usr/bin/env bash
# Odtwarza SQL Server od zera, laduje dane z PostgreSQL (BULK INSERT), buduje kod i uruchamia skrypty demonstracyjne
set -euo pipefail
cd "$(dirname "$0")"
./reset_mssql.sh >/dev/null
docker compose exec -T pg bash /etl/bulk/export.sh >/dev/null
docker compose exec -T mssql bash /etl/bulk/load.sh >/dev/null
./scripts/mssql_build.sh code >/dev/null
for f in 20_functions_demo 21_procedures_demo 22_triggers_demo 23_job_demo; do
  docker compose exec -T mssql bash -c "/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U noir_admin -P Noir_Admin_pw1 -d noir -I -W -i /manual/mssql_$f.sql" > results/mssql_$f.txt 2>&1
done
echo "Gotowe: results/mssql_2*.txt"
