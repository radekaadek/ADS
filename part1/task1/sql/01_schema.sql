-- Baza "Biuro detektywistyczne noir" (PostgreSQL 17)
-- Konwencje: snake_case, IDENTITY zamiast serial, brak ENUM/tablic/jsonb,
-- slowniki jako tabele, nazwane ograniczenia, typy standardowe.

CREATE SCHEMA noir AUTHORIZATION noir_admin;
SET search_path = noir;

-- ===================== SLOWNIKI =====================
CREATE TABLE case_status (
    status_id   SMALLINT GENERATED ALWAYS AS IDENTITY,
    name        VARCHAR(30) NOT NULL,
    CONSTRAINT pk_case_status PRIMARY KEY (status_id),
    CONSTRAINT uq_case_status_name UNIQUE (name)
);

CREATE TABLE case_type (
    type_id     SMALLINT GENERATED ALWAYS AS IDENTITY,
    name        VARCHAR(40) NOT NULL,
    CONSTRAINT pk_case_type PRIMARY KEY (type_id),
    CONSTRAINT uq_case_type_name UNIQUE (name)
);

CREATE TABLE evidence_type (
    evidence_type_id SMALLINT GENERATED ALWAYS AS IDENTITY,
    name             VARCHAR(40) NOT NULL,
    CONSTRAINT pk_evidence_type PRIMARY KEY (evidence_type_id),
    CONSTRAINT uq_evidence_type_name UNIQUE (name)
);

CREATE TABLE detective_rank (
    rank_id     SMALLINT GENERATED ALWAYS AS IDENTITY,
    name        VARCHAR(40) NOT NULL,
    hourly_rate NUMERIC(8,2) NOT NULL,
    CONSTRAINT pk_detective_rank PRIMARY KEY (rank_id),
    CONSTRAINT uq_detective_rank_name UNIQUE (name),
    CONSTRAINT ck_detective_rank_rate CHECK (hourly_rate > 0)
);

CREATE TABLE payment_method (
    method_id   SMALLINT GENERATED ALWAYS AS IDENTITY,
    name        VARCHAR(30) NOT NULL,
    CONSTRAINT pk_payment_method PRIMARY KEY (method_id),
    CONSTRAINT uq_payment_method_name UNIQUE (name)
);

-- ===================== TABELE GLOWNE =====================
CREATE TABLE client (
    client_id    INTEGER GENERATED ALWAYS AS IDENTITY,
    first_name   VARCHAR(50)  NOT NULL,
    last_name    VARCHAR(80)  NOT NULL,
    email        VARCHAR(120) NOT NULL,
    phone        VARCHAR(20),
    company_name VARCHAR(120),
    registered_on DATE NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_client PRIMARY KEY (client_id),
    CONSTRAINT uq_client_email UNIQUE (email)
);

CREATE TABLE detective (
    detective_id INTEGER GENERATED ALWAYS AS IDENTITY,
    rank_id      SMALLINT NOT NULL,
    first_name   VARCHAR(50) NOT NULL,
    last_name    VARCHAR(80) NOT NULL,
    license_no   VARCHAR(20) NOT NULL,
    hired_on     DATE NOT NULL,
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT pk_detective PRIMARY KEY (detective_id),
    CONSTRAINT uq_detective_license UNIQUE (license_no),
    CONSTRAINT fk_detective_rank FOREIGN KEY (rank_id) REFERENCES detective_rank (rank_id)
);

CREATE TABLE location (
    location_id INTEGER GENERATED ALWAYS AS IDENTITY,
    name        VARCHAR(100) NOT NULL,
    street      VARCHAR(120),
    city        VARCHAR(60) NOT NULL,
    notes       VARCHAR(300),
    CONSTRAINT pk_location PRIMARY KEY (location_id)
);

