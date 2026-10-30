#!/usr/bin/env bash
# Odtwarza baze PostgreSQL od zera i uruchamia po kolei skrypty demonstracyjne; wyniki trafiaja do results/
set -euo pipefail
cd "$(dirname "$0")"
./reset_pg.sh
for f in 20_functions_demo 21_procedures_demo 22_triggers_demo 23_job_demo; do
  docker compose exec -T pg psql -U noir_admin -d noir -f /manual/$f.sql > results/pg_$f.txt 2>&1
done
echo "Gotowe: results/pg_2*.txt"
