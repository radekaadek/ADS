# Case study - biuro detektywistyczne noir - Radosław Dąbkowski 325683

## 1. Case study (opis problematyki)
Agencja detektywistyczna „Noir & Spółka" prowadzi śledztwa dla klientów prywatnych i firm: zaginięcia, zdrady małżeńskie, szantaże, oszustwa ubezpieczeniowe, kradzieże i konsultacje w sprawach zabójstw. Każda **sprawa** ma klienta, typ (np. szantaż), status (otwarta, w toku, wstrzymana, zamknięta) oraz najwyżej jednego prowadzącego **detektywa** i opcjonalnych pomocników; detektywi mają stopnie wyznaczające stawkę godzinową. W sprawie pojawiają się **podejrzani** (z poziomem podejrzeń 1-5), **świadkowie** ze zeznaniami i oceną wiarygodności oraz **informatorzy** pod pseudonimami, przekazujący wskazówki i pozostający pod opieką jednego detektywa. Zebrane **dowody** (zdjęcia, dokumenty, broń, nagrania, ślady, listy) mają miejsce znalezienia, a każde przekazanie dowodu między detektywami jest zapisywane w **łańcuchu dowodowym**, bez którego dowód traci wartość. Agencja wystawia **faktury** za sprawy, a klienci opłacają je w ratach różnymi metodami płatności.

Użytkownicy bazy: **detektyw** (prowadzi sprawy, dodaje dowody, zeznania i wskazówki), **księgowy** (faktury i płatności, bez wglądu w treść śledztw), **klient** (podgląd statusu własnych spraw przez portal), **administrator** (właściciel schematu). Usługi: rejestracja spraw i dowodów, śledzenie łańcucha dowodowego, raport obciążenia detektywów, rozliczenia i salda faktur, portal statusu dla klienta.

> Zakres bazy: dane przechowywane w bazie to klienci, detektywi i ich stopnie, sprawy, podejrzani, świadkowie, informatorzy i wskazówki, dowody wraz z lokalizacjami i łańcuchem dowodowym, faktury i płatności (20 tabel).

## 2. Wybór SZBD: PostgreSQL 17 (Docker)
**Uzasadnienie:** PostgreSQL ma najszerszy ekosystem rozszerzeń wśród popularnych relacyjnych SZBD: rozszerzenia dodają nowe typy danych, metody indeksowania, funkcje i operatory, obce źródła danych, języki proceduralne, monitoring i audyt. Na moment pisania sprawozdania katalog [pgext.cloud](https://pgext.cloud) obejmuje 2569 rozszerzeń, a dystrybucja Pigsty udostępnia 584 rozszerzeń ([Pigsty - Extensions for Everyone](https://pigsty.io/ext/#extension-statistics)), np. PostGIS dla danych geograficznych miejsc zdarzeń, `pg_trgm` do wyszukiwania nazwisk, `pgcrypto` do szyfrowania danych informatorów.

Dodatkowo: `GENERATED AS IDENTITY`, schematy bazodanowe, rozbudowany optymalizator z `EXPLAIN ANALYZE`, otwarta licencja i brak kosztów.

**Konfiguracja.** PostgreSQL działa w kontenerze Docker uruchamianym przez Docker Compose z oficjalnego obrazu `postgres:17`. Baza `noir` należy do użytkownika `noir_admin`, dane są w trwałym wolumenie `noir_data`, a skrypty SQL montowane do katalogu `/docker-entrypoint-initdb.d` budują całą bazę automatycznie przy pierwszym starcie. Konfiguracja usługi:

```yaml
services:
  db:
    image: postgres:17
    container_name: noir_pg
    environment:
      POSTGRES_USER: noir_admin
      POSTGRES_PASSWORD: noir_admin_pw   # tylko środowisko deweloperskie / zaliczeniowe
      POSTGRES_DB: noir
    ports:
      - "5432:5432"
    volumes:
      - noir_data:/var/lib/postgresql/data
      - ./sql:/docker-entrypoint-initdb.d:ro
      - ./sql/tests:/tests:ro
      - ./sql/manual:/manual:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U noir_admin -d noir"]
      interval: 5s
      timeout: 3s
      retries: 10

volumes:
  noir_data:
```

Uruchomienie i sprawdzenie bazy:

```bash
docker compose up -d                      # pobranie obrazu, utworzenie bazy i wykonanie skryptów
docker compose ps                         # oczekiwany stan: healthy
docker compose logs db | grep -i error    # brak wyników = brak błędów
docker compose exec db psql -U noir_admin -d noir     # połączenie jako administrator
docker compose down -v && docker compose up -d        # odtworzenie bazy od zera
```

Poprawność konfiguracji potwierdzono w następujący sposób: kontener osiąga stan *healthy* (`pg_isready`), logi nie zawierają błędów, a ponowne uruchomienie z usunięciem wolumenu odtwarza bazę od zera.

## 3. Projekt bazy
### 3.1 ERD
Diagram w języku naturalnym: encja - relacja - encja, np. *Klient zleca Sprawę (1:n)*, *Detektyw prowadzi/pracuje nad Sprawą (n:m)*, *Sprawa obejmuje Podejrzanego (n:m)*, *Dowód znaleziono w Lokalizacji (n:1)*, *Detektyw przejmuje w depozyt Dowód (n:m)*, *Informator przekazuje wskazówkę o Sprawie (n:m)*. Żółte encje to słowniki.

![](diagrams/pdf/erd.pdf){ width=17cm }

### 3.2 Schemat logiczny
Schemat zawiera typy danych, PK/FK/UNIQUE/NOT NULL oraz indeksy; tabele słownikowe są żółte, asocjacyjne fioletowe. Schemat logiczny ma już tabele asocjacyjne (zamiast relacji n:m tak jak w ERD), słowniki, klucze i typy.

```{=latex}
\newpage
\newgeometry{landscape,margin=1cm}
\special{papersize=29.7cm,21cm}
```

![](diagrams/pdf/schemat_logiczny.pdf){ width=27cm }

```{=latex}
\newpage
\restoregeometry
\special{papersize=21cm,29.7cm}
```

### 3.3 Tabele (schemat `noir`)
- **Słownikowe (5):** `case_status`, `case_type`, `evidence_type`, `detective_rank`, `payment_method`.
- **Główne (11):** `client`, `detective`, `location`, `case_file`, `suspect`, `witness`, `informant`, `evidence`, `tip`, `invoice`, `payment`.
- **Asocjacyjne (4):** `case_detective`, `case_suspect`, `case_witness`, `evidence_custody`.
