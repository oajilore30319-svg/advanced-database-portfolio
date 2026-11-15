-- =====================================================================
-- MIT 8103 Advanced Database Systems - Portfolio 2
-- Case study : LagoonPay (same schema as Portfolio 1)
-- Author     : Ajilore Opeyemi (301930319)
-- Purpose    : Rebuild the Portfolio 1 schema and load a large synthetic
--              dataset so that execution plans are meaningful.
--              20,000 customers, 30,000 accounts, 430,000 transactions,
--              about 590,000 ledger entries, spread over Jan 2025 - Oct 2026.
-- Note       : This script DROPS and recreates the lagoonpay schema.
-- =====================================================================
\set ON_ERROR_STOP on
\ir ../portfolio-1-database-design/01_schema.sql
SET search_path TO lagoonpay;
SELECT setseed(0.42);          -- repeatable pseudo-random data

-- ---- reference data (same rows as Portfolio 1) ------------------------
INSERT INTO account_types VALUES
('SAV', 'Savings Account',  1000.00,  1000000.00, 4.50),
('CUR', 'Current Account',     0.00,  5000000.00, 0.00),
('WAL', 'Wallet (Tier 1)',     0.00,    50000.00, 0.00);

INSERT INTO banks VALUES
('011', 'First Bank of Nigeria'), ('033', 'United Bank for Africa'),
('044', 'Access Bank'), ('057', 'Zenith Bank'), ('058', 'Guaranty Trust Bank');

-- ---- 20,000 customers ---------------------------------------------------
INSERT INTO customers (first_name, last_name, email, phone, date_of_birth, kyc_tier, created_at)
SELECT fn, ln,
       lower(fn || '.' || ln || g) || '@example.com',
       '+234' || (8000000000 + g)::text,
       DATE '1960-01-01' + (r1 * 16400)::int,
       CASE WHEN r2 < 0.50 THEN 1 WHEN r2 < 0.85 THEN 2 ELSE 3 END,
       TIMESTAMPTZ '2023-01-01' + r3 * INTERVAL '700 days'
FROM (
    SELECT g, random() AS r1, random() AS r2, random() AS r3,
           (ARRAY['Adaeze','Tunde','Halima','Chidi','Funmilayo','Emeka','Zainab','Bolaji','Ngozi','Ibrahim',
                  'Kemi','Uche','Aisha','Segun','Amaka','Musa','Folake','Obinna','Hauwa','Dele'])[1 + floor(random() * 20)::int] AS fn,
           (ARRAY['Nwosu','Bakare','Abubakar','Okeke','Adeyemi','Eze','Yusuf','Ogunleye','Okafor','Bello',
                  'Adebayo','Nwachukwu','Suleiman','Olawale','Chukwu','Lawal','Onyeka','Danjuma','Akinola','Umeh',
                  'Balogun','Ibekwe','Garba','Oyelaran','Ekwueme'])[1 + floor(random() * 25)::int] AS ln
    FROM generate_series(1, 20000) g
) s;

-- ---- 30,000 accounts ----------------------------------------------------
-- Every customer gets one account; 10,000 customers get a second one.
-- Accounts 1-20 are "merchant" current accounts that receive a large
-- share of all transfers (a realistic skew: a few accounts are very busy).
INSERT INTO accounts (account_number, customer_id, account_type_code, opened_at)
SELECT '30' || lpad(g::text, 8, '0'),
       CASE WHEN g <= 20000 THEN g ELSE 1 + floor(random() * 20000)::int END,
       CASE WHEN g <= 20 THEN 'CUR'
            ELSE (ARRAY['SAV','SAV','CUR','WAL'])[1 + floor(random() * 4)::int] END,
       TIMESTAMPTZ '2024-12-01'
FROM generate_series(1, 30000) g;

-- ---- 15,000 saved beneficiaries ----------------------------------------
INSERT INTO beneficiaries (customer_id, bank_code, account_number, account_name, added_at)
SELECT 1 + floor(random() * 20000)::int,
       (ARRAY['011','033','044','057','058'])[1 + floor(random() * 5)::int],
       lpad(g::text, 10, '0'),
       'Beneficiary ' || g,
       TIMESTAMPTZ '2024-12-15'
FROM generate_series(1, 15000) g;

-- ---- staging table: one row per generated transaction ------------------
CREATE TEMP TABLE stg_txn AS
SELECT g AS transaction_id,
       'DEPOSIT'::varchar AS txn_type, 'SUCCESS'::varchar AS status,
       5000000.00::numeric(18,2) AS amount, 'WEB'::varchar AS channel,
       NULL::bigint AS beneficiary_id,
       TIMESTAMPTZ '2024-12-20' + g * INTERVAL '1 second' AS initiated_at,
       NULL::bigint AS src_account, g::bigint AS dst_account,
       'Opening deposit'::varchar AS narration
FROM generate_series(1, 30000) g;                       -- opening deposits

