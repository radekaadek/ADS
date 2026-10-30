#!/usr/bin/env bash
# Buduje baze noir w SQL Server. Fazy (dane migrowane sa narzedziami ETL pomiedzy faza schema a code):
#   schema - baza, tabele, indeksy        ./scripts/mssql_build.sh schema
#   code   - widoki, funkcje, procedury, wyzwalacze, role, job   ./scripts/mssql_build.sh code
set -euo pipefail
cd "$(dirname "$0")/.."
# -I: QUOTED_IDENTIFIER ON (wymagane przez indeksy filtrowane), -b: przerwij przy bledzie.
# Skrypty bazy wykonuje noir_admin (domyslny schemat noir); sa tworzy baze (00), loginy i uprawnienia (04) oraz zadania Agenta (12).
run() {
  echo ">> $1"
  case "$1" in
    00_*|04_*|12_*|13_*) auth='-U sa -P "$MSSQL_SA_PASSWORD"' ;;
    *)         auth='-U noir_admin -P Noir_Admin_pw1' ;;
  esac
  docker compose exec -T mssql bash -c "/opt/mssql-tools18/bin/sqlcmd -C -S localhost $auth -b -I -i /sql/$1"
}
case "${1:-}" in
  schema) for f in 00_database 01_schema 06_support 05_indexes; do run $f.sql; done ;;
  code)   for f in 03_views 07_functions 08_procedures 09_triggers 10_job_procedure 11_views_roles 04_roles 12_jobs 13_sync; do run $f.sql; done ;;
  *) echo "usage: $0 schema|code"; exit 1 ;;
esac
