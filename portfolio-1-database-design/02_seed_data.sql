-- =====================================================================
-- Portfolio 1 - sample data for LagoonPay
-- All customers are fictional. Bank names/codes are public reference data.
-- Run after 01_schema.sql:  psql -d lagoonpay_db -f 02_seed_data.sql
-- =====================================================================
SET search_path TO lagoonpay;

BEGIN;

INSERT INTO account_types (account_type_code, type_name, min_balance, daily_transfer_limit, annual_interest_rate) VALUES
('SAV', 'Savings Account',  1000.00,  1000000.00, 4.50),
('CUR', 'Current Account',     0.00,  5000000.00, 0.00),
('WAL', 'Wallet (Tier 1)',     0.00,    50000.00, 0.00);

INSERT INTO banks (bank_code, bank_name) VALUES
('011', 'First Bank of Nigeria'),
('033', 'United Bank for Africa'),
('044', 'Access Bank'),
('057', 'Zenith Bank'),
('058', 'Guaranty Trust Bank');

INSERT INTO customers (first_name, last_name, email, phone, date_of_birth, kyc_tier) VALUES
('Adaeze',   'Nwosu',     'adaeze.nwosu@example.com',    '+2348030000001', '1991-03-14', 3),
('Tunde',    'Bakare',    'tunde.bakare@example.com',    '+2348030000002', '1987-11-02', 3),
('Halima',   'Abubakar',  'halima.abubakar@example.com', '+2348030000003', '1995-07-21', 2),
('Chidi',    'Okeke',     'chidi.okeke@example.com',     '+2348030000004', '1999-01-30', 1),
('Funmilayo','Adeyemi',   'funmi.adeyemi@example.com',   '+2348030000005', '1983-09-09', 3),
('Emeka',    'Eze',       'emeka.eze@example.com',       '+2348030000006', '1990-05-17', 2),
('Zainab',   'Yusuf',     'zainab.yusuf@example.com',    '+2348030000007', '2001-12-05', 1),
('Bolaji',   'Ogunleye',  'bolaji.ogunleye@example.com', '+2348030000008', '1978-06-25', 3);

-- balance starts at 0; money only arrives through post_ledger_entry()
INSERT INTO accounts (account_number, customer_id, account_type_code) VALUES
('3010000001', 1, 'SAV'),
('3010000002', 1, 'CUR'),
('3010000003', 2, 'CUR'),
('3010000004', 3, 'SAV'),
('3010000005', 4, 'WAL'),
('3010000006', 5, 'SAV'),
('3010000007', 5, 'CUR'),
('3010000008', 6, 'CUR'),
('3010000009', 7, 'WAL'),
('3010000010', 8, 'SAV');

INSERT INTO beneficiaries (customer_id, bank_code, account_number, account_name, nickname) VALUES
(1, '058', '0123456789', 'Nwosu Stores Ltd',   'Shop'),
(2, '044', '0987654321', 'Kemi Bakare',        'Sister'),
(5, '057', '2001234567', 'Greenfield Schools', 'School fees'),
(6, '011', '3009876543', 'Ikeja Electric',     'Light bill'),
(8, '033', '1002003004', 'Ogunleye Farms',     NULL);

-- ---- Opening deposits (one CREDIT each) ------------------------------
INSERT INTO transactions (reference, txn_type, amount, status, channel, narration, completed_at) VALUES
('LGP-0000000001', 'DEPOSIT', 250000.00, 'SUCCESS', 'WEB',        'Opening deposit', now()),
('LGP-0000000002', 'DEPOSIT', 120000.00, 'SUCCESS', 'MOBILE_APP', 'Opening deposit', now()),
('LGP-0000000003', 'DEPOSIT', 800000.00, 'SUCCESS', 'WEB',        'Opening deposit', now()),
('LGP-0000000004', 'DEPOSIT',  60000.00, 'SUCCESS', 'USSD',       'Opening deposit', now()),
('LGP-0000000005', 'DEPOSIT',  15000.00, 'SUCCESS', 'MOBILE_APP', 'Wallet top-up',   now()),
('LGP-0000000006', 'DEPOSIT', 500000.00, 'SUCCESS', 'WEB',        'Opening deposit', now()),
('LGP-0000000007', 'DEPOSIT', 340000.00, 'SUCCESS', 'POS',        'Cash deposit',    now()),
('LGP-0000000008', 'DEPOSIT',  95000.00, 'SUCCESS', 'MOBILE_APP', 'Salary',          now()),
('LGP-0000000009', 'DEPOSIT',   8000.00, 'SUCCESS', 'USSD',       'Wallet top-up',   now()),
('LGP-0000000010', 'DEPOSIT', 410000.00, 'SUCCESS', 'WEB',        'Opening deposit', now());

SELECT post_ledger_entry(t.transaction_id, t.transaction_id, 'CREDIT', t.amount)
FROM transactions t
WHERE t.transaction_id BETWEEN 1 AND 10      -- deposit n funds account n
ORDER BY t.transaction_id;

-- ---- Internal transfer: Tunde (acct 3) -> Adaeze current (acct 2) ----
INSERT INTO transactions (reference, txn_type, amount, status, channel, narration, completed_at)
VALUES ('LGP-0000000011', 'TRANSFER', 75000.00, 'SUCCESS', 'MOBILE_APP', 'Rent contribution', now());
SELECT post_ledger_entry(11, 3, 'DEBIT',  75000.00);
SELECT post_ledger_entry(11, 2, 'CREDIT', 75000.00);

-- ---- External transfer to a saved beneficiary (DEBIT only) -----------
INSERT INTO transactions (reference, txn_type, amount, status, channel, beneficiary_id, narration, completed_at)
VALUES ('LGP-0000000012', 'TRANSFER', 180000.00, 'SUCCESS', 'WEB', 3, 'Second term fees', now());
SELECT post_ledger_entry(12, 7, 'DEBIT', 180000.00);

-- ---- ATM withdrawal ---------------------------------------------------
INSERT INTO transactions (reference, txn_type, amount, status, channel, narration, completed_at)
VALUES ('LGP-0000000013', 'WITHDRAWAL', 20000.00, 'SUCCESS', 'ATM', 'ATM cash', now());
SELECT post_ledger_entry(13, 8, 'DEBIT', 20000.00);

-- ---- A transfer that is later reversed --------------------------------
INSERT INTO transactions (reference, txn_type, amount, status, channel, narration, completed_at)
VALUES ('LGP-0000000014', 'TRANSFER', 30000.00, 'REVERSED', 'MOBILE_APP', 'Sent to wrong account', now());
SELECT post_ledger_entry(14, 6, 'DEBIT',  30000.00);
SELECT post_ledger_entry(14, 10, 'CREDIT', 30000.00);

INSERT INTO transactions (reference, txn_type, amount, status, channel, reverses_transaction_id, narration, completed_at)
VALUES ('LGP-0000000015', 'REVERSAL', 30000.00, 'SUCCESS', 'WEB', 14, 'Reversal of LGP-0000000014', now());
SELECT post_ledger_entry(15, 10, 'DEBIT',  30000.00);
SELECT post_ledger_entry(15, 6,  'CREDIT', 30000.00);

-- ---- A failed transfer: recorded, but no money moved ------------------
INSERT INTO transactions (reference, txn_type, amount, status, channel, narration)
VALUES ('LGP-0000000016', 'TRANSFER', 900000.00, 'FAILED', 'USSD', 'Insufficient funds');

COMMIT;
