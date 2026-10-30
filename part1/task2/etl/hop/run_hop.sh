#!/usr/bin/env bash
# Uruchamia potok Apache Hop (kontener apache/hop) kopiujacy tabele PostgreSQL -> schemat stg w SQL Server.
# Projekt Hop (katalog etl/hop z metadanymi polaczen) jest kopiowany do katalogu tymczasowego kontenera.
cd "$(dirname "$0")/../.."
docker run --rm --network task2_default -v "$PWD/etl/hop:/project:ro" --entrypoint bash apache/hop:latest -c '
cp -r /project /tmp/noir-etl
/opt/hop/hop-conf.sh --project-create --project noir-etl --project-home /tmp/noir-etl >/dev/null 2>&1
/opt/hop/hop-run.sh -j noir-etl -f /tmp/noir-etl/pg_to_staging.hpl -r local -l Basic'
