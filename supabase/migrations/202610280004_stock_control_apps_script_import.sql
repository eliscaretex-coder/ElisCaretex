-- =====================================================================
-- ElisCaretex V2
-- Stock Control: import of the "Elis Stock Control" Apps Script spreadsheet
-- Batch APPS_SCRIPT_STOCK_20261028_001 (file "Stock Control DB.xlsx", sent by the owner 2026-10-28)
--
-- Follows docs/database/APPS_SCRIPT_DATA_IMPORT_GUIDE.md:
-- 1. Land: every source row is kept untouched in
--    staging.apps_script_stock_rows (sheet, source key, raw JSON). The CONFIG
--    sheet is not imported (it holds an API key) and neither is CUSTOMERS:
--    no movement in the file was booked to a customer.
-- 2. Map: people are matched only by their legacy ids, never by guessing:
--    EMPLOYEES with SOURCE=USER -> staff_members.legacy_user_id,
--    SOURCE=DRIVER -> distribution_drivers.legacy_driver_id. KEY_LOG has only
--    a name, matched to the EMPLOYEES sheet (names there are unique).
--    Profiled 2026-10-28: 72 of 73 people matched. EMP-0070 "Ryotaro"
--    (UserID 111) has no Staff Master record; nothing in the file is
--    assigned to that person. Unmatched rows keep the name only and are
--    marked REVIEW in staging.
-- 3. Promote into the stock tables with source APPS_SCRIPT and a source key,
--    so running the file again adds nothing. Item stock and last count are
--    the spreadsheet's current values; movements, counts, uniform and key
--    logs are history. Local spreadsheet times are Europe/Dublin.
-- Apply after 202610280003_stock_control.sql.
-- =====================================================================

begin;

create table if not exists staging.apps_script_stock_rows (
  batch_id text not null,
  sheet_name text not null,
  source_key text not null,
  raw jsonb not null,
  review_status text not null default 'LANDED' check (review_status in ('LANDED','PROMOTED','REVIEW')),
  review_reason text,
  loaded_at timestamptz not null default now(),
  primary key (batch_id,sheet_name,source_key)
);
alter table staging.apps_script_stock_rows enable row level security;
revoke all on staging.apps_script_stock_rows from public,anon,authenticated;

-- 1. Land ----------------------------------------------------------------

