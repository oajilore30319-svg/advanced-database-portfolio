-- =====================================================================
-- Portfolio 2 - the workload
-- Six business queries are stored in a table so that exactly the same
-- text is used for the results, the baseline plans and the optimised
-- plans. sql_before is the first version of the query; sql_after is the
-- version used after tuning (identical unless the query was rewritten).
-- =====================================================================
SET search_path TO lagoonpay;

DROP TABLE IF EXISTS perf_results;
DROP TABLE IF EXISTS perf_queries;

CREATE TABLE perf_queries (
    query_id     TEXT PRIMARY KEY,
    description  TEXT NOT NULL,
    sql_before   TEXT NOT NULL,
    sql_after    TEXT NOT NULL
);

CREATE TABLE perf_results (
    query_id     TEXT REFERENCES perf_queries,
    phase        TEXT CHECK (phase IN ('before', 'after')),
    exec_ms      NUMERIC(12,3) NOT NULL,     -- best of 5 runs
    buffers      BIGINT NOT NULL,            -- 8 kB pages touched (hit + read)
    access_path  TEXT NOT NULL,              -- scan nodes found in the plan
    PRIMARY KEY (query_id, phase)
);

-- ---- Q1: all transactions initiated on one day (support / dispute desk)
INSERT INTO perf_queries VALUES ('Q1', 'Transactions initiated on 15 June 2026',
$q$SELECT transaction_id, reference, txn_type, amount, status, initiated_at
FROM transactions
WHERE initiated_at::date = DATE '2026-06-15'
ORDER BY initiated_at$q$,
$q$SELECT transaction_id, reference, txn_type, amount, status, initiated_at
FROM transactions
WHERE initiated_at >= TIMESTAMPTZ '2026-06-15'
  AND initiated_at <  TIMESTAMPTZ '2026-06-16'
ORDER BY initiated_at$q$);

-- ---- Q1c: control. Same as Q1 but NOT rewritten, to show that the new
--      index alone does not help while the column is wrapped in a cast.
INSERT INTO perf_queries VALUES ('Q1c', 'Control: Q1 left with the ::date cast',
$q$SELECT transaction_id, reference, txn_type, amount, status, initiated_at
FROM transactions
WHERE initiated_at::date = DATE '2026-06-15'
ORDER BY initiated_at$q$,
$q$SELECT transaction_id, reference, txn_type, amount, status, initiated_at
FROM transactions
WHERE initiated_at::date = DATE '2026-06-15'
ORDER BY initiated_at$q$);

-- ---- Q2: oldest transactions still stuck in PENDING (operations queue)
INSERT INTO perf_queries VALUES ('Q2', 'Oldest 50 transactions stuck in PENDING',
$q$SELECT transaction_id, reference, txn_type, amount, channel, initiated_at
FROM transactions
WHERE status = 'PENDING'
  AND initiated_at < TIMESTAMPTZ '2026-10-30'
ORDER BY initiated_at
LIMIT 50$q$,
$q$SELECT transaction_id, reference, txn_type, amount, channel, initiated_at
FROM transactions
WHERE status = 'PENDING'
  AND initiated_at < TIMESTAMPTZ '2026-10-30'
ORDER BY initiated_at
LIMIT 50$q$);

-- ---- Q3: case-insensitive customer search by name (call centre)
INSERT INTO perf_queries VALUES ('Q3', 'Find customers named Chidi Okeke, any letter case',
$q$SELECT customer_id, first_name, last_name, email, phone
FROM customers
WHERE lower(last_name) = 'okeke' AND lower(first_name) = 'chidi'
ORDER BY customer_id$q$,
$q$SELECT customer_id, first_name, last_name, email, phone
FROM customers
WHERE lower(last_name) = 'okeke' AND lower(first_name) = 'chidi'
ORDER BY customer_id$q$);

-- ---- Q4: mini-statement, last 20 entries of a very busy merchant account
INSERT INTO perf_queries VALUES ('Q4', 'Last 20 ledger entries of merchant account 3000000007',
$q$SELECT t.reference, t.txn_type, l.direction, l.amount, l.balance_after, l.created_at
FROM ledger_entries l
JOIN transactions t ON t.transaction_id = l.transaction_id
WHERE l.account_id = (SELECT account_id FROM accounts WHERE account_number = '3000000007')
ORDER BY l.created_at DESC
LIMIT 20$q$,
$q$SELECT t.reference, t.txn_type, l.direction, l.amount, l.balance_after, l.created_at
FROM ledger_entries l
JOIN transactions t ON t.transaction_id = l.transaction_id
WHERE l.account_id = (SELECT account_id FROM accounts WHERE account_number = '3000000007')
ORDER BY l.created_at DESC
LIMIT 20$q$);

