#!/usr/bin/env bash
# Kopia zapasowa PostgreSQL i test jej poprawnosci. Uruchamiac na hoscie w katalogu task2 (kontener pg musi dzialac).
set -euo pipefail
cd "$(dirname "$0")/.."
ODCISK=/manual/30_checksums_pg.sql   # skrypt odcisku zawartosci tabel
X="docker compose exec -T pg"
PSQL="$X psql -U noir_admin -qAt"

echo "== 1. Logical backup (pg_dump, custom format, compression) =="
$X pg_dump -U noir_admin -d noir -Fc -f /backup/noir.dump
$X pg_dump -U noir_admin -d noir --schema-only -f /backup/noir_schema.ddl
$X pg_dumpall -U noir_admin --globals-only -f /backup/globals.ddl      # role i hasla
$X ls -l /backup/noir.dump
echo "-- archive table of contents (first lines)"
$X pg_restore --list /backup/noir.dump | head -12

echo "== 2. Physical backup (pg_basebackup) and its verification (pg_verifybackup) =="
$X rm -rf /backup/base
$X pg_basebackup -U noir_admin -D /backup/base -Fp -X stream -c fast
$X pg_verifybackup /backup/base

echo "== 3. Restore of the logical backup into a separate database noir_restore =="
$PSQL -d postgres -c "DROP DATABASE IF EXISTS noir_restore"
$PSQL -d postgres -c "CREATE DATABASE noir_restore"
$X pg_restore -U noir_admin -d noir_restore --exit-on-error /backup/noir.dump
$PSQL -d noir_restore -c "SELECT 'tabel w noir_restore: ' || count(*) FROM information_schema.tables WHERE table_schema='noir' AND table_type='BASE TABLE'"

echo "== 4. Content comparison: row count and md5 of every table (original vs backup) =="
$X psql -U noir_admin -d noir -qAt -f "$ODCISK" > /tmp/fp_o.txt
$X psql -U noir_admin -d noir_restore -qAt -f "$ODCISK" > /tmp/fp_r.txt
printf '%-22s %-10s %-34s %-34s %s\n' table rows "md5 noir" "md5 noir_restore" match
join -t'|' -j1 <(sort -t'|' -k1,1 /tmp/fp_o.txt) <(sort -t'|' -k1,1 /tmp/fp_r.txt) | awk -F'|' '{ ok = ($2==$4 && $3==$5) ? "YES" : "NO"; printf "%-22s %-10s %-34s %-34s %s\n", $1, $2"/"$4, $3, $5, ok }'
if diff -q /tmp/fp_o.txt /tmp/fp_r.txt >/dev/null; then echo "RESULT: content identical in all tables"; else echo "RESULT: DIFFERENCES"; diff /tmp/fp_o.txt /tmp/fp_r.txt; fi

echo "== 5. Failure test: deleting data in noir and restoring from the backup =="
$PSQL -d noir -c "SELECT 'invoices before failure: ' || count(*) FROM noir.invoice"
$X psql -U noir_admin -d noir -qAt -c "TRUNCATE noir.payment, noir.invoice CASCADE" >/dev/null
$PSQL -d noir -c "SELECT 'invoices after failure: ' || count(*) FROM noir.invoice"
$X pg_restore -U noir_admin -d noir --data-only --disable-triggers -t invoice -t payment -t alert /backup/noir.dump
$PSQL -d noir -c "SELECT 'invoices after restore: ' || count(*) || ', payments: ' || (SELECT count(*) FROM noir.payment) FROM noir.invoice"
$X psql -U noir_admin -d noir -qAt -f "$ODCISK" > /tmp/fp_o2.txt
diff -q /tmp/fp_o2.txt /tmp/fp_r.txt >/dev/null && echo "RESULT: after the restore the content matches the backup" || diff /tmp/fp_o2.txt /tmp/fp_r.txt