insert into staging.apps_script_stock_rows(batch_id,sheet_name,source_key,raw)
select 'APPS_SCRIPT_STOCK_20261028_001',v.sheet,v.k,v.raw from (values
  ('ITEMS','ITM-0001',$j${"ACTIVE": true, "CATEGORY": "Chemical", "CODE": null, "ID": "ITM-0001", "LAST_COUNT": "2026-09-28T12:25:21.542000", "LOCATION": null, "MIN_STOCK": 2, "NAME": "SOFTENET FLOWERCARE", "STOCK": 5, "SUPPLIER": "Henkel Ecolab", "TRACK_BY": "NONE", "UNIT": "unit", "UNIT_PRICE": 156.79}$j$::jsonb),
  ('ITEMS','ITM-0002',$j${"ACTIVE": true, "CATEGORY": "Chemical", "CODE": null, "ID": "ITM-0002", "LAST_COUNT": "2026-09-28T12:25:21.542000", "LOCATION": null, "MIN_STOCK": 5, "NAME": "TRIPLEX COLOUR CARE 20L", "STOCK": 15, "SUPPLIER": "Henkel Ecolab", "TRACK_BY": "NONE", "UNIT": "unit", "UNIT_PRICE": 118.9}$j$::jsonb),
  ('ITEMS','ITM-0003',$j${"ACTIVE": true, "CATEGORY": "Chemical", "CODE": null, "ID": "ITM-0003", "LAST_COUNT": "2026-09-18T10:23:36.434000", "LOCATION": null, "MIN_STOCK": 3, "NAME": "P3-POLIX CHLORANT 24kg", "STOCK": 8, "SUPPLIER": "Henkel Ecolab", "TRACK_BY": "NONE", "UNIT": "unit", "UNIT_PRICE": 30.48}$j$::jsonb),
  ('ITEMS','ITM-0004',$j${"ACTIVE": false, "CATEGORY": "Chemical", "CODE": null, "ID": "ITM-0004", "LAST_COUNT": "2026-07-21T18:51:08.121000", "LOCATION": null, "MIN_STOCK": 2, "NAME": "TRIPLEX ENERGY PF 25KG", "STOCK": 0, "SUPPLIER": "Henkel Ecolab", "TRACK_BY": "NONE", "UNIT": "unit", "UNIT_PRICE": 0}$j$::jsonb),
  ('ITEMS','ITM-0005',$j${"ACTIVE": true, "CATEGORY": "Chemical", "CODE": null, "ID": "ITM-0005", "LAST_COUNT": "2026-09-28T12:25:21.542000", "LOCATION": null, "MIN_STOCK": 1, "NAME": "MULTICARE BIO POWER *NEW", "STOCK": 4, "SUPPLIER": "Henkel Ecolab", "TRACK_BY": "NONE", "UNIT": "unit", "UNIT_PRICE": 1085.85}$j$::jsonb),
  ('ITEMS','ITM-0006',$j${"ACTIVE": true, "CATEGORY": "Chemical", "CODE": null, "ID": "ITM-0006", "LAST_COUNT": "2026-09-25T16:04:32.522000", "LOCATION": null, "MIN_STOCK": 2, "NAME": "DELICATE DES", "STOCK": 3, "SUPPLIER": "Henkel Ecolab", "TRACK_BY": "NONE", "UNIT": "unit", "UNIT_PRICE": 510.7}$j$::jsonb),
  ('ITEMS','ITM-0007',$j${"ACTIVE": true, "CATEGORY": "Chemical", "CODE": null, "ID": "ITM-0007", "LAST_COUNT": "2026-09-28T12:25:21.542000", "LOCATION": null, "MIN_STOCK": 3, "NAME": "DELICATE DETERGENT", "STOCK": 10, "SUPPLIER": "Henkel Ecolab", "TRACK_BY": "NONE", "UNIT": "unit", "UNIT_PRICE": 565.88}$j$::jsonb),
  ('ITEMS','ITM-0008',$j${"ACTIVE": true, "CATEGORY": "Chemical", "CODE": null, "ID": "ITM-0008", "LAST_COUNT": "2026-09-28T12:25:21.542000", "LOCATION": null, "MIN_STOCK": 1, "NAME": "MULTICARE EMULSION", "STOCK": 5, "SUPPLIER": "Henkel Ecolab", "TRACK_BY": "NONE", "UNIT": "unit", "UNIT_PRICE": 697.88}$j$::jsonb),
  ('ITEMS','ITM-0009',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": null, "ID": "ITM-0009", "LAST_COUNT": "2026-08-28T12:04:49.905000", "LOCATION": null, "MIN_STOCK": 1, "NAME": "Clear Packing Tape", "STOCK": 1, "SUPPLIER": "RECAH", "TRACK_BY": "CUSTOMER", "UNIT": "unit", "UNIT_PRICE": 50.04}$j$::jsonb),
  ('ITEMS','ITM-0010',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": null, "ID": "ITM-0010", "LAST_COUNT": "2026-09-28T12:27:30.965000", "LOCATION": null, "MIN_STOCK": 10, "NAME": "Extra Small Bag", "STOCK": 26, "SUPPLIER": "RECAH", "TRACK_BY": "CUSTOMER", "UNIT": "box", "UNIT_PRICE": 58.75}$j$::jsonb),
  ('ITEMS','ITM-0011',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": null, "ID": "ITM-0011", "LAST_COUNT": "2026-09-28T12:27:30.965000", "LOCATION": null, "MIN_STOCK": 5, "NAME": "Small bags 380x550 (17mu)", "STOCK": 3, "SUPPLIER": "RECAH", "TRACK_BY": "CUSTOMER", "UNIT": "box", "UNIT_PRICE": 20.75}$j$::jsonb),
  ('ITEMS','ITM-0012',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": null, "ID": "ITM-0012", "LAST_COUNT": "2026-09-28T12:27:30.965000", "LOCATION": null, "MIN_STOCK": 5, "NAME": "Medium bags 320x540x830 (16mu)", "STOCK": 19, "SUPPLIER": "RECAH", "TRACK_BY": "CUSTOMER", "UNIT": "box", "UNIT_PRICE": 20.84}$j$::jsonb),
  ('ITEMS','ITM-0013',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": null, "ID": "ITM-0013", "LAST_COUNT": "2026-09-28T12:27:30.965000", "LOCATION": null, "MIN_STOCK": 10, "NAME": "Large bags (roll) 380x660x1120 (30mu)", "STOCK": 0, "SUPPLIER": "RECAH", "TRACK_BY": "CUSTOMER", "UNIT": "roll", "UNIT_PRICE": 26.8}$j$::jsonb),
  ('ITEMS','ITM-0014',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": null, "ID": "ITM-0014", "LAST_COUNT": "2026-09-28T12:27:30.965000", "LOCATION": null, "MIN_STOCK": 200, "NAME": "Cable ties - Large", "STOCK": 0, "SUPPLIER": "Kedington", "TRACK_BY": "CUSTOMER", "UNIT": "unit", "UNIT_PRICE": 1.95}$j$::jsonb),
  ('ITEMS','ITM-0015',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": null, "ID": "ITM-0015", "LAST_COUNT": "2026-09-28T12:27:30.965000", "LOCATION": null, "MIN_STOCK": 500, "NAME": "Cable ties - black", "STOCK": 0, "SUPPLIER": "Kedington", "TRACK_BY": "CUSTOMER", "UNIT": "unit", "UNIT_PRICE": 1.39}$j$::jsonb),
  ('ITEMS','ITM-0016',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": null, "ID": "ITM-0016", "LAST_COUNT": "2026-09-28T12:27:30.965000", "LOCATION": null, "MIN_STOCK": 200, "NAME": "Net bags - RED/WHITE", "STOCK": 400, "SUPPLIER": "U.T.C/Cherry Textiles", "TRACK_BY": "CUSTOMER", "UNIT": "unit", "UNIT_PRICE": 3.09}$j$::jsonb),
  ('ITEMS','ITM-0017',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": null, "ID": "ITM-0017", "LAST_COUNT": "2026-09-28T12:27:30.965000", "LOCATION": null, "MIN_STOCK": 300, "NAME": "Net bags", "STOCK": 1400, "SUPPLIER": "U.T.C/Cherry Textiles", "TRACK_BY": "CUSTOMER", "UNIT": "unit", "UNIT_PRICE": 3}$j$::jsonb),
  ('ITEMS','ITM-0018',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": "0075/BUU001", "ID": "ITM-0018", "LAST_COUNT": "2026-09-28T12:27:30.965000", "LOCATION": null, "MIN_STOCK": 20, "NAME": "Disposable Mops", "STOCK": 27, "SUPPLIER": "Concept", "TRACK_BY": "CUSTOMER", "UNIT": "unit", "UNIT_PRICE": 0}$j$::jsonb),
  ('ITEMS','ITM-0019',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": "BTS HIQ70", "ID": "ITM-0019", "LAST_COUNT": "2026-09-28T12:27:30.965000", "LOCATION": null, "MIN_STOCK": 5, "NAME": "BTS HIQ70", "STOCK": 18, "SUPPLIER": "Thermopatch", "TRACK_BY": "CUSTOMER", "UNIT": "unit", "UNIT_PRICE": 133}$j$::jsonb),
  ('ITEMS','ITM-0020',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": "BTS HIQ30", "ID": "ITM-0020", "LAST_COUNT": "2026-09-28T12:27:30.965000", "LOCATION": null, "MIN_STOCK": 2, "NAME": "BTS HIQ30", "STOCK": 16, "SUPPLIER": "Thermopatch", "TRACK_BY": "CUSTOMER", "UNIT": "unit", "UNIT_PRICE": 55}$j$::jsonb),
  ('ITEMS','ITM-0021',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": "MVN1098", "ID": "ITM-0021", "LAST_COUNT": "2026-09-28T12:27:30.965000", "LOCATION": null, "MIN_STOCK": 50, "NAME": "EYELET half size", "STOCK": 2, "SUPPLIER": "Thermopatch", "TRACK_BY": "CUSTOMER", "UNIT": "unit", "UNIT_PRICE": 0}$j$::jsonb),
  ('ITEMS','ITM-0022',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": "MVN468", "ID": "ITM-0022", "LAST_COUNT": "2026-09-28T12:27:30.965000", "LOCATION": null, "MIN_STOCK": 50, "NAME": "EYELET full size", "STOCK": 2, "SUPPLIER": "Thermopatch", "TRACK_BY": "CUSTOMER", "UNIT": "unit", "UNIT_PRICE": 0}$j$::jsonb),
  ('ITEMS','ITM-0023',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": "MVN125", "ID": "ITM-0023", "LAST_COUNT": "2026-08-28T12:04:24.143000", "LOCATION": null, "MIN_STOCK": 50, "NAME": "T-BAR half size", "STOCK": 3, "SUPPLIER": "Thermopatch", "TRACK_BY": "CUSTOMER", "UNIT": "unit", "UNIT_PRICE": 0}$j$::jsonb),
  ('ITEMS','ITM-0024',$j${"ACTIVE": true, "CATEGORY": "Packing", "CODE": "MVN191", "ID": "ITM-0024", "LAST_COUNT": "2026-09-28T12:27:30.965000", "LOCATION": null, "MIN_STOCK": 50, "NAME": "T-BAR full size", "STOCK": 0, "SUPPLIER": "Thermopatch", "TRACK_BY": "CUSTOMER", "UNIT": "unit", "UNIT_PRICE": 0}$j$::jsonb),
  ('ITEMS','ITM-0025',$j${"ACTIVE": true, "CATEGORY": "Uniform", "CODE": null, "ID": "ITM-0025", "LAST_COUNT": null, "LOCATION": null, "MIN_STOCK": 5, "NAME": "Polo Shirt (Uniform)", "STOCK": 0, "SUPPLIER": null, "TRACK_BY": "EMPLOYEE", "UNIT": "unit", "UNIT_PRICE": 0}$j$::jsonb),
  ('ITEMS','ITM-0026',$j${"ACTIVE": true, "CATEGORY": "Uniform", "CODE": null, "ID": "ITM-0026", "LAST_COUNT": null, "LOCATION": null, "MIN_STOCK": 5, "NAME": "Trousers (Uniform)", "STOCK": 0, "SUPPLIER": null, "TRACK_BY": "EMPLOYEE", "UNIT": "unit", "UNIT_PRICE": 0}$j$::jsonb),
  ('ITEMS','ITM-0027',$j${"ACTIVE": true, "CATEGORY": "Uniform", "CODE": null, "ID": "ITM-0027", "LAST_COUNT": null, "LOCATION": null, "MIN_STOCK": 5, "NAME": "Hi-Vis Vest", "STOCK": 0, "SUPPLIER": null, "TRACK_BY": "EMPLOYEE", "UNIT": "unit", "UNIT_PRICE": 0}$j$::jsonb),
  ('ITEMS','ITM-0028',$j${"ACTIVE": true, "CATEGORY": "Safety Shoes", "CODE": null, "ID": "ITM-0028", "LAST_COUNT": null, "LOCATION": null, "MIN_STOCK": 3, "NAME": "Safety Shoes", "STOCK": 0, "SUPPLIER": "Lyreco", "TRACK_BY": "EMPLOYEE", "UNIT": "pair", "UNIT_PRICE": 40.11}$j$::jsonb),
  ('ITEMS','ITM-0029',$j${"ACTIVE": true, "CATEGORY": "Other", "CODE": "N/A", "ID": "ITM-0029", "LAST_COUNT": null, "LOCATION": null, "MIN_STOCK": 300, "NAME": "MOPS", "STOCK": 0, "SUPPLIER": "Linen Direct", "TRACK_BY": "CUSTOMER", "UNIT": "unit", "UNIT_PRICE": 2.14}$j$::jsonb),
  ('ITEMS','ITM-0030',$j${"ACTIVE": true, "CATEGORY": "Other", "CODE": null, "ID": "ITM-0030", "LAST_COUNT": null, "LOCATION": null, "MIN_STOCK": 0, "NAME": "Velcro Mops", "STOCK": 0, "SUPPLIER": "Concept", "TRACK_BY": "CUSTOMER", "UNIT": "unit", "UNIT_PRICE": 0}$j$::jsonb),
  ('ITEMS','ITM-0031',$j${"ACTIVE": true, "CATEGORY": "Other", "CODE": null, "ID": "ITM-0031", "LAST_COUNT": null, "LOCATION": null, "MIN_STOCK": 0, "NAME": "Mop Handles", "STOCK": 0, "SUPPLIER": "Concept Microfibre", "TRACK_BY": "EMPLOYEE", "UNIT": "unit", "UNIT_PRICE": 0}$j$::jsonb),
  ('ITEMS','ITM-0032',$j${"ACTIVE": true, "CATEGORY": "Other", "CODE": null, "ID": "ITM-0032", "LAST_COUNT": null, "LOCATION": null, "MIN_STOCK": 0, "NAME": "Mop Frames", "STOCK": 0, "SUPPLIER": "Concept", "TRACK_BY": "CUSTOMER", "UNIT": "unit", "UNIT_PRICE": 0}$j$::jsonb),
  ('ITEMS','ITM-0033',$j${"ACTIVE": true, "CATEGORY": "Chemical", "CODE": null, "ID": "ITM-0033", "LAST_COUNT": "2026-09-28T12:25:21.542000", "LOCATION": null, "MIN_STOCK": 1, "NAME": "Biocel 30% Caustic WT/VOL", "STOCK": 3, "SUPPLIER": "Biocel", "TRACK_BY": "NONE", "UNIT": "unit", "UNIT_PRICE": 0}$j$::jsonb),
  ('EMPLOYEES','EMP-0001',$j${"ACTIVE": true, "DEPARTMENT": "Supervisor", "ID": "EMP-0001", "NAME": "Adrian Banut", "SOURCE": "USER", "SOURCE_ID": 28}$j$::jsonb),
  ('EMPLOYEES','EMP-0002',$j${"ACTIVE": true, "DEPARTMENT": "Sorting Area", "ID": "EMP-0002", "NAME": "Agostinho", "SOURCE": "USER", "SOURCE_ID": 37}$j$::jsonb),
  ('EMPLOYEES','EMP-0003',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 3", "ID": "EMP-0003", "NAME": "Ana Maria Marc", "SOURCE": "USER", "SOURCE_ID": 25}$j$::jsonb),
  ('EMPLOYEES','EMP-0004',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 2", "ID": "EMP-0004", "NAME": "Anergha Putanpura", "SOURCE": "USER", "SOURCE_ID": 65}$j$::jsonb),
  ('EMPLOYEES','EMP-0005',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 2", "ID": "EMP-0005", "NAME": "Barbara Balentic", "SOURCE": "USER", "SOURCE_ID": 2}$j$::jsonb),
  ('EMPLOYEES','EMP-0006',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 1", "ID": "EMP-0006", "NAME": "Belen Vas", "SOURCE": "USER", "SOURCE_ID": 15}$j$::jsonb),
  ('EMPLOYEES','EMP-0007',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 2", "ID": "EMP-0007", "NAME": "Bendita Fernandes", "SOURCE": "USER", "SOURCE_ID": 23}$j$::jsonb),
  ('EMPLOYEES','EMP-0008',$j${"ACTIVE": true, "DEPARTMENT": "Team Leader - Table 3", "ID": "EMP-0008", "NAME": "Cristina iliescu", "SOURCE": "USER", "SOURCE_ID": 41}$j$::jsonb),
  ('EMPLOYEES','EMP-0009',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 3", "ID": "EMP-0009", "NAME": "Elvira Rebello", "SOURCE": "USER", "SOURCE_ID": 27}$j$::jsonb),
  ('EMPLOYEES','EMP-0010',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 1", "ID": "EMP-0010", "NAME": "Emma Fernandes", "SOURCE": "USER", "SOURCE_ID": 20}$j$::jsonb),
  ('EMPLOYEES','EMP-0011',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 1", "ID": "EMP-0011", "NAME": "Fernanda Rodriguez", "SOURCE": "USER", "SOURCE_ID": 89}$j$::jsonb),
  ('EMPLOYEES','EMP-0012',$j${"ACTIVE": true, "DEPARTMENT": "Team Leader - Table 2", "ID": "EMP-0012", "NAME": "Flavia Josephina", "SOURCE": "USER", "SOURCE_ID": 3}$j$::jsonb),
  ('EMPLOYEES','EMP-0013',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 1", "ID": "EMP-0013", "NAME": "Flavy Colaco", "SOURCE": "USER", "SOURCE_ID": 19}$j$::jsonb),
  ('EMPLOYEES','EMP-0014',$j${"ACTIVE": true, "DEPARTMENT": "Sorting Area", "ID": "EMP-0014", "NAME": "Franky Gomes", "SOURCE": "USER", "SOURCE_ID": 16}$j$::jsonb),
  ('EMPLOYEES','EMP-0015',$j${"ACTIVE": false, "DEPARTMENT": "General Operative - Table 3", "ID": "EMP-0015", "NAME": "IIIia", "SOURCE": "USER", "SOURCE_ID": 43}$j$::jsonb),
  ('EMPLOYEES','EMP-0016',$j${"ACTIVE": true, "DEPARTMENT": "Team Leader - Table 2", "ID": "EMP-0016", "NAME": "Jaqueline Cerretti", "SOURCE": "USER", "SOURCE_ID": 92}$j$::jsonb),
  ('EMPLOYEES','EMP-0017',$j${"ACTIVE": false, "DEPARTMENT": "General Operative - Table 1", "ID": "EMP-0017", "NAME": "Jhenniffer", "SOURCE": "USER", "SOURCE_ID": 97}$j$::jsonb),
  ('EMPLOYEES','EMP-0018',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 1", "ID": "EMP-0018", "NAME": "Jorge Coca", "SOURCE": "USER", "SOURCE_ID": 64}$j$::jsonb),
  ('EMPLOYEES','EMP-0019',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 3", "ID": "EMP-0019", "NAME": "Joyce Soares", "SOURCE": "USER", "SOURCE_ID": 38}$j$::jsonb),
  ('EMPLOYEES','EMP-0020',$j${"ACTIVE": true, "DEPARTMENT": "Sorting Area", "ID": "EMP-0020", "NAME": "Julio Vas", "SOURCE": "USER", "SOURCE_ID": 14}$j$::jsonb),
  ('EMPLOYEES','EMP-0021',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 2", "ID": "EMP-0021", "NAME": "Kevin", "SOURCE": "USER", "SOURCE_ID": 86}$j$::jsonb),
  ('EMPLOYEES','EMP-0022',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 1", "ID": "EMP-0022", "NAME": "Lena Banut", "SOURCE": "USER", "SOURCE_ID": 75}$j$::jsonb),
  ('EMPLOYEES','EMP-0023',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 2", "ID": "EMP-0023", "NAME": "Lodovico", "SOURCE": "USER", "SOURCE_ID": 29}$j$::jsonb),
  ('EMPLOYEES','EMP-0024',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 2", "ID": "EMP-0024", "NAME": "Lubna Altalla", "SOURCE": "USER", "SOURCE_ID": 69}$j$::jsonb),
  ('EMPLOYEES','EMP-0025',$j${"ACTIVE": true, "DEPARTMENT": "Supervisor", "ID": "EMP-0025", "NAME": "Luiz Teodoro Barbosa Silva", "SOURCE": "USER", "SOURCE_ID": 12}$j$::jsonb),
  ('EMPLOYEES','EMP-0026',$j${"ACTIVE": false, "DEPARTMENT": "Cleaner", "ID": "EMP-0026", "NAME": "Manuela Espinel", "SOURCE": "USER", "SOURCE_ID": 31}$j$::jsonb),
  ('EMPLOYEES','EMP-0027',$j${"ACTIVE": false, "DEPARTMENT": "General Operative - Table 1", "ID": "EMP-0027", "NAME": "Mothusiotsile Kgosi", "SOURCE": "USER", "SOURCE_ID": 57}$j$::jsonb),
  ('EMPLOYEES','EMP-0028',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 2", "ID": "EMP-0028", "NAME": "Paola Cortez Galvis", "SOURCE": "USER", "SOURCE_ID": 5}$j$::jsonb),
  ('EMPLOYEES','EMP-0029',$j${"ACTIVE": true, "DEPARTMENT": "Sorting Area", "ID": "EMP-0029", "NAME": "Patrick Fernandes", "SOURCE": "USER", "SOURCE_ID": 30}$j$::jsonb),
  ('EMPLOYEES','EMP-0030',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 1", "ID": "EMP-0030", "NAME": "Rahma Mohamed", "SOURCE": "USER", "SOURCE_ID": 22}$j$::jsonb),
  ('EMPLOYEES','EMP-0031',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 3", "ID": "EMP-0031", "NAME": "Richard Fernandes", "SOURCE": "USER", "SOURCE_ID": 73}$j$::jsonb),
  ('EMPLOYEES','EMP-0032',$j${"ACTIVE": false, "DEPARTMENT": "Sorting Area", "ID": "EMP-0032", "NAME": "Robert Fernandes", "SOURCE": "USER", "SOURCE_ID": 68}$j$::jsonb),
  ('EMPLOYEES','EMP-0033',$j${"ACTIVE": true, "DEPARTMENT": "Sorting Area", "ID": "EMP-0033", "NAME": "Ronaldo da Silva", "SOURCE": "USER", "SOURCE_ID": 35}$j$::jsonb),
  ('EMPLOYEES','EMP-0034',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 3", "ID": "EMP-0034", "NAME": "Savio Carmo", "SOURCE": "USER", "SOURCE_ID": 42}$j$::jsonb),
  ('EMPLOYEES','EMP-0035',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 3", "ID": "EMP-0035", "NAME": "Taina Furlaneto", "SOURCE": "USER", "SOURCE_ID": 46}$j$::jsonb),
  ('EMPLOYEES','EMP-0036',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 1", "ID": "EMP-0036", "NAME": "Tatiana Furlaneto", "SOURCE": "USER", "SOURCE_ID": 47}$j$::jsonb),
  ('EMPLOYEES','EMP-0037',$j${"ACTIVE": false, "DEPARTMENT": "Team Leader - Table 1", "ID": "EMP-0037", "NAME": "Vasyl", "SOURCE": "USER", "SOURCE_ID": 44}$j$::jsonb),
  ('EMPLOYEES','EMP-0038',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 2", "ID": "EMP-0038", "NAME": "Vesley Julio M. Fernandes", "SOURCE": "USER", "SOURCE_ID": 26}$j$::jsonb),
  ('EMPLOYEES','EMP-0039',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 3", "ID": "EMP-0039", "NAME": "Vifon Fernandes", "SOURCE": "USER", "SOURCE_ID": 81}$j$::jsonb),
  ('EMPLOYEES','EMP-0040',$j${"ACTIVE": true, "DEPARTMENT": "Label", "ID": "EMP-0040", "NAME": "Viorica Closca", "SOURCE": "USER", "SOURCE_ID": 9}$j$::jsonb),
  ('EMPLOYEES','EMP-0041',$j${"ACTIVE": false, "DEPARTMENT": "General Operative - Table 3", "ID": "EMP-0041", "NAME": "Vishal", "SOURCE": "USER", "SOURCE_ID": 66}$j$::jsonb),
  ('EMPLOYEES','EMP-0042',$j${"ACTIVE": false, "DEPARTMENT": "Sorting Area", "ID": "EMP-0042", "NAME": "Yogesh", "SOURCE": "USER", "SOURCE_ID": 67}$j$::jsonb),
  ('EMPLOYEES','EMP-0043',$j${"ACTIVE": false, "DEPARTMENT": "General Operative - Table 2", "ID": "EMP-0043", "NAME": "Vladimir", "SOURCE": "USER", "SOURCE_ID": 98}$j$::jsonb),
  ('EMPLOYEES','EMP-0044',$j${"ACTIVE": true, "DEPARTMENT": "Driver (C)", "ID": "EMP-0044", "NAME": "Alex", "SOURCE": "DRIVER", "SOURCE_ID": 10}$j$::jsonb),
  ('EMPLOYEES','EMP-0045',$j${"ACTIVE": true, "DEPARTMENT": "Driver (C)", "ID": "EMP-0045", "NAME": "Andre", "SOURCE": "DRIVER", "SOURCE_ID": 3}$j$::jsonb),
  ('EMPLOYEES','EMP-0046',$j${"ACTIVE": true, "DEPARTMENT": "Driver (C)", "ID": "EMP-0046", "NAME": "Cornell", "SOURCE": "DRIVER", "SOURCE_ID": 4}$j$::jsonb),
  ('EMPLOYEES','EMP-0047',$j${"ACTIVE": false, "DEPARTMENT": "Driver (B/C)", "ID": "EMP-0047", "NAME": "Gabriel", "SOURCE": "DRIVER", "SOURCE_ID": 9}$j$::jsonb),
  ('EMPLOYEES','EMP-0048',$j${"ACTIVE": true, "DEPARTMENT": "Driver (C)", "ID": "EMP-0048", "NAME": "Gizelle", "SOURCE": "DRIVER", "SOURCE_ID": 1}$j$::jsonb),
  ('EMPLOYEES','EMP-0049',$j${"ACTIVE": true, "DEPARTMENT": "Driver (B)", "ID": "EMP-0049", "NAME": "Jaqueline", "SOURCE": "DRIVER", "SOURCE_ID": 15}$j$::jsonb),
  ('EMPLOYEES','EMP-0050',$j${"ACTIVE": true, "DEPARTMENT": "Driver (C)", "ID": "EMP-0050", "NAME": "Jeferson", "SOURCE": "DRIVER", "SOURCE_ID": 6}$j$::jsonb),
  ('EMPLOYEES','EMP-0051',$j${"ACTIVE": false, "DEPARTMENT": "Driver (C)", "ID": "EMP-0051", "NAME": "John", "SOURCE": "DRIVER", "SOURCE_ID": 11}$j$::jsonb),
  ('EMPLOYEES','EMP-0052',$j${"ACTIVE": true, "DEPARTMENT": "Driver (C)", "ID": "EMP-0052", "NAME": "Julian", "SOURCE": "DRIVER", "SOURCE_ID": 2}$j$::jsonb),
  ('EMPLOYEES','EMP-0053',$j${"ACTIVE": true, "DEPARTMENT": "Driver (C)", "ID": "EMP-0053", "NAME": "Juliana", "SOURCE": "DRIVER", "SOURCE_ID": 8}$j$::jsonb),
  ('EMPLOYEES','EMP-0054',$j${"ACTIVE": true, "DEPARTMENT": "Driver (C)", "ID": "EMP-0054", "NAME": "Kally", "SOURCE": "DRIVER", "SOURCE_ID": 7}$j$::jsonb),
  ('EMPLOYEES','EMP-0055',$j${"ACTIVE": true, "DEPARTMENT": "Driver (C)", "ID": "EMP-0055", "NAME": "Khalid", "SOURCE": "DRIVER", "SOURCE_ID": 12}$j$::jsonb),
  ('EMPLOYEES','EMP-0056',$j${"ACTIVE": true, "DEPARTMENT": "Driver (C)", "ID": "EMP-0056", "NAME": "Lwa", "SOURCE": "DRIVER", "SOURCE_ID": 5}$j$::jsonb),
  ('EMPLOYEES','EMP-0057',$j${"ACTIVE": false, "DEPARTMENT": "General Operative - Table 2", "ID": "EMP-0057", "NAME": "Sarai", "SOURCE": "USER", "SOURCE_ID": 99}$j$::jsonb),
  ('EMPLOYEES','EMP-0058',$j${"ACTIVE": false, "DEPARTMENT": "General Operative - Table 3", "ID": "EMP-0058", "NAME": "Larissa", "SOURCE": "USER", "SOURCE_ID": 100}$j$::jsonb),
  ('EMPLOYEES','EMP-0059',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 1", "ID": "EMP-0059", "NAME": "Lazia", "SOURCE": "USER", "SOURCE_ID": 101}$j$::jsonb),
  ('EMPLOYEES','EMP-0060',$j${"ACTIVE": false, "DEPARTMENT": "General Operative - Table 2", "ID": "EMP-0060", "NAME": "Marcez", "SOURCE": "USER", "SOURCE_ID": 102}$j$::jsonb),
  ('EMPLOYEES','EMP-0061',$j${"ACTIVE": false, "DEPARTMENT": "General Operative - Table 3", "ID": "EMP-0061", "NAME": "Miriam", "SOURCE": "USER", "SOURCE_ID": 103}$j$::jsonb),
  ('EMPLOYEES','EMP-0062',$j${"ACTIVE": true, "DEPARTMENT": "Driver (B,C,D)", "ID": "EMP-0062", "NAME": "Liban Hassan", "SOURCE": "DRIVER", "SOURCE_ID": 16}$j$::jsonb),
  ('EMPLOYEES','EMP-0063',$j${"ACTIVE": true, "DEPARTMENT": "Sorting Area", "ID": "EMP-0063", "NAME": "Josue", "SOURCE": "USER", "SOURCE_ID": 104}$j$::jsonb),
  ('EMPLOYEES','EMP-0064',$j${"ACTIVE": false, "DEPARTMENT": "General Operative - Table 3", "ID": "EMP-0064", "NAME": "YAMILA", "SOURCE": "USER", "SOURCE_ID": 105}$j$::jsonb),
  ('EMPLOYEES','EMP-0065',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 3", "ID": "EMP-0065", "NAME": "Tarcisio Barboza", "SOURCE": "USER", "SOURCE_ID": 106}$j$::jsonb),
  ('EMPLOYEES','EMP-0066',$j${"ACTIVE": false, "DEPARTMENT": "Cleaner", "ID": "EMP-0066", "NAME": "Moses", "SOURCE": "USER", "SOURCE_ID": 107}$j$::jsonb),
  ('EMPLOYEES','EMP-0067',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 1", "ID": "EMP-0067", "NAME": "Vasile Ciuciu (Bonnie)", "SOURCE": "USER", "SOURCE_ID": 108}$j$::jsonb),
  ('EMPLOYEES','EMP-0068',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 3", "ID": "EMP-0068", "NAME": "Irina", "SOURCE": "USER", "SOURCE_ID": 109}$j$::jsonb),
  ('EMPLOYEES','EMP-0069',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 2", "ID": "EMP-0069", "NAME": "Wasi", "SOURCE": "USER", "SOURCE_ID": 110}$j$::jsonb),
  ('EMPLOYEES','EMP-0070',$j${"ACTIVE": false, "DEPARTMENT": "Sorting Area", "ID": "EMP-0070", "NAME": "Ryotaro", "SOURCE": "USER", "SOURCE_ID": 111}$j$::jsonb),
  ('EMPLOYEES','EMP-0071',$j${"ACTIVE": true, "DEPARTMENT": "Driver (C)", "ID": "EMP-0071", "NAME": "Ionel Cucu", "SOURCE": "DRIVER", "SOURCE_ID": 17}$j$::jsonb),
  ('EMPLOYEES','EMP-0072',$j${"ACTIVE": true, "DEPARTMENT": "Sorting Area", "ID": "EMP-0072", "NAME": "Ryotaro Kawauchi", "SOURCE": "USER", "SOURCE_ID": 112}$j$::jsonb),
  ('EMPLOYEES','EMP-0073',$j${"ACTIVE": true, "DEPARTMENT": "General Operative - Table 1", "ID": "EMP-0073", "NAME": "Alessandra Laura", "SOURCE": "USER", "SOURCE_ID": 113}$j$::jsonb),
  ('MOVEMENTS','row-0002',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "NOTES": "Usage since last count (CNT-20260721-185108)", "PO": null, "QTY": -1, "REGISTERED_BY": "Anca", "STOCK_AFTER": 0, "TIMESTAMP": "2026-07-21T18:51:08.121000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0003',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "NOTES": "Stock count CNT-20260721-185108", "PO": null, "QTY": 5, "REGISTERED_BY": "Anca", "STOCK_AFTER": 5, "TIMESTAMP": "2026-07-21T18:51:08.121000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0004',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0005", "ITEM_NAME": "MULTICARE BIO POWER *NEW", "NOTES": "Stock count CNT-20260721-185108", "PO": null, "QTY": 1, "REGISTERED_BY": "Anca", "STOCK_AFTER": 1, "TIMESTAMP": "2026-07-21T18:51:08.121000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0005',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0006", "ITEM_NAME": "DELICATE DES", "NOTES": "Stock count CNT-20260721-185108", "PO": null, "QTY": 4, "REGISTERED_BY": "Anca", "STOCK_AFTER": 4, "TIMESTAMP": "2026-07-21T18:51:08.121000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0006',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "NOTES": "Stock count CNT-20260721-185108", "PO": null, "QTY": 4, "REGISTERED_BY": "Anca", "STOCK_AFTER": 4, "TIMESTAMP": "2026-07-21T18:51:08.121000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0007',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0009", "ITEM_NAME": "Clear Packing Tape", "NOTES": "Stock count CNT-20260728-140029", "PO": null, "QTY": -1, "REGISTERED_BY": "Tamara", "STOCK_AFTER": 0, "TIMESTAMP": "2026-07-28T14:00:29.500000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0008',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0010", "ITEM_NAME": "Extra Small Bag", "NOTES": "Stock count CNT-20260728-140029", "PO": null, "QTY": 32, "REGISTERED_BY": "Tamara", "STOCK_AFTER": 32, "TIMESTAMP": "2026-07-28T14:00:29.500000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0009',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0012", "ITEM_NAME": "Medium bags 320x540x830 (16mu)", "NOTES": "Stock count CNT-20260728-140029", "PO": null, "QTY": 10, "REGISTERED_BY": "Tamara", "STOCK_AFTER": 10, "TIMESTAMP": "2026-07-28T14:00:29.500000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0010',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0013", "ITEM_NAME": "Large bags (roll) 380x660x1120 (30mu)", "NOTES": "Stock count CNT-20260728-140029", "PO": null, "QTY": 24, "REGISTERED_BY": "Tamara", "STOCK_AFTER": 24, "TIMESTAMP": "2026-07-28T14:00:29.500000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0011',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0015", "ITEM_NAME": "Cable ties - black", "NOTES": "Stock count CNT-20260728-140029", "PO": null, "QTY": 1000, "REGISTERED_BY": "Tamara", "STOCK_AFTER": 1000, "TIMESTAMP": "2026-07-28T14:00:29.500000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0012',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0016", "ITEM_NAME": "Net bags - RED/WHITE", "NOTES": "Stock count CNT-20260728-140029", "PO": null, "QTY": 1100, "REGISTERED_BY": "Tamara", "STOCK_AFTER": 1100, "TIMESTAMP": "2026-07-28T14:00:29.500000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0013',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0017", "ITEM_NAME": "Net bags", "NOTES": "Stock count CNT-20260728-140029", "PO": null, "QTY": 1500, "REGISTERED_BY": "Tamara", "STOCK_AFTER": 1500, "TIMESTAMP": "2026-07-28T14:00:29.500000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0014',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0018", "ITEM_NAME": "Disposable Mops", "NOTES": "Stock count CNT-20260728-140029", "PO": null, "QTY": 23, "REGISTERED_BY": "Tamara", "STOCK_AFTER": 23, "TIMESTAMP": "2026-07-28T14:00:29.500000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0015',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0019", "ITEM_NAME": "BTS HIQ70", "NOTES": "Stock count CNT-20260728-140029", "PO": null, "QTY": 22, "REGISTERED_BY": "Tamara", "STOCK_AFTER": 22, "TIMESTAMP": "2026-07-28T14:00:29.500000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0016',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0020", "ITEM_NAME": "BTS HIQ30", "NOTES": "Stock count CNT-20260728-140029", "PO": null, "QTY": 31, "REGISTERED_BY": "Tamara", "STOCK_AFTER": 31, "TIMESTAMP": "2026-07-28T14:00:29.500000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0017',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0021", "ITEM_NAME": "EYELET half size", "NOTES": "Stock count CNT-20260728-140029", "PO": null, "QTY": 7, "REGISTERED_BY": "Tamara", "STOCK_AFTER": 7, "TIMESTAMP": "2026-07-28T14:00:29.500000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0018',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0022", "ITEM_NAME": "EYELET full size", "NOTES": "Stock count CNT-20260728-140029", "PO": null, "QTY": 12, "REGISTERED_BY": "Tamara", "STOCK_AFTER": 12, "TIMESTAMP": "2026-07-28T14:00:29.500000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0019',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0023", "ITEM_NAME": "T-BAR half size", "NOTES": "Stock count CNT-20260728-140029", "PO": null, "QTY": 4, "REGISTERED_BY": "Tamara", "STOCK_AFTER": 4, "TIMESTAMP": "2026-07-28T14:00:29.500000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0020',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0024", "ITEM_NAME": "T-BAR full size", "NOTES": "Stock count CNT-20260728-140029", "PO": null, "QTY": 4, "REGISTERED_BY": "Tamara", "STOCK_AFTER": 4, "TIMESTAMP": "2026-07-28T14:00:29.500000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0021',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "NOTES": "Usage since last count (CNT-20260728-140319)", "PO": null, "QTY": -1, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 3, "TIMESTAMP": "2026-07-28T14:03:19.043000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0022',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0008", "ITEM_NAME": "MULTICARE EMULSION", "NOTES": "Stock count CNT-20260728-140319", "PO": null, "QTY": 5, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 5, "TIMESTAMP": "2026-07-28T14:03:19.043000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0023',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "NOTES": null, "PO": null, "QTY": 4, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 4, "TIMESTAMP": "2026-07-30T14:11:30.766000", "TYPE": "IN"}$j$::jsonb),
  ('MOVEMENTS','row-0024',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0005", "ITEM_NAME": "MULTICARE BIO POWER *NEW", "NOTES": null, "PO": null, "QTY": 2, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 3, "TIMESTAMP": "2026-07-30T14:11:54.104000", "TYPE": "IN"}$j$::jsonb),
  ('MOVEMENTS','row-0025',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0006", "ITEM_NAME": "DELICATE DES", "NOTES": null, "PO": null, "QTY": 6, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 10, "TIMESTAMP": "2026-07-30T14:12:09.035000", "TYPE": "IN"}$j$::jsonb),
  ('MOVEMENTS','row-0026',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "NOTES": null, "PO": null, "QTY": 7, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 10, "TIMESTAMP": "2026-07-30T14:12:32.255000", "TYPE": "IN"}$j$::jsonb),
  ('MOVEMENTS','row-0027',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "NOTES": null, "PO": null, "QTY": 10, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 15, "TIMESTAMP": "2026-07-30T14:13:27.184000", "TYPE": "IN"}$j$::jsonb),
  ('MOVEMENTS','row-0028',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0003", "ITEM_NAME": "P3-POLIX CHLORANT 24kg", "NOTES": null, "PO": null, "QTY": 10, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 10, "TIMESTAMP": "2026-07-30T14:13:46.761000", "TYPE": "IN"}$j$::jsonb),
  ('MOVEMENTS','row-0029',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "NOTES": "Usage since last count (CNT-20260730-150624)", "PO": null, "QTY": -1, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 3, "TIMESTAMP": "2026-07-30T15:06:24.834000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0030',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "NOTES": "Usage since last count (CNT-20260730-150624)", "PO": null, "QTY": -4, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 11, "TIMESTAMP": "2026-07-30T15:06:24.834000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0031',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0003", "ITEM_NAME": "P3-POLIX CHLORANT 24kg", "NOTES": "Usage since last count (CNT-20260730-150624)", "PO": null, "QTY": -1, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 9, "TIMESTAMP": "2026-07-30T15:06:24.834000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0032',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0006", "ITEM_NAME": "DELICATE DES", "NOTES": "Usage since last count (CNT-20260730-150624)", "PO": null, "QTY": -2, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 8, "TIMESTAMP": "2026-07-30T15:06:24.834000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0033',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "NOTES": "Usage since last count (CNT-20260730-150624)", "PO": null, "QTY": -3, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 7, "TIMESTAMP": "2026-07-30T15:06:24.834000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0034',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0006", "ITEM_NAME": "DELICATE DES", "NOTES": null, "PO": null, "QTY": -2, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 6, "TIMESTAMP": "2026-08-12T18:06:53.406000", "TYPE": "ADJUST"}$j$::jsonb),
  ('MOVEMENTS','row-0035',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "NOTES": null, "PO": null, "QTY": -4, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 3, "TIMESTAMP": "2026-08-12T18:07:08.787000", "TYPE": "ADJUST"}$j$::jsonb),
  ('MOVEMENTS','row-0036',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0005", "ITEM_NAME": "MULTICARE BIO POWER *NEW", "NOTES": null, "PO": null, "QTY": -1, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 2, "TIMESTAMP": "2026-08-12T18:07:24.876000", "TYPE": "OUT"}$j$::jsonb),
  ('MOVEMENTS','row-0037',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "NOTES": null, "PO": null, "QTY": -1, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 2, "TIMESTAMP": "2026-08-12T18:07:37.965000", "TYPE": "OUT"}$j$::jsonb),
  ('MOVEMENTS','row-0038',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "NOTES": null, "PO": null, "QTY": 1, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 3, "TIMESTAMP": "2026-08-12T18:08:45.130000", "TYPE": "ADJUST"}$j$::jsonb),
  ('MOVEMENTS','row-0039',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "NOTES": null, "PO": null, "QTY": -5, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 6, "TIMESTAMP": "2026-08-12T18:11:05.376000", "TYPE": "ADJUST"}$j$::jsonb),
  ('MOVEMENTS','row-0040',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "NOTES": "Usage since last count (CNT-20260821-190949)", "PO": null, "QTY": -1, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 2, "TIMESTAMP": "2026-08-21T19:09:49.388000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0041',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "NOTES": "Usage since last count (CNT-20260821-190949)", "PO": null, "QTY": -5, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 1, "TIMESTAMP": "2026-08-21T19:09:49.388000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0042',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0006", "ITEM_NAME": "DELICATE DES", "NOTES": "Usage since last count (CNT-20260821-190949)", "PO": null, "QTY": -1, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 5, "TIMESTAMP": "2026-08-21T19:09:49.388000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0043',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "NOTES": "Usage since last count (CNT-20260821-190949)", "PO": null, "QTY": -3, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 0, "TIMESTAMP": "2026-08-21T19:09:49.388000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0044',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0033", "ITEM_NAME": "Biocel 30% Caustic WT/VOL", "NOTES": "Initial stock", "PO": null, "QTY": 1, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 1, "TIMESTAMP": "2026-08-21T19:13:17.759000", "TYPE": "IN"}$j$::jsonb),
  ('MOVEMENTS','row-0045',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0033", "ITEM_NAME": "Biocel 30% Caustic WT/VOL", "NOTES": "Usage since last count (CNT-20260821-191432)", "PO": null, "QTY": -1, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 0, "TIMESTAMP": "2026-08-21T19:14:32.669000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0046',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0010", "ITEM_NAME": "Extra Small Bag", "NOTES": "Stock count CNT-20260828-120424", "PO": null, "QTY": -5, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 27, "TIMESTAMP": "2026-08-28T12:04:24.143000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0047',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0011", "ITEM_NAME": "Small bags 380x550 (17mu)", "NOTES": "Stock count CNT-20260828-120424", "PO": null, "QTY": 9, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 9, "TIMESTAMP": "2026-08-28T12:04:24.143000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0048',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0012", "ITEM_NAME": "Medium bags 320x540x830 (16mu)", "NOTES": "Stock count CNT-20260828-120424", "PO": null, "QTY": 14, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 24, "TIMESTAMP": "2026-08-28T12:04:24.143000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0049',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0013", "ITEM_NAME": "Large bags (roll) 380x660x1120 (30mu)", "NOTES": "Stock count CNT-20260828-120424", "PO": null, "QTY": -16, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 8, "TIMESTAMP": "2026-08-28T12:04:24.143000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0050',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0015", "ITEM_NAME": "Cable ties - black", "NOTES": "Stock count CNT-20260828-120424", "PO": null, "QTY": -200, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 800, "TIMESTAMP": "2026-08-28T12:04:24.143000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0051',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0016", "ITEM_NAME": "Net bags - RED/WHITE", "NOTES": "Stock count CNT-20260828-120424", "PO": null, "QTY": -100, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 1000, "TIMESTAMP": "2026-08-28T12:04:24.143000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0052',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0017", "ITEM_NAME": "Net bags", "NOTES": "Stock count CNT-20260828-120424", "PO": null, "QTY": -1400, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 100, "TIMESTAMP": "2026-08-28T12:04:24.143000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0053',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0018", "ITEM_NAME": "Disposable Mops", "NOTES": "Stock count CNT-20260828-120424", "PO": null, "QTY": -12, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 11, "TIMESTAMP": "2026-08-28T12:04:24.143000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0054',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0019", "ITEM_NAME": "BTS HIQ70", "NOTES": "Stock count CNT-20260828-120424", "PO": null, "QTY": -2, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 20, "TIMESTAMP": "2026-08-28T12:04:24.143000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0055',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0020", "ITEM_NAME": "BTS HIQ30", "NOTES": "Stock count CNT-20260828-120424", "PO": null, "QTY": -8, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 23, "TIMESTAMP": "2026-08-28T12:04:24.143000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0056',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0021", "ITEM_NAME": "EYELET half size", "NOTES": "Stock count CNT-20260828-120424", "PO": null, "QTY": -2, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 5, "TIMESTAMP": "2026-08-28T12:04:24.143000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0057',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0022", "ITEM_NAME": "EYELET full size", "NOTES": "Stock count CNT-20260828-120424", "PO": null, "QTY": -5, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 7, "TIMESTAMP": "2026-08-28T12:04:24.143000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0058',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0023", "ITEM_NAME": "T-BAR half size", "NOTES": "Stock count CNT-20260828-120424", "PO": null, "QTY": -1, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 3, "TIMESTAMP": "2026-08-28T12:04:24.143000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0059',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0024", "ITEM_NAME": "T-BAR full size", "NOTES": "Stock count CNT-20260828-120424", "PO": null, "QTY": -3, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 1, "TIMESTAMP": "2026-08-28T12:04:24.143000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0060',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0009", "ITEM_NAME": "Clear Packing Tape", "NOTES": "Stock count CNT-20260828-120449", "PO": null, "QTY": 1, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 1, "TIMESTAMP": "2026-08-28T12:04:49.905000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0061',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0013", "ITEM_NAME": "Large bags (roll) 380x660x1120 (30mu)", "NOTES": "Stock count CNT-20260828-120539", "PO": null, "QTY": 3, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 11, "TIMESTAMP": "2026-08-28T12:05:39.121000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0062',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "NOTES": null, "PO": null, "QTY": -1, "REGISTERED_BY": "Paulo (eliscaretex@gmail.com)", "STOCK_AFTER": 0, "TIMESTAMP": "2026-08-28T20:23:48.378000", "TYPE": "OUT"}$j$::jsonb),
  ('MOVEMENTS','row-0063',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "NOTES": "Usage since last count (CNT-20260915-155031)", "PO": null, "QTY": -1, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 1, "TIMESTAMP": "2026-09-15T15:50:31.256000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0064',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "NOTES": "Stock count CNT-20260915-155031", "PO": null, "QTY": 8, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 8, "TIMESTAMP": "2026-09-15T15:50:31.256000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0065',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0005", "ITEM_NAME": "MULTICARE BIO POWER *NEW", "NOTES": "Usage since last count (CNT-20260915-155031)", "PO": null, "QTY": -1, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 1, "TIMESTAMP": "2026-09-15T15:50:31.256000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0066',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0006", "ITEM_NAME": "DELICATE DES", "NOTES": "Usage since last count (CNT-20260915-155031)", "PO": null, "QTY": -3, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 2, "TIMESTAMP": "2026-09-15T15:50:31.256000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0067',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "NOTES": "Stock count CNT-20260915-155031", "PO": null, "QTY": 2, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 2, "TIMESTAMP": "2026-09-15T15:50:31.256000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0068',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0033", "ITEM_NAME": "Biocel 30% Caustic WT/VOL", "NOTES": "Stock count CNT-20260915-155031", "PO": null, "QTY": 3, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 3, "TIMESTAMP": "2026-09-15T15:50:31.256000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0069',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0006", "ITEM_NAME": "DELICATE DES", "NOTES": null, "PO": null, "QTY": 2, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 4, "TIMESTAMP": "2026-09-15T15:55:19.770000", "TYPE": "ADJUST"}$j$::jsonb),
  ('MOVEMENTS','row-0070',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0005", "ITEM_NAME": "MULTICARE BIO POWER *NEW", "NOTES": null, "PO": null, "QTY": 2, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 3, "TIMESTAMP": "2026-09-15T15:55:34.667000", "TYPE": "ADJUST"}$j$::jsonb),
  ('MOVEMENTS','row-0071',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "NOTES": null, "PO": null, "QTY": 4, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 5, "TIMESTAMP": "2026-09-16T22:43:09.111000", "TYPE": "IN"}$j$::jsonb),
  ('MOVEMENTS','row-0072',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "NOTES": "Usage since last count (CNT-20260918-102336)", "PO": null, "QTY": -1, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 4, "TIMESTAMP": "2026-09-18T10:23:36.434000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0073',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "NOTES": "Stock count CNT-20260918-102336", "PO": null, "QTY": 11, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 19, "TIMESTAMP": "2026-09-18T10:23:36.434000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0074',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0003", "ITEM_NAME": "P3-POLIX CHLORANT 24kg", "NOTES": "Usage since last count (CNT-20260918-102336)", "PO": null, "QTY": -1, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 8, "TIMESTAMP": "2026-09-18T10:23:36.434000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0075',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0005", "ITEM_NAME": "MULTICARE BIO POWER *NEW", "NOTES": "Stock count CNT-20260918-102336", "PO": null, "QTY": 1, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 4, "TIMESTAMP": "2026-09-18T10:23:36.434000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0076',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "NOTES": "Usage since last count (CNT-20260918-102336)", "PO": null, "QTY": -1, "REGISTERED_BY": "Tamara Bastos", "STOCK_AFTER": 1, "TIMESTAMP": "2026-09-18T10:23:36.434000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0077',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "NOTES": "Usage since last count (CNT-20260925-160432)", "PO": null, "QTY": -3, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 16, "TIMESTAMP": "2026-09-25T16:04:32.522000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0078',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0005", "ITEM_NAME": "MULTICARE BIO POWER *NEW", "NOTES": "Usage since last count (CNT-20260925-160432)", "PO": null, "QTY": -1, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 3, "TIMESTAMP": "2026-09-25T16:04:32.522000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0079',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0006", "ITEM_NAME": "DELICATE DES", "NOTES": "Usage since last count (CNT-20260925-160432)", "PO": null, "QTY": -1, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 3, "TIMESTAMP": "2026-09-25T16:04:32.522000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0080',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "NOTES": "Stock count CNT-20260925-160432", "PO": null, "QTY": 10, "REGISTERED_BY": "Paulo", "STOCK_AFTER": 11, "TIMESTAMP": "2026-09-25T16:04:32.522000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0081',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "NOTES": "Stock count CNT-20260928-122521", "PO": null, "QTY": 1, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 5, "TIMESTAMP": "2026-09-28T12:25:21.542000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0082',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "NOTES": "Usage since last count (CNT-20260928-122521)", "PO": null, "QTY": -1, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 15, "TIMESTAMP": "2026-09-28T12:25:21.542000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0083',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0005", "ITEM_NAME": "MULTICARE BIO POWER *NEW", "NOTES": "Stock count CNT-20260928-122521", "PO": null, "QTY": 1, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 4, "TIMESTAMP": "2026-09-28T12:25:21.542000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0084',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "NOTES": "Usage since last count (CNT-20260928-122521)", "PO": null, "QTY": -1, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 10, "TIMESTAMP": "2026-09-28T12:25:21.542000", "TYPE": "CONSUMPTION"}$j$::jsonb),
  ('MOVEMENTS','row-0085',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0010", "ITEM_NAME": "Extra Small Bag", "NOTES": "Stock count CNT-20260928-122730", "PO": null, "QTY": -1, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 26, "TIMESTAMP": "2026-09-28T12:27:30.965000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0086',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0011", "ITEM_NAME": "Small bags 380x550 (17mu)", "NOTES": "Stock count CNT-20260928-122730", "PO": null, "QTY": -6, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 3, "TIMESTAMP": "2026-09-28T12:27:30.965000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0087',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0012", "ITEM_NAME": "Medium bags 320x540x830 (16mu)", "NOTES": "Stock count CNT-20260928-122730", "PO": null, "QTY": -5, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 19, "TIMESTAMP": "2026-09-28T12:27:30.965000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0088',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0013", "ITEM_NAME": "Large bags (roll) 380x660x1120 (30mu)", "NOTES": "Stock count CNT-20260928-122730", "PO": null, "QTY": -11, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 0, "TIMESTAMP": "2026-09-28T12:27:30.965000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0089',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0015", "ITEM_NAME": "Cable ties - black", "NOTES": "Stock count CNT-20260928-122730", "PO": null, "QTY": -800, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 0, "TIMESTAMP": "2026-09-28T12:27:30.965000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0090',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0016", "ITEM_NAME": "Net bags - RED/WHITE", "NOTES": "Stock count CNT-20260928-122730", "PO": null, "QTY": -600, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 400, "TIMESTAMP": "2026-09-28T12:27:30.965000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0091',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0017", "ITEM_NAME": "Net bags", "NOTES": "Stock count CNT-20260928-122730", "PO": null, "QTY": 1300, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 1400, "TIMESTAMP": "2026-09-28T12:27:30.965000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0092',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0018", "ITEM_NAME": "Disposable Mops", "NOTES": "Stock count CNT-20260928-122730", "PO": null, "QTY": 16, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 27, "TIMESTAMP": "2026-09-28T12:27:30.965000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0093',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0019", "ITEM_NAME": "BTS HIQ70", "NOTES": "Stock count CNT-20260928-122730", "PO": null, "QTY": -2, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 18, "TIMESTAMP": "2026-09-28T12:27:30.965000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0094',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0020", "ITEM_NAME": "BTS HIQ30", "NOTES": "Stock count CNT-20260928-122730", "PO": null, "QTY": -7, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 16, "TIMESTAMP": "2026-09-28T12:27:30.965000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0095',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0021", "ITEM_NAME": "EYELET half size", "NOTES": "Stock count CNT-20260928-122730", "PO": null, "QTY": -3, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 2, "TIMESTAMP": "2026-09-28T12:27:30.965000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0096',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0022", "ITEM_NAME": "EYELET full size", "NOTES": "Stock count CNT-20260928-122730", "PO": null, "QTY": -5, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 2, "TIMESTAMP": "2026-09-28T12:27:30.965000", "TYPE": "COUNT"}$j$::jsonb),
  ('MOVEMENTS','row-0097',$j${"CUSTOMER": null, "EMPLOYEE": null, "ITEM_ID": "ITM-0024", "ITEM_NAME": "T-BAR full size", "NOTES": "Stock count CNT-20260928-122730", "PO": null, "QTY": -1, "REGISTERED_BY": "Luiz", "STOCK_AFTER": 0, "TIMESTAMP": "2026-09-28T12:27:30.965000", "TYPE": "COUNT"}$j$::jsonb),
  ('COUNTS','row-0002',$j${"COUNTED": 0, "EXPECTED": 1, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "REGISTERED_BY": "Unknown", "SESSION_ID": "CNT-20260721-185108", "TIMESTAMP": "2026-07-21T18:51:08.121000", "VARIANCE": -1, "VARIANCE_VALUE": -156.79}$j$::jsonb),
  ('COUNTS','row-0003',$j${"COUNTED": 5, "EXPECTED": 0, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "REGISTERED_BY": "Unknown", "SESSION_ID": "CNT-20260721-185108", "TIMESTAMP": "2026-07-21T18:51:08.121000", "VARIANCE": 5, "VARIANCE_VALUE": 594.5}$j$::jsonb),
  ('COUNTS','row-0004',$j${"COUNTED": 0, "EXPECTED": 0, "ITEM_ID": "ITM-0003", "ITEM_NAME": "P3-POLIX CHLORANT 24kg", "REGISTERED_BY": "Unknown", "SESSION_ID": "CNT-20260721-185108", "TIMESTAMP": "2026-07-21T18:51:08.121000", "VARIANCE": 0, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0005',$j${"COUNTED": 0, "EXPECTED": 0, "ITEM_ID": "ITM-0004", "ITEM_NAME": "TRIPLEX ENERGY PF 25KG", "REGISTERED_BY": "Unknown", "SESSION_ID": "CNT-20260721-185108", "TIMESTAMP": "2026-07-21T18:51:08.121000", "VARIANCE": 0, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0006',$j${"COUNTED": 1, "EXPECTED": 0, "ITEM_ID": "ITM-0005", "ITEM_NAME": "MULTICARE BIO POWER *NEW", "REGISTERED_BY": "Unknown", "SESSION_ID": "CNT-20260721-185108", "TIMESTAMP": "2026-07-21T18:51:08.121000", "VARIANCE": 1, "VARIANCE_VALUE": 1085.85}$j$::jsonb),
  ('COUNTS','row-0007',$j${"COUNTED": 4, "EXPECTED": 0, "ITEM_ID": "ITM-0006", "ITEM_NAME": "DELICATE DES", "REGISTERED_BY": "Unknown", "SESSION_ID": "CNT-20260721-185108", "TIMESTAMP": "2026-07-21T18:51:08.121000", "VARIANCE": 4, "VARIANCE_VALUE": 2042.8}$j$::jsonb),
  ('COUNTS','row-0008',$j${"COUNTED": 4, "EXPECTED": 0, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "REGISTERED_BY": "Unknown", "SESSION_ID": "CNT-20260721-185108", "TIMESTAMP": "2026-07-21T18:51:08.121000", "VARIANCE": 4, "VARIANCE_VALUE": 2263.52}$j$::jsonb),
  ('COUNTS','row-0009',$j${"COUNTED": 0, "EXPECTED": 0, "ITEM_ID": "ITM-0008", "ITEM_NAME": "MULTICARE EMULSION", "REGISTERED_BY": "Unknown", "SESSION_ID": "CNT-20260721-185108", "TIMESTAMP": "2026-07-21T18:51:08.121000", "VARIANCE": 0, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0010',$j${"COUNTED": 0, "EXPECTED": 1, "ITEM_ID": "ITM-0009", "ITEM_NAME": "Clear Packing Tape", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": -1, "VARIANCE_VALUE": -50.04}$j$::jsonb),
  ('COUNTS','row-0011',$j${"COUNTED": 32, "EXPECTED": 0, "ITEM_ID": "ITM-0010", "ITEM_NAME": "Extra Small Bag", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": 32, "VARIANCE_VALUE": 1880}$j$::jsonb),
  ('COUNTS','row-0012',$j${"COUNTED": 0, "EXPECTED": 0, "ITEM_ID": "ITM-0011", "ITEM_NAME": "Small bags 380x550 (17mu)", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": 0, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0013',$j${"COUNTED": 10, "EXPECTED": 0, "ITEM_ID": "ITM-0012", "ITEM_NAME": "Medium bags 320x540x830 (16mu)", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": 10, "VARIANCE_VALUE": 208.4}$j$::jsonb),
  ('COUNTS','row-0014',$j${"COUNTED": 24, "EXPECTED": 0, "ITEM_ID": "ITM-0013", "ITEM_NAME": "Large bags (roll) 380x660x1120 (30mu)", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": 24, "VARIANCE_VALUE": 643.2}$j$::jsonb),
  ('COUNTS','row-0015',$j${"COUNTED": 0, "EXPECTED": 0, "ITEM_ID": "ITM-0014", "ITEM_NAME": "Cable ties - Large", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": 0, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0016',$j${"COUNTED": 1000, "EXPECTED": 0, "ITEM_ID": "ITM-0015", "ITEM_NAME": "Cable ties - black", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": 1000, "VARIANCE_VALUE": 1390}$j$::jsonb),
  ('COUNTS','row-0017',$j${"COUNTED": 1100, "EXPECTED": 0, "ITEM_ID": "ITM-0016", "ITEM_NAME": "Net bags - RED/WHITE", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": 1100, "VARIANCE_VALUE": 3399}$j$::jsonb),
  ('COUNTS','row-0018',$j${"COUNTED": 1500, "EXPECTED": 0, "ITEM_ID": "ITM-0017", "ITEM_NAME": "Net bags", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": 1500, "VARIANCE_VALUE": 4500}$j$::jsonb),
  ('COUNTS','row-0019',$j${"COUNTED": 23, "EXPECTED": 0, "ITEM_ID": "ITM-0018", "ITEM_NAME": "Disposable Mops", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": 23, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0020',$j${"COUNTED": 22, "EXPECTED": 0, "ITEM_ID": "ITM-0019", "ITEM_NAME": "BTS HIQ70", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": 22, "VARIANCE_VALUE": 2926}$j$::jsonb),
  ('COUNTS','row-0021',$j${"COUNTED": 31, "EXPECTED": 0, "ITEM_ID": "ITM-0020", "ITEM_NAME": "BTS HIQ30", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": 31, "VARIANCE_VALUE": 1705}$j$::jsonb),
  ('COUNTS','row-0022',$j${"COUNTED": 7, "EXPECTED": 0, "ITEM_ID": "ITM-0021", "ITEM_NAME": "EYELET half size", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": 7, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0023',$j${"COUNTED": 12, "EXPECTED": 0, "ITEM_ID": "ITM-0022", "ITEM_NAME": "EYELET full size", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": 12, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0024',$j${"COUNTED": 4, "EXPECTED": 0, "ITEM_ID": "ITM-0023", "ITEM_NAME": "T-BAR half size", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": 4, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0025',$j${"COUNTED": 4, "EXPECTED": 0, "ITEM_ID": "ITM-0024", "ITEM_NAME": "T-BAR full size", "REGISTERED_BY": "Tamara", "SESSION_ID": "CNT-20260728-140029", "TIMESTAMP": "2026-07-28T14:00:29.500000", "VARIANCE": 4, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0026',$j${"COUNTED": 3, "EXPECTED": 4, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260728-140319", "TIMESTAMP": "2026-07-28T14:03:19.043000", "VARIANCE": -1, "VARIANCE_VALUE": -565.88}$j$::jsonb),
  ('COUNTS','row-0027',$j${"COUNTED": 5, "EXPECTED": 0, "ITEM_ID": "ITM-0008", "ITEM_NAME": "MULTICARE EMULSION", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260728-140319", "TIMESTAMP": "2026-07-28T14:03:19.043000", "VARIANCE": 5, "VARIANCE_VALUE": 3489.4}$j$::jsonb),
  ('COUNTS','row-0028',$j${"COUNTED": 3, "EXPECTED": 4, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260730-150624", "TIMESTAMP": "2026-07-30T15:06:24.834000", "VARIANCE": -1, "VARIANCE_VALUE": -156.79}$j$::jsonb),
  ('COUNTS','row-0029',$j${"COUNTED": 11, "EXPECTED": 15, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260730-150624", "TIMESTAMP": "2026-07-30T15:06:24.834000", "VARIANCE": -4, "VARIANCE_VALUE": -475.6}$j$::jsonb),
  ('COUNTS','row-0030',$j${"COUNTED": 9, "EXPECTED": 10, "ITEM_ID": "ITM-0003", "ITEM_NAME": "P3-POLIX CHLORANT 24kg", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260730-150624", "TIMESTAMP": "2026-07-30T15:06:24.834000", "VARIANCE": -1, "VARIANCE_VALUE": -30.48}$j$::jsonb),
  ('COUNTS','row-0031',$j${"COUNTED": 3, "EXPECTED": 3, "ITEM_ID": "ITM-0005", "ITEM_NAME": "MULTICARE BIO POWER *NEW", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260730-150624", "TIMESTAMP": "2026-07-30T15:06:24.834000", "VARIANCE": 0, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0032',$j${"COUNTED": 8, "EXPECTED": 10, "ITEM_ID": "ITM-0006", "ITEM_NAME": "DELICATE DES", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260730-150624", "TIMESTAMP": "2026-07-30T15:06:24.834000", "VARIANCE": -2, "VARIANCE_VALUE": -1021.4}$j$::jsonb),
  ('COUNTS','row-0033',$j${"COUNTED": 7, "EXPECTED": 10, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260730-150624", "TIMESTAMP": "2026-07-30T15:06:24.834000", "VARIANCE": -3, "VARIANCE_VALUE": -1697.6399999999999}$j$::jsonb),
  ('COUNTS','row-0034',$j${"COUNTED": 2, "EXPECTED": 3, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260821-190949", "TIMESTAMP": "2026-08-21T19:09:49.388000", "VARIANCE": -1, "VARIANCE_VALUE": -156.79}$j$::jsonb),
  ('COUNTS','row-0035',$j${"COUNTED": 1, "EXPECTED": 6, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260821-190949", "TIMESTAMP": "2026-08-21T19:09:49.388000", "VARIANCE": -5, "VARIANCE_VALUE": -594.5}$j$::jsonb),
  ('COUNTS','row-0036',$j${"COUNTED": 9, "EXPECTED": 9, "ITEM_ID": "ITM-0003", "ITEM_NAME": "P3-POLIX CHLORANT 24kg", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260821-190949", "TIMESTAMP": "2026-08-21T19:09:49.388000", "VARIANCE": 0, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0037',$j${"COUNTED": 2, "EXPECTED": 2, "ITEM_ID": "ITM-0005", "ITEM_NAME": "MULTICARE BIO POWER *NEW", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260821-190949", "TIMESTAMP": "2026-08-21T19:09:49.388000", "VARIANCE": 0, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0038',$j${"COUNTED": 5, "EXPECTED": 6, "ITEM_ID": "ITM-0006", "ITEM_NAME": "DELICATE DES", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260821-190949", "TIMESTAMP": "2026-08-21T19:09:49.388000", "VARIANCE": -1, "VARIANCE_VALUE": -510.7}$j$::jsonb),
  ('COUNTS','row-0039',$j${"COUNTED": 0, "EXPECTED": 3, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260821-190949", "TIMESTAMP": "2026-08-21T19:09:49.388000", "VARIANCE": -3, "VARIANCE_VALUE": -1697.6399999999999}$j$::jsonb),
  ('COUNTS','row-0040',$j${"COUNTED": 0, "EXPECTED": 1, "ITEM_ID": "ITM-0033", "ITEM_NAME": "Biocel 30% Caustic WT/VOL", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260821-191432", "TIMESTAMP": "2026-08-21T19:14:32.669000", "VARIANCE": -1, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0041',$j${"COUNTED": 27, "EXPECTED": 32, "ITEM_ID": "ITM-0010", "ITEM_NAME": "Extra Small Bag", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120424", "TIMESTAMP": "2026-08-28T12:04:24.143000", "VARIANCE": -5, "VARIANCE_VALUE": -293.75}$j$::jsonb),
  ('COUNTS','row-0042',$j${"COUNTED": 9, "EXPECTED": 0, "ITEM_ID": "ITM-0011", "ITEM_NAME": "Small bags 380x550 (17mu)", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120424", "TIMESTAMP": "2026-08-28T12:04:24.143000", "VARIANCE": 9, "VARIANCE_VALUE": 186.75}$j$::jsonb),
  ('COUNTS','row-0043',$j${"COUNTED": 24, "EXPECTED": 10, "ITEM_ID": "ITM-0012", "ITEM_NAME": "Medium bags 320x540x830 (16mu)", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120424", "TIMESTAMP": "2026-08-28T12:04:24.143000", "VARIANCE": 14, "VARIANCE_VALUE": 291.76}$j$::jsonb),
  ('COUNTS','row-0044',$j${"COUNTED": 8, "EXPECTED": 24, "ITEM_ID": "ITM-0013", "ITEM_NAME": "Large bags (roll) 380x660x1120 (30mu)", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120424", "TIMESTAMP": "2026-08-28T12:04:24.143000", "VARIANCE": -16, "VARIANCE_VALUE": -428.8}$j$::jsonb),
  ('COUNTS','row-0045',$j${"COUNTED": 800, "EXPECTED": 1000, "ITEM_ID": "ITM-0015", "ITEM_NAME": "Cable ties - black", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120424", "TIMESTAMP": "2026-08-28T12:04:24.143000", "VARIANCE": -200, "VARIANCE_VALUE": -278}$j$::jsonb),
  ('COUNTS','row-0046',$j${"COUNTED": 1000, "EXPECTED": 1100, "ITEM_ID": "ITM-0016", "ITEM_NAME": "Net bags - RED/WHITE", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120424", "TIMESTAMP": "2026-08-28T12:04:24.143000", "VARIANCE": -100, "VARIANCE_VALUE": -309}$j$::jsonb),
  ('COUNTS','row-0047',$j${"COUNTED": 100, "EXPECTED": 1500, "ITEM_ID": "ITM-0017", "ITEM_NAME": "Net bags", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120424", "TIMESTAMP": "2026-08-28T12:04:24.143000", "VARIANCE": -1400, "VARIANCE_VALUE": -4200}$j$::jsonb),
  ('COUNTS','row-0048',$j${"COUNTED": 11, "EXPECTED": 23, "ITEM_ID": "ITM-0018", "ITEM_NAME": "Disposable Mops", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120424", "TIMESTAMP": "2026-08-28T12:04:24.143000", "VARIANCE": -12, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0049',$j${"COUNTED": 20, "EXPECTED": 22, "ITEM_ID": "ITM-0019", "ITEM_NAME": "BTS HIQ70", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120424", "TIMESTAMP": "2026-08-28T12:04:24.143000", "VARIANCE": -2, "VARIANCE_VALUE": -266}$j$::jsonb),
  ('COUNTS','row-0050',$j${"COUNTED": 23, "EXPECTED": 31, "ITEM_ID": "ITM-0020", "ITEM_NAME": "BTS HIQ30", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120424", "TIMESTAMP": "2026-08-28T12:04:24.143000", "VARIANCE": -8, "VARIANCE_VALUE": -440}$j$::jsonb),
  ('COUNTS','row-0051',$j${"COUNTED": 5, "EXPECTED": 7, "ITEM_ID": "ITM-0021", "ITEM_NAME": "EYELET half size", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120424", "TIMESTAMP": "2026-08-28T12:04:24.143000", "VARIANCE": -2, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0052',$j${"COUNTED": 7, "EXPECTED": 12, "ITEM_ID": "ITM-0022", "ITEM_NAME": "EYELET full size", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120424", "TIMESTAMP": "2026-08-28T12:04:24.143000", "VARIANCE": -5, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0053',$j${"COUNTED": 3, "EXPECTED": 4, "ITEM_ID": "ITM-0023", "ITEM_NAME": "T-BAR half size", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120424", "TIMESTAMP": "2026-08-28T12:04:24.143000", "VARIANCE": -1, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0054',$j${"COUNTED": 1, "EXPECTED": 4, "ITEM_ID": "ITM-0024", "ITEM_NAME": "T-BAR full size", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120424", "TIMESTAMP": "2026-08-28T12:04:24.143000", "VARIANCE": -3, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0055',$j${"COUNTED": 1, "EXPECTED": 0, "ITEM_ID": "ITM-0009", "ITEM_NAME": "Clear Packing Tape", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120449", "TIMESTAMP": "2026-08-28T12:04:49.905000", "VARIANCE": 1, "VARIANCE_VALUE": 50.04}$j$::jsonb),
  ('COUNTS','row-0056',$j${"COUNTED": 11, "EXPECTED": 8, "ITEM_ID": "ITM-0013", "ITEM_NAME": "Large bags (roll) 380x660x1120 (30mu)", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260828-120539", "TIMESTAMP": "2026-08-28T12:05:39.121000", "VARIANCE": 3, "VARIANCE_VALUE": 80.4}$j$::jsonb),
  ('COUNTS','row-0057',$j${"COUNTED": 1, "EXPECTED": 2, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260915-155031", "TIMESTAMP": "2026-09-15T15:50:31.256000", "VARIANCE": -1, "VARIANCE_VALUE": -156.79}$j$::jsonb),
  ('COUNTS','row-0058',$j${"COUNTED": 8, "EXPECTED": 0, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260915-155031", "TIMESTAMP": "2026-09-15T15:50:31.256000", "VARIANCE": 8, "VARIANCE_VALUE": 951.2}$j$::jsonb),
  ('COUNTS','row-0059',$j${"COUNTED": 1, "EXPECTED": 2, "ITEM_ID": "ITM-0005", "ITEM_NAME": "MULTICARE BIO POWER *NEW", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260915-155031", "TIMESTAMP": "2026-09-15T15:50:31.256000", "VARIANCE": -1, "VARIANCE_VALUE": -1085.85}$j$::jsonb),
  ('COUNTS','row-0060',$j${"COUNTED": 2, "EXPECTED": 5, "ITEM_ID": "ITM-0006", "ITEM_NAME": "DELICATE DES", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260915-155031", "TIMESTAMP": "2026-09-15T15:50:31.256000", "VARIANCE": -3, "VARIANCE_VALUE": -1532.1}$j$::jsonb),
  ('COUNTS','row-0061',$j${"COUNTED": 2, "EXPECTED": 0, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260915-155031", "TIMESTAMP": "2026-09-15T15:50:31.256000", "VARIANCE": 2, "VARIANCE_VALUE": 1131.76}$j$::jsonb),
  ('COUNTS','row-0062',$j${"COUNTED": 3, "EXPECTED": 0, "ITEM_ID": "ITM-0033", "ITEM_NAME": "Biocel 30% Caustic WT/VOL", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260915-155031", "TIMESTAMP": "2026-09-15T15:50:31.256000", "VARIANCE": 3, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0063',$j${"COUNTED": 4, "EXPECTED": 5, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260918-102336", "TIMESTAMP": "2026-09-18T10:23:36.434000", "VARIANCE": -1, "VARIANCE_VALUE": -156.79}$j$::jsonb),
  ('COUNTS','row-0064',$j${"COUNTED": 19, "EXPECTED": 8, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260918-102336", "TIMESTAMP": "2026-09-18T10:23:36.434000", "VARIANCE": 11, "VARIANCE_VALUE": 1307.9}$j$::jsonb),
  ('COUNTS','row-0065',$j${"COUNTED": 8, "EXPECTED": 9, "ITEM_ID": "ITM-0003", "ITEM_NAME": "P3-POLIX CHLORANT 24kg", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260918-102336", "TIMESTAMP": "2026-09-18T10:23:36.434000", "VARIANCE": -1, "VARIANCE_VALUE": -30.48}$j$::jsonb),
  ('COUNTS','row-0066',$j${"COUNTED": 4, "EXPECTED": 3, "ITEM_ID": "ITM-0005", "ITEM_NAME": "MULTICARE BIO POWER *NEW", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260918-102336", "TIMESTAMP": "2026-09-18T10:23:36.434000", "VARIANCE": 1, "VARIANCE_VALUE": 1085.85}$j$::jsonb),
  ('COUNTS','row-0067',$j${"COUNTED": 1, "EXPECTED": 2, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260918-102336", "TIMESTAMP": "2026-09-18T10:23:36.434000", "VARIANCE": -1, "VARIANCE_VALUE": -565.88}$j$::jsonb),
  ('COUNTS','row-0068',$j${"COUNTED": 3, "EXPECTED": 3, "ITEM_ID": "ITM-0033", "ITEM_NAME": "Biocel 30% Caustic WT/VOL", "REGISTERED_BY": "Tamara Bastos", "SESSION_ID": "CNT-20260918-102430", "TIMESTAMP": "2026-09-18T10:24:30.620000", "VARIANCE": 0, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0069',$j${"COUNTED": 4, "EXPECTED": 4, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260925-160432", "TIMESTAMP": "2026-09-25T16:04:32.522000", "VARIANCE": 0, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0070',$j${"COUNTED": 16, "EXPECTED": 19, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260925-160432", "TIMESTAMP": "2026-09-25T16:04:32.522000", "VARIANCE": -3, "VARIANCE_VALUE": -356.70000000000005}$j$::jsonb),
  ('COUNTS','row-0071',$j${"COUNTED": 3, "EXPECTED": 4, "ITEM_ID": "ITM-0005", "ITEM_NAME": "MULTICARE BIO POWER *NEW", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260925-160432", "TIMESTAMP": "2026-09-25T16:04:32.522000", "VARIANCE": -1, "VARIANCE_VALUE": -1085.85}$j$::jsonb),
  ('COUNTS','row-0072',$j${"COUNTED": 3, "EXPECTED": 4, "ITEM_ID": "ITM-0006", "ITEM_NAME": "DELICATE DES", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260925-160432", "TIMESTAMP": "2026-09-25T16:04:32.522000", "VARIANCE": -1, "VARIANCE_VALUE": -510.7}$j$::jsonb),
  ('COUNTS','row-0073',$j${"COUNTED": 11, "EXPECTED": 1, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "REGISTERED_BY": "Paulo", "SESSION_ID": "CNT-20260925-160432", "TIMESTAMP": "2026-09-25T16:04:32.522000", "VARIANCE": 10, "VARIANCE_VALUE": 5658.8}$j$::jsonb),
  ('COUNTS','row-0074',$j${"COUNTED": 5, "EXPECTED": 4, "ITEM_ID": "ITM-0001", "ITEM_NAME": "SOFTENET FLOWERCARE", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122521", "TIMESTAMP": "2026-09-28T12:25:21.542000", "VARIANCE": 1, "VARIANCE_VALUE": 156.79}$j$::jsonb),
  ('COUNTS','row-0075',$j${"COUNTED": 15, "EXPECTED": 16, "ITEM_ID": "ITM-0002", "ITEM_NAME": "TRIPLEX COLOUR CARE 20L", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122521", "TIMESTAMP": "2026-09-28T12:25:21.542000", "VARIANCE": -1, "VARIANCE_VALUE": -118.9}$j$::jsonb),
  ('COUNTS','row-0076',$j${"COUNTED": 4, "EXPECTED": 3, "ITEM_ID": "ITM-0005", "ITEM_NAME": "MULTICARE BIO POWER *NEW", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122521", "TIMESTAMP": "2026-09-28T12:25:21.542000", "VARIANCE": 1, "VARIANCE_VALUE": 1085.85}$j$::jsonb),
  ('COUNTS','row-0077',$j${"COUNTED": 10, "EXPECTED": 11, "ITEM_ID": "ITM-0007", "ITEM_NAME": "DELICATE DETERGENT", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122521", "TIMESTAMP": "2026-09-28T12:25:21.542000", "VARIANCE": -1, "VARIANCE_VALUE": -565.88}$j$::jsonb),
  ('COUNTS','row-0078',$j${"COUNTED": 5, "EXPECTED": 5, "ITEM_ID": "ITM-0008", "ITEM_NAME": "MULTICARE EMULSION", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122521", "TIMESTAMP": "2026-09-28T12:25:21.542000", "VARIANCE": 0, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0079',$j${"COUNTED": 3, "EXPECTED": 3, "ITEM_ID": "ITM-0033", "ITEM_NAME": "Biocel 30% Caustic WT/VOL", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122521", "TIMESTAMP": "2026-09-28T12:25:21.542000", "VARIANCE": 0, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0080',$j${"COUNTED": 26, "EXPECTED": 27, "ITEM_ID": "ITM-0010", "ITEM_NAME": "Extra Small Bag", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122730", "TIMESTAMP": "2026-09-28T12:27:30.965000", "VARIANCE": -1, "VARIANCE_VALUE": -58.75}$j$::jsonb),
  ('COUNTS','row-0081',$j${"COUNTED": 3, "EXPECTED": 9, "ITEM_ID": "ITM-0011", "ITEM_NAME": "Small bags 380x550 (17mu)", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122730", "TIMESTAMP": "2026-09-28T12:27:30.965000", "VARIANCE": -6, "VARIANCE_VALUE": -124.5}$j$::jsonb),
  ('COUNTS','row-0082',$j${"COUNTED": 19, "EXPECTED": 24, "ITEM_ID": "ITM-0012", "ITEM_NAME": "Medium bags 320x540x830 (16mu)", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122730", "TIMESTAMP": "2026-09-28T12:27:30.965000", "VARIANCE": -5, "VARIANCE_VALUE": -104.2}$j$::jsonb),
  ('COUNTS','row-0083',$j${"COUNTED": 0, "EXPECTED": 11, "ITEM_ID": "ITM-0013", "ITEM_NAME": "Large bags (roll) 380x660x1120 (30mu)", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122730", "TIMESTAMP": "2026-09-28T12:27:30.965000", "VARIANCE": -11, "VARIANCE_VALUE": -294.8}$j$::jsonb),
  ('COUNTS','row-0084',$j${"COUNTED": 0, "EXPECTED": 0, "ITEM_ID": "ITM-0014", "ITEM_NAME": "Cable ties - Large", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122730", "TIMESTAMP": "2026-09-28T12:27:30.965000", "VARIANCE": 0, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0085',$j${"COUNTED": 0, "EXPECTED": 800, "ITEM_ID": "ITM-0015", "ITEM_NAME": "Cable ties - black", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122730", "TIMESTAMP": "2026-09-28T12:27:30.965000", "VARIANCE": -800, "VARIANCE_VALUE": -1112}$j$::jsonb),
  ('COUNTS','row-0086',$j${"COUNTED": 400, "EXPECTED": 1000, "ITEM_ID": "ITM-0016", "ITEM_NAME": "Net bags - RED/WHITE", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122730", "TIMESTAMP": "2026-09-28T12:27:30.965000", "VARIANCE": -600, "VARIANCE_VALUE": -1854}$j$::jsonb),
  ('COUNTS','row-0087',$j${"COUNTED": 1400, "EXPECTED": 100, "ITEM_ID": "ITM-0017", "ITEM_NAME": "Net bags", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122730", "TIMESTAMP": "2026-09-28T12:27:30.965000", "VARIANCE": 1300, "VARIANCE_VALUE": 3900}$j$::jsonb),
  ('COUNTS','row-0088',$j${"COUNTED": 27, "EXPECTED": 11, "ITEM_ID": "ITM-0018", "ITEM_NAME": "Disposable Mops", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122730", "TIMESTAMP": "2026-09-28T12:27:30.965000", "VARIANCE": 16, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0089',$j${"COUNTED": 18, "EXPECTED": 20, "ITEM_ID": "ITM-0019", "ITEM_NAME": "BTS HIQ70", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122730", "TIMESTAMP": "2026-09-28T12:27:30.965000", "VARIANCE": -2, "VARIANCE_VALUE": -266}$j$::jsonb),
  ('COUNTS','row-0090',$j${"COUNTED": 16, "EXPECTED": 23, "ITEM_ID": "ITM-0020", "ITEM_NAME": "BTS HIQ30", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122730", "TIMESTAMP": "2026-09-28T12:27:30.965000", "VARIANCE": -7, "VARIANCE_VALUE": -385}$j$::jsonb),
  ('COUNTS','row-0091',$j${"COUNTED": 2, "EXPECTED": 5, "ITEM_ID": "ITM-0021", "ITEM_NAME": "EYELET half size", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122730", "TIMESTAMP": "2026-09-28T12:27:30.965000", "VARIANCE": -3, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0092',$j${"COUNTED": 2, "EXPECTED": 7, "ITEM_ID": "ITM-0022", "ITEM_NAME": "EYELET full size", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122730", "TIMESTAMP": "2026-09-28T12:27:30.965000", "VARIANCE": -5, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('COUNTS','row-0093',$j${"COUNTED": 0, "EXPECTED": 1, "ITEM_ID": "ITM-0024", "ITEM_NAME": "T-BAR full size", "REGISTERED_BY": "Luiz", "SESSION_ID": "CNT-20260928-122730", "TIMESTAMP": "2026-09-28T12:27:30.965000", "VARIANCE": -1, "VARIANCE_VALUE": 0}$j$::jsonb),
  ('UNIFORM_LOG','row-0002',$j${"ACTION": "ISSUED", "DESCRIPTION": "T-shirt", "EMPLOYEE_ID": "EMP-0021", "EMPLOYEE_NAME": "Kevin", "NOTES": null, "QTY": 4, "REGISTERED_BY": "Luiz", "SIZE": "M", "TIMESTAMP": "2026-07-28T14:04:42.769000", "TYPE": "Uniform"}$j$::jsonb),
  ('UNIFORM_LOG','row-0003',$j${"ACTION": "ISSUED", "DESCRIPTION": "T-shirt", "EMPLOYEE_ID": "EMP-0021", "EMPLOYEE_NAME": "Kevin", "NOTES": null, "QTY": 4, "REGISTERED_BY": "Luiz", "SIZE": "M", "TIMESTAMP": "2026-07-28T14:04:44.827000", "TYPE": "Uniform"}$j$::jsonb),
  ('UNIFORM_LOG','row-0004',$j${"ACTION": "RETURNED", "DESCRIPTION": "T-shirt", "EMPLOYEE_ID": "EMP-0021", "EMPLOYEE_NAME": "Kevin", "NOTES": null, "QTY": 4, "REGISTERED_BY": "Luiz", "SIZE": "M", "TIMESTAMP": "2026-07-28T14:16:51.300000", "TYPE": "Uniform"}$j$::jsonb),
  ('UNIFORM_LOG','row-0005',$j${"ACTION": "ISSUED", "DESCRIPTION": "Shirt", "EMPLOYEE_ID": "EMP-0021", "EMPLOYEE_NAME": "Kevin", "NOTES": null, "QTY": 4, "REGISTERED_BY": "Luiz", "SIZE": "M", "TIMESTAMP": "2026-07-28T14:26:46.342000", "TYPE": "Uniform"}$j$::jsonb),
  ('UNIFORM_LOG','row-0006',$j${"ACTION": "ISSUED", "DESCRIPTION": "Shirt", "EMPLOYEE_ID": "EMP-0021", "EMPLOYEE_NAME": "Kevin", "NOTES": null, "QTY": 4, "REGISTERED_BY": "Luiz", "SIZE": "M", "TIMESTAMP": "2026-07-28T14:26:47.443000", "TYPE": "Uniform"}$j$::jsonb),
  ('UNIFORM_LOG','row-0007',$j${"ACTION": "RETURNED", "DESCRIPTION": "Shirt", "EMPLOYEE_ID": "EMP-0021", "EMPLOYEE_NAME": "Kevin", "NOTES": null, "QTY": 4, "REGISTERED_BY": "Luiz", "SIZE": "M", "TIMESTAMP": "2026-07-28T14:29:16.062000", "TYPE": "Uniform"}$j$::jsonb),
  ('UNIFORM_LOG','row-0008',$j${"ACTION": "RETURNED", "DESCRIPTION": "Shirt", "EMPLOYEE_ID": "EMP-0021", "EMPLOYEE_NAME": "Kevin", "NOTES": null, "QTY": 4, "REGISTERED_BY": "Luiz", "SIZE": "M", "TIMESTAMP": "2026-07-28T15:11:45.107000", "TYPE": "Uniform"}$j$::jsonb),
  ('UNIFORM_LOG','row-0009',$j${"ACTION": "RETURNED", "DESCRIPTION": "Shirt", "EMPLOYEE_ID": "EMP-0021", "EMPLOYEE_NAME": "Kevin", "NOTES": null, "QTY": 4, "REGISTERED_BY": "Luiz", "SIZE": "M", "TIMESTAMP": "2026-07-28T15:15:23.253000", "TYPE": "Uniform"}$j$::jsonb),
  ('KEYS','KEY-0001',$j${"ASSIGNED_TO_ID": "EMP-0025", "ASSIGNED_TO_NAME": "Luiz Teodoro Barbosa Silva", "KEY_ID": "KEY-0001", "LABEL": "M-01", "SINCE": "2026-07-22T15:41:16.961000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0002',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0002", "LABEL": "M-02", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0003',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0003", "LABEL": "M-03", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0004',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0004", "LABEL": "M-04", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0005',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0005", "LABEL": "M-05", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0006',$j${"ASSIGNED_TO_ID": "EMP-0002", "ASSIGNED_TO_NAME": "Agostinho", "KEY_ID": "KEY-0006", "LABEL": "M-06", "SINCE": "2026-07-22T15:42:23.502000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0007',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0007", "LABEL": "M-07", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0008',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0008", "LABEL": "M-08", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0009',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0009", "LABEL": "M-09", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0010',$j${"ASSIGNED_TO_ID": "EMP-0031", "ASSIGNED_TO_NAME": "Richard Fernandes", "KEY_ID": "KEY-0010", "LABEL": "M-10", "SINCE": "2026-07-22T16:45:39.986000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0011',$j${"ASSIGNED_TO_ID": "EMP-0041", "ASSIGNED_TO_NAME": "Vishal", "KEY_ID": "KEY-0011", "LABEL": "M-11", "SINCE": "2026-07-22T15:44:02.994000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0012',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0012", "LABEL": "M-12", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0013',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0013", "LABEL": "M-13", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0014',$j${"ASSIGNED_TO_ID": "EMP-0038", "ASSIGNED_TO_NAME": "Vesley Julio M. Fernandes", "KEY_ID": "KEY-0014", "LABEL": "M-14", "SINCE": "2026-07-22T16:48:53.355000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0015',$j${"ASSIGNED_TO_ID": "EMP-0023", "ASSIGNED_TO_NAME": "Lodovico", "KEY_ID": "KEY-0015", "LABEL": "M-15", "SINCE": "2026-07-22T15:50:44.577000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0016',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0016", "LABEL": "M-16", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0017',$j${"ASSIGNED_TO_ID": "EMP-0029", "ASSIGNED_TO_NAME": "Patrick Fernandes", "KEY_ID": "KEY-0017", "LABEL": "M-17", "SINCE": "2026-07-22T16:50:37", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0018',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0018", "LABEL": "M-18", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0019',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0019", "LABEL": "M-19", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0020',$j${"ASSIGNED_TO_ID": "EMP-0021", "ASSIGNED_TO_NAME": "Kevin", "KEY_ID": "KEY-0020", "LABEL": "M-20", "SINCE": "2026-07-22T15:50:56.146000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0021',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0021", "LABEL": "M-21", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0022',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0022", "LABEL": "M-22", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0023',$j${"ASSIGNED_TO_ID": "EMP-0034", "ASSIGNED_TO_NAME": "Savio Carmo", "KEY_ID": "KEY-0023", "LABEL": "M-23", "SINCE": "2026-07-22T15:45:56.096000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0024',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0024", "LABEL": "M-24", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0025',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0025", "LABEL": "M-25", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0026',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0026", "LABEL": "M-26", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0027',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0027", "LABEL": "M-27", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0028',$j${"ASSIGNED_TO_ID": "EMP-0032", "ASSIGNED_TO_NAME": "Robert Fernandes", "KEY_ID": "KEY-0028", "LABEL": "M-28", "SINCE": "2026-07-22T15:43:23.340000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0029',$j${"ASSIGNED_TO_ID": "EMP-0033", "ASSIGNED_TO_NAME": "Ronaldo da Silva", "KEY_ID": "KEY-0029", "LABEL": "M-29", "SINCE": "2026-07-22T15:46:47.200000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0030',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0030", "LABEL": "M-30", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0031',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0031", "LABEL": "M-31", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0032',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0032", "LABEL": "M-32", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0033',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0033", "LABEL": "M-33", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0034',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0034", "LABEL": "M-34", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0035',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0035", "LABEL": "M-35", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0036',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0036", "LABEL": "M-36", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0037',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0037", "LABEL": "M-37", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0038',$j${"ASSIGNED_TO_ID": "EMP-0047", "ASSIGNED_TO_NAME": "Gabriel", "KEY_ID": "KEY-0038", "LABEL": "M-38", "SINCE": "2026-07-22T15:51:45.471000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0039',$j${"ASSIGNED_TO_ID": "EMP-0045", "ASSIGNED_TO_NAME": "Andre", "KEY_ID": "KEY-0039", "LABEL": "M-39", "SINCE": "2026-07-22T15:51:23.973000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0040',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0040", "LABEL": "M-40", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0041',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0041", "LABEL": "F-01", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0042',$j${"ASSIGNED_TO_ID": "EMP-0036", "ASSIGNED_TO_NAME": "Tatiana Furlaneto", "KEY_ID": "KEY-0042", "LABEL": "F-02", "SINCE": "2026-07-22T15:47:59.325000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0043',$j${"ASSIGNED_TO_ID": "EMP-0028", "ASSIGNED_TO_NAME": "Paola Cortez Galvis", "KEY_ID": "KEY-0043", "LABEL": "F-03", "SINCE": "2026-07-22T15:48:12.183000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0044',$j${"ASSIGNED_TO_ID": "EMP-0040", "ASSIGNED_TO_NAME": "Viorica Closca", "KEY_ID": "KEY-0044", "LABEL": "F-04", "SINCE": "2026-07-22T15:48:36.632000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0045',$j${"ASSIGNED_TO_ID": "EMP-0008", "ASSIGNED_TO_NAME": "Cristina iliescu", "KEY_ID": "KEY-0045", "LABEL": "F-05", "SINCE": "2026-07-22T15:48:48.339000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0046',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0046", "LABEL": "F-06", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0047',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0047", "LABEL": "F-07", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0048',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0048", "LABEL": "F-08", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0049',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0049", "LABEL": "F-09", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0050',$j${"ASSIGNED_TO_ID": "EMP-0007", "ASSIGNED_TO_NAME": "Bendita Fernandes", "KEY_ID": "KEY-0050", "LABEL": "F-10", "SINCE": "2026-07-22T15:49:07.520000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0051',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0051", "LABEL": "F-11", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0052',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0052", "LABEL": "F-12", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0053',$j${"ASSIGNED_TO_ID": "EMP-0035", "ASSIGNED_TO_NAME": "Taina Furlaneto", "KEY_ID": "KEY-0053", "LABEL": "F-13", "SINCE": "2026-07-22T15:49:25.644000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0054',$j${"ASSIGNED_TO_ID": "EMP-0004", "ASSIGNED_TO_NAME": "Anergha Putanpura", "KEY_ID": "KEY-0054", "LABEL": "F-14", "SINCE": "2026-07-22T16:47:37.731000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0055',$j${"ASSIGNED_TO_ID": "EMP-0003", "ASSIGNED_TO_NAME": "Ana Maria Marc", "KEY_ID": "KEY-0055", "LABEL": "F-15", "SINCE": "2026-07-22T16:44:52.155000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0056',$j${"ASSIGNED_TO_ID": "EMP-0011", "ASSIGNED_TO_NAME": "Fernanda Rodriguez", "KEY_ID": "KEY-0056", "LABEL": "F-16", "SINCE": "2026-07-22T15:56:27.628000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0057',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0057", "LABEL": "F-17", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0058',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0058", "LABEL": "F-18", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0059',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0059", "LABEL": "F-19", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0060',$j${"ASSIGNED_TO_ID": "EMP-0010", "ASSIGNED_TO_NAME": "Emma Fernandes", "KEY_ID": "KEY-0060", "LABEL": "F-20", "SINCE": "2026-07-22T15:50:07.977000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0061',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0061", "LABEL": "F-21", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0062',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0062", "LABEL": "F-22", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0063',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0063", "LABEL": "F-23", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0064',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0064", "LABEL": "F-24", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0065',$j${"ASSIGNED_TO_ID": "EMP-0030", "ASSIGNED_TO_NAME": "Rahma Mohamed", "KEY_ID": "KEY-0065", "LABEL": "F-25", "SINCE": "2026-07-22T15:49:42.957000", "STATUS": "Assigned"}$j$::jsonb),
  ('KEYS','KEY-0066',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0066", "LABEL": "F-26", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0067',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0067", "LABEL": "F-27", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0068',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0068", "LABEL": "F-28", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0069',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0069", "LABEL": "F-29", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0070',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0070", "LABEL": "F-30", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0071',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0071", "LABEL": "F-31", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0072',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0072", "LABEL": "F-32", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0073',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0073", "LABEL": "F-33", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0074',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0074", "LABEL": "F-34", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0075',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0075", "LABEL": "F-35", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0076',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0076", "LABEL": "F-36", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0077',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0077", "LABEL": "F-37", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0078',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0078", "LABEL": "F-38", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0079',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0079", "LABEL": "F-39", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEYS','KEY-0080',$j${"ASSIGNED_TO_ID": null, "ASSIGNED_TO_NAME": null, "KEY_ID": "KEY-0080", "LABEL": "F-40", "SINCE": null, "STATUS": "Available"}$j$::jsonb),
  ('KEY_LOG','row-0002',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Luiz Teodoro Barbosa Silva", "KEY_ID": "KEY-0001", "LABEL": "M-01", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:41:16.961000"}$j$::jsonb),
  ('KEY_LOG','row-0003',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Agostinho", "KEY_ID": "KEY-0006", "LABEL": "M-06", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:42:23.502000"}$j$::jsonb),
  ('KEY_LOG','row-0004',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Robert Fernandes", "KEY_ID": "KEY-0028", "LABEL": "M-28", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:43:23.340000"}$j$::jsonb),
  ('KEY_LOG','row-0005',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Vishal", "KEY_ID": "KEY-0011", "LABEL": "M-11", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:44:02.994000"}$j$::jsonb),
  ('KEY_LOG','row-0006',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Savio Carmo", "KEY_ID": "KEY-0023", "LABEL": "M-23", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:45:56.096000"}$j$::jsonb),
  ('KEY_LOG','row-0007',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Ronaldo da Silva", "KEY_ID": "KEY-0029", "LABEL": "M-29", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:46:47.200000"}$j$::jsonb),
  ('KEY_LOG','row-0008',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Tatiana Furlaneto", "KEY_ID": "KEY-0042", "LABEL": "F-02", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:47:59.325000"}$j$::jsonb),
  ('KEY_LOG','row-0009',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Paola Cortez Galvis", "KEY_ID": "KEY-0043", "LABEL": "F-03", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:48:12.183000"}$j$::jsonb),
  ('KEY_LOG','row-0010',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Viorica Closca", "KEY_ID": "KEY-0044", "LABEL": "F-04", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:48:36.632000"}$j$::jsonb),
  ('KEY_LOG','row-0011',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Cristina iliescu", "KEY_ID": "KEY-0045", "LABEL": "F-05", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:48:48.339000"}$j$::jsonb),
  ('KEY_LOG','row-0012',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Bendita Fernandes", "KEY_ID": "KEY-0050", "LABEL": "F-10", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:49:07.520000"}$j$::jsonb),
  ('KEY_LOG','row-0013',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Taina Furlaneto", "KEY_ID": "KEY-0053", "LABEL": "F-13", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:49:25.644000"}$j$::jsonb),
  ('KEY_LOG','row-0014',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Rahma Mohamed", "KEY_ID": "KEY-0065", "LABEL": "F-25", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:49:42.957000"}$j$::jsonb),
  ('KEY_LOG','row-0015',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Emma Fernandes", "KEY_ID": "KEY-0060", "LABEL": "F-20", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:50:07.977000"}$j$::jsonb),
  ('KEY_LOG','row-0016',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Lodovico", "KEY_ID": "KEY-0015", "LABEL": "M-15", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:50:44.577000"}$j$::jsonb),
  ('KEY_LOG','row-0017',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Kevin", "KEY_ID": "KEY-0020", "LABEL": "M-20", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:50:56.146000"}$j$::jsonb),
  ('KEY_LOG','row-0018',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Andre", "KEY_ID": "KEY-0039", "LABEL": "M-39", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:51:23.973000"}$j$::jsonb),
  ('KEY_LOG','row-0019',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Gabriel", "KEY_ID": "KEY-0038", "LABEL": "M-38", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:51:45.471000"}$j$::jsonb),
  ('KEY_LOG','row-0020',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Fernanda Rodriguez", "KEY_ID": "KEY-0056", "LABEL": "F-16", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T15:56:27.628000"}$j$::jsonb),
  ('KEY_LOG','row-0021',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Ana Maria Marc", "KEY_ID": "KEY-0055", "LABEL": "F-15", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T16:44:52.155000"}$j$::jsonb),
  ('KEY_LOG','row-0022',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Richard Fernandes", "KEY_ID": "KEY-0010", "LABEL": "M-10", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T16:45:39.986000"}$j$::jsonb),
  ('KEY_LOG','row-0023',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Anergha Putanpura", "KEY_ID": "KEY-0054", "LABEL": "F-14", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T16:47:37.731000"}$j$::jsonb),
  ('KEY_LOG','row-0024',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Vesley Julio M. Fernandes", "KEY_ID": "KEY-0014", "LABEL": "M-14", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T16:48:53.355000"}$j$::jsonb),
  ('KEY_LOG','row-0025',$j${"ACTION": "ASSIGNED", "EMPLOYEE": "Patrick Fernandes", "KEY_ID": "KEY-0017", "LABEL": "M-17", "NOTES": null, "REGISTERED_BY": "Paulo", "TIMESTAMP": "2026-07-22T16:50:37"}$j$::jsonb)
) v(sheet,k,raw)
on conflict (batch_id,sheet_name,source_key) do nothing;

-- 2. Map people ----------------------------------------------------------

-- A plain temporary table (no ON COMMIT DROP): the SQL Editor may run the
-- script without the outer transaction, and the table must survive until the end.
drop table if exists pg_temp.stock_import_people;
create temporary table stock_import_people as
select r.source_key emp_id,trim(r.raw->>'NAME') source_name,
  s.staff_id,d.driver_id,coalesce(s.display_name,d.display_name,trim(r.raw->>'NAME')) holder_name
from staging.apps_script_stock_rows r
left join public.staff_members s on r.raw->>'SOURCE'='USER' and s.legacy_user_id=(r.raw->>'SOURCE_ID')::integer and s.deleted_at is null
left join public.distribution_drivers d on r.raw->>'SOURCE'='DRIVER' and d.legacy_driver_id=(r.raw->>'SOURCE_ID') and d.deleted_at is null
where r.batch_id='APPS_SCRIPT_STOCK_20261028_001' and r.sheet_name='EMPLOYEES';

update staging.apps_script_stock_rows r set review_status=case when p.staff_id is null and p.driver_id is null then 'REVIEW' else 'PROMOTED' end,
  review_reason=case when p.staff_id is null and p.driver_id is null then 'No Staff Master or driver record has this legacy id.' end
from stock_import_people p where r.batch_id='APPS_SCRIPT_STOCK_20261028_001' and r.sheet_name='EMPLOYEES' and r.source_key=p.emp_id;

create or replace function pg_temp.stock_import_time(p text) returns timestamptz language sql immutable as $$
  select case when nullif(p,'') is null then null else (p::timestamp at time zone 'Europe/Dublin') end
$$;

-- 3. Items ---------------------------------------------------------------

insert into public.stock_items(legacy_item_code,item_code,item_name,category_code,supplier,unit,unit_price,stock_qty,min_stock,location,track_by,requestable,active,last_counted_at,created_at)
select r.source_key,
  case when upper(trim(coalesce(r.raw->>'CODE',''))) in ('','N/A','NA','-') then null else trim(r.raw->>'CODE') end,
  trim(r.raw->>'NAME'),c.category_code,nullif(trim(r.raw->>'SUPPLIER'),''),coalesce(nullif(trim(r.raw->>'UNIT'),''),'unit'),
  coalesce((r.raw->>'UNIT_PRICE')::numeric,0),greatest(coalesce((r.raw->>'STOCK')::numeric,0),0),coalesce((r.raw->>'MIN_STOCK')::numeric,0),
  nullif(trim(r.raw->>'LOCATION'),''),t.track_by,
  c.stock_area='PPE_UNIFORM' and t.track_by='STAFF',
  coalesce((r.raw->>'ACTIVE')::boolean,true),pg_temp.stock_import_time(r.raw->>'LAST_COUNT'),now()
from staging.apps_script_stock_rows r
cross join lateral (select case trim(r.raw->>'CATEGORY') when 'Chemical' then 'CHEMICAL' when 'Packing' then 'PACKING' when 'Uniform' then 'UNIFORM'
  when 'Safety Shoes' then 'SAFETY_SHOES' when 'PPE' then 'PPE' else 'OTHER' end code) m
join public.stock_categories c on c.category_code=m.code
cross join lateral (select case upper(trim(coalesce(r.raw->>'TRACK_BY',''))) when 'EMPLOYEE' then 'STAFF' when 'CUSTOMER' then 'CUSTOMER' when 'NONE' then 'NONE' else c.default_track_by end track_by) t
where r.batch_id='APPS_SCRIPT_STOCK_20261028_001' and r.sheet_name='ITEMS'
on conflict (legacy_item_code) do nothing;

-- 4. Count sessions and lines -------------------------------------------

insert into public.stock_count_sessions(session_code,counted_at,counted_by_name,notes,items_counted,items_adjusted,consumption_lines,variance_value,consumption_value,source)
select r.raw->>'SESSION_ID',min(pg_temp.stock_import_time(r.raw->>'TIMESTAMP')),
  max(nullif(r.raw->>'REGISTERED_BY','Unknown')),'Imported from the Apps Script stock control',
  count(*),
  count(*) filter (where (r.raw->>'VARIANCE')::numeric<>0 and not (i.track_by='NONE' and (r.raw->>'VARIANCE')::numeric<0)),
  count(*) filter (where i.track_by='NONE' and (r.raw->>'VARIANCE')::numeric<0),
  coalesce(sum((r.raw->>'VARIANCE_VALUE')::numeric) filter (where not (i.track_by='NONE' and (r.raw->>'VARIANCE')::numeric<0)),0),
  coalesce(sum(abs((r.raw->>'VARIANCE_VALUE')::numeric)) filter (where i.track_by='NONE' and (r.raw->>'VARIANCE')::numeric<0),0),
  'APPS_SCRIPT'
from staging.apps_script_stock_rows r join public.stock_items i on i.legacy_item_code=r.raw->>'ITEM_ID'
where r.batch_id='APPS_SCRIPT_STOCK_20261028_001' and r.sheet_name='COUNTS'
group by r.raw->>'SESSION_ID'
on conflict (session_code) do nothing;

insert into public.stock_count_lines(session_id,item_id,expected_qty,counted_qty,variance_qty,variance_value)
select s.session_id,i.item_id,(r.raw->>'EXPECTED')::numeric,(r.raw->>'COUNTED')::numeric,(r.raw->>'VARIANCE')::numeric,coalesce((r.raw->>'VARIANCE_VALUE')::numeric,0)
from staging.apps_script_stock_rows r
join public.stock_items i on i.legacy_item_code=r.raw->>'ITEM_ID'
join public.stock_count_sessions s on s.session_code=r.raw->>'SESSION_ID' and s.source='APPS_SCRIPT'
where r.batch_id='APPS_SCRIPT_STOCK_20261028_001' and r.sheet_name='COUNTS'
on conflict (session_id,item_id) do nothing;

-- 5. Movements -----------------------------------------------------------

insert into public.stock_movements(item_id,movement_type,qty_change,stock_after,unit_price,staff_id,driver_id,holder_name,po_number,notes,count_session_id,recorded_at,recorded_by_name,source,source_key)
select i.item_id,upper(r.raw->>'TYPE'),coalesce((r.raw->>'QTY')::numeric,0),coalesce((r.raw->>'STOCK_AFTER')::numeric,0),i.unit_price,
  p.staff_id,p.driver_id,coalesce(p.holder_name,nullif(trim(r.raw->>'EMPLOYEE'),'')),nullif(trim(r.raw->>'PO'),''),nullif(trim(r.raw->>'NOTES'),''),
  s.session_id,pg_temp.stock_import_time(r.raw->>'TIMESTAMP'),nullif(trim(r.raw->>'REGISTERED_BY'),''),'APPS_SCRIPT','APPS_SCRIPT_STOCK_20261028_001:'||r.sheet_name||':'||r.source_key
from staging.apps_script_stock_rows r
join public.stock_items i on i.legacy_item_code=r.raw->>'ITEM_ID'
left join stock_import_people p on lower(p.source_name)=lower(trim(r.raw->>'EMPLOYEE'))
left join public.stock_count_sessions s on s.source='APPS_SCRIPT' and s.session_code=substring(r.raw->>'NOTES' from 'CNT-[0-9]{8}-[0-9]{6}')
where r.batch_id='APPS_SCRIPT_STOCK_20261028_001' and r.sheet_name='MOVEMENTS'
on conflict (source_key) do nothing;

-- 6. Uniforms and PPE ----------------------------------------------------

insert into public.stock_ppe_events(staff_id,driver_id,holder_name,item_type,description,size,qty,ppe_action,notes,recorded_at,recorded_by_name,source,source_key)
select p.staff_id,p.driver_id,coalesce(p.holder_name,trim(r.raw->>'EMPLOYEE_NAME')),
  coalesce(nullif(trim(r.raw->>'TYPE'),''),'Uniform'),trim(r.raw->>'DESCRIPTION'),nullif(trim(r.raw->>'SIZE'),''),
  coalesce((r.raw->>'QTY')::numeric,1),upper(r.raw->>'ACTION'),nullif(trim(r.raw->>'NOTES'),''),
  pg_temp.stock_import_time(r.raw->>'TIMESTAMP'),nullif(trim(r.raw->>'REGISTERED_BY'),''),'APPS_SCRIPT','APPS_SCRIPT_STOCK_20261028_001:'||r.sheet_name||':'||r.source_key
from staging.apps_script_stock_rows r
left join stock_import_people p on p.emp_id=r.raw->>'EMPLOYEE_ID'
where r.batch_id='APPS_SCRIPT_STOCK_20261028_001' and r.sheet_name='UNIFORM_LOG'
on conflict (source_key) do nothing;

-- 7. Lockers and key log -------------------------------------------------

insert into public.stock_lockers(legacy_key_id,label,locker_status,staff_id,driver_id,holder_name,assigned_at)
select r.source_key,trim(r.raw->>'LABEL'),
  case when r.raw->>'STATUS'='Assigned' then 'ASSIGNED' else 'AVAILABLE' end,
  case when r.raw->>'STATUS'='Assigned' then p.staff_id end,case when r.raw->>'STATUS'='Assigned' then p.driver_id end,
  case when r.raw->>'STATUS'='Assigned' then coalesce(p.holder_name,nullif(trim(r.raw->>'ASSIGNED_TO_NAME'),''),'Unknown') end,
  case when r.raw->>'STATUS'='Assigned' then pg_temp.stock_import_time(r.raw->>'SINCE') end
from staging.apps_script_stock_rows r
left join stock_import_people p on p.emp_id=r.raw->>'ASSIGNED_TO_ID'
where r.batch_id='APPS_SCRIPT_STOCK_20261028_001' and r.sheet_name='KEYS'
on conflict (legacy_key_id) do nothing;

insert into public.stock_locker_events(locker_id,label,locker_action,staff_id,driver_id,holder_name,notes,recorded_at,recorded_by_name,source,source_key)
select l.locker_id,l.label,upper(r.raw->>'ACTION'),p.staff_id,p.driver_id,coalesce(p.holder_name,nullif(trim(r.raw->>'EMPLOYEE'),'')),
  nullif(trim(r.raw->>'NOTES'),''),pg_temp.stock_import_time(r.raw->>'TIMESTAMP'),nullif(trim(r.raw->>'REGISTERED_BY'),''),'APPS_SCRIPT','APPS_SCRIPT_STOCK_20261028_001:'||r.sheet_name||':'||r.source_key
from staging.apps_script_stock_rows r
join public.stock_lockers l on l.legacy_key_id=r.raw->>'KEY_ID'
left join stock_import_people p on lower(p.source_name)=lower(trim(r.raw->>'EMPLOYEE'))
where r.batch_id='APPS_SCRIPT_STOCK_20261028_001' and r.sheet_name='KEY_LOG'
on conflict (source_key) do nothing;

-- 8. Mark what was promoted and what needs review -------------------------

update staging.apps_script_stock_rows r set review_status='PROMOTED' where r.batch_id='APPS_SCRIPT_STOCK_20261028_001' and r.sheet_name<>'EMPLOYEES' and r.review_status='LANDED';
update staging.apps_script_stock_rows r set review_status='REVIEW',review_reason='Person not matched; imported with the name only.'
where r.batch_id='APPS_SCRIPT_STOCK_20261028_001' and (
  (r.sheet_name='UNIFORM_LOG' and not exists(select 1 from stock_import_people p where p.emp_id=r.raw->>'EMPLOYEE_ID' and (p.staff_id is not null or p.driver_id is not null)))
  or (r.sheet_name='KEYS' and r.raw->>'STATUS'='Assigned' and not exists(select 1 from stock_import_people p where p.emp_id=r.raw->>'ASSIGNED_TO_ID' and (p.staff_id is not null or p.driver_id is not null))));

-- 9. Reconcile: every source row must have arrived ------------------------

do $$
declare v_missing text;
begin
  select string_agg(format('%s %s/%s',sheet,got,expected),', ') into v_missing from (
    select 'ITEMS' sheet,(select count(*) from staging.apps_script_stock_rows where batch_id='APPS_SCRIPT_STOCK_20261028_001' and sheet_name='ITEMS') expected,(select count(*) from public.stock_items where legacy_item_code is not null) got
    union all select 'MOVEMENTS',(select count(*) from staging.apps_script_stock_rows where batch_id='APPS_SCRIPT_STOCK_20261028_001' and sheet_name='MOVEMENTS'),(select count(*) from public.stock_movements where source_key like 'APPS_SCRIPT_STOCK_20261028_001:MOVEMENTS:%')
    union all select 'COUNTS',(select count(*) from staging.apps_script_stock_rows where batch_id='APPS_SCRIPT_STOCK_20261028_001' and sheet_name='COUNTS'),(select count(*) from public.stock_count_lines l join public.stock_count_sessions s using(session_id) where s.source='APPS_SCRIPT')
    union all select 'UNIFORM_LOG',(select count(*) from staging.apps_script_stock_rows where batch_id='APPS_SCRIPT_STOCK_20261028_001' and sheet_name='UNIFORM_LOG'),(select count(*) from public.stock_ppe_events where source_key like 'APPS_SCRIPT_STOCK_20261028_001:UNIFORM_LOG:%')
    union all select 'KEYS',(select count(*) from staging.apps_script_stock_rows where batch_id='APPS_SCRIPT_STOCK_20261028_001' and sheet_name='KEYS'),(select count(*) from public.stock_lockers where legacy_key_id is not null)
    union all select 'KEY_LOG',(select count(*) from staging.apps_script_stock_rows where batch_id='APPS_SCRIPT_STOCK_20261028_001' and sheet_name='KEY_LOG'),(select count(*) from public.stock_locker_events where source_key like 'APPS_SCRIPT_STOCK_20261028_001:KEY_LOG:%')
  ) x where got<>expected;
  if v_missing is not null then raise exception 'Stock import reconciliation failed: %',v_missing; end if;
end $$;

drop table if exists pg_temp.stock_import_people;

commit;
