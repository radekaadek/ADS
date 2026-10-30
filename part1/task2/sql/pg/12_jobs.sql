-- Automation: pg_cron (job metadata in the postgres database, jobs run in the noir database)
\connect postgres
CREATE EXTENSION IF NOT EXISTS pg_cron;
-- daily at 02:00 (server time, UTC)
SELECT cron.schedule_in_database('noir_nightly_maintenance', '0 2 * * *', 'CALL noir.sp_nightly_maintenance()', 'noir');
\connect noir
