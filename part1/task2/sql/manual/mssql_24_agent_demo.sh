#!/usr/bin/env bash
# Uruchamiany w kontenerze mssql: docker compose exec -T mssql bash /manual/mssql_24_agent_demo.sh
# Pokazuje zadania i scheduley SQL Server Agent, uruchamia zadanie recznie, a potem tymczasowo ustawia
# schedule co minute, czeka na przebieg zlecony przez Agenta i przywraca 02:00.
Q() { /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -I -W -s "|" "$@"; }
echo "--- zadania i scheduley"
Q -d msdb -Q "SET NOCOUNT ON; SELECT j.name AS job, s.name AS schedule, s.freq_type, s.active_start_time, j.enabled FROM dbo.sysjobs j JOIN dbo.sysjobschedules js ON js.job_id = j.job_id JOIN dbo.sysschedules s ON s.schedule_id = js.schedule_id ORDER BY j.name"
echo "--- manual job start (sp_start_job)"
Q -d msdb -Q "SET NOCOUNT ON; EXEC dbo.sp_start_job 'noir_nightly_maintenance'"
sleep 8
echo "--- schedule changed to every minute (for the duration of the test only)"
Q -d msdb -Q "SET NOCOUNT ON; EXEC dbo.sp_update_schedule @name = 'noir_daily_0200', @freq_subday_type = 4, @freq_subday_interval = 1"
sleep 75
Q -d msdb -Q "SET NOCOUNT ON; EXEC dbo.sp_update_schedule @name = 'noir_daily_0200', @freq_subday_type = 1, @freq_subday_interval = 0, @active_start_time = 20000"
echo "--- job history in msdb (step 1 = step result, step 0 = job result)"
Q -d msdb -Q "SET NOCOUNT ON; SELECT h.step_id, CASE h.run_status WHEN 1 THEN 'Succeeded' WHEN 0 THEN 'Failed' ELSE CAST(h.run_status AS VARCHAR(5)) END AS run_status,
  STUFF(STUFF(RIGHT('000000' + CAST(h.run_time AS VARCHAR(6)), 6), 5, 0, ':'), 3, 0, ':') AS run_time, h.run_duration, LEFT(h.message, 90) AS message
  FROM dbo.sysjobhistory h JOIN dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = 'noir_nightly_maintenance' ORDER BY h.instance_id"
echo "--- job_run_log after runs triggered by the Agent"
Q -d noir -Q "SET NOCOUNT ON; SELECT run_id, job_name, status, details FROM noir.job_run_log ORDER BY run_id"
echo "--- schedule restored"
Q -d msdb -Q "SET NOCOUNT ON; SELECT s.name, s.freq_type, s.freq_subday_type, s.active_start_time FROM dbo.sysschedules s WHERE s.name = 'noir_daily_0200'"
