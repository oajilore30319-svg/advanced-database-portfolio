# Portfolio 4: NoSQL and Advanced Data Models

**Student:** Ajilore Opeyemi (301930319)
**Case study:** LagoonPay (same data as Portfolios 1 to 3)
**Engines:** MongoDB 9.0 (document store), fed from PostgreSQL 18

## 1. Aim

Model part of LagoonPay as documents in MongoDB, load it with the same data used in the relational portfolios, and show with real output where the document model fits the bank better than tables and where it does not.

## 2. Where NoSQL fits in a bank

LagoonPay would not move its ledger out of PostgreSQL. Money movement needs multi-row transactions, foreign keys and CHECK constraints, which Portfolios 1 and 3 rely on. The document store is added beside it, for the workloads the relational model serves poorly:

| Workload | Why tables are awkward | Why documents fit |
|---|---|---|
| Customer profile screen in the app | 5-table join on every app launch | One document, one read |
| Statement / activity feed | Every line needs joins to transaction, counterparty account, customer, bank | Each line is stored ready to display |
| Channel-specific details (ATM terminal, POS merchant, USSD session, app device) | Either many nullable columns or one table per channel | A `meta` sub-document whose fields differ per channel |
| KYC records that differ by tier and change with regulation | `ALTER TABLE` and backfills | New fields are added to the documents that need them |
| Sessions and one-time passwords | Rows that must be deleted by a job | Key lookup by `_id`, removed automatically by a TTL index |

This arrangement is usually called polyglot persistence: PostgreSQL remains the system of record, and MongoDB holds read-optimised copies and flexible data.

## 3. The document model

### 3.1 Mapping from the relational schema

| Relational (Portfolio 1) | MongoDB | Decision |
|---|---|---|
| `customers` | `customers` collection | One document per customer |
| `accounts` + `account_types` | `customers.accounts[]` | **Embedded.** A customer has a few accounts, they are always shown together, and they are never needed without the customer |
| `beneficiaries` + `banks` | `customers.beneficiaries[]` | **Embedded**, with the bank name copied in. A bounded list that only its owner reads |
| `ledger_entries` + `transactions` | `activity` collection | **Separate collection, referenced** by `accountId` and `customerId`. The list is unbounded, so embedding it would grow the customer document without limit (MongoDB documents are capped at 16 MB) |
| Counterparty (second ledger line, or beneficiary and bank) | `activity.counterparty` | **Embedded copy** of the name and account number, so a statement line needs no lookup |
| (no equivalent) | `activity.meta` | Polymorphic: fields depend on the channel |
| (no equivalent) | `sessions` | Key-value documents with a TTL index |
| Materialized view (Portfolio 2, Q5) | `daily_account_summary` | Computed pattern: totals pre-aggregated with `$merge` |

The rule applied: embed what is bounded and read together; reference what grows without limit or is shared.

### 3.2 Shape of the documents

```js
// customers
{
  _id: 3,
  name: { first: "Folake", last: "Okeke" },
  email: "...", phone: "+234...",
  kyc: { tier: 3, documents: [ { type: "PHONE", verified: true },
                               { type: "NIN", last4: "3757" },
                               { type: "UTILITY_BILL", issuer: "...", issuedOn: ISODate(...) } ] },
  address: { city: "Port Harcourt", country: "NG" },      // tier 3 only
  accounts: [ { accountId: 3, accountNumber: "3000000003",
                type: { code: "CUR", name: "Current Account" },
                currency: "NGN", balance: Decimal128("..."), status: "ACTIVE", openedAt: ISODate(...) } ],
  beneficiaries: [ { bankCode: "057", bankName: "Zenith Bank", accountNumber: "...", accountName: "..." } ],
  createdAt: ISODate(...)
}

// activity (one statement line)
{
  _id: 233014, txnId: 324775, reference: "LGP-0000324775",
  accountId: 23442, accountNumber: "3000023442", customerId: 841,
  type: "TRANSFER", direction: "CREDIT",
  amount: Decimal128("672.05"), balanceAfter: Decimal128("4914947.08"),
  channel: "MOBILE_APP",
  counterparty: { kind: "INTERNAL", accountNumber: "3000024429", name: "Ngozi Danjuma" },
  meta: { device: { os: "iOS", appVersion: "4.1" } },     // differs per channel
  createdAt: ISODate(...)
}
```

Money is stored as `Decimal128`, never as a floating-point number, so amounts stay exact.

### 3.3 What is given up

Embedding copies data. The bank name sits in every beneficiary and the counterparty's name sits in every statement line. If a name changes, the old statement lines keep the old name. For a statement that is arguably correct (it records what was true at the time), but it is a decision the relational design never had to make. MongoDB also has no foreign keys: nothing stops an `activity` document from pointing at a customer that does not exist. That is one more reason the ledger of record stays in PostgreSQL.

