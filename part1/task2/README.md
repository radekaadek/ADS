# Biuro detektywistyczne noir - etap 2 (PostgreSQL 17 + SQL Server 2022 w Dockerze)

Etap 2 rozszerza bazę z `../task1` o elementy programowalne (funkcje, procedury, wyzwalacze), automatyzację (zadania), kopie zapasowe oraz migrację na drugi SZBD (SQL Server 2022). Sprawozdanie: [`sprawozdanie.md`](sprawozdanie.md), PDF w `pdf/`.

## Wymagania
Docker + Docker Compose v2 (pobiera obrazy `postgres:17`, `mcr.microsoft.com/mssql/server:2022-latest`, `apache/hop`, `ghcr.io/dimitri/pgloader`), ok. 4 GB wolnego RAM dla SQL Server.

## Szybki start
```bash
cd part1/task2
./run_all.sh          # całość od zera (ok. 8 min): bazy, migracja, testy, demonstracje, kopie; wyniki w results/
```
Pojedyncze kroki:
```bash
docker compose up -d pg        # PostgreSQL 17 + pg_cron (port 5433); skrypty sql/pg/01..12 wykonują się przy pierwszym starcie
./reset_pg.sh                  # PostgreSQL od zera
./reset_mssql.sh               # SQL Server od zera: baza noir, schemat i tabele (bez danych)
# migracja danych z PostgreSQL (jedna z dwóch metod):
docker compose exec -T pg bash /etl/bulk/export.sh && docker compose exec -T mssql bash /etl/bulk/load.sh   # CSV + BULK INSERT
./etl/hop/run_all.sh                                                                                           # Apache Hop
./scripts/compare_fingerprints.sh   # porównanie zawartości tabel w obu SZBD (md5 wierszy)
./sql/manual/25_sync_demo.sh        # pokaz synchronizacji PostgreSQL <-> SQL Server (ok. 3 min; wymaga obu baz po run_all.sh)
./scripts/mssql_build.sh code       # widoki, funkcje, procedury, wyzwalacze, role, zadania Agenta
```

## Układ katalogów
| Ścieżka | Zawartość |
|---|---|
| `sql/pg/01..05` | schemat, dane, widoki, role, indeksy (baza z etapu 1) |
| `sql/pg/06..12` | tabele pomocnicze, funkcje, procedury, wyzwalacze, procedura zadania, widoki i uprawnienia, pg_cron |
| `sql/pg/13_sync.sql`, `sql/mssql/13_sync.sql` | zawartość dodatkowa: link PostgreSQL → SQL Server (`tds_fdw`), rejestr `partner_agency` i dwukierunkowa synchronizacja przez `pg_cron` |
| `sql/mssql/` | te same elementy w T-SQL (`00`-`12`) + `etl_staging.sql`, `etl_finalize.sql` |
| `sql/manual/` | skrypty demonstracyjne (`20`-`24` PostgreSQL, `mssql_20`-`mssql_24` SQL Server), odciski tabel (`31_*`), kopia (`mssql_30_backup.sql`) |
| `sql/tests/` | testy uprawnień: `permissions.sh` (PostgreSQL), `permissions_mssql.sh` (SQL Server) |
| `etl/` | migracja: `bulk/` (CSV + BULK INSERT), `hop/` (potok Apache Hop), `pgloader_attempt.sh` |
| `scripts/` | budowa SQL Server, kopie zapasowe, porównanie zawartości |
| `results/` | zapisane wyniki wszystkich uruchomień |

## Połączenia (hasła wyłącznie deweloperskie)
```bash
docker compose exec pg psql -U noir_admin -d noir                                   # PostgreSQL (administrator)
PGPASSWORD=detective_pw psql -h localhost -p 5433 -U detective_app -d noir          # detektyw, analogicznie accountant_app / client_portal
docker compose exec mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U noir_admin -P Noir_Admin_pw1 -d noir -I   # SQL Server
```
Hasła w SQL Server: `Detective_pw1`, `Accountant_pw1`, `Client_pw1`, administrator `Noir_Admin_pw1` (polityka złożoności haseł), `sa` - `Noir_Admin_pw1`.
Klienty SQL Server muszą łączyć się z `QUOTED_IDENTIFIER ON` (`sqlcmd -I`): tabele mają indeksy filtrowane.

## Uwagi
- W logu PostgreSQL pojawia się jedna linia `FATAL: terminating background worker "pg_cron launcher"`: to zamknięcie tymczasowego serwera inicjalizacyjnego obrazu `postgres`, nie błąd bazy.
- Wolumen kopii SQL Server wymaga zmiany właściciela na `mssql` (robi to `reset_mssql.sh`).
- Pełny reset obu baz: `docker compose down -v`.
