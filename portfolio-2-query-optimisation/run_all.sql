-- =====================================================================
-- Portfolio 2 - run everything in order.
-- Run from inside the portfolio-2-query-optimisation folder:
--     psql -d lagoonpay_db -f run_all.sql
-- Long output is written to the results/ folder; the final comparison
-- is also printed on screen.
-- =====================================================================
\set ON_ERROR_STOP on
\echo 'Step 1 of 6: rebuilding schema and loading data (about a minute)...'
\o results/01_data_load.txt
\ir 01_load_data.sql
\echo 'Step 2 of 6: running the six queries...'
\o results/02_query_results.txt
\ir 02_queries.sql
\echo 'Step 3 of 6: baseline execution plans...'
\o results/03_baseline_plans.txt
\ir 03_baseline_plans.sql
\echo 'Step 4 of 6: creating indexes and materialized view...'
\o results/04_tuning.txt
\ir 04_optimise.sql
\echo 'Step 5 of 6: optimised execution plans...'
\o results/05_optimised_plans.txt
\ir 05_optimised_plans.sql
\echo 'Step 6 of 6: summary'
\o results/06_summary.txt
\ir 06_summary.sql
\o
\ir 06_summary.sql
\echo 'Done. Full output is in the results folder.'
