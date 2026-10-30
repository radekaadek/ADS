#!/usr/bin/env bash
# Odtwarza SQL Server od zera (pusty wolumen) i buduje schemat (faza schema)
set -euo pipefail
cd "$(dirname "$0")"
docker compose rm -sf mssql >/dev/null 2>&1 || true
docker volume rm -f task2_mssql_data task2_mssql_backup >/dev/null
docker compose up -d mssql
until [ "$(docker inspect -f '{{.State.Health.Status}}' noir2_mssql)" = healthy ]; do sleep 3; done
docker compose exec -T -u 0 mssql chown mssql:root /var/opt/mssql/backup   # wolumen kopii zapasowych musi byc zapisywalny dla procesu SQL Server
./scripts/mssql_build.sh schema
