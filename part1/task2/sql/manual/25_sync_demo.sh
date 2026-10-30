#!/usr/bin/env bash
# Uruchamiany na hoscie (z katalogu etapu): ./sql/manual/25_sync_demo.sh
# Dwukierunkowa synchronizacja rejestru agencji partnerskich PostgreSQL <-> SQL Server przez pg_cron i tds_fdw.
cd "$(dirname "$0")/../.."
pg()   { docker compose exec -T pg psql -U noir_admin -d noir -X -q "$@" 2>&1 | grep -v -e "^NOTICE:  DB-Library" -e "^NOTICE:  tds_fdw" -e "^WARNING:  Table definition mismatch"; }
pgc()  { docker compose exec -T pg psql -U noir_admin -d postgres -X -q "$@"; }
ms()   { docker compose exec -T mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U noir_admin -P Noir_Admin_pw1 -d noir -I -W -s "|" -Q "SET NOCOUNT ON; $1"; }
SHOW_PG="SELECT agency_code, name, city, phone, is_active, updated_at FROM noir.partner_agency ORDER BY agency_code"
SHOW_MS="SELECT agency_code, name, city, phone, is_active, updated_at FROM noir.partner_agency ORDER BY agency_code"
both() { echo "PostgreSQL:"; pg -c "$SHOW_PG"; echo "SQL Server:"; ms "$SHOW_MS"; }
wait_cycles() { sleep 25; }

echo "--- 1. Polaczenie (link) z PostgreSQL do SQL Server: tabela zewnetrzna widzi rejestr w SQL Server"
pg -c "SELECT srvname, srvoptions FROM pg_foreign_server" -c "SELECT COUNT(*) AS wierszy_w_sql_server FROM noir.mssql_partner_agency"
echo "--- 2. Harmonogram pg_cron (zadanie nieaktywne do czasu uruchomienia) - na czas pokazu co 10 sekund"
pgc -c "SELECT jobid, jobname, schedule, database, command, active FROM cron.job WHERE jobname = 'noir_partner_sync'"
pgc -qAt -c "SELECT cron.alter_job(jobid, schedule := '10 seconds', active := true) FROM cron.job WHERE jobname = 'noir_partner_sync'" >/dev/null

echo "--- 3. Zmiany w obu systemach: PostgreSQL dodaje WAW i KRK, SQL Server dodaje BER"
pg -c "INSERT INTO noir.partner_agency (agency_code, name, city, phone) VALUES ('WAW', 'Warszawska Agencja Detektywow', 'Warszawa', '+48 22 555 01 01'), ('KRK', 'Krakowskie Biuro Sledcze', 'Krakow', '+48 12 555 02 02')"
ms "INSERT INTO noir.partner_agency (agency_code, name, city, phone) VALUES ('BER', N'Berliner Detektei', 'Berlin', '+49 30 555 03 03')"
echo "przed synchronizacja:"; both
wait_cycles
echo "po synchronizacji (pg_cron):"; both

echo "--- 4. Modyfikacje: PostgreSQL zmienia telefon WAW, SQL Server zmienia miasto KRK i wycofuje BER"
pg -c "UPDATE noir.partner_agency SET phone = '+48 22 555 99 99' WHERE agency_code = 'WAW'"
ms "UPDATE noir.partner_agency SET city = 'Krakow-Nowa Huta' WHERE agency_code = 'KRK'; UPDATE noir.partner_agency SET is_active = 0 WHERE agency_code = 'BER'"
wait_cycles
echo "po synchronizacji:"; both

echo "--- 5. Konflikt: ta sama agencja (WAW) zmieniona w obu systemach, pozniejsza zmiana (SQL Server) wygrywa"
pg -c "UPDATE noir.partner_agency SET name = 'WAW - wersja z PostgreSQL' WHERE agency_code = 'WAW'"
sleep 2
ms "UPDATE noir.partner_agency SET name = N'WAW - wersja z SQL Server' WHERE agency_code = 'WAW'"
wait_cycles
echo "po synchronizacji:"; both

echo "--- 6. Dziennik synchronizacji (job_run_log) i historia pg_cron"
pg -c "SELECT status, COUNT(*) AS przebiegow FROM noir.job_run_log WHERE job_name = 'partner_sync' GROUP BY status"
pg -c "SELECT run_id, status, details FROM noir.job_run_log WHERE job_name = 'partner_sync' AND details NOT LIKE 'from SQL Server: 0, to SQL Server: 0 new, 0 changed' ORDER BY run_id"
pgc -c "SELECT status, COUNT(*) AS przebiegow FROM cron.job_run_details d JOIN cron.job j USING (jobid) WHERE j.jobname = 'noir_partner_sync' GROUP BY status"

echo "--- 7. Awaria SQL Server: przebieg konczy sie wpisem ERROR, po powrocie synchronizacja nadrabia zmiany"
docker compose stop mssql >/dev/null 2>&1
pg -c "UPDATE noir.partner_agency SET phone = '+48 12 555 77 77' WHERE agency_code = 'KRK'"
sleep 15
pg -c "SELECT status, LEFT(details, 90) AS details FROM noir.job_run_log WHERE job_name = 'partner_sync' ORDER BY run_id DESC LIMIT 1"
docker compose start mssql >/dev/null 2>&1
until [ "$(docker inspect -f '{{.State.Health.Status}}' noir2_mssql)" = healthy ]; do sleep 3; done
sleep 25
echo "po powrocie SQL Server:"; both

echo "--- 8. Przywrocenie harmonogramu (co 5 minut, zadanie nieaktywne)"
pgc -qAt -c "SELECT cron.alter_job(jobid, schedule := '*/5 * * * *', active := false) FROM cron.job WHERE jobname = 'noir_partner_sync'" >/dev/null
pgc -c "SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'noir_partner_sync'"
