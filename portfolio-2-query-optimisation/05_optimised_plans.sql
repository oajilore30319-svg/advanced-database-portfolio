-- =====================================================================
-- Portfolio 2 - execution plans AFTER tuning (same queries, or the
-- rewritten version where 02_queries.sql defines one).
-- =====================================================================
SET search_path TO lagoonpay;
\pset pager off

SELECT format('SELECT %L AS optimised_plan', query_id || ': ' || description) || E';\n'
    || 'EXPLAIN (ANALYZE, BUFFERS) ' || sql_after
FROM perf_queries
ORDER BY query_id
\gexec

SELECT measure('after');
