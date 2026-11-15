-- =====================================================================
-- MIT 8103 Advanced Database Systems - Portfolio 3
-- Case study : LagoonPay
-- Author     : Ajilore Opeyemi (301930319)
-- Purpose    : Helper functions used by the transaction and concurrency
--              demonstrations. Needs the Portfolio 2 dataset to be loaded.
-- =====================================================================
SET search_path TO lagoonpay, public;

-- dblink lets one psql script open a SECOND real database connection.
-- In the demos the script itself is "session A" and the dblink
-- connection is "session B", so two concurrent users can be shown in
-- one repeatable run.
CREATE EXTENSION IF NOT EXISTS dblink WITH SCHEMA public;

-- Next transaction id and its reference, e.g. LGP-0000430001
CREATE OR REPLACE FUNCTION next_txn_id() RETURNS BIGINT
LANGUAGE sql AS $$
    SELECT nextval(pg_get_serial_sequence('lagoonpay.transactions', 'transaction_id'));
$$;

-- ---- deposit: one transaction row + one CREDIT ledger line -----------
CREATE OR REPLACE FUNCTION deposit(p_account BIGINT, p_amount NUMERIC, p_narration VARCHAR DEFAULT 'Deposit')
RETURNS NUMERIC
LANGUAGE plpgsql SET search_path = lagoonpay, public AS $$
DECLARE
    v_id BIGINT := next_txn_id();
BEGIN
    INSERT INTO transactions (transaction_id, reference, txn_type, amount, status, channel, narration, completed_at)
    OVERRIDING SYSTEM VALUE
    VALUES (v_id, 'LGP-' || lpad(v_id::text, 10, '0'), 'DEPOSIT', p_amount, 'SUCCESS', 'MOBILE_APP', p_narration, clock_timestamp());
    RETURN post_ledger_entry(v_id, p_account, 'CREDIT', p_amount);
END;
$$;

-- ---- withdraw: one transaction row + one DEBIT ledger line -----------
CREATE OR REPLACE FUNCTION withdraw(p_account BIGINT, p_amount NUMERIC, p_narration VARCHAR DEFAULT 'Withdrawal')
RETURNS NUMERIC
LANGUAGE plpgsql SET search_path = lagoonpay, public AS $$
DECLARE
    v_id BIGINT := next_txn_id();
BEGIN
    INSERT INTO transactions (transaction_id, reference, txn_type, amount, status, channel, narration, completed_at)
    OVERRIDING SYSTEM VALUE
    VALUES (v_id, 'LGP-' || lpad(v_id::text, 10, '0'), 'WITHDRAWAL', p_amount, 'SUCCESS', 'ATM', p_narration, clock_timestamp());
    RETURN post_ledger_entry(v_id, p_account, 'DEBIT', p_amount);
END;
$$;

-- ---- transfer_funds: the production-style transfer --------------------
-- * Locks both accounts in ascending account_id order, so two transfers
--   in opposite directions can never deadlock (see demo 5).
-- * The money movement runs in an inner block. If a business rule fails
--   (insufficient funds, frozen account) the inner block is rolled back
--   and a FAILED transaction row is recorded instead, so the customer and
--   the support team can see what happened.
-- * Serialization failures and deadlocks are NOT caught: the caller is
--   expected to retry those.
CREATE OR REPLACE FUNCTION transfer_funds(p_from BIGINT, p_to BIGINT, p_amount NUMERIC, p_narration VARCHAR DEFAULT 'Transfer')
RETURNS TEXT
LANGUAGE plpgsql SET search_path = lagoonpay, public AS $$
DECLARE
    v_id   BIGINT := next_txn_id();
    v_ref  TEXT   := 'LGP-' || lpad(v_id::text, 10, '0');
    v_err  TEXT;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'amount must be positive';
    END IF;

    BEGIN                                            -- inner block = implicit savepoint
        IF p_from = p_to THEN
            RAISE EXCEPTION 'cannot transfer to the same account';
        END IF;

        PERFORM 1 FROM accounts
        WHERE account_id IN (p_from, p_to)
        ORDER BY account_id
        FOR UPDATE;                                  -- consistent lock order

        INSERT INTO transactions (transaction_id, reference, txn_type, amount, status, channel, narration, completed_at)
        OVERRIDING SYSTEM VALUE
        VALUES (v_id, v_ref, 'TRANSFER', p_amount, 'SUCCESS', 'MOBILE_APP', p_narration, clock_timestamp());

        PERFORM post_ledger_entry(v_id, p_from, 'DEBIT',  p_amount);
        PERFORM post_ledger_entry(v_id, p_to,   'CREDIT', p_amount);
        RETURN v_ref || ' SUCCESS';
    EXCEPTION WHEN check_violation OR raise_exception THEN
        GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
        INSERT INTO transactions (transaction_id, reference, txn_type, amount, status, channel, narration, completed_at)
        OVERRIDING SYSTEM VALUE
        VALUES (v_id, v_ref, 'TRANSFER', p_amount, 'FAILED', 'MOBILE_APP', left(v_err, 140), clock_timestamp());
        RETURN v_ref || ' FAILED: ' || v_err;
    END;
END;
$$;

-- ---- reset_balances: put stored balances back in line with the ledger
-- Some demos deliberately write accounts.balance directly to reproduce
-- a bug. This restores the affected accounts afterwards.
CREATE OR REPLACE FUNCTION reset_balances(VARIADIC p_accounts BIGINT[]) RETURNS void
LANGUAGE sql SET search_path = lagoonpay, public AS $$
    UPDATE accounts a
    SET balance = (SELECT COALESCE(SUM(CASE direction WHEN 'CREDIT' THEN amount ELSE -amount END), 0)
                   FROM ledger_entries l WHERE l.account_id = a.account_id)
    WHERE a.account_id = ANY (p_accounts);
$$;

\qecho '--- Setup complete. Dataset check (should be 30000 accounts) ---'
SELECT COUNT(*) AS accounts FROM accounts;
