-- Portfolio 1 - quick look at what was built (use for screenshots)
SET search_path TO lagoonpay;

\echo '--- Tables ---'
\dt lagoonpay.*

\echo '--- Row counts ---'
SELECT 'customers' AS table_name, COUNT(*) FROM customers
UNION ALL SELECT 'accounts',       COUNT(*) FROM accounts
UNION ALL SELECT 'beneficiaries',  COUNT(*) FROM beneficiaries
UNION ALL SELECT 'transactions',   COUNT(*) FROM transactions
UNION ALL SELECT 'ledger_entries', COUNT(*) FROM ledger_entries
UNION ALL SELECT 'audit_log',      COUNT(*) FROM audit_log;

\echo '--- Constraints declared ---'
SELECT conrelid::regclass AS table_name,
       CASE contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'f' THEN 'FOREIGN KEY'
                    WHEN 'u' THEN 'UNIQUE'      WHEN 'c' THEN 'CHECK' END AS kind,
       COUNT(*) AS how_many
FROM pg_constraint
WHERE connamespace = 'lagoonpay'::regnamespace
GROUP BY 1, 2 ORDER BY 1, 2;

\echo '--- Balance reconciliation (difference must be 0) ---'
SELECT * FROM v_balance_reconciliation ORDER BY account_id;

\echo '--- Statement for account 3010000002 ---'
SELECT t.reference, t.txn_type, l.direction, l.amount, l.balance_after, t.narration
FROM ledger_entries l
JOIN transactions t USING (transaction_id)
JOIN accounts a     USING (account_id)
WHERE a.account_number = '3010000002'
ORDER BY l.entry_id;
