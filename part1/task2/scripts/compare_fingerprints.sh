#!/usr/bin/env bash
# Porownuje odciski zawartosci tabel w PostgreSQL i SQL Server (liczba wierszy i md5 kazdej tabeli).
# Rejestr partner_agency jest pomijany: nie podlega migracji, wypelnia go synchronizacja miedzy systemami.
cd "$(dirname "$0")/.."
docker compose exec -T pg psql -U noir_admin -d noir -qAt -f /manual/31_fingerprint_pg.sql | grep -v '^partner_agency|' > /tmp/fp_pg.txt
docker compose exec -T mssql bash -c '/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -d noir -I -h -1 -W -b -i /manual/31_fingerprint_mssql.sql' | tr -d '\r' | grep -v -e '^$' -e '^partner_agency|' > /tmp/fp_mssql.txt
printf '%-22s %-10s %-34s %-34s %s\n' tabela wiersze "md5 PostgreSQL" "md5 SQL Server" zgodne
join -t'|' -j1 <(sort -t'|' -k1,1 /tmp/fp_pg.txt) <(sort -t'|' -k1,1 /tmp/fp_mssql.txt) | awk -F'|' '{ ok = ($2==$4 && $3==$5) ? "TAK" : "NIE"; printf "%-22s %-10s %-34s %-34s %s\n", $1, $2"/"$4, $3, $5, ok }'
if diff -q /tmp/fp_pg.txt /tmp/fp_mssql.txt >/dev/null; then echo "RESULT: all tables match"; else echo "RESULT: DIFFERENCES"; fi
