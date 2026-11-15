-- =====================================================================
-- Portfolio 3, demo 5: deadlock, detection, and prevention
-- Accounts used: 401 and 402
-- =====================================================================
\ir _session_b.sql
SHOW deadlock_timeout;

\qecho
\qecho '=================================================================='
\qecho ' 5A. Deadlock: two transfers in opposite directions lock the'
\qecho '     accounts in opposite order'
\qecho '       A: locks 401, then wants 402'
\qecho '       B: locks 402, then wants 401'
\qecho '=================================================================='
BEGIN;
SELECT 'A locks 401' AS step, account_id FROM accounts WHERE account_id = 401 FOR UPDATE;

SELECT dblink_exec('B', 'BEGIN') AS b;
SELECT 'B locks 402' AS step, account_id
FROM dblink('B', 'SELECT account_id FROM accounts WHERE account_id = 402 FOR UPDATE') AS t(account_id bigint);

SELECT 'B asks for 401 and has to wait for A' AS step,
       dblink_send_query('B', 'SELECT account_id FROM accounts WHERE account_id = 401 FOR UPDATE') AS sent;
\o /dev/null
SELECT pg_sleep(0.3);
\o

\qecho '-- A now asks for 402, which B holds. Each waits for the other: a cycle.'
\qecho '-- After deadlock_timeout PostgreSQL finds the cycle and aborts one transaction.'
SELECT 'A asks for 402' AS step, account_id FROM accounts WHERE account_id = 402 FOR UPDATE;

\qecho '-- what happened to B (an error message here means B was chosen as the victim)'
SELECT * FROM dblink_get_result('B', false) AS t(account_id bigint);
SELECT dblink_error_message('B') AS session_b_error;
SELECT * FROM dblink_get_result('B', false) AS t(account_id bigint);
ROLLBACK;
SELECT dblink_exec('B', 'ROLLBACK', false) AS b;
\qecho '-- If the ERROR appeared on "A asks for 402" instead, A was the victim. Either way'
\qecho '-- exactly one transaction is aborted and the other one is able to continue.'

\qecho
\qecho '=================================================================='
\qecho ' 5B. Prevention: always lock accounts in the same order'
\qecho '     transfer_funds() locks the lower account_id first, whatever'
\qecho '     the direction of the transfer. The same two opposite transfers'
\qecho '     now queue up instead of deadlocking.'
\qecho '=================================================================='
SELECT account_id, balance FROM accounts WHERE account_id IN (401, 402) ORDER BY 1;

BEGIN;
SELECT 'A: transfer 401 -> 402 of 1,000 (not yet committed)' AS step,
       transfer_funds(401, 402, 1000, 'Demo 5B A to B') AS result;

SELECT 'B: transfer 402 -> 401 of 2,000 is sent' AS step,
       dblink_send_query('B', $$SELECT transfer_funds(402, 401, 2000, 'Demo 5B B to A')$$) AS sent;
\o /dev/null
SELECT pg_sleep(0.5);
\o

\qecho '-- B is waiting for A, but holds nothing A needs, so there is no cycle'
SELECT pid AS blocked_pid, wait_event_type, wait_event, pg_blocking_pids(pid) AS blocked_by
FROM pg_stat_activity
WHERE datname = current_database() AND wait_event_type = 'Lock';

COMMIT;
SELECT 'A commits; B is released and completes' AS step, result
FROM dblink_get_result('B') AS t(result text);
\o /dev/null
SELECT * FROM dblink_get_result('B') AS t(result text);
\o

\qecho '-- net effect: 401 is up 1,000 and 402 is down 1,000'
SELECT account_id, balance FROM accounts WHERE account_id IN (401, 402) ORDER BY 1;

\qecho
\qecho '-- consistency check: difference must be 0.00'
SELECT * FROM v_balance_reconciliation WHERE account_id IN (401, 402) ORDER BY account_id;
\o /dev/null
SELECT dblink_disconnect('B') AS session_b_closed;
\o
