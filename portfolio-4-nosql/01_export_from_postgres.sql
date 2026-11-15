-- =====================================================================
-- MIT 8103 Advanced Database Systems - Portfolio 4
-- Case study : LagoonPay
-- Author     : Ajilore Opeyemi (301930319)
-- Purpose    : Turn relational LagoonPay data into documents.
--              PostgreSQL does the joins once and writes one JSON
--              document per line (MongoDB Extended JSON), which
--              02_load_data.js then loads into MongoDB.
-- Scope      : the first 2,000 customers, their accounts and
--              beneficiaries, and every ledger entry on those accounts.
-- Output     : data/customers.json, data/activity.json
-- =====================================================================
SET search_path TO lagoonpay, public;
\pset pager off
\pset tuples_only on
\pset format unaligned

-- Extended JSON helpers so that MongoDB receives real dates and exact decimals
CREATE FUNCTION pg_temp.ej_date(ts timestamptz) RETURNS json LANGUAGE sql AS $$
    SELECT json_build_object('$date', to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
$$;
CREATE FUNCTION pg_temp.ej_dec(n numeric) RETURNS json LANGUAGE sql AS $$
    SELECT json_build_object('$numberDecimal', n::text);
$$;

-- ---------------------------------------------------------------------
-- customers: one document per customer with accounts and beneficiaries
-- EMBEDDED. Four relational tables become one document.
-- The kyc sub-document has a different shape for each KYC tier.
-- ---------------------------------------------------------------------
\o data/customers.json
SELECT json_strip_nulls(json_build_object(
    '_id',         c.customer_id,
    'name',        json_build_object('first', c.first_name, 'last', c.last_name),
    'email',       c.email,
    'phone',       c.phone,
    'dateOfBirth', pg_temp.ej_date(c.date_of_birth::timestamp AT TIME ZONE 'UTC'),
    'kyc',         json_build_object(
                       'tier', c.kyc_tier,
                       'documents',
                           CASE c.kyc_tier
                           WHEN 1 THEN json_build_array(
                               json_build_object('type', 'PHONE', 'verified', true))
                           WHEN 2 THEN json_build_array(
                               json_build_object('type', 'PHONE', 'verified', true),
                               json_build_object('type', 'NIN', 'last4', lpad(((c.customer_id * 7919) % 10000)::text, 4, '0')))
                           ELSE json_build_array(
                               json_build_object('type', 'PHONE', 'verified', true),
                               json_build_object('type', 'NIN', 'last4', lpad(((c.customer_id * 7919) % 10000)::text, 4, '0')),
                               json_build_object('type', 'UTILITY_BILL', 'issuer', 'Electricity distribution company',
                                                 'issuedOn', pg_temp.ej_date(c.created_at - INTERVAL '30 days')))
                           END),
    'address',     CASE WHEN c.kyc_tier = 3 THEN json_build_object(      -- only tier 3 customers have one
                       'city',  (ARRAY['Lagos','Abuja','Ibadan','Port Harcourt','Kano','Enugu','Benin City','Osogbo'])[1 + c.customer_id % 8],
                       'country', 'NG') END,
    'accounts',    (SELECT json_agg(json_build_object(
                               'accountId',     a.account_id,
                               'accountNumber', a.account_number,
                               'type',          json_build_object('code', t.account_type_code, 'name', t.type_name),
                               'currency',      a.currency,
                               'balance',       pg_temp.ej_dec(a.balance),
                               'status',        a.status,
                               'openedAt',      pg_temp.ej_date(a.opened_at)) ORDER BY a.account_id)
                    FROM accounts a JOIN account_types t USING (account_type_code)
                    WHERE a.customer_id = c.customer_id),
    'beneficiaries', COALESCE((SELECT json_agg(json_build_object(
                               'bankCode',      b.bank_code,
                               'bankName',      k.bank_name,
                               'accountNumber', b.account_number,
                               'accountName',   b.account_name,
                               'nickname',      b.nickname) ORDER BY b.beneficiary_id)
                    FROM beneficiaries b JOIN banks k USING (bank_code)
                    WHERE b.customer_id = c.customer_id), '[]'::json),
    'createdAt',   pg_temp.ej_date(c.created_at)
))::text
FROM customers c
WHERE c.customer_id <= 2000
ORDER BY c.customer_id;

-- ---------------------------------------------------------------------
-- activity: one document per ledger entry (one line of a statement),
-- with everything the mobile app shows already inside it: the
-- transaction, the counterparty, and channel-specific details in "meta".
-- "meta" has different fields for ATM, POS, USSD, app and web.
-- ---------------------------------------------------------------------
\o data/activity.json
SELECT json_strip_nulls(json_build_object(
    '_id',           l.entry_id,
    'txnId',         t.transaction_id,
    'reference',     t.reference,
    'accountId',     a.account_id,
    'accountNumber', a.account_number,
    'customerId',    a.customer_id,
    'type',          t.txn_type,
    'direction',     l.direction,
    'amount',        pg_temp.ej_dec(l.amount),
    'balanceAfter',  pg_temp.ej_dec(l.balance_after),
    'channel',       t.channel,
    'narration',     t.narration,
    'counterparty',  CASE
                       WHEN o.account_id IS NOT NULL THEN json_build_object(
                            'kind', 'INTERNAL',
                            'accountNumber', o.account_number,
                            'name', o.first_name || ' ' || o.last_name)
                       WHEN b.beneficiary_id IS NOT NULL THEN json_build_object(
                            'kind', 'EXTERNAL',
                            'bankCode', b.bank_code,
                            'bankName', k.bank_name,
                            'accountNumber', b.account_number,
                            'name', b.account_name)
                     END,
    'meta',          CASE t.channel
                       WHEN 'ATM' THEN json_build_object(
                            'terminalId', 'ATM-' || lpad((t.transaction_id % 400)::text, 4, '0'),
                            'location',   (ARRAY['Lagos','Abuja','Ibadan','Port Harcourt','Kano','Enugu','Benin City','Osogbo'])[1 + t.transaction_id % 8],
                            'cardLast4',  lpad(((t.transaction_id * 7919) % 10000)::text, 4, '0'))
                       WHEN 'POS' THEN json_build_object(
                            'terminalId',   'POS-' || lpad((t.transaction_id % 900)::text, 5, '0'),
                            'merchantName', (ARRAY['Corner Pharmacy','City Supermarket','Mainland Fuel Station','Campus Bookshop','Island Restaurant'])[1 + t.transaction_id % 5],
                            'merchantCategory', (ARRAY['HEALTH','GROCERY','FUEL','EDUCATION','DINING'])[1 + t.transaction_id % 5])
                       WHEN 'USSD' THEN json_build_object(
                            'network',   (ARRAY['Network A','Network B','Network C','Network D'])[1 + t.transaction_id % 4],
                            'sessionId', 'USSD' || t.transaction_id)
                       WHEN 'MOBILE_APP' THEN json_build_object(
                            'device', json_build_object(
                                'os', (ARRAY['Android','iOS'])[1 + t.transaction_id % 2],
                                'appVersion', '4.' || (t.transaction_id % 6)))
                       ELSE json_build_object(
                            'browser', (ARRAY['Chrome','Safari','Firefox','Edge'])[1 + t.transaction_id % 4])
                     END,
    'createdAt',     pg_temp.ej_date(l.created_at)
))::text
FROM ledger_entries l
JOIN accounts a      ON a.account_id = l.account_id
JOIN transactions t  ON t.transaction_id = l.transaction_id
LEFT JOIN LATERAL (
        SELECT a2.account_id, a2.account_number, c2.first_name, c2.last_name
        FROM ledger_entries l2
        JOIN accounts  a2 ON a2.account_id  = l2.account_id
        JOIN customers c2 ON c2.customer_id = a2.customer_id
        WHERE l2.transaction_id = l.transaction_id AND l2.account_id <> l.account_id
        LIMIT 1) o ON true
LEFT JOIN beneficiaries b ON b.beneficiary_id = t.beneficiary_id
LEFT JOIN banks k         ON k.bank_code = b.bank_code
WHERE a.customer_id <= 2000
ORDER BY l.entry_id;
\o

\pset tuples_only off
\pset format aligned
\echo 'Export finished: data/customers.json and data/activity.json'
