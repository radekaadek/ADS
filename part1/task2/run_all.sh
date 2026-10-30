#!/usr/bin/env bash
# Pelne, powtarzalne uruchomienie calego projektu od zera; wyniki trafiaja do results/.
#  1. PostgreSQL od zera + test uprawnien
#  2. proby migracji i migracje do SQL Server (pgloader, BULK INSERT, Apache Hop) z porownaniem zawartosci
#  3. SQL Server: kod (widoki, funkcje, procedury, wyzwalacze, role, job), testy, demonstracje, Agent, kopia zapasowa
#  4. PostgreSQL: demonstracje funkcji, procedur, wyzwalaczy, zadania, pg_cron i kopia zapasowa
#  5. Zawartosc dodatkowa: polaczenie PostgreSQL -> SQL Server (tds_fdw) i dwukierunkowa synchronizacja przez pg_cron
set -euo pipefail
cd "$(dirname "$0")"
R=results; mkdir -p $R
docker compose build pg >/dev/null
echo "[1/5] PostgreSQL: reset i test uprawnien"
./reset_pg.sh >/dev/null 2>&1
docker compose exec -T pg bash /tests/permissions.sh > $R/pg_permissions_output.txt
docker compose logs pg 2>&1 | grep -iE "error|fatal" | grep -v -e "pg_cron launcher" -e "permission denied" -e "exceed invoice amount" -e "is before invoice issue date" -e "is in the future" > $R/pg_startup_errors.txt || true

echo "[2/5] Migracja PostgreSQL -> SQL Server"
./reset_mssql.sh >/dev/null 2>&1
./etl/pgloader_attempt.sh > $R/etl_pgloader_attempt.txt 2>&1 || true
docker compose exec -T pg bash /etl/bulk/export.sh > /dev/null
./etl/bulk/attempt_naive.sh > $R/etl_bulk_attempt1.txt 2>&1 || true
./etl/hop/run_all.sh > $R/etl_hop_run.txt 2>&1
./scripts/compare_fingerprints.sh > $R/etl_hop_compare.txt
./reset_mssql.sh >/dev/null 2>&1
docker compose exec -T mssql bash /etl/bulk/load.sh > $R/etl_bulk_load.txt 2>&1
./scripts/compare_fingerprints.sh > $R/etl_bulk_compare.txt

echo "[3/5] SQL Server: kod, testy, demonstracje, Agent, kopia zapasowa"
./scripts/mssql_build.sh code > $R/mssql_build_code.txt 2>&1
docker compose exec -T mssql bash /tests/permissions_mssql.sh > $R/mssql_permissions_output.txt
for f in 20_functions_demo 21_procedures_demo 22_triggers_demo 23_job_demo; do
  docker compose exec -T mssql bash -c "/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U noir_admin -P Noir_Admin_pw1 -d noir -I -W -s \"|\" -i /manual/mssql_$f.sql" > $R/mssql_$f.txt 2>&1
done
docker compose exec -T mssql bash /manual/mssql_24_agent_demo.sh > $R/mssql_24_agent_demo.txt 2>&1
./scripts/backup_mssql.sh > $R/mssql_backup_output.txt 2>&1

echo "[4/5] PostgreSQL: demonstracje, pg_cron, kopia zapasowa"
for f in 20_functions_demo 21_procedures_demo 22_triggers_demo 23_job_demo; do
  docker compose exec -T pg psql -U noir_admin -d noir -f /manual/$f.sql > $R/pg_$f.txt 2>&1
done
docker compose exec -T pg bash /manual/24_cron_demo.sh > $R/pg_24_cron_demo.txt 2>&1
./scripts/backup_pg.sh > $R/pg_backup_output.txt 2>&1
docker compose exec -T pg psql -U noir_admin -d noir -f /manual/40_dialect_checks_pg.sql > $R/pg_40_dialect_checks.txt 2>&1
docker compose exec -T mssql bash -c '/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U noir_admin -P Noir_Admin_pw1 -d noir -I -W -s "|" -i /manual/mssql_40_dialect_checks.sql' > $R/mssql_40_dialect_checks.txt 2>&1
echo "[5/5] Polaczenie baz i synchronizacja (pg_cron + tds_fdw)"
./sql/manual/25_sync_demo.sh > $R/sync_demo.txt 2>&1
grep -c '^PASS' $R/pg_permissions_output.txt $R/mssql_permissions_output.txt
grep -h RESULT $R/etl_*_compare.txt $R/pg_backup_output.txt $R/mssql_backup_output.txt
echo "Gotowe: results/"
