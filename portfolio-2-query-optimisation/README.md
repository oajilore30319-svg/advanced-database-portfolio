# Portfolio 2: Query Processing and Optimisation

**Student:** Ajilore Opeyemi (301930319)
**Case study:** LagoonPay (same schema as Portfolio 1)
**Engine:** PostgreSQL 18

## 1. Aim

Take six realistic LagoonPay queries, read the execution plan PostgreSQL chooses for each, find out why it is slow, apply one tuning technique per query, and measure the difference.

## 2. Dataset

The 16 transactions from Portfolio 1 are too few for the planner to do anything but scan every table. `01_load_data.sql` rebuilds the same schema and generates a larger dataset with `generate_series` and a fixed random seed:

| Table | Rows |
|---|---|
| customers | 20,000 |
| accounts | 30,000 |
| beneficiaries | 15,000 |
| transactions | 430,000 (Jan 2025 to Oct 2026; about 94.5% SUCCESS, 5% FAILED, 0.5% PENDING) |
| ledger_entries | about 578,000 |

Two properties were built in on purpose because they matter for tuning:

- **Skew.** Accounts 1 to 20 are merchants that receive about 30% of internal transfers, so they have thousands of ledger entries while an ordinary account has about twenty.
- **Rare values.** Only about 0.5% of transactions are PENDING.

The load finishes by checking that every stored balance still equals its ledger total (0 accounts out of balance).

## 3. Method

1. The six queries are stored once in the table `perf_queries` (`02_queries.sql`), so the results, the baseline plan and the optimised plan all use exactly the same text.
2. Baseline: `EXPLAIN (ANALYZE, BUFFERS)` with only the Portfolio 1 indexes in place (`03_baseline_plans.sql`).
3. Tuning: indexes, one query rewrite and one materialized view (`04_optimise.sql`), followed by `VACUUM (ANALYZE)`.
4. Same plans again (`05_optimised_plans.sql`).
5. The function `measure()` runs each query six times, discards the first run (cold cache) and stores the best execution time, the number of 8 kB pages touched and the scan nodes in the plan. `06_summary.sql` prints the comparison.

Pages touched is reported next to time because it does not depend on how fast the machine is.

## 4. The queries and what was done

| Query | Business question | Problem in the baseline plan | Technique |
|---|---|---|---|
| Q1 | All transactions initiated on one day | Sequential scan of all 430,000 rows | B-tree index on `initiated_at` **and** a query rewrite |
| Q1c | Control: Q1 without the rewrite | Same | Index only, no rewrite |
| Q2 | Oldest 50 transactions stuck in PENDING | Sequential scan and sort to find about 0.5% of rows | Partial index |
| Q3 | Customer search by name, any letter case | Sequential scan; `lower()` on the column hides it from ordinary indexes | Expression index |
| Q4 | Last 20 statement lines of a busy merchant account | Fetches every entry of the account, sorts them, keeps 20 | Composite index (equality column, then sort column) |
| Q5 | Monthly volume and value by channel and type | Reads and aggregates nearly the whole table | Materialized view |
| Q6 | Top 10 customers by debits in a month (3-table join) | Sequential scan of the whole ledger to find one month | Covering index, index-only scan |

### Q1: sargable predicates

The first version filtered with `initiated_at::date = DATE '2026-06-15'`. Wrapping the column in a cast means PostgreSQL has to compute the cast for every row before it can compare, so an index on `initiated_at` cannot be used. The control query Q1c proves this: after the index was created its plan was still a sequential scan and its time did not change.

Rewriting the filter as a range on the bare column (`initiated_at >= '2026-06-15' AND initiated_at < '2026-06-16'`) returns the same rows and lets the planner use a bitmap index scan on `idx_txn_initiated_at`.

Lesson: an index is only half of the fix. The predicate has to be written so the index can be used.

### Q2: partial index

A full index on `status` would be poor value: three values, one of which covers 94.5% of the table. The operations team only ever asks about PENDING rows, so the index is declared with `WHERE status = 'PENDING'`. It holds only those rows, already ordered by `initiated_at`, so the query reads the first 50 index entries and stops. There is no sort step in the new plan. The index sizes in `results/04_tuning.txt` show how small it is next to the full index on the same column.

### Q3: expression index

`WHERE lower(last_name) = 'okeke'` cannot use an index on `last_name`, for the same reason as Q1. Here the expression is the requirement (case-insensitive search), so instead of rewriting the query the index is built on the expression itself: `(lower(last_name), lower(first_name))`.

### Q4: composite index and column order

The Portfolio 1 index on `ledger_entries(account_id)` finds the merchant's rows, but there are thousands of them, and all of them are fetched and sorted just to return the newest 20. The composite index `(account_id, created_at DESC)` stores each account's entries already in statement order. The plan becomes an index scan that stops after 20 rows, and the sort node disappears.

The order of columns matters: the equality column goes first and the ordering column second. Because the new index starts with `account_id`, it also serves every lookup the old single-column index served, so the old one was dropped to save space and write cost.

### Q5: when an index is the wrong tool

