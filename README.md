# Advanced Database Systems Portfolio

**Student:** Ajilore Opeyemi (301930319)
**Programme:** Master of Information Technology, Miva Open University
**Course:** MIT 8103 Advanced Database Systems, 2026/2027 first semester

## Case study: LagoonPay

LagoonPay is a simulated Nigerian digital bank. Customers hold savings, current and wallet accounts and move money through a mobile app, the web, USSD, POS and ATMs. The database stores customers, accounts, beneficiaries, transactions, ledger entries and an audit trail, and supports deposits, withdrawals, transfers, reversals and balance reconciliation. The full description is in [Portfolio 1](portfolio-1-database-design/README.md).

## Contents

| Folder | Activity | Status |
|---|---|---|
| [portfolio-1-database-design](portfolio-1-database-design/) | ER diagram, relational schema, keys, constraints, normalisation | Done |
| [portfolio-2-query-optimisation](portfolio-2-query-optimisation/) | SQL queries, execution plans, indexing | Done |
| [portfolio-3-transactions-concurrency](portfolio-3-transactions-concurrency/) | Commit, rollback, isolation levels, locking | Done |
| [portfolio-4-nosql](portfolio-4-nosql/) | MongoDB document model of the same case study | Done |
| [portfolio-5-distributed-cloud](portfolio-5-distributed-cloud/) | Replication, failover, sharding, consistency, cloud design | Done |

## Tools

PostgreSQL 18 (with `dblink`), `psql`, MongoDB Community 9.0.8 (`mongod`, `mongos`, `mongosh`), Mermaid for diagrams, Git and GitHub.

## How to run

Each folder has its own README with exact commands. In order:

1. `portfolio-1-database-design`: run the four SQL files with `psql -d lagoonpay_db -f <file>`.
2. `portfolio-2-query-optimisation`: `psql -d lagoonpay_db -f run_all.sql` (rebuilds the schema and loads the large dataset).
3. `portfolio-3-transactions-concurrency`: `sh run_all.sh`.
4. `portfolio-4-nosql`: `sh run_all.sh` (needs MongoDB running).
5. `portfolio-5-distributed-cloud`: `sh run_all.sh` (needs Portfolio 4 to have been run).

Every folder contains `results/` (text output of each step, including execution plans) and `evidence/` (screenshots from my machine).

## AI use declaration

I selected the case study and technology stack, ran every script on my own MacBook (PostgreSQL 18, MongoDB 9.0.8), and produced all outputs and screenshots myself; the results tables report figures from my own runs. I used Claude (Anthropic) to draft the scripts and documentation and to troubleshoot errors. I verified the output by executing and re-running it, reporting failures on my versions until they were corrected, and reviewing the documentation so that I can explain the design and results.
