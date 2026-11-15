// =====================================================================
// MIT 8103 Advanced Database Systems - Portfolio 4
// Case study : LagoonPay
// Author     : Ajilore Opeyemi (301930319)
// Purpose    : Create the MongoDB collections (with schema validation)
//              and load the documents exported from PostgreSQL.
// Run with   : mongosh --quiet --file 02_load_data.js
// =====================================================================
const fs = require('fs');
db = db.getSiblingDB('lagoonpay');
db.dropDatabase();

print('MongoDB server version: ' + db.version());

// ---------------------------------------------------------------------
// 1. Collections with $jsonSchema validation
//    MongoDB does not force a schema, but a bank cannot accept just any
//    document. The validator fixes the fields that must always be there
//    and leaves the rest (kyc documents, address, meta) flexible.
// ---------------------------------------------------------------------
db.createCollection('customers', {
  validator: { $jsonSchema: {
    bsonType: 'object',
    required: ['_id', 'name', 'email', 'phone', 'kyc', 'accounts', 'createdAt'],
    properties: {
      name:  { bsonType: 'object', required: ['first', 'last'] },
      email: { bsonType: 'string', pattern: '^[^@\\s]+@[^@\\s]+\\.[a-z]{2,}$' },
      phone: { bsonType: 'string', pattern: '^\\+234[0-9]{10}$' },
      kyc:   { bsonType: 'object', required: ['tier'],
               properties: { tier: { bsonType: 'number', minimum: 1, maximum: 3 } } },
      accounts: {
        bsonType: 'array', minItems: 1,
        items: {
          bsonType: 'object',
          required: ['accountNumber', 'type', 'currency', 'balance', 'status'],
          properties: {
            accountNumber: { bsonType: 'string', pattern: '^[0-9]{10}$' },
            balance:       { bsonType: 'decimal', minimum: 0 },
            status:        { enum: ['ACTIVE', 'FROZEN', 'CLOSED'] }
          }
        }
      },
      beneficiaries: { bsonType: 'array' }
    }
  } }
});

db.createCollection('activity', {
  validator: { $jsonSchema: {
    bsonType: 'object',
    required: ['_id', 'txnId', 'reference', 'accountId', 'customerId', 'type',
               'direction', 'amount', 'balanceAfter', 'channel', 'createdAt'],
    properties: {
      type:      { enum: ['DEPOSIT', 'WITHDRAWAL', 'TRANSFER', 'REVERSAL'] },
      direction: { enum: ['DEBIT', 'CREDIT'] },
      amount:    { bsonType: 'decimal', minimum: 0, exclusiveMinimum: true },
      channel:   { enum: ['MOBILE_APP', 'USSD', 'WEB', 'POS', 'ATM'] },
      createdAt: { bsonType: 'date' },
      meta:      { bsonType: 'object' }           // contents depend on the channel
    }
  } }
});

// ---------------------------------------------------------------------
// 2. Load the exported files (one Extended JSON document per line)
// ---------------------------------------------------------------------
function loadFile(path, collection) {
  const lines = fs.readFileSync(path, 'utf8').split('\n').filter(l => l.trim() !== '');
  let batch = [], total = 0;
  for (const line of lines) {
    batch.push(EJSON.parse(line));               // {"$date":..} -> Date, {"$numberDecimal":..} -> Decimal128
    if (batch.length === 1000) {
      total += Object.keys(collection.insertMany(batch, { ordered: false }).insertedIds).length;
      batch = [];
    }
  }
  if (batch.length > 0) {
    total += Object.keys(collection.insertMany(batch, { ordered: false }).insertedIds).length;
  }
  return total;
}

const t0 = Date.now();
print('customers loaded : ' + loadFile('data/customers.json', db.customers));
print('activity loaded  : ' + loadFile('data/activity.json',  db.activity));
print('load time (ms)   : ' + (Date.now() - t0));

// ---------------------------------------------------------------------
// 3. Indexes that enforce uniqueness (the equivalent of UNIQUE in SQL).
//    Query-tuning indexes are added in 03_queries.js, after a baseline
//    explain, so their effect can be measured.
// ---------------------------------------------------------------------
db.customers.createIndex({ email: 1 }, { unique: true });
db.customers.createIndex({ phone: 1 }, { unique: true });
db.customers.createIndex({ 'accounts.accountNumber': 1 }, { unique: true });   // multikey: indexes every array element

print('\n--- collections ---');
db.getCollectionNames().sort().forEach(c => print(c + ': ' + db.getCollection(c).countDocuments({}) + ' documents'));

print('\n--- one customer document (tier 3: has address and three KYC documents) ---');
printjson(db.customers.findOne({ 'kyc.tier': 3 }));

print('\n--- one customer document (tier 1: no address, one KYC document) ---');
printjson(db.customers.findOne({ 'kyc.tier': 1 }, { name: 1, kyc: 1, address: 1, 'accounts.accountNumber': 1 }));

print('\n--- one activity document per channel: "meta" has a different shape each time ---');
['ATM', 'POS', 'USSD', 'MOBILE_APP', 'WEB'].forEach(ch =>
  printjson(db.activity.findOne({ channel: ch }, { _id: 0, reference: 1, channel: 1, type: 1, amount: 1, meta: 1 })));
