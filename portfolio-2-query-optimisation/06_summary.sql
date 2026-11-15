-- =====================================================================
-- Portfolio 2 - before / after comparison (best of 5 runs each)
-- =====================================================================
SET search_path TO lagoonpay;
\pset pager off

\qecho '--- Execution time and pages touched, before and after tuning ---'
SELECT b.query_id,
       b.exec_ms  AS before_ms,
       a.exec_ms  AS after_ms,
       round(b.exec_ms / NULLIF(a.exec_ms, 0), 1) AS times_faster,
       b.buffers  AS before_pages,
       a.buffers  AS after_pages
FROM perf_results b
JOIN perf_results a ON a.query_id = b.query_id AND a.phase = 'after'
WHERE b.phase = 'before'
ORDER BY b.query_id;

\qecho '--- Access path chosen by the planner, before and after ---'
\x on
SELECT b.query_id, q.description,
       b.access_path AS before_path,
       a.access_path AS after_path
FROM perf_results b
JOIN perf_results a ON a.query_id = b.query_id AND a.phase = 'after'
JOIN perf_queries q ON q.query_id = b.query_id
WHERE b.phase = 'before'
ORDER BY b.query_id;
\x off