INSERT INTO stg_txn
SELECT 30000 + g,
       kind,
       CASE WHEN r_status < 0.945 THEN 'SUCCESS' WHEN r_status < 0.995 THEN 'FAILED' ELSE 'PENDING' END,
       round((500 + power(r_amount, 3) * 49500)::numeric, 2),
       (ARRAY['MOBILE_APP','MOBILE_APP','MOBILE_APP','USSD','WEB','POS','ATM'])[1 + floor(r_channel * 7)::int],
       CASE WHEN kind = 'TRANSFER' AND r_kind >= 0.80 THEN 1 + floor(r_ben * 15000)::int END,
       TIMESTAMPTZ '2025-01-01' + r_time * INTERVAL '669 days',
       CASE WHEN kind IN ('WITHDRAWAL', 'TRANSFER') THEN src END,
       CASE WHEN kind = 'DEPOSIT' THEN src
            WHEN kind = 'TRANSFER' AND r_kind < 0.80
                 THEN CASE WHEN r_merchant < 0.30 THEN 1 + floor(r_dst * 20)::int      -- merchant
                           WHEN dst = src THEN dst % 30000 + 1
                           ELSE dst END
       END,
       NULL
FROM (
    SELECT g, r_kind,
           CASE WHEN r_kind < 0.20 THEN 'DEPOSIT'
                WHEN r_kind < 0.35 THEN 'WITHDRAWAL'
                ELSE 'TRANSFER' END AS kind,          -- 0.35-0.80 internal, 0.80-1 external
           r_status, r_amount, r_channel, r_ben, r_time, r_merchant, r_dst,
           21 + floor(r_src * 29980)::int AS src,     -- merchants never send
           21 + floor(r_dst * 29980)::int AS dst
    FROM (SELECT g, random() r_kind, random() r_status, random() r_amount, random() r_channel,
                 random() r_ben, random() r_time, random() r_merchant, random() r_src, random() r_dst
          FROM generate_series(1, 400000) g) r
) s;

-- ---- transactions -------------------------------------------------------
INSERT INTO transactions (transaction_id, reference, txn_type, amount, status, channel,
                          beneficiary_id, narration, initiated_at, completed_at)
OVERRIDING SYSTEM VALUE
SELECT transaction_id, 'LGP-' || lpad(transaction_id::text, 10, '0'), txn_type, amount, status, channel,
       beneficiary_id, narration, initiated_at,
       CASE WHEN status <> 'PENDING' THEN initiated_at + INTERVAL '2 seconds' END
FROM stg_txn
ORDER BY transaction_id;

SELECT setval(pg_get_serial_sequence('lagoonpay.transactions', 'transaction_id'), 430000);

-- ---- ledger entries (successful transactions only) ---------------------
-- balance_after is a running total per account, computed with a window function.
INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, balance_after, created_at)
SELECT transaction_id, account_id, direction, amount,
       SUM(CASE direction WHEN 'CREDIT' THEN amount ELSE -amount END)
           OVER (PARTITION BY account_id ORDER BY created_at, transaction_id, direction),
       created_at
FROM (
    SELECT transaction_id, src_account AS account_id, 'DEBIT' AS direction, amount,
           initiated_at + INTERVAL '2 seconds' AS created_at
    FROM stg_txn WHERE status = 'SUCCESS' AND src_account IS NOT NULL
    UNION ALL
    SELECT transaction_id, dst_account, 'CREDIT', amount, initiated_at + INTERVAL '2 seconds'
    FROM stg_txn WHERE status = 'SUCCESS' AND dst_account IS NOT NULL
) e
ORDER BY created_at, transaction_id;

-- ---- bring stored balances in line with the ledger ---------------------
-- The audit trigger is switched off for the bulk load only, otherwise it
-- would write 30,000 meaningless audit rows.
ALTER TABLE accounts DISABLE TRIGGER trg_audit_account_change;
UPDATE accounts a
SET balance = s.bal
FROM (SELECT account_id,
             SUM(CASE direction WHEN 'CREDIT' THEN amount ELSE -amount END) AS bal
      FROM ledger_entries GROUP BY account_id) s
WHERE s.account_id = a.account_id;
ALTER TABLE accounts ENABLE TRIGGER trg_audit_account_change;

DROP TABLE stg_txn;
VACUUM (ANALYZE);              -- fresh statistics for the planner

\qecho '--- Data loaded: row counts ---'
SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM customers
UNION ALL SELECT 'accounts',       COUNT(*) FROM accounts
UNION ALL SELECT 'beneficiaries',  COUNT(*) FROM beneficiaries
UNION ALL SELECT 'transactions',   COUNT(*) FROM transactions
UNION ALL SELECT 'ledger_entries', COUNT(*) FROM ledger_entries;

\qecho '--- Accounts whose stored balance differs from the ledger (must be 0) ---'
SELECT COUNT(*) AS accounts_out_of_balance FROM v_balance_reconciliation WHERE difference <> 0;

\qecho '--- Table sizes ---'
SELECT relname AS table_name,
       pg_size_pretty(pg_table_size(oid))   AS table_size,
       pg_size_pretty(pg_indexes_size(oid)) AS index_size
FROM pg_class
WHERE relnamespace = 'lagoonpay'::regnamespace AND relkind = 'r'
ORDER BY pg_table_size(oid) DESC;
