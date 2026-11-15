-- =====================================================================
-- Portfolio 3, demo 1: COMMIT, ROLLBACK, SAVEPOINT (atomicity, durability)
-- Accounts used: 101 (sender), 102-105 (receivers)
-- =====================================================================
SET search_path TO lagoonpay, public;
\pset pager off
SELECT to_char(clock_timestamp(), 'YYMMDD-HH24MISS') AS run \gset

\qecho
\qecho '=================================================================='
\qecho ' 1A. COMMIT: a transfer is one atomic unit of three statements'
\qecho '=================================================================='
\qecho '-- balances before'
SELECT account_id, account_number, balance FROM accounts WHERE account_id IN (101, 102) ORDER BY 1;

BEGIN;
INSERT INTO transactions (reference, txn_type, amount, status, channel, narration, completed_at)
VALUES ('P3-' || :'run' || '-1A', 'TRANSFER', 25000, 'SUCCESS', 'MOBILE_APP', 'Demo 1A committed transfer', clock_timestamp())
RETURNING transaction_id AS txn_1a \gset
SELECT post_ledger_entry(:txn_1a, 101, 'DEBIT',  25000) AS sender_balance;
SELECT post_ledger_entry(:txn_1a, 102, 'CREDIT', 25000) AS receiver_balance;
COMMIT;

\qecho '-- balances after COMMIT: 25,000 has moved from 101 to 102'
SELECT account_id, account_number, balance FROM accounts WHERE account_id IN (101, 102) ORDER BY 1;
\qecho '-- the two ledger lines written by the transaction'
SELECT entry_id, transaction_id, account_id, direction, amount, balance_after
FROM ledger_entries WHERE transaction_id = :txn_1a ORDER BY entry_id;

\qecho
\qecho '=================================================================='
\qecho ' 1B. Explicit ROLLBACK: the user cancels before confirming'
\qecho '=================================================================='
BEGIN;
INSERT INTO transactions (reference, txn_type, amount, status, channel, narration, completed_at)
VALUES ('P3-' || :'run' || '-1B', 'TRANSFER', 40000, 'SUCCESS', 'MOBILE_APP', 'Demo 1B cancelled transfer', clock_timestamp())
RETURNING transaction_id AS txn_1b \gset
SELECT post_ledger_entry(:txn_1b, 101, 'DEBIT',  40000) AS sender_balance;
SELECT post_ledger_entry(:txn_1b, 102, 'CREDIT', 40000) AS receiver_balance;
\qecho '-- inside the transaction the new balances are visible to this session'
SELECT account_id, balance FROM accounts WHERE account_id IN (101, 102) ORDER BY 1;
ROLLBACK;

\qecho '-- after ROLLBACK: balances are back to the 1A values and no row was kept'
SELECT account_id, balance FROM accounts WHERE account_id IN (101, 102) ORDER BY 1;
SELECT COUNT(*) AS rows_kept_from_1b FROM transactions WHERE reference = 'P3-' || :'run' || '-1B';

\qecho
\qecho '=================================================================='
\qecho ' 1C. Automatic rollback: an error in the middle undoes everything'
\qecho '     The receiver is credited first, then the debit breaks the'
\qecho '     no-overdraft rule. The credit must not survive.'
\qecho '=================================================================='
BEGIN;
INSERT INTO transactions (reference, txn_type, amount, status, channel, narration, completed_at)
VALUES ('P3-' || :'run' || '-1C', 'TRANSFER', 900000000, 'SUCCESS', 'MOBILE_APP', 'Demo 1C overdraft attempt', clock_timestamp())
RETURNING transaction_id AS txn_1c \gset
SELECT post_ledger_entry(:txn_1c, 102, 'CREDIT', 900000000) AS receiver_balance_inside_txn;
\qecho '-- the next statement is expected to fail with a CHECK violation'
SELECT post_ledger_entry(:txn_1c, 101, 'DEBIT',  900000000) AS sender_balance;
\qecho '-- the transaction is now aborted; PostgreSQL refuses further work in it'
SELECT account_id, balance FROM accounts WHERE account_id IN (101, 102);
\qecho '-- COMMIT on an aborted transaction is turned into ROLLBACK'
COMMIT;

\qecho '-- balances unchanged: the 900,000,000 credit was undone'
SELECT account_id, balance FROM accounts WHERE account_id IN (101, 102) ORDER BY 1;

\qecho
\qecho '=================================================================='
\qecho ' 1D. SAVEPOINT: partial rollback inside a batch'
\qecho '     Three payouts from 101. The second goes to a frozen account.'
\qecho '     Only that one is undone; the other two are committed.'
\qecho '=================================================================='
UPDATE accounts SET status = 'FROZEN' WHERE account_id = 104;
SELECT account_id, balance, status FROM accounts WHERE account_id IN (101, 103, 104, 105) ORDER BY 1;

BEGIN;
SELECT withdraw(101, 10000, 'Demo 1D payout 1 out') AS sender_balance;
SELECT deposit (103, 10000, 'Demo 1D payout 1 in')  AS receiver_103;

SAVEPOINT before_payout_2;
SELECT withdraw(101, 10000, 'Demo 1D payout 2 out') AS sender_balance;
\qecho '-- the next statement is expected to fail: account 104 is frozen'
SELECT deposit (104, 10000, 'Demo 1D payout 2 in')  AS receiver_104;
ROLLBACK TO SAVEPOINT before_payout_2;

SELECT withdraw(101, 10000, 'Demo 1D payout 3 out') AS sender_balance;
SELECT deposit (105, 10000, 'Demo 1D payout 3 in')  AS receiver_105;
COMMIT;

\qecho '-- 101 is down 20,000 (not 30,000); 103 and 105 are up 10,000; 104 is untouched'
SELECT account_id, balance, status FROM accounts WHERE account_id IN (101, 103, 104, 105) ORDER BY 1;
UPDATE accounts SET status = 'ACTIVE' WHERE account_id = 104;

\qecho
\qecho '=================================================================='
\qecho ' 1E. transfer_funds(): the same logic packaged as one function'
\qecho '=================================================================='
\qecho '-- a normal transfer'
SELECT transfer_funds(101, 102, 5000, 'Demo 1E good transfer') AS result;
\qecho '-- a transfer that is too large: money does not move, a FAILED row is recorded'
SELECT transfer_funds(101, 102, 900000000, 'Demo 1E too large') AS result;
SELECT transaction_id, reference, amount, status, narration
FROM transactions ORDER BY transaction_id DESC LIMIT 2;

\qecho
\qecho '=================================================================='
\qecho ' 1F. Durability: a commit is written to the write-ahead log (WAL)'
\qecho '=================================================================='
SHOW synchronous_commit;
SELECT pg_current_wal_lsn() AS wal_before \gset
SELECT transfer_funds(101, 102, 1000, 'Demo 1F durability') AS result;
SELECT :'wal_before'::pg_lsn AS wal_position_before,
       pg_current_wal_lsn()  AS wal_position_after,
       pg_current_wal_lsn() - :'wal_before'::pg_lsn AS wal_bytes_written;

\qecho
\qecho '-- consistency check for the accounts used: difference must be 0.00'
SELECT * FROM v_balance_reconciliation WHERE account_id BETWEEN 101 AND 105 ORDER BY account_id;