## 4. Implementation

| Step | File | What it does |
|---|---|---|
| 1 | `01_export_from_postgres.sql` | PostgreSQL performs the joins once and writes one Extended JSON document per line for 2,000 customers and every ledger entry on their accounts |
| 2 | `02_load_data.js` | Creates the collections with `$jsonSchema` validators, loads the files, builds the unique indexes |
| 3 | `03_queries.js` | Queries, `explain()` before and after indexes, array queries, updates, validation tests, key-value use |
| 4 | `04_aggregations.js` | Six aggregation pipelines |

The export is itself part of the evidence: the SQL in step 1 is the 5-table join that the document model removes from every later read.

## 5. What the output shows

Full output is in `results/`.

Run on my MacBook Pro with MongoDB 9.0.8: 2,000 customer documents and 103,060 activity documents loaded.

| Section | Test | Before | After / result |
|---|---|---|---|
| A | Customer profile by phone number | 5-table join in SQL | One document returned by one indexed read |
| B | Last 5 statement lines of merchant account 7 | `COLLSCAN` then `SORT`, 103,060 documents examined | `IXSCAN(ix_account_recent)` then `LIMIT`, **5** documents examined, no sort |
| C | Owner of an account number inside the embedded array | | `EXPRESS_IXSCAN` on the multikey index, 1 document examined |
| C | Customers with a Savings account above 5,100,000 (`$elemMatch`) | | 41 customers |
| D | ATM withdrawals in Osogbo (`meta.location`) | `COLLSCAN`, 103,060 examined, 25 ms | Partial index `ix_atm_location`, 1,790 examined for 1,790 returned, 1 ms |
| E | `$inc` on one array element, `$addToSet`, KYC upgrade with new fields | | Applied; second `$addToSet` changed nothing; new fields added with no schema change |
| F | Seven invalid writes | | All seven rejected (validation error 121 or duplicate key 11000) |
| G | Session lookup by key | | `EXPRESS_IXSCAN(_id_)`, 1 document examined |

Points worth noting:

- **B** is the same idea as Q4 in Portfolio 2. The compound index puts the equality field first and the sort field second, so MongoDB reads the newest five entries straight from the index. Documents examined dropped from 103,060 to 5.
- **C** shows that an index on a field inside an array (a multikey index) indexes every element, so "which customer owns this account number" is a single key lookup even though accounts are embedded. Declaring it `unique` also stops two customers holding the same account number (test F6).
- **C** also shows why `$elemMatch` matters. Without it, a customer with a small Savings account and a large Current account would match, because each condition could be satisfied by a different array element.
- **D** indexes a field that most documents do not have. The partial index covers only ATM documents, so it is small, and every document it leads to is one the query wants (1,790 examined, 1,790 returned).
- **F7** is the document-model version of the Portfolio 1 CHECK constraint: the validator rejects an update that would take an embedded balance below zero. It protects one document only; it cannot protect a rule that spans two documents, which is the limit discussed in section 6.

The aggregation output (`results/04_aggregations.txt`) covers grouping by month and channel, grouping on an embedded field, a `$lookup` join, `$bucket`, `$unwind` on the embedded accounts, and `$merge` into a pre-aggregated collection.

## 6. Suitability: when to use which

| Requirement | PostgreSQL | MongoDB |
|---|---|---|
| Move money between two accounts atomically | Natural (Portfolio 3) | Possible only with multi-document transactions on a replica set; not the model's strength |
| Guarantee a balance never goes negative | CHECK constraint | Validator on the document (test F7), but only within one document |
| Guarantee an entry points at a real account | Foreign key | Not available |
| Show a customer's whole profile | 5-table join | One read |
| Store attributes that differ per channel or change often | Nullable columns or extra tables | Native |
| Ad hoc reporting across everything | SQL joins | Aggregation pipeline; `$lookup` works but is not what the engine is built around |
| Scale reads and writes across many servers | Harder | Built in (Portfolio 5) |

Other NoSQL families were considered for the same case study. A **key-value** store such as Redis is the usual choice for sessions and rate limits; section G shows the same access pattern inside MongoDB to avoid running another system. A **wide-column** store such as Cassandra suits an append-only activity feed at very large scale, partitioned by account. A **graph** database suits fraud detection, where the question is how accounts are connected through chains of transfers. The document model was chosen because it covers the most LagoonPay workloads with one engine.

## 7. How to run

PostgreSQL must hold the Portfolio 2 dataset and MongoDB must be running (`brew services start mongodb-community`). From inside this folder:

```bash
sh run_all.sh
```

The exported files in `data/` are about 48 MB and are regenerated on every run, so they are excluded from Git by `.gitignore`.
