#!/usr/bin/env bash
# Proby migracji narzedziem pgloader (uruchamiane w sieci compose):
#  1. source PostgreSQL, target SQL Server (kierunek wymagany przez projekt),
#  2. kierunek odwrotny (zrodlo SQL Server, cel PostgreSQL) do pustej bazy pomocniczej scratch - sprawdzenie, co narzedzie obsluguje.
cd "$(dirname "$0")/.."
PGL="docker run --rm --network task2_default ghcr.io/dimitri/pgloader:latest"
$PGL pgloader --version
echo "--- source PostgreSQL, target SQL Server"
$PGL pgloader "postgresql://noir_admin:noir_admin_pw@pg:5432/noir" "mssql://sa:Noir_Admin_pw1@mssql:1433/noir" || true
echo "--- reverse direction: source SQL Server, target PostgreSQL (auxiliary database scratch)"
docker compose exec -T pg psql -U noir_admin -d postgres -qAt -c "DROP DATABASE IF EXISTS scratch" -c "CREATE DATABASE scratch" > /dev/null
$PGL pgloader "mssql://sa:Noir_Admin_pw1@mssql:1433/noir" "postgresql://noir_admin:noir_admin_pw@pg:5432/scratch" || true
docker compose exec -T pg psql -U noir_admin -d postgres -qAt -c "DROP DATABASE IF EXISTS scratch" > /dev/null
