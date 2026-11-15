-- =====================================================================
-- Portfolio 1 - constraint tests
-- Each block attempts something the design must refuse. A test PASSES
-- when PostgreSQL raises the expected error. Nothing is left behind.
-- Run with:  psql -d lagoonpay_db -f 03_constraint_tests.sql
-- =====================================================================
SET search_path TO lagoonpay;
\set VERBOSITY terse

DO $$
BEGIN
    -- T1 entity integrity: duplicate email
    BEGIN
        INSERT INTO customers (first_name, last_name, email, phone, date_of_birth)
        VALUES ('Dup', 'Email', 'adaeze.nwosu@example.com', '+2348039999991', '1990-01-01');
        RAISE NOTICE 'T1 FAIL: duplicate email was accepted';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'T1 PASS: duplicate email rejected (UNIQUE)';
    END;

    -- T2 domain: badly formed phone number
    BEGIN
        INSERT INTO customers (first_name, last_name, email, phone, date_of_birth)
        VALUES ('Bad', 'Phone', 'bad.phone@example.com', '08030000000', '1990-01-01');
        RAISE NOTICE 'T2 FAIL: bad phone was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'T2 PASS: phone not in +234XXXXXXXXXX format rejected (CHECK)';
    END;

    -- T3 referential integrity: account for a customer that does not exist
    BEGIN
        INSERT INTO accounts (account_number, customer_id, account_type_code)
        VALUES ('3019999999', 9999, 'SAV');
        RAISE NOTICE 'T3 FAIL: orphan account was accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'T3 PASS: account without a customer rejected (FOREIGN KEY)';
    END;

    -- T4 business rule: overdraft
    BEGIN
        UPDATE accounts SET balance = balance - 999999999 WHERE account_id = 5;
        RAISE NOTICE 'T4 FAIL: negative balance was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'T4 PASS: negative balance rejected (CHECK balance >= 0)';
    END;

    -- T5 domain: zero-amount transaction
    BEGIN
        INSERT INTO transactions (reference, txn_type, amount, channel)
        VALUES ('LGP-TEST-T5', 'DEPOSIT', 0, 'WEB');
        RAISE NOTICE 'T5 FAIL: zero amount was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'T5 PASS: zero amount rejected (CHECK amount > 0)';
    END;

    -- T6 cross-column rule: a REVERSAL must name the transaction it reverses
    BEGIN
        INSERT INTO transactions (reference, txn_type, amount, channel)
        VALUES ('LGP-TEST-T6', 'REVERSAL', 500, 'WEB');
        RAISE NOTICE 'T6 FAIL: reversal without a target was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'T6 PASS: reversal without a target rejected (chk_reversal_link)';
    END;

    -- T7 a transaction can only be reversed once (14 is already reversed by 15)
    BEGIN
        INSERT INTO transactions (reference, txn_type, amount, channel, reverses_transaction_id)
        VALUES ('LGP-TEST-T7', 'REVERSAL', 30000, 'WEB', 14);
        RAISE NOTICE 'T7 FAIL: second reversal was accepted';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'T7 PASS: second reversal of the same transaction rejected (UNIQUE)';
    END;

    -- T8 composite key: same payee saved twice by the same customer
    BEGIN
        INSERT INTO beneficiaries (customer_id, bank_code, account_number, account_name)
        VALUES (1, '058', '0123456789', 'Nwosu Stores Ltd');
        RAISE NOTICE 'T8 FAIL: duplicate beneficiary was accepted';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'T8 PASS: duplicate beneficiary rejected (composite UNIQUE)';
    END;

    -- T9 delete rule: customer who still owns accounts
    BEGIN
        DELETE FROM customers WHERE customer_id = 1;
        RAISE NOTICE 'T9 FAIL: customer with accounts was deleted';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'T9 PASS: customer with accounts cannot be deleted (ON DELETE RESTRICT)';
    END;

    -- T10 trigger: ledger history cannot be edited
    BEGIN
        UPDATE ledger_entries SET amount = 1 WHERE entry_id = 1;
        RAISE NOTICE 'T10 FAIL: ledger entry was edited';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'T10 PASS: ledger edit blocked (append-only trigger)';
    END;

    -- T11 posting function: frozen account refuses postings
    BEGIN
        UPDATE accounts SET status = 'FROZEN' WHERE account_id = 9;
        PERFORM post_ledger_entry(9, 9, 'DEBIT', 100);
        RAISE NOTICE 'T11 FAIL: posting to a frozen account was accepted';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'T11 PASS: posting to a frozen account refused (post_ledger_entry)';
    END;
END;
$$;

-- T12 reconciliation: stored balance must equal the ledger for every account
SELECT CASE WHEN COUNT(*) = 0
            THEN 'T12 PASS: all stored balances match the ledger'
            ELSE 'T12 FAIL: ' || COUNT(*) || ' account(s) out of balance'
       END AS reconciliation
FROM v_balance_reconciliation
WHERE difference <> 0;