CREATE TABLE case_file (
    case_id      INTEGER GENERATED ALWAYS AS IDENTITY,
    case_number  VARCHAR(20) NOT NULL,
    title        VARCHAR(150) NOT NULL,
    description  VARCHAR(2000),
    type_id      SMALLINT NOT NULL,
    status_id    SMALLINT NOT NULL,
    client_id    INTEGER  NOT NULL,
    opened_on    DATE NOT NULL,
    closed_on    DATE,
    fee_estimate NUMERIC(10,2) NOT NULL DEFAULT 0,
    CONSTRAINT pk_case_file PRIMARY KEY (case_id),
    CONSTRAINT uq_case_file_number UNIQUE (case_number),
    CONSTRAINT fk_case_file_type   FOREIGN KEY (type_id)   REFERENCES case_type (type_id),
    CONSTRAINT fk_case_file_status FOREIGN KEY (status_id) REFERENCES case_status (status_id),
    CONSTRAINT fk_case_file_client FOREIGN KEY (client_id) REFERENCES client (client_id),
    CONSTRAINT ck_case_file_dates  CHECK (closed_on IS NULL OR closed_on >= opened_on),
    CONSTRAINT ck_case_file_fee    CHECK (fee_estimate >= 0)
);

CREATE TABLE suspect (
    suspect_id  INTEGER GENERATED ALWAYS AS IDENTITY,
    first_name  VARCHAR(50) NOT NULL,
    last_name   VARCHAR(80) NOT NULL,
    alias       VARCHAR(60),
    birth_date  DATE,
    last_seen_location_id INTEGER,
    CONSTRAINT pk_suspect PRIMARY KEY (suspect_id),
    CONSTRAINT fk_suspect_location FOREIGN KEY (last_seen_location_id) REFERENCES location (location_id)
);

CREATE TABLE witness (
    witness_id  INTEGER GENERATED ALWAYS AS IDENTITY,
    first_name  VARCHAR(50) NOT NULL,
    last_name   VARCHAR(80) NOT NULL,
    phone       VARCHAR(20),
    reliability SMALLINT NOT NULL,
    CONSTRAINT pk_witness PRIMARY KEY (witness_id),
    CONSTRAINT ck_witness_reliability CHECK (reliability BETWEEN 1 AND 5)
);

CREATE TABLE informant (
    informant_id INTEGER GENERATED ALWAYS AS IDENTITY,
    codename     VARCHAR(40) NOT NULL,
    handler_id   INTEGER NOT NULL,
    trust_level  SMALLINT NOT NULL,
    fee_per_tip  NUMERIC(8,2) NOT NULL DEFAULT 0,
    CONSTRAINT pk_informant PRIMARY KEY (informant_id),
    CONSTRAINT uq_informant_codename UNIQUE (codename),
    CONSTRAINT fk_informant_handler FOREIGN KEY (handler_id) REFERENCES detective (detective_id),
    CONSTRAINT ck_informant_trust CHECK (trust_level BETWEEN 1 AND 5),
    CONSTRAINT ck_informant_fee   CHECK (fee_per_tip >= 0)
);

CREATE TABLE evidence (
    evidence_id      INTEGER GENERATED ALWAYS AS IDENTITY,
    evidence_code    VARCHAR(20) NOT NULL,
    case_id          INTEGER  NOT NULL,
    evidence_type_id SMALLINT NOT NULL,
    location_id      INTEGER,
    description      VARCHAR(500) NOT NULL,
    found_at         TIMESTAMP NOT NULL,
    CONSTRAINT pk_evidence PRIMARY KEY (evidence_id),
    CONSTRAINT uq_evidence_code UNIQUE (evidence_code),
    CONSTRAINT fk_evidence_case     FOREIGN KEY (case_id)          REFERENCES case_file (case_id),
    CONSTRAINT fk_evidence_type     FOREIGN KEY (evidence_type_id) REFERENCES evidence_type (evidence_type_id),
    CONSTRAINT fk_evidence_location FOREIGN KEY (location_id)      REFERENCES location (location_id)
);

CREATE TABLE tip (
    tip_id       INTEGER GENERATED ALWAYS AS IDENTITY,
    informant_id INTEGER NOT NULL,
    case_id      INTEGER NOT NULL,
    received_at  TIMESTAMP NOT NULL,
    content      VARCHAR(1000) NOT NULL,
    CONSTRAINT pk_tip PRIMARY KEY (tip_id),
    CONSTRAINT fk_tip_informant FOREIGN KEY (informant_id) REFERENCES informant (informant_id),
    CONSTRAINT fk_tip_case      FOREIGN KEY (case_id)      REFERENCES case_file (case_id)
);