-- ---- Q5: monthly volume and value by channel and type (management report)
INSERT INTO perf_queries VALUES ('Q5', 'Monthly successful volume and value by channel and type',
$q$SELECT date_trunc('month', initiated_at) AS month, channel, txn_type,
       COUNT(*) AS txn_count, SUM(amount) AS total_value
FROM transactions
WHERE status = 'SUCCESS'
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3$q$,
$q$SELECT month, channel, txn_type, txn_count, total_value
FROM mv_monthly_volume
ORDER BY month, channel, txn_type$q$);

-- ---- Q6: top 10 customers by money sent out in September 2026 (3-table join)
INSERT INTO perf_queries VALUES ('Q6', 'Top 10 customers by total debits in September 2026',
$q$SELECT c.customer_id, c.first_name, c.last_name,
       COUNT(*) AS debit_count, SUM(l.amount) AS total_debited
FROM ledger_entries l
JOIN accounts  a ON a.account_id  = l.account_id
JOIN customers c ON c.customer_id = a.customer_id
WHERE l.direction = 'DEBIT'
  AND l.created_at >= TIMESTAMPTZ '2026-09-01'
  AND l.created_at <  TIMESTAMPTZ '2026-10-01'
GROUP BY c.customer_id
ORDER BY total_debited DESC
LIMIT 10$q$,
$q$SELECT c.customer_id, c.first_name, c.last_name,
       COUNT(*) AS debit_count, SUM(l.amount) AS total_debited
FROM ledger_entries l
JOIN accounts  a ON a.account_id  = l.account_id
JOIN customers c ON c.customer_id = a.customer_id
WHERE l.direction = 'DEBIT'
  AND l.created_at >= TIMESTAMPTZ '2026-09-01'
  AND l.created_at <  TIMESTAMPTZ '2026-10-01'
GROUP BY c.customer_id
ORDER BY total_debited DESC
LIMIT 10$q$);

-- ---------------------------------------------------------------------
-- measure(): runs EXPLAIN ANALYZE on every stored query for one phase
-- and records the best execution time of 5 runs, the pages touched and
-- the scan nodes the planner chose.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION measure(p_phase TEXT) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    q       RECORD;
    v_sql   TEXT;
    j       JSONB;
    v_ms    NUMERIC;
    v_best  NUMERIC;
    v_buf   BIGINT;
    v_path  TEXT;
BEGIN
    FOR q IN SELECT * FROM lagoonpay.perf_queries ORDER BY query_id LOOP
        v_sql  := CASE p_phase WHEN 'before' THEN q.sql_before ELSE q.sql_after END;
        v_best := NULL;
        FOR i IN 1..6 LOOP                              -- run 1 only warms the cache
            EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || v_sql INTO j;
            v_ms := (j -> 0 ->> 'Execution Time')::numeric;
            IF i > 1 AND (v_best IS NULL OR v_ms < v_best) THEN
                v_best := v_ms;
            END IF;
        END LOOP;

        v_buf := COALESCE((j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint, 0)
               + COALESCE((j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint, 0);

        SELECT string_agg(DISTINCT
                   (n ->> 'Node Type') || ' on ' || COALESCE(n ->> 'Index Name', n ->> 'Relation Name'),
                   '; ')
        INTO v_path
        FROM jsonb_path_query(j, '$.**') AS n
        WHERE jsonb_typeof(n) = 'object'
          AND n ? 'Node Type'
          AND n ->> 'Node Type' LIKE '%Scan%'
          AND n ->> 'Node Type' <> 'Bitmap Heap Scan';

        INSERT INTO lagoonpay.perf_results VALUES (q.query_id, p_phase, v_best, v_buf, v_path)
        ON CONFLICT (query_id, phase) DO UPDATE
            SET exec_ms = EXCLUDED.exec_ms, buffers = EXCLUDED.buffers, access_path = EXCLUDED.access_path;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- Query results (first 10 rows of each) as evidence that the queries
-- return sensible answers.
-- ---------------------------------------------------------------------
\pset pager off
SELECT format('SELECT %L AS query', query_id || ': ' || description) || E';\n'
    || format('SELECT * FROM (%s) AS result LIMIT 10', sql_before)
FROM perf_queries
WHERE query_id <> 'Q1c'
ORDER BY query_id
\gexec
