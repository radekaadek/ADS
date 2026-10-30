#!/usr/bin/env bash
# Odtwarza baze PostgreSQL od zera (skrypty sql/pg/*.sql wykonuja sie przy pierwszym starcie na pustym wolumenie)
set -euo pipefail
cd "$(dirname "$0")"
docker compose rm -sf pg >/dev/null 2>&1 || true
docker volume rm -f task2_pg_data task2_pg_backup >/dev/null
docker compose up -d pg
until [ "$(docker inspect -f '{{.State.Health.Status}}' noir2_pg)" = healthy ]; do sleep 2; done
sleep 3
