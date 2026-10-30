#!/usr/bin/env bash
# Proba 1: eksport bez konwersji typow (\copy ... CSV) i BULK INSERT do tabeli z kolumna BIT.
# Uruchamiac z hosta w katalogu task2.
cd "$(dirname "$0")/../.."
docker compose exec -T pg bash -c "mkdir -p /exchange/naive && psql -U noir_admin -d noir -qAt -c \"\\copy noir.detective TO '/exchange/naive/detective.csv' WITH (FORMAT csv)\" && chmod -R a+rX /exchange/naive && cat /exchange/naive/detective.csv"
docker compose exec -T mssql bash -c "/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P \"\$MSSQL_SA_PASSWORD\" -d noir -I -Q \"BULK INSERT noir.detective FROM '/exchange/naive/detective.csv' WITH (FORMAT = 'CSV', KEEPIDENTITY)\""
