SET search_path = noir;

-- Zapytanie 1: detektywi z liczba aktywnych spraw nie wieksza niz srednia (CTE, JOIN-y, GROUP BY, podzapytania)
WITH workload AS (
    SELECT detective, active_cases
    FROM v_detective_workload
)
SELECT detective, active_cases
FROM workload
WHERE active_cases <= (SELECT AVG(active_cases) FROM workload)
ORDER BY active_cases DESC, detective;

-- Zapytanie 2: podejrzani z kilku spraw, majacy powiazany dowod znaleziony w ich ostatnio widzianej lokalizacji
-- (podzapytanie skorelowane EXISTS + agregacja z HAVING)
SELECT sp.first_name || ' ' || sp.last_name AS suspect,
       COALESCE(sp.alias, '-') AS alias,
       COUNT(*) AS cases_count,
       MAX(cs.suspicion_level) AS max_suspicion,
       l.name AS last_seen
FROM suspect sp
JOIN case_suspect cs ON cs.suspect_id = sp.suspect_id
JOIN location l ON l.location_id = sp.last_seen_location_id
WHERE EXISTS (
        SELECT 1
        FROM evidence e
        JOIN case_suspect cs2 ON cs2.case_id = e.case_id
        WHERE cs2.suspect_id = sp.suspect_id
          AND e.location_id = sp.last_seen_location_id)
GROUP BY sp.suspect_id, sp.first_name, sp.last_name, sp.alias, l.name
HAVING COUNT(*) > 1
ORDER BY cases_count DESC, max_suspicion DESC;
