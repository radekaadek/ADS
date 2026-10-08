SET search_path = noir;

INSERT INTO case_status (name) VALUES ('Open'), ('In progress'), ('On hold'), ('Closed - solved'), ('Closed - unsolved');
INSERT INTO case_type (name) VALUES ('Missing person'), ('Infidelity'), ('Fraud'), ('Theft'), ('Blackmail'), ('Murder consultation');
INSERT INTO evidence_type (name) VALUES ('Photograph'), ('Document'), ('Weapon'), ('Recording'), ('Physical trace'), ('Letter');
INSERT INTO detective_rank (name, hourly_rate) VALUES ('Rookie', 40.00), ('Investigator', 65.00), ('Senior investigator', 95.00), ('Chief detective', 140.00);
INSERT INTO payment_method (name) VALUES ('Cash'), ('Bank transfer'), ('Cheque'), ('Card');

INSERT INTO client (first_name, last_name, email, phone, company_name, registered_on) VALUES
 ('Vivian',  'Sternwood', 'vivian@sternwood.example',   '555-0101', NULL,                    '2025-01-12'),
 ('Carmen',  'Regan',     'carmen.regan@example.com',   '555-0102', NULL,                    '2025-02-03'),
 ('Gutman',  'Kasper',    'kasper@fatbird.example',     '555-0103', 'Fat Bird Imports',      '2025-03-21'),
 ('Brigid',  'O''Shaughnessy', 'brigid@example.com',    '555-0104', NULL,                    '2025-05-09'),
 ('Walter',  'Neff',      'wneff@pacific-ins.example',  '555-0105', 'Pacific All Risk Ins.', '2025-06-30'),
 ('Phyllis', 'Dietrichson','phyllis@example.com',       '555-0106', NULL,                    '2025-08-14');

INSERT INTO detective (rank_id, first_name, last_name, license_no, hired_on, is_active) VALUES
 (4, 'Philip',  'Marlowe', 'LIC-0001', '2018-03-01', TRUE),
 (3, 'Sam',     'Spade',   'LIC-0002', '2019-07-15', TRUE),
 (2, 'Mike',    'Hammer',  'LIC-0003', '2021-01-10', TRUE),
 (2, 'Nora',    'Charles', 'LIC-0004', '2022-09-05', TRUE),
 (1, 'Jake',    'Gittes',  'LIC-0005', '2025-01-10', TRUE),
 (3, 'Lew',     'Archer',  'LIC-0006', '2017-11-30', FALSE);

INSERT INTO location (name, street, city, notes) VALUES
 ('Sternwood Mansion',      '3765 Alta Brea Crescent', 'Los Angeles', 'Greenhouse in the back'),
 ('Hotel Belvedere',        '12 Sutter Street',        'San Francisco', 'Room 12'),
 ('Burbank Pier',           'Pier 4',                  'Los Angeles', 'Abandoned warehouse nearby'),
 ('Silver Moon Club',       '88 Ocean Avenue',         'Santa Monica', 'Back door to the alley'),
 ('Hollywood Hills Garage', '14 Mulholland Drive',     'Los Angeles', NULL),
 ('Union Station',          '800 N Alameda Street',    'Los Angeles', 'Locker 117');

INSERT INTO case_file (case_number, title, description, type_id, status_id, client_id, opened_on, closed_on, fee_estimate) VALUES
 ('NOIR-2025-001', 'The Missing Chauffeur',      'Chauffeur of the Sternwood family vanished after a night out.', 1, 4, 1, '2025-01-15', '2025-03-02', 2500.00),
 ('NOIR-2025-002', 'Compromising Photographs',   'A client is being blackmailed over photographs.',               5, 2, 2, '2025-02-10', NULL,         3200.00),
 ('NOIR-2025-003', 'The Falcon Statuette',       'Search for a stolen black bird statuette.',                    4, 4, 3, '2025-03-25', '2025-06-18', 8000.00),
 ('NOIR-2025-004', 'Fraudulent Policy',          'Suspected insurance fraud on a double-indemnity policy.',      3, 2, 5, '2025-07-02', NULL,         5400.00),
 ('NOIR-2025-005', 'Unfaithful Husband',         'Surveillance of spouse across three nights.',                  2, 5, 6, '2025-08-20', '2025-09-12', 900.00),
 ('NOIR-2025-006', 'Shadows at the Silver Moon', 'Inquiry into a death at the Silver Moon club.',                6, 1, 4, '2025-09-18', NULL,         6100.00),
 ('NOIR-2025-007', 'Letters from Nowhere',       'Anonymous letters threatening a company owner.',               5, 3, 3, '2025-10-01', NULL,         1800.00);

INSERT INTO case_detective (case_id, detective_id, role, assigned_on) VALUES
 (1, 1, 'LEAD', '2025-01-15'), (1, 5, 'ASSISTANT', '2025-01-20'),
 (2, 3, 'LEAD', '2025-02-10'), (2, 4, 'ASSISTANT', '2025-02-12'),
 (3, 2, 'LEAD', '2025-03-25'), (3, 1, 'ASSISTANT', '2025-04-01'),
 (4, 2, 'LEAD', '2025-07-02'), (4, 3, 'ASSISTANT', '2025-07-05'),
 (5, 5, 'LEAD', '2025-08-20'),
 (6, 1, 'LEAD', '2025-09-18'), (6, 4, 'ASSISTANT', '2025-09-19'),
 (7, 3, 'LEAD', '2025-10-01');

