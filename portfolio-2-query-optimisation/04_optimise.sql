-- =====================================================================
-- Portfolio 2 - the tuning. One technique per problem found in the
-- baseline plans.
-- =====================================================================
SET search_path TO lagoonpay;
\pset pager off

-- Q1: B-tree on the timestamp. Only useful together with the query
--     rewrite (range predicate instead of a cast on the column).
CREATE INDEX idx_txn_initiated_at ON transactions (initiated_at);

-- Q2: PARTIAL index. Only about 0.5% of rows are PENDING, so the index
--     holds just those rows, already sorted the way the query wants them.
CREATE INDEX idx_txn_pending ON transactions (initiated_at) WHERE status = 'PENDING';

-- Q3: EXPRESSION index, so that lower(...) = '...' can be answered from an index.
CREATE INDEX idx_customers_name_lower ON customers (lower(last_name), lower(first_name));

-- Q4: COMPOSITE index. Equality column first, then the sort column, so the
--     newest 20 rows of an account are read straight off the index with no sort.
CREATE INDEX idx_ledger_account_created ON ledger_entries (account_id, created_at DESC);
--     The old single-column index is now redundant: the new one starts
--     with the same column. Dropping it saves space and write cost.
DROP INDEX idx_ledger_account;

-- Q5: MATERIALIZED VIEW. The report reads almost every row, so no index
--     can make it cheap. The answer is pre-computed instead.
CREATE MATERIALIZED VIEW mv_monthly_volume AS
SELECT date_trunc('month', initiated_at) AS month, channel, txn_type,
       COUNT(*) AS txn_count, SUM(amount) AS total_value
FROM transactions
WHERE status = 'SUCCESS'
GROUP BY 1, 2, 3;
--     A unique index allows REFRESH MATERIALIZED VIEW CONCURRENTLY
--     (readers are not blocked while the view is rebuilt).
CREATE UNIQUE INDEX uq_mv_monthly_volume ON mv_monthly_volume (month, channel, txn_type);

-- Q6: COVERING index. Every ledger column the query needs is in the
--     index, so PostgreSQL can use an index-only scan and skip the table.
CREATE INDEX idx_ledger_created_cover ON ledger_entries (created_at)
    INCLUDE (account_id, direction, amount);

VACUUM (ANALYZE);   -- updates statistics and the visibility map (needed for index-only scans)

\qecho '--- Indexes after tuning, with size ---'
SELECT c.relname AS index_name, t.relname AS on_table,
       pg_size_pretty(pg_relation_size(c.oid)) AS index_size
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
WHERE c.relnamespace = 'lagoonpay'::regnamespace
  AND c.relname LIKE ANY (ARRAY['idx_%', 'uq_mv_%'])
ORDER BY pg_relation_size(c.oid) DESC;
