// =====================================================================
// Portfolio 4 - queries, indexes, updates, validation, key-value use
// Run with : mongosh --quiet --file 03_queries.js
// =====================================================================
db = db.getSiblingDB('lagoonpay');

function heading(text) {
  print('\n==================================================================');
  print(' ' + text);
  print('==================================================================');
}

// Pulls the useful numbers out of an explain("executionStats") result.
function planSummary(explain) {
  const stages = [];
  (function walk(node) {
    if (!node || typeof node !== 'object') return;
    if (node.stage) stages.push(node.indexName ? node.stage + '(' + node.indexName + ')' : node.stage);
    if (node.queryPlan) walk(node.queryPlan);
    if (node.inputStage) walk(node.inputStage);
    if (Array.isArray(node.inputStages)) node.inputStages.forEach(walk);
  })(explain.queryPlanner.winningPlan);
  const s = explain.executionStats;
  return { plan: stages.join(' <- '), returned: s.nReturned, keysExamined: s.totalKeysExamined,
           docsExamined: s.totalDocsExamined, millis: s.executionTimeMillis };
}

// ---------------------------------------------------------------------
heading('A. Customer profile in ONE read (SQL needs a 5-table join)');
// ---------------------------------------------------------------------
const profile = db.customers.findOne(
  { phone: '+2348000001500' },
  { name: 1, phone: 1, 'kyc.tier': 1, 'accounts.accountNumber': 1, 'accounts.type.name': 1,
    'accounts.balance': 1, 'accounts.status': 1, beneficiaries: 1 });
printjson(profile);

// ---------------------------------------------------------------------
heading('B. Mini-statement: last 5 entries of merchant account 7, before and after an index');
// ---------------------------------------------------------------------
const stmt = () => db.activity.find(
    { accountId: 7 },
    { _id: 0, reference: 1, type: 1, direction: 1, amount: 1, balanceAfter: 1, createdAt: 1, 'counterparty.name': 1 })
  .sort({ createdAt: -1 }).limit(5);

stmt().forEach(d => printjson(d));

print('\n-- plan BEFORE index');
const before = planSummary(stmt().explain('executionStats'));
printjson(before);

db.activity.createIndex({ accountId: 1, createdAt: -1 }, { name: 'ix_account_recent' });

print('\n-- plan AFTER index { accountId: 1, createdAt: -1 }');
const after = planSummary(stmt().explain('executionStats'));
printjson(after);
print('\ndocuments examined: ' + before.docsExamined + ' -> ' + after.docsExamined);

// ---------------------------------------------------------------------
heading('C. Querying inside embedded arrays');
// ---------------------------------------------------------------------
print('-- who owns account 3000001234? (multikey index on accounts.accountNumber)');
printjson(db.customers.findOne({ 'accounts.accountNumber': '3000001234' },
                               { name: 1, phone: 1, 'accounts.$': 1 }));
printjson(planSummary(db.customers.find({ 'accounts.accountNumber': '3000001234' }).explain('executionStats')));

print('\n-- customers holding a Savings account with more than 5,100,000 in THAT account ($elemMatch)');
const rich = { accounts: { $elemMatch: { 'type.code': 'SAV', balance: { $gt: Decimal128('5100000') } } } };
print('matching customers: ' + db.customers.countDocuments(rich));
db.customers.find(rich, { _id: 1, name: 1, 'accounts.$': 1 }).limit(2).forEach(d => printjson(d));

// ---------------------------------------------------------------------
heading('D. Fields that only some documents have (polymorphic "meta")');
// ---------------------------------------------------------------------
print('-- which meta fields exist for each channel');
db.activity.aggregate([
  { $project: { channel: 1, keys: { $objectToArray: '$meta' } } },
  { $unwind: '$keys' },
  { $group: { _id: '$channel', metaFields: { $addToSet: '$keys.k' } } },
  { $sort: { _id: 1 } }
]).forEach(d => printjson(d));

print('\n-- ATM withdrawals in Osogbo: meta.location exists only on ATM documents');
const atm = { channel: 'ATM', 'meta.location': 'Osogbo' };
print('before index: ' + JSON.stringify(planSummary(db.activity.find(atm).explain('executionStats'))));
// partial index: only ATM documents are indexed, so it stays small
db.activity.createIndex({ 'meta.location': 1, createdAt: -1 },
                        { name: 'ix_atm_location', partialFilterExpression: { channel: 'ATM' } });
print('after index : ' + JSON.stringify(planSummary(db.activity.find(atm).explain('executionStats'))));
db.activity.find(atm, { _id: 0, reference: 1, amount: 1, meta: 1, createdAt: 1 })
  .sort({ createdAt: -1 }).limit(2).forEach(d => printjson(d));

// ---------------------------------------------------------------------
heading('E. Updates on documents');
// ---------------------------------------------------------------------
const acct = '3000001500';
const show = () => printjson(db.customers.findOne({ 'accounts.accountNumber': acct },
                   { _id: 0, 'kyc': 1, 'accounts.accountNumber': 1, 'accounts.balance': 1, beneficiaries: 1, address: 1 }));
print('-- before');
show();

