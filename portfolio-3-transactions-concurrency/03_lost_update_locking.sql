-- =====================================================================
-- Portfolio 3, demo 3: the lost update problem and three ways to stop it
-- Two ATM withdrawals hit account 301 at the same moment:
--   session A takes 30,000, session B takes 20,000.
-- The correct final balance is the starting balance minus 50,000.
-- These demos write accounts.balance directly, the way a naive
-- application would ("read the balance, subtract, write it back").
-- =====================================================================
\ir _session_b.sql
\o /dev/null
SELECT reset_balances(301);
\o

\qecho
\qecho '=================================================================='
\qecho ' 3A. The problem: read, calculate in the application, write back'
\qecho '=================================================================='
SELECT balance AS start_bal FROM accounts WHERE account_id = 301 \gset
SELECT :start_bal AS starting_balance, :start_bal - 50000 AS correct_final_balance;

BEGIN;
SELECT balance AS a_read FROM accounts WHERE account_id = 301 \gset
SELECT 'A reads' AS step, :a_read AS balance;

SELECT dblink_exec('B', 'BEGIN') AS b;
SELECT balance AS b_read FROM dblink('B', 'SELECT balance FROM accounts WHERE account_id = 301') AS t(balance numeric) \gset
SELECT 'B reads' AS step, :b_read AS balance;

UPDATE accounts SET balance = :a_read - 30000 WHERE account_id = 301;
COMMIT;
SELECT 'A writes its result and commits' AS step, balance FROM accounts WHERE account_id = 301;

SELECT dblink_exec('B', format('UPDATE accounts SET balance = %s WHERE account_id = 301', :b_read - 20000)) AS b;
SELECT dblink_exec('B', 'COMMIT') AS b;
SELECT 'B writes its result and commits' AS step, balance FROM accounts WHERE account_id = 301;

SELECT balance AS final_balance, :start_bal - 50000 AS correct_balance,
       balance - (:start_bal - 50000) AS money_created_by_the_bug
FROM accounts WHERE account_id = 301;
\qecho '-- A''s withdrawal of 30,000 has been overwritten: 50,000 left the ATM, only 20,000 left the account'

\o /dev/null
SELECT reset_balances(301);
\o

\qecho
\qecho '=================================================================='
\qecho ' 3B. Fix 1, pessimistic locking: SELECT ... FOR UPDATE'
\qecho '     A locks the row when it reads. B has to wait for A to finish,'
\qecho '     and then reads the balance A left behind.'
\qecho '=================================================================='
BEGIN;
SELECT balance AS a_read FROM accounts WHERE account_id = 301 FOR UPDATE \gset
SELECT 'A reads FOR UPDATE (row is now locked)' AS step, :a_read AS balance;

SELECT dblink_exec('B', 'BEGIN') AS b;
SELECT dblink_send_query('B', 'SELECT balance FROM accounts WHERE account_id = 301 FOR UPDATE') AS b_query_sent;
\o /dev/null
SELECT pg_sleep(0.5);
\o

\qecho '-- B is blocked: PostgreSQL shows it waiting on a lock held by A'
SELECT pid AS blocked_pid, wait_event_type, wait_event, state,
       pg_blocking_pids(pid) AS blocked_by, pg_backend_pid() AS session_a_pid,
       left(query, 62) AS waiting_query
FROM pg_stat_activity
WHERE datname = current_database() AND wait_event_type = 'Lock';

UPDATE accounts SET balance = :a_read - 30000 WHERE account_id = 301;
COMMIT;
SELECT 'A writes and commits (lock released)' AS step, balance FROM accounts WHERE account_id = 301;

SELECT balance AS b_read FROM dblink_get_result('B') AS t(balance numeric) \gset
\o /dev/null
SELECT * FROM dblink_get_result('B') AS t(balance numeric);
\o
SELECT 'B is released and reads the NEW balance' AS step, :b_read AS balance;

SELECT dblink_exec('B', format('UPDATE accounts SET balance = %s WHERE account_id = 301', :b_read - 20000)) AS b;
SELECT dblink_exec('B', 'COMMIT') AS b;

SELECT balance AS final_balance, :start_bal - 50000 AS correct_balance,
       balance - (:start_bal - 50000) AS difference
FROM accounts WHERE account_id = 301;

\o /dev/null
SELECT reset_balances(301);
\o

\qecho
\qecho '=================================================================='
\qecho ' 3C. Fix 2, optimistic check: only write if nobody changed the row'
\qecho '     No lock is held while the user thinks. B''s update carries the'
\qecho '     balance it read; it matches 0 rows, so B knows it must retry.'
\qecho '=================================================================='
SELECT balance AS a_read FROM accounts WHERE account_id = 301 \gset
SELECT balance AS b_read FROM dblink('B', 'SELECT balance FROM accounts WHERE account_id = 301') AS t(balance numeric) \gset

UPDATE accounts SET balance = :a_read - 30000 WHERE account_id = 301 AND balance = :a_read;
SELECT 'A writes first (1 row updated)' AS step, balance FROM accounts WHERE account_id = 301;

SELECT 'B writes with its stale balance' AS step,
       dblink_exec('B', format('UPDATE accounts SET balance = %s WHERE account_id = 301 AND balance = %s',
                               :b_read - 20000, :b_read)) AS b_result_update_0_means_conflict_detected;

\qecho '-- B retries: reads again, then writes'
SELECT balance AS b_read FROM dblink('B', 'SELECT balance FROM accounts WHERE account_id = 301') AS t(balance numeric) \gset
SELECT 'B retry' AS step,
       dblink_exec('B', format('UPDATE accounts SET balance = %s WHERE account_id = 301 AND balance = %s',
                               :b_read - 20000, :b_read)) AS b_result;

SELECT balance AS final_balance, :start_bal - 50000 AS correct_balance,
       balance - (:start_bal - 50000) AS difference
FROM accounts WHERE account_id = 301;

\o /dev/null
SELECT reset_balances(301);
\o

\qecho
\qecho '=================================================================='
\qecho ' 3D. Fix 3, let the database do the arithmetic (what LagoonPay uses)'
\qecho '     withdraw() runs UPDATE ... SET balance = balance - amount under'
\qecho '     a row lock, so there is no stale value to write back. Both'
\qecho '     withdrawals also get proper transaction and ledger rows.'
\qecho '=================================================================='
SELECT 'A withdraws 30,000' AS step, withdraw(301, 30000, 'Demo 3D ATM A') AS balance;
SELECT 'B withdraws 20,000' AS step, new_balance AS balance
FROM dblink('B', $$SELECT withdraw(301, 20000, 'Demo 3D ATM B')$$) AS t(new_balance numeric);

SELECT balance AS final_balance, :start_bal - 50000 AS correct_balance,
       balance - (:start_bal - 50000) AS difference
FROM accounts WHERE account_id = 301;

\qecho
\qecho '-- consistency check: difference must be 0.00'
SELECT * FROM v_balance_reconciliation WHERE account_id = 301;
\o /dev/null
SELECT dblink_disconnect('B') AS session_b_closed;
\o
