#!/usr/bin/env bash
# Kopia zapasowa SQL Server i test jej poprawnosci (kontener mssql musi dzialac, baza noir zaladowana).
set -euo pipefail
cd "$(dirname "$0")/.."
SQL='/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -I -W'
M="docker compose exec -T mssql bash -c"
$M "$SQL -b -i /manual/mssql_30_backup.sql"
echo "== 6. Content comparison: table fingerprints of noir and noir_restore =="
$M "$SQL -d noir -h -1 -i /manual/31_fingerprint_mssql.sql" | tr -d '\r' | grep -v '^$' > /tmp/fp_a.txt
$M "$SQL -d noir_restore -h -1 -i /manual/31_fingerprint_mssql.sql" | tr -d '\r' | grep -v '^$' > /tmp/fp_b.txt
printf '%-22s %-10s %-34s %-34s %s\n' table rows "md5 noir" "md5 noir_restore" match
join -t'|' -j1 <(sort -t'|' -k1,1 /tmp/fp_a.txt) <(sort -t'|' -k1,1 /tmp/fp_b.txt) | awk -F'|' '{ ok = ($2==$4 && $3==$5) ? "YES" : "NO"; printf "%-22s %-10s %-34s %-34s %s\n", $1, $2"/"$4, $3, $5, ok }'
if diff -q /tmp/fp_a.txt /tmp/fp_b.txt >/dev/null; then echo "RESULT: content identical in all tables"; else echo "RESULT: DIFFERENCES"; diff /tmp/fp_a.txt /tmp/fp_b.txt; fi
echo "== 7. Failure test: deleting financial data in noir and restoring the database from the backup (WITH REPLACE) =="
$M "$SQL -d noir -h -1 -Q \"SET NOCOUNT ON; DELETE FROM noir.alert; DELETE FROM noir.payment; DELETE FROM noir.invoice; SELECT 'invoices after failure: ' + CAST(COUNT(*) AS VARCHAR(10)) FROM noir.invoice\""
$M "$SQL -h -1 -b -Q \"SET NOCOUNT ON; ALTER DATABASE noir SET SINGLE_USER WITH ROLLBACK IMMEDIATE; RESTORE DATABASE noir FROM DISK = '/var/opt/mssql/backup/noir_full.bak' WITH REPLACE, NORECOVERY; RESTORE DATABASE noir FROM DISK = '/var/opt/mssql/backup/noir_diff.bak' WITH RECOVERY; ALTER DATABASE noir SET MULTI_USER;\"" > /dev/null
$M "$SQL -d noir -h -1 -Q \"SET NOCOUNT ON; SELECT 'invoices after restore: ' + CAST(COUNT(*) AS VARCHAR(10)) + ', payments: ' + CAST((SELECT COUNT(*) FROM noir.payment) AS VARCHAR(10)) FROM noir.invoice\""
$M "$SQL -d noir -h -1 -i /manual/31_fingerprint_mssql.sql" | tr -d '\r' | grep -v '^$' > /tmp/fp_c.txt
if diff -q /tmp/fp_c.txt /tmp/fp_b.txt >/dev/null; then echo "RESULT: after the restore the content matches the backup"; else echo "RESULT: DIFFERENCES"; diff /tmp/fp_c.txt /tmp/fp_b.txt; fi
