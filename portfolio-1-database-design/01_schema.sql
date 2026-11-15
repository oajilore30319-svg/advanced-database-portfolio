-- =====================================================================
-- MIT 8103 Advanced Database Systems - Portfolio 1
-- Case study : LagoonPay (simulated Nigerian digital bank / fintech)
-- Author     : Ajilore Opeyemi (301930319)
-- Engine     : PostgreSQL 16
-- Purpose    : Relational schema with keys, constraints and triggers
-- Run with   : psql -d lagoonpay_db -f 01_schema.sql
-- =====================================================================

DROP SCHEMA IF EXISTS lagoonpay CASCADE;
CREATE SCHEMA lagoonpay;
SET search_path TO lagoonpay;

-- ---------------------------------------------------------------------
-- 1. Reference tables
-- ---------------------------------------------------------------------

-- Product catalogue. Limits live here (not on each account) so that a
-- change to a product rule is made in exactly one row (3NF).
CREATE TABLE account_types (
    account_type_code     CHAR(3)        PRIMARY KEY,
    type_name             VARCHAR(40)    NOT NULL UNIQUE,
    min_balance           NUMERIC(18,2)  NOT NULL DEFAULT 0 CHECK (min_balance >= 0),
    daily_transfer_limit  NUMERIC(18,2)  NOT NULL CHECK (daily_transfer_limit > 0),
    annual_interest_rate  NUMERIC(5,2)   NOT NULL DEFAULT 0
                          CHECK (annual_interest_rate BETWEEN 0 AND 100)
);

-- Other banks that customers can send money to.
CREATE TABLE banks (
    bank_code  CHAR(3)       PRIMARY KEY CHECK (bank_code ~ '^[0-9]{3}$'),
    bank_name  VARCHAR(80)   NOT NULL UNIQUE
);

-- ---------------------------------------------------------------------
-- 2. Core entities
-- ---------------------------------------------------------------------