CREATE TABLE invoice (
    invoice_id     INTEGER GENERATED ALWAYS AS IDENTITY,
    invoice_number VARCHAR(20) NOT NULL,
    case_id        INTEGER NOT NULL,
    issued_on      DATE NOT NULL,
    due_on         DATE NOT NULL,
    amount         NUMERIC(10,2) NOT NULL,
    CONSTRAINT pk_invoice PRIMARY KEY (invoice_id),
    CONSTRAINT uq_invoice_number UNIQUE (invoice_number),
    CONSTRAINT fk_invoice_case FOREIGN KEY (case_id) REFERENCES case_file (case_id),
    CONSTRAINT ck_invoice_amount CHECK (amount > 0),
    CONSTRAINT ck_invoice_dates  CHECK (due_on >= issued_on)
);

CREATE TABLE payment (
    payment_id  INTEGER GENERATED ALWAYS AS IDENTITY,
    invoice_id  INTEGER NOT NULL,
    method_id   SMALLINT NOT NULL,
    paid_on     DATE NOT NULL,
    amount      NUMERIC(10,2) NOT NULL,
    CONSTRAINT pk_payment PRIMARY KEY (payment_id),
    CONSTRAINT fk_payment_invoice FOREIGN KEY (invoice_id) REFERENCES invoice (invoice_id),
    CONSTRAINT fk_payment_method  FOREIGN KEY (method_id)  REFERENCES payment_method (method_id),
    CONSTRAINT ck_payment_amount  CHECK (amount > 0)
);

-- ===================== TABELE ASOCJACYJNE (klucze zlozone; evidence_custody ma klucz zastepczy) =====================
CREATE TABLE case_detective (
    case_id      INTEGER NOT NULL,
    detective_id INTEGER NOT NULL,
    role         VARCHAR(10) NOT NULL DEFAULT 'ASSISTANT',
    assigned_on  DATE NOT NULL,
    CONSTRAINT pk_case_detective PRIMARY KEY (case_id, detective_id),
    CONSTRAINT fk_cd_case      FOREIGN KEY (case_id)      REFERENCES case_file (case_id),
    CONSTRAINT fk_cd_detective FOREIGN KEY (detective_id) REFERENCES detective (detective_id),
    CONSTRAINT ck_cd_role CHECK (role IN ('LEAD', 'ASSISTANT'))
);

CREATE TABLE case_suspect (
    case_id         INTEGER NOT NULL,
    suspect_id      INTEGER NOT NULL,
    suspicion_level SMALLINT NOT NULL,
    CONSTRAINT pk_case_suspect PRIMARY KEY (case_id, suspect_id),
    CONSTRAINT fk_cs_case    FOREIGN KEY (case_id)    REFERENCES case_file (case_id),
    CONSTRAINT fk_cs_suspect FOREIGN KEY (suspect_id) REFERENCES suspect (suspect_id),
    CONSTRAINT ck_cs_level CHECK (suspicion_level BETWEEN 1 AND 5)
);

CREATE TABLE case_witness (
    case_id        INTEGER NOT NULL,
    witness_id     INTEGER NOT NULL,
    statement_date DATE NOT NULL,
    statement      VARCHAR(1500),
    CONSTRAINT pk_case_witness PRIMARY KEY (case_id, witness_id),
    CONSTRAINT fk_cw_case    FOREIGN KEY (case_id)    REFERENCES case_file (case_id),
    CONSTRAINT fk_cw_witness FOREIGN KEY (witness_id) REFERENCES witness (witness_id)
);

-- lancuch dowodowy: kto i kiedy przejal dowod (klucz zastepczy; ten sam dowod nie moze miec dwoch przekazan w tej samej chwili)
CREATE TABLE evidence_custody (
    custody_id     INTEGER GENERATED ALWAYS AS IDENTITY,
    evidence_id    INTEGER NOT NULL,
    transferred_at TIMESTAMP NOT NULL,
    detective_id   INTEGER NOT NULL,
    note           VARCHAR(200),
    CONSTRAINT pk_evidence_custody PRIMARY KEY (custody_id),
    CONSTRAINT uq_evidence_custody_time UNIQUE (evidence_id, transferred_at),
    CONSTRAINT fk_ec_evidence  FOREIGN KEY (evidence_id)  REFERENCES evidence (evidence_id),
    CONSTRAINT fk_ec_detective FOREIGN KEY (detective_id) REFERENCES detective (detective_id)
);
