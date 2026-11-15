-- =====================================================================
-- Portfolio 2 - baseline: execution plans BEFORE any tuning.
-- Only the Portfolio 1 indexes exist (primary keys, unique keys and the
-- three foreign-key indexes).
-- =====================================================================
SET search_path TO lagoonpay;
\pset pager off

SELECT format('SELECT %L AS baseline_plan', query_id || ': ' || description) || E';\n'
    || 'EXPLAIN (ANALYZE, BUFFERS) ' || sql_before
FROM perf_queries
ORDER BY query_id
\gexec

SELECT measure('before');