INSERT INTO suspect (first_name, last_name, alias, birth_date, last_seen_location_id) VALUES
 ('Joel',     'Cairo',    'The Levantine',  '1902-04-11', 2),
 ('Eddie',    'Mars',     'Mr. Mars',       '1898-09-02', 4),
 ('Lash',     'Canino',   'Lash',           '1910-01-23', 3),
 ('Norton',   'Dietrichson', NULL,          '1895-06-17', 5),
 ('Arthur',   'Geiger',   'Gig',            '1899-12-05', 1),
 ('Lola',     'Fenn',     'The Blonde',     NULL,         4);

INSERT INTO case_suspect (case_id, suspect_id, suspicion_level) VALUES
 (1, 2, 4), (1, 3, 3),
 (2, 5, 5), (2, 2, 2),
 (3, 1, 5), (3, 3, 4), (3, 6, 2),
 (4, 4, 5),
 (6, 2, 3), (6, 6, 4), (6, 3, 2);

INSERT INTO witness (first_name, last_name, phone, reliability) VALUES
 ('Agnes',  'Lozelle',  '555-0201', 3),
 ('Harry',  'Jones',    '555-0202', 2),
 ('Norris', 'Butler',   '555-0203', 5),
 ('Mona',   'Mars',     NULL,       4),
 ('Owen',   'Taylor',   '555-0205', 1);

INSERT INTO case_witness (case_id, witness_id, statement_date, statement) VALUES
 (1, 3, '2025-01-18', 'Saw the chauffeur leave in the grey sedan around midnight.'),
 (1, 5, '2025-01-22', 'Claims the car was parked at the pier.'),
 (2, 1, '2025-02-14', 'Delivered a package to Geiger''s shop on the 9th.'),
 (3, 2, '2025-04-02', 'Overheard a conversation about a black bird in the hotel lobby.'),
 (3, 4, '2025-05-11', 'Remembers a man with a cane near the docks.'),
 (6, 4, '2025-09-21', 'Was at the bar when the lights went out.'),
 (6, 1, '2025-09-25', NULL);

INSERT INTO informant (codename, handler_id, trust_level, fee_per_tip) VALUES
 ('Whistler',  1, 4, 25.00),
 ('Shadow',    2, 5, 50.00),
 ('Newsboy',   3, 2, 5.00),
 ('Barkeep',   1, 3, 15.00);

INSERT INTO tip (informant_id, case_id, received_at, content) VALUES
 (1, 1, '2025-01-17 22:10', 'The grey sedan was seen near Burbank Pier.'),
 (2, 3, '2025-04-05 03:40', 'The statuette is being moved through Union Station.'),
 (3, 2, '2025-02-15 09:00', 'Geiger''s shop has a hidden darkroom.'),
 (4, 6, '2025-09-20 01:30', 'Mars''s men were seen leaving by the back door.'),
 (2, 4, '2025-07-10 18:20', 'Dietrichson signed the policy while travelling.');

INSERT INTO evidence (evidence_code, case_id, evidence_type_id, location_id, description, found_at) VALUES
 ('EV-0001', 1, 5, 3, 'Tyre tracks matching a grey sedan.',               '2025-01-19 08:30'),
 ('EV-0002', 1, 2, 1, 'Unsigned note found in the chauffeur''s room.',    '2025-01-16 14:00'),
 ('EV-0003', 2, 1, 2, 'Negatives of compromising photographs.',           '2025-02-16 21:15'),
 ('EV-0004', 3, 3, 6, 'Replica statuette with a lead core.',              '2025-04-06 04:10'),
 ('EV-0005', 3, 6, 2, 'Letter signed with an initial "G".',               '2025-04-02 11:45'),
 ('EV-0006', 4, 2, 5, 'Insurance policy with a forged-looking signature.','2025-07-08 10:00'),
 ('EV-0007', 6, 4, 4, 'Recording of an argument from the club office.',   '2025-09-22 23:55'),
 ('EV-0008', 6, 3, 4, '.38 revolver, one round fired.',                   '2025-09-19 02:20'),
 ('EV-0009', 6, 5, 4, 'Lipstick smear on a glass.',                       '2025-09-19 02:45');

INSERT INTO evidence_custody (evidence_id, transferred_at, detective_id, note) VALUES
 (1, '2025-01-19 09:00', 1, 'Collected'),
 (1, '2025-01-20 10:00', 5, 'Handed over for analysis'),
 (3, '2025-02-16 22:00', 3, 'Collected'),
 (4, '2025-04-06 05:00', 2, 'Collected'),
 (4, '2025-04-07 09:30', 1, 'Second opinion'),
 (7, '2025-09-23 08:00', 1, 'Collected'),
 (8, '2025-09-19 03:00', 1, 'Collected'),
 (8, '2025-09-19 12:00', 4, 'To ballistics'),
 (9, '2025-09-19 03:10', 4, 'Collected');

INSERT INTO invoice (invoice_number, case_id, issued_on, due_on, amount) VALUES
 ('INV-2025-0001', 1, '2025-03-03', '2025-04-02', 2500.00),
 ('INV-2025-0002', 3, '2025-04-30', '2025-05-30', 4000.00),
 ('INV-2025-0003', 3, '2025-06-20', '2025-07-20', 4200.00),
 ('INV-2025-0004', 5, '2025-09-13', '2025-10-13', 900.00),
 ('INV-2025-0005', 4, '2025-08-01', '2025-08-31', 2000.00),
 ('INV-2025-0006', 6, '2025-10-01', '2025-10-31', 1500.00);

INSERT INTO payment (invoice_id, method_id, paid_on, amount) VALUES
 (1, 2, '2025-03-20', 2500.00),
 (2, 3, '2025-05-10', 4000.00),
 (3, 2, '2025-07-01', 2000.00),
 (4, 1, '2025-09-20', 900.00),
 (5, 4, '2025-08-15', 1000.00);
