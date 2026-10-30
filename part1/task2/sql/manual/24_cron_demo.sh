#!/usr/bin/env bash
# Uruchamiany w kontenerze pg: docker compose exec -T pg bash /manual/24_cron_demo.sh
# Pokazuje schedule, tymczasowo ustawia go na kazda minute, czeka na przebieg i przywraca 02:00.
P="psql -U noir_admin -d postgres -At -F | "
echo "--- schedule"; psql -U noir_admin -d postgres -c "SELECT jobid, jobname, schedule, database, command, active FROM cron.job"
psql -U noir_admin -d noir -qAt -c "SELECT 'przebiegow w job_run_log przed: ' || COUNT(*) FROM noir.job_run_log"
echo "--- schedule changed to every minute (for the duration of the test only)"
psql -U noir_admin -d postgres -qAt -c "SELECT cron.alter_job(1, schedule := '* * * * *')"
sleep 70
echo "--- cron.job_run_details"
psql -U noir_admin -d postgres -c "SELECT jobid, status, return_message, start_time::timestamp(0), end_time::timestamp(0) FROM cron.job_run_details ORDER BY runid"
psql -U noir_admin -d postgres -qAt -c "SELECT cron.alter_job(1, schedule := '0 2 * * *')"
echo "--- job_run_log after a run triggered by pg_cron"
psql -U noir_admin -d noir -c "SELECT run_id, job_name, status, details FROM noir.job_run_log ORDER BY run_id"
echo "--- schedule restored"; psql -U noir_admin -d postgres -c "SELECT jobname, schedule FROM cron.job"
