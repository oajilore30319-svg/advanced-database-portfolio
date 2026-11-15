-- =====================================================================
-- Portfolio 3, demo 4: write skew and SERIALIZABLE
-- Business rule: a customer who holds two accounts must keep a COMBINED
-- balance of at least 6,000,000 (for example, collateral for a loan).
-- Two sessions each check the rule, then each withdraws 3,000,000 from
-- a DIFFERENT account. Each withdrawal is fine alone; together they
-- break the rule. No row is updated by both, so row locks cannot help.
-- =====================================================================
\ir _session_b.sql

-- pick a customer with exactly two ordinary accounts holding roughly 10,000,000 in total
SELECT customer_id AS cust, MIN(account_id) AS acc1, MAX(account_id) AS acc2
FROM accounts
GROUP BY customer_id
HAVING COUNT(*) = 2 AND MIN(account_id) > 1000
   AND SUM(balance) BETWEEN 9500000 AND 11500000
ORDER BY customer_id LIMIT 1 \gset

\qecho
\qecho '=================================================================='
\qecho ' 4A. REPEATABLE READ allows write skew'
\qecho '=================================================================='
SELECT account_id, balance, SUM(balance) OVER () AS combined_balance, 6000000 AS required_minimum
FROM accounts WHERE customer_id = :cust ORDER BY account_id;

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT 'A checks the rule' AS step, SUM(balance) AS combined, SUM(balance) - 3000000 >= 6000000 AS withdrawal_allowed
FROM accounts WHERE customer_id = :cust;

SELECT dblink_exec('B', 'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ') AS b;
SELECT 'B checks the rule' AS step, combined, combined - 3000000 >= 6000000 AS withdrawal_allowed
FROM dblink('B', format('SELECT SUM(balance) FROM accounts WHERE customer_id = %s', :cust)) AS t(combined numeric);

SELECT 'A withdraws 3,000,000 from account ' || :acc1 AS step, withdraw(:acc1, 3000000, 'Demo 4A session A') AS balance;
SELECT 'B withdraws 3,000,000 from account ' || :acc2 AS step, new_balance AS balance
FROM dblink('B', format($$SELECT withdraw(%s, 3000000, 'Demo 4A session B')$$, :acc2)) AS t(new_balance numeric);

COMMIT;
SELECT dblink_exec('B', 'COMMIT') AS b_commit;

SELECT 'both committed' AS step, SUM(balance) AS combined_balance, 6000000 AS required_minimum,
       SUM(balance) >= 6000000 AS rule_still_holds
FROM accounts WHERE customer_id = :cust;
\qecho '-- the rule is broken although each transaction checked it'

\qecho '-- put the money back before the next run'
SELECT deposit(:acc1, 3000000, 'Demo 4A restore') AS acc1_balance, deposit(:acc2, 3000000, 'Demo 4A restore') AS acc2_balance;

\qecho
\qecho '=================================================================='
\qecho ' 4B. SERIALIZABLE detects it: the second transaction is aborted'
\qecho '=================================================================='
BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SELECT 'A checks the rule' AS step, SUM(balance) AS combined, SUM(balance) - 3000000 >= 6000000 AS withdrawal_allowed
FROM accounts WHERE customer_id = :cust;

SELECT dblink_exec('B', 'BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE') AS b;
SELECT 'B checks the rule' AS step, combined, combined - 3000000 >= 6000000 AS withdrawal_allowed
FROM dblink('B', format('SELECT SUM(balance) FROM accounts WHERE customer_id = %s', :cust)) AS t(combined numeric);

SELECT 'A withdraws 3,000,000 from account ' || :acc1 AS step, withdraw(:acc1, 3000000, 'Demo 4B session A') AS balance;
SELECT 'A commits' AS step;
COMMIT;

\qecho '-- B now tries the same thing; PostgreSQL is expected to refuse (SQLSTATE 40001)'
SELECT 'B withdraws 3,000,000 from account ' || :acc2 AS step,
       dblink_exec('B', format($$SELECT withdraw(%s, 3000000, 'Demo 4B session B')$$, :acc2), false) AS b_withdraw_result;
SELECT 'B commits' AS step, dblink_exec('B', 'COMMIT', false) AS b_commit_result_rollback_means_aborted;

SELECT 'final' AS step, SUM(balance) AS combined_balance, 6000000 AS required_minimum,
       SUM(balance) >= 6000000 AS rule_still_holds
FROM accounts WHERE customer_id = :cust;
\qecho '-- only A''s withdrawal went through. B would retry, see the new total and be declined.'

\qecho '-- put the money back'
SELECT deposit(:acc1, 3000000, 'Demo 4B restore') AS acc1_balance;

\qecho
\qecho '-- consistency check: difference must be 0.00'
SELECT * FROM v_balance_reconciliation WHERE account_id IN (:acc1, :acc2) ORDER BY account_id;
\o /dev/null
SELECT dblink_disconnect('B') AS session_b_closed;
\o
