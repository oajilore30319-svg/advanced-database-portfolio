-- =====================================================================
-- Portfolio 3, demo 2: isolation levels
-- Session A = this script. Session B = second connection (dblink).
-- Account used: 201
-- =====================================================================
\ir _session_b.sql

\qecho
\qecho '=================================================================='
\qecho ' 2A. Dirty read is impossible in PostgreSQL'
\qecho '     B deposits 50,000 but has NOT committed. A asks for READ'
\qecho '     UNCOMMITTED and still sees only committed data.'
\qecho '=================================================================='
SELECT 'A' AS session, balance FROM accounts WHERE account_id = 201;

SELECT dblink_exec('B', 'BEGIN') AS b;
SELECT 'B' AS session, new_balance AS balance_seen_by_b_uncommitted
FROM dblink('B', $$SELECT deposit(201, 50000, 'Demo 2A deposit')$$) AS t(new_balance numeric);

BEGIN TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SELECT 'A' AS session, balance AS balance_seen_by_a, 'B has not committed' AS note
FROM accounts WHERE account_id = 201;
COMMIT;

SELECT dblink_exec('B', 'COMMIT') AS b;
SELECT 'A' AS session, balance AS balance_seen_by_a, 'B has committed' AS note
FROM accounts WHERE account_id = 201;

\qecho
\qecho '=================================================================='
\qecho ' 2B. READ COMMITTED (the default): non-repeatable read and phantom'
\qecho '     A reads the same data twice in ONE transaction. B commits a'
\qecho '     deposit in between. A gets two different answers.'
\qecho '=================================================================='
BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;
SELECT 'A first read' AS step, a.balance,
       (SELECT COUNT(*) FROM ledger_entries l WHERE l.account_id = 201) AS ledger_rows
FROM accounts a WHERE a.account_id = 201;

SELECT 'B commits a deposit of 50,000' AS step, new_balance
FROM dblink('B', $$SELECT deposit(201, 50000, 'Demo 2B deposit')$$) AS t(new_balance numeric);

SELECT 'A second read, same transaction' AS step, a.balance,
       (SELECT COUNT(*) FROM ledger_entries l WHERE l.account_id = 201) AS ledger_rows
FROM accounts a WHERE a.account_id = 201;
COMMIT;
\qecho '-- balance changed (non-repeatable read) and a new ledger row appeared (phantom)'

\qecho
\qecho '=================================================================='
\qecho ' 2C. REPEATABLE READ: A works from a snapshot'
\qecho '     Same steps as 2B. A now gets the same answer both times.'
\qecho '=================================================================='
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT 'A first read' AS step, a.balance,
       (SELECT COUNT(*) FROM ledger_entries l WHERE l.account_id = 201) AS ledger_rows
FROM accounts a WHERE a.account_id = 201;

SELECT 'B commits a deposit of 50,000' AS step, new_balance
FROM dblink('B', $$SELECT deposit(201, 50000, 'Demo 2C deposit')$$) AS t(new_balance numeric);

SELECT 'A second read, same transaction' AS step, a.balance,
       (SELECT COUNT(*) FROM ledger_entries l WHERE l.account_id = 201) AS ledger_rows
FROM accounts a WHERE a.account_id = 201;
COMMIT;

SELECT 'A after its own COMMIT' AS step, a.balance,
       (SELECT COUNT(*) FROM ledger_entries l WHERE l.account_id = 201) AS ledger_rows
FROM accounts a WHERE a.account_id = 201;
\qecho '-- inside the transaction nothing moved; the deposit only shows after A commits'

\qecho
\qecho '=================================================================='
\qecho ' 2D. REPEATABLE READ refuses to write over a change it cannot see'
\qecho '     A reads, B commits a deposit, A then tries to withdraw.'
\qecho '     PostgreSQL aborts A instead of letting it use a stale balance.'
\qecho '=================================================================='
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT 'A reads' AS step, balance FROM accounts WHERE account_id = 201;

SELECT 'B commits a deposit of 50,000' AS step, new_balance
FROM dblink('B', $$SELECT deposit(201, 50000, 'Demo 2D deposit')$$) AS t(new_balance numeric);

\qecho '-- the next statement is expected to fail: could not serialize access due to concurrent update'
SELECT withdraw(201, 10000, 'Demo 2D withdrawal') AS balance_after_withdrawal;
ROLLBACK;

\qecho '-- the application simply retries in a new transaction, which now sees the deposit'
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT withdraw(201, 10000, 'Demo 2D withdrawal (retry)') AS balance_after_withdrawal;
COMMIT;

\qecho
\qecho '-- consistency check: difference must be 0.00'
SELECT * FROM v_balance_reconciliation WHERE account_id = 201;
\o /dev/null
SELECT dblink_disconnect('B') AS session_b_closed;
\o