CREATE TABLE customers (
    customer_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name     VARCHAR(50)   NOT NULL,
    last_name      VARCHAR(50)   NOT NULL,
    email          VARCHAR(120)  NOT NULL UNIQUE
                   CHECK (email ~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$'),
    phone          VARCHAR(14)   NOT NULL UNIQUE
                   CHECK (phone ~ '^\+234[0-9]{10}$'),
    date_of_birth  DATE          NOT NULL,
    kyc_tier       SMALLINT      NOT NULL DEFAULT 1 CHECK (kyc_tier BETWEEN 1 AND 3),
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TABLE accounts (
    account_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_number     CHAR(10)       NOT NULL UNIQUE
                       CHECK (account_number ~ '^[0-9]{10}$'),
    customer_id        BIGINT         NOT NULL
                       REFERENCES customers (customer_id) ON DELETE RESTRICT,
    account_type_code  CHAR(3)        NOT NULL
                       REFERENCES account_types (account_type_code) ON UPDATE CASCADE,
    currency           CHAR(3)        NOT NULL DEFAULT 'NGN'
                       CHECK (currency IN ('NGN', 'USD', 'GBP')),
    balance            NUMERIC(18,2)  NOT NULL DEFAULT 0
                       CHECK (balance >= 0),            -- no overdrafts
    status             VARCHAR(10)    NOT NULL DEFAULT 'ACTIVE'
                       CHECK (status IN ('ACTIVE', 'FROZEN', 'CLOSED')),
    opened_at          TIMESTAMPTZ    NOT NULL DEFAULT now()
);

-- Saved payees at other banks.
CREATE TABLE beneficiaries (
    beneficiary_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     BIGINT        NOT NULL
                    REFERENCES customers (customer_id) ON DELETE CASCADE,
    bank_code       CHAR(3)       NOT NULL REFERENCES banks (bank_code),
    account_number  CHAR(10)      NOT NULL CHECK (account_number ~ '^[0-9]{10}$'),
    account_name    VARCHAR(100)  NOT NULL,
    nickname        VARCHAR(40),
    added_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    -- a customer cannot save the same payee twice
    CONSTRAINT uq_beneficiary UNIQUE (customer_id, bank_code, account_number)
);

-- ---------------------------------------------------------------------
-- 3. Money movement
-- ---------------------------------------------------------------------

-- One row per business event (a deposit, a withdrawal, a transfer...).
CREATE TABLE transactions (
    transaction_id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reference                VARCHAR(30)    NOT NULL UNIQUE,
    txn_type                 VARCHAR(12)    NOT NULL
                             CHECK (txn_type IN ('DEPOSIT', 'WITHDRAWAL', 'TRANSFER', 'REVERSAL')),
    amount                   NUMERIC(18,2)  NOT NULL CHECK (amount > 0),
    status                   VARCHAR(10)    NOT NULL DEFAULT 'PENDING'
                             CHECK (status IN ('PENDING', 'SUCCESS', 'FAILED', 'REVERSED')),
    channel                  VARCHAR(12)    NOT NULL
                             CHECK (channel IN ('MOBILE_APP', 'USSD', 'WEB', 'POS', 'ATM')),
    beneficiary_id           BIGINT         REFERENCES beneficiaries (beneficiary_id),
    reverses_transaction_id  BIGINT         UNIQUE      -- a transaction is reversed at most once
                             REFERENCES transactions (transaction_id),
    narration                VARCHAR(140),
    initiated_at             TIMESTAMPTZ    NOT NULL DEFAULT now(),
    completed_at             TIMESTAMPTZ,
    CONSTRAINT chk_completed_after_initiated
        CHECK (completed_at IS NULL OR completed_at >= initiated_at),
    -- only a REVERSAL points at another transaction, and it must do so
    CONSTRAINT chk_reversal_link
        CHECK ((txn_type = 'REVERSAL') = (reverses_transaction_id IS NOT NULL)),
    -- only transfers can go to a saved external payee
    CONSTRAINT chk_beneficiary_only_on_transfer
        CHECK (beneficiary_id IS NULL OR txn_type = 'TRANSFER')
);

-- One row per account touched by a transaction.
-- Deposit = 1 CREDIT, withdrawal = 1 DEBIT, internal transfer = 1 DEBIT + 1 CREDIT.
CREATE TABLE ledger_entries (
    entry_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id  BIGINT         NOT NULL
                    REFERENCES transactions (transaction_id) ON DELETE RESTRICT,
    account_id      BIGINT         NOT NULL
                    REFERENCES accounts (account_id) ON DELETE RESTRICT,
    direction       VARCHAR(6)     NOT NULL CHECK (direction IN ('DEBIT', 'CREDIT')),
    amount          NUMERIC(18,2)  NOT NULL CHECK (amount > 0),
    balance_after   NUMERIC(18,2)  NOT NULL CHECK (balance_after >= 0),
    created_at      TIMESTAMPTZ    NOT NULL DEFAULT now(),
    -- the same transaction cannot debit (or credit) the same account twice
    CONSTRAINT uq_ledger_line UNIQUE (transaction_id, account_id, direction)
);

-- Who changed a balance or status, and when.
CREATE TABLE audit_log (
    audit_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id   BIGINT         NOT NULL REFERENCES accounts (account_id),
    old_balance  NUMERIC(18,2)  NOT NULL,
    new_balance  NUMERIC(18,2)  NOT NULL,
    old_status   VARCHAR(10)    NOT NULL,
    new_status   VARCHAR(10)    NOT NULL,
    changed_by   TEXT           NOT NULL DEFAULT current_user,
    changed_at   TIMESTAMPTZ    NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 4. Indexes on foreign keys
--    PostgreSQL indexes PRIMARY KEY and UNIQUE columns automatically but
--    NOT foreign keys. Further tuning is done in Portfolio 2.
-- ---------------------------------------------------------------------
CREATE INDEX idx_accounts_customer    ON accounts (customer_id);
CREATE INDEX idx_ledger_account       ON ledger_entries (account_id);
CREATE INDEX idx_audit_account        ON audit_log (account_id);

-- ---------------------------------------------------------------------
-- 5. Triggers
-- ---------------------------------------------------------------------

-- 5a. Every balance or status change on an account is written to audit_log.
CREATE FUNCTION fn_audit_account_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (account_id, old_balance, new_balance, old_status, new_status)
    VALUES (OLD.account_id, OLD.balance, NEW.balance, OLD.status, NEW.status);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_account_change
AFTER UPDATE OF balance, status ON accounts
FOR EACH ROW
WHEN (OLD.balance IS DISTINCT FROM NEW.balance OR OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION fn_audit_account_change();

-- 5b. The ledger is append-only: history must never be edited or deleted.
CREATE FUNCTION fn_ledger_is_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'ledger_entries is append-only: % is not allowed', TG_OP;
END;
$$;

CREATE TRIGGER trg_ledger_is_immutable
BEFORE UPDATE OR DELETE ON ledger_entries
FOR EACH ROW EXECUTE FUNCTION fn_ledger_is_immutable();

-- ---------------------------------------------------------------------
-- 6. Posting function
--    The only supported way to move money on an account. It locks the
--    account row, checks status, changes the balance and writes the
--    ledger line with the resulting balance, all in the caller's
--    transaction.
-- ---------------------------------------------------------------------
CREATE FUNCTION post_ledger_entry(
    p_transaction_id BIGINT,
    p_account_id     BIGINT,
    p_direction      VARCHAR,
    p_amount         NUMERIC
) RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_status      VARCHAR(10);
    v_new_balance NUMERIC(18,2);
BEGIN
    SELECT status INTO v_status
    FROM accounts WHERE account_id = p_account_id
    FOR UPDATE;                                   -- row lock until commit/rollback

    IF NOT FOUND THEN
        RAISE EXCEPTION 'account % does not exist', p_account_id;
    ELSIF v_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'account % is %, posting refused', p_account_id, v_status;
    END IF;

    UPDATE accounts
    SET balance = balance + CASE p_direction WHEN 'CREDIT' THEN p_amount ELSE -p_amount END
    WHERE account_id = p_account_id
    RETURNING balance INTO v_new_balance;         -- CHECK (balance >= 0) stops overdrafts here

    INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, balance_after)
    VALUES (p_transaction_id, p_account_id, p_direction, p_amount, v_new_balance);

    RETURN v_new_balance;
END;
$$;

-- ---------------------------------------------------------------------
-- 7. Reconciliation view ("audit account balances")
--    balance is stored for speed, so this view proves it still equals
--    the sum of the ledger. difference must be 0 for every account.
-- ---------------------------------------------------------------------
CREATE VIEW v_balance_reconciliation AS
SELECT a.account_id,
       a.account_number,
       a.balance                                        AS stored_balance,
       COALESCE(SUM(CASE l.direction WHEN 'CREDIT' THEN l.amount
                                     ELSE -l.amount END), 0) AS ledger_balance,
       a.balance - COALESCE(SUM(CASE l.direction WHEN 'CREDIT' THEN l.amount
                                                 ELSE -l.amount END), 0) AS difference
FROM accounts a
LEFT JOIN ledger_entries l ON l.account_id = a.account_id
GROUP BY a.account_id, a.account_number, a.balance;