print('\n-- E1. atomic increment of one element of the accounts array ($inc with the positional operator)');
printjson(db.customers.updateOne({ 'accounts.accountNumber': acct },
                                 { $inc: { 'accounts.$.balance': Decimal128('2500.00') } }));

print('\n-- E2. add a beneficiary only if it is not already saved ($addToSet), run twice');
const payee = { bankCode: '058', bankName: 'Guaranty Trust Bank', accountNumber: '0123456789', accountName: 'Demo Payee' };
printjson(db.customers.updateOne({ 'accounts.accountNumber': acct }, { $addToSet: { beneficiaries: payee } }));
printjson(db.customers.updateOne({ 'accounts.accountNumber': acct }, { $addToSet: { beneficiaries: payee } }));

print('\n-- E3. schema evolution: upgrade KYC and add fields no other customer has yet. No ALTER TABLE.');
printjson(db.customers.updateOne({ 'accounts.accountNumber': acct },
  { $set: { 'kyc.tier': 3, 'kyc.upgradedAt': new Date(), 'address': { city: 'Lagos', country: 'NG' } },
    $push: { 'kyc.documents': { type: 'SELFIE', livenessScore: 0.97 } } }));

print('\n-- after');
show();

// ---------------------------------------------------------------------
heading('F. Integrity: what MongoDB refuses');
// ---------------------------------------------------------------------
function attempt(label, fn) {
  try { fn(); print(label + ': ACCEPTED (unexpected)'); }
  catch (e) { print(label + ': REJECTED - ' + (e.codeName || e.code) + ' - ' + String(e.message).split('\n')[0].slice(0, 110)); }
}
const good = { txnId: 999001, reference: 'LGP-TEST', accountId: 1500, customerId: 1500, type: 'DEPOSIT',
               direction: 'CREDIT', amount: Decimal128('100.00'), balanceAfter: Decimal128('100.00'),
               channel: 'WEB', createdAt: new Date() };
attempt('F1 negative amount            ', () => db.activity.insertOne({ ...good, _id: 900000001, amount: Decimal128('-5') }));
attempt('F2 unknown direction          ', () => db.activity.insertOne({ ...good, _id: 900000002, direction: 'SIDEWAYS' }));
attempt('F3 missing required field     ', () => { const d = { ...good, _id: 900000003 }; delete d.reference; db.activity.insertOne(d); });
attempt('F4 amount stored as a string  ', () => db.activity.insertOne({ ...good, _id: 900000004, amount: '100.00' }));
attempt('F5 duplicate customer email   ', () => db.customers.insertOne({
  _id: 900001, name: { first: 'Dup', last: 'Email' }, email: db.customers.findOne({ _id: 1 }).email, phone: '+2349990000001',
  kyc: { tier: 1 }, accounts: [{ accountNumber: '9990000001', type: { code: 'WAL' }, currency: 'NGN',
  balance: Decimal128('0'), status: 'ACTIVE' }], createdAt: new Date() }));
attempt('F6 duplicate account number   ', () => db.customers.insertOne({
  _id: 900002, name: { first: 'Dup', last: 'Account' }, email: 'dup.account@example.com', phone: '+2349990000002',
  kyc: { tier: 1 }, accounts: [{ accountNumber: '3000000001', type: { code: 'WAL' }, currency: 'NGN',
  balance: Decimal128('0'), status: 'ACTIVE' }], createdAt: new Date() }));
attempt('F7 overdraft on embedded acct ', () => db.customers.updateOne({ 'accounts.accountNumber': acct },
                                                   { $inc: { 'accounts.$.balance': Decimal128('-999999999') } }));

// ---------------------------------------------------------------------
heading('G. Key-value use: login sessions and one-time passwords that expire by themselves');
// ---------------------------------------------------------------------
db.sessions.drop();
db.sessions.createIndex({ expireAt: 1 }, { expireAfterSeconds: 0 });      // TTL index
const now = new Date();
db.sessions.insertMany([
  { _id: 'session:9f2c41d7', customerId: 1500, device: 'Android', expireAt: new Date(now.getTime() + 15 * 60 * 1000) },
  { _id: 'otp:+2348000001500', codeHash: 'sha256:5e88...', attempts: 0, expireAt: new Date(now.getTime() + 5 * 60 * 1000) }
]);
print('-- lookup by key');
printjson(db.sessions.findOne({ _id: 'session:9f2c41d7' }));
printjson(planSummary(db.sessions.find({ _id: 'session:9f2c41d7' }).explain('executionStats')));
print('-- atomic counter on a key');
printjson(db.sessions.findOneAndUpdate({ _id: 'otp:+2348000001500' }, { $inc: { attempts: 1 } }, { returnDocument: 'after' }));

// ---------------------------------------------------------------------
heading('H. Indexes in place');
// ---------------------------------------------------------------------
['customers', 'activity', 'sessions'].forEach(c => {
  print(c + ':');
  db.getCollection(c).getIndexes().forEach(ix => print('   ' + ix.name + '  ' + JSON.stringify(ix.key) +
    (ix.unique ? '  unique' : '') + (ix.partialFilterExpression ? '  partial ' + JSON.stringify(ix.partialFilterExpression) : '') +
    (ix.expireAfterSeconds !== undefined ? '  ttl' : '')));
});