This report needs about 94% of the rows in the table. When a query reads most of a table, a sequential scan is the cheapest way to do it and no index will change that. The cost is in the volume of work, not in finding rows.

The answer is to do the work once. `mv_monthly_volume` stores the aggregated result (a few hundred rows) and the report reads that. The trade-off is freshness: the view shows data as of the last `REFRESH MATERIALIZED VIEW`. That is acceptable for a monthly management report and would not be acceptable for a balance. A unique index on the view allows `REFRESH ... CONCURRENTLY`, so readers are not blocked while it is rebuilt.

### Q6: covering index and join strategy

One month is under 5% of the ledger, but with no index on `created_at` the baseline scanned all of it. The new index is on `created_at` and carries `account_id`, `direction` and `amount` with `INCLUDE`. Everything the query needs from the ledger is inside the index, so the plan uses an **index-only scan** and does not visit the table. This depends on the visibility map being up to date, which is why `VACUUM` runs after the indexes are created.

The joins to `accounts` and `customers` stayed as hash joins over sequential scans in both plans. That is the right choice: the query needs a large share of both small tables, and building one hash table is cheaper than thousands of index probes. The improvement on Q6 is therefore smaller than on the other queries, because most of the remaining time is spent joining and aggregating rather than finding rows.

## 5. Results

Measured on my MacBook Pro with PostgreSQL 18. Times are the best of five warm runs. Full output is in `results/06_summary.txt`; every plan is in `results/03_baseline_plans.txt` and `results/05_optimised_plans.txt`.

| Query | Before (ms) | After (ms) | Times faster | Pages before | Pages after |
|---|---|---|---|---|---|
| Q1 | 20.488 | 0.271 | 75.6 | 6,071 | 547 |
| Q1c (control) | 20.481 | 20.183 | 1.0 | 6,071 | 6,071 |
| Q2 | 14.767 | 0.018 | 820.4 | 6,071 | 52 |
| Q3 | 4.299 | 0.018 | 238.8 | 282 | 33 |
| Q4 | 3.990 | 0.033 | 120.9 | 12,443 | 102 |
| Q5 | 297.577 | 0.106 | 2,807.3 | 5,995 | 4 |
| Q6 | 24.201 | 14.103 | 1.7 | 8,967 | 1,115 |

| Query | Access path before | Access path after |
|---|---|---|
| Q1 | Seq Scan on transactions | Bitmap Index Scan on idx_txn_initiated_at |
| Q1c (control) | Seq Scan on transactions | Seq Scan on transactions |
| Q2 | Seq Scan on transactions | Index Scan on idx_txn_pending |
| Q3 | Seq Scan on customers | Bitmap Index Scan on idx_customers_name_lower |
| Q4 | Bitmap Index Scan on idx_ledger_account, then sort | Index Scan on idx_ledger_account_created, no sort |
| Q5 | Seq Scan on transactions | Seq Scan on mv_monthly_volume |
| Q6 | Seq Scan on ledger_entries | Index Only Scan on idx_ledger_created_cover |

What the numbers show:

- **Q1 against Q1c** is the clearest result. Both ran against the same index. The rewritten query dropped from 6,071 pages to 547 and ran about 76 times faster; the version that kept the `::date` cast still read all 6,071 pages and took the same 20 ms.
- **Q2** went from reading the whole table (6,071 pages) to 52 pages, because the partial index contains only the PENDING rows in the order the query asks for.
- **Q4** shows that an index being used does not mean the plan is good. The baseline already used an index but touched 12,443 pages to return 20 rows. With the composite index it touches 102.
- **Q5** has the largest gain (about 2,800 times) and it did not come from an index. The work was moved from query time to refresh time.
- **Q6** improved the least in time (1.7 times) although pages fell from 8,967 to 1,115. Finding the month's rows is now cheap; what remains is the hash joins and the aggregation, which the index does not touch.

## 6. Cost of the tuning

Indexes are not free. Each one takes disk space (sizes are listed in `results/04_tuning.txt`) and must be updated on every insert into its table. `ledger_entries` and `transactions` are the busiest tables in a bank, so each index was justified by a specific query, one redundant index was removed, and the partial index was chosen partly because it adds almost no write cost: a row only enters it while it is PENDING.

## 7. How to run

From inside this folder:

```bash
psql -d lagoonpay_db -f run_all.sql
```

This rebuilds the schema, loads the data, runs all steps and prints the comparison. Note that it drops and recreates the `lagoonpay` schema, so the small Portfolio 1 dataset is replaced.

| File | Purpose |
|---|---|
| `01_load_data.sql` | Rebuild the schema and generate the dataset |
| `02_queries.sql` | The six queries, the `measure()` function, and the first 10 rows of each result |
| `03_baseline_plans.sql` | Execution plans before tuning |
| `04_optimise.sql` | Indexes, materialized view, VACUUM ANALYZE |
| `05_optimised_plans.sql` | Execution plans after tuning |
| `06_summary.sql` | Before and after comparison |
| `run_all.sql` | Runs all of the above and writes output to `results/` |
| `results/` | Text output of every step, including all execution plans |
| `evidence/` | Screenshots |
