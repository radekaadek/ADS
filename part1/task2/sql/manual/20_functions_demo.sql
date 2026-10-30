\set VERBOSITY terse
SET search_path = noir;
\echo '--- fn_case_timeline(3): timeline of the Falcon Statuette case'
SELECT * FROM fn_case_timeline(3);
