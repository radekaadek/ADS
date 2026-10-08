SET search_path = noir;
-- PK i UNIQUE tworza indeksy automatycznie. PostgreSQL NIE indeksuje kluczy obcych,
-- dlatego dodajemy B-tree tam, gdzie FK uczestniczy w JOIN-ach lub filtrach.

-- case_file: sprawy klienta w danym statusie od daty (rownosc, rownosc, zakres) -> jeden indeks zlozony;
-- obsluguje tez samo client_id (lewy prefiks), wiec osobny indeks po kliencie jest zbedny
CREATE INDEX ix_case_file_client_status_opened ON case_file (client_id, status_id, opened_on);
CREATE INDEX ix_case_file_type                 ON case_file (type_id);
-- status_id nie jest pierwsza kolumna indeksu zlozonego, a po nim laczy sie widoki i filtruje zapytania
CREATE INDEX ix_case_file_status               ON case_file (status_id);

-- evidence: dowody danej sprawy oraz filtr po typie w obrebie sprawy
CREATE INDEX ix_evidence_case_type ON evidence (case_id, evidence_type_id);
CREATE INDEX ix_evidence_location  ON evidence (location_id);
CREATE INDEX ix_evidence_type      ON evidence (evidence_type_id);

-- asocjacyjne: PK (case_id, x) obsluguje wyszukiwanie po case_id; odwrotny kierunek wymaga drugiego indeksu
CREATE INDEX ix_case_detective_detective ON case_detective (detective_id);
-- najwyzej jeden prowadzacy (LEAD) na sprawe
CREATE UNIQUE INDEX uq_case_detective_lead ON case_detective (case_id) WHERE role = 'LEAD';
CREATE INDEX ix_case_suspect_suspect     ON case_suspect (suspect_id);
CREATE INDEX ix_case_witness_witness     ON case_witness (witness_id);

-- lancuch dowodowy: kto przechowuje dowody
CREATE INDEX ix_evidence_custody_detective ON evidence_custody (detective_id);

-- finanse
CREATE INDEX ix_invoice_case    ON invoice (case_id);
CREATE INDEX ix_payment_invoice ON payment (invoice_id);
CREATE INDEX ix_payment_method  ON payment (method_id);

-- raport faktur po terminie (zakres po due_on)
CREATE INDEX ix_invoice_due ON invoice (due_on);

CREATE INDEX ix_tip_informant ON tip (informant_id);
CREATE INDEX ix_tip_case      ON tip (case_id);
CREATE INDEX ix_detective_rank ON detective (rank_id);
CREATE INDEX ix_informant_handler ON informant (handler_id);
-- wyszukiwanie osob po nazwisku
CREATE INDEX ix_suspect_last_name ON suspect (last_name);
CREATE INDEX ix_witness_last_name ON witness (last_name);
CREATE INDEX ix_suspect_location ON suspect (last_seen_location_id);
-- client, location, evidence_custody(evidence_id): bez dodatkowych indeksow - klucz glowny lub UNIQUE
-- (evidence_id, transferred_at) juz obsluguje wyszukiwanie; client i location nie maja kluczy obcych.
