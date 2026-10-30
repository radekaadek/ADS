#!/usr/bin/env bash
# Pelna migracja narzedziem Apache Hop: schemat stg -> potok Hop -> przeniesienie do tabel noir -> usuniecie stg.
# Wymaga pustych tabel noir w SQL Server (po ./reset_mssql.sh) i dzialajacego PostgreSQL.
set -euo pipefail
cd "$(dirname "$0")/../.."
SQLCMD='/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U noir_admin -P Noir_Admin_pw1 -b -I'
docker compose exec -T mssql bash -c "$SQLCMD -i /sql/etl_staging.sql" > /dev/null
./etl/hop/run_hop.sh 2>&1 | grep -v "^INFO:\|TDSTokenHandler\|Finished reading"
docker compose exec -T mssql bash -c "$SQLCMD -i /sql/etl_finalize.sql" | grep -v '^$\|rows affected'
