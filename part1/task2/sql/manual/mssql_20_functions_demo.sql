SET NOCOUNT ON;
PRINT '--- fn_case_timeline(3): timeline of the Falcon Statuette case';
SELECT * FROM noir.fn_case_timeline(3) ORDER BY event_at, event_type;
GO
