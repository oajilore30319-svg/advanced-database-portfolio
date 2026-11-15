// =====================================================================
// Portfolio 5, part A: replication, write concern, read preference
// and the consistency of secondary reads.
// Run through run_all.sh (needs the replica set from 01_replica_set_start.sh)
// =====================================================================
const fs = require('fs');
db = db.getSiblingDB('lagoonpay');

function heading(text) {
  print('\n==================================================================');
  print(' ' + text);
  print('==================================================================');
}
function members() {
  rs.status().members.forEach(m => print('  ' + m.name + '  ' + m.stateStr.padEnd(10) +
      '  health=' + m.health + '  optime=' + m.optimeDate.toISOString()));
}
// a direct connection to ONE member, bypassing replica-set routing
function direct(hostPort) {
  const conn = new Mongo('mongodb://' + hostPort + '/?directConnection=true');
  conn.setReadPref('secondaryPreferred');
  return conn.getDB('lagoonpay');
}

// ---------------------------------------------------------------------
heading('A1. Topology');
// ---------------------------------------------------------------------
print('MongoDB ' + db.version() + ', replica set "' + rs.status().set + '"');
members();
const hello = db.hello();
const primaryHost = hello.primary;
const secondaryHosts = hello.hosts.filter(h => h !== primaryHost);
print('primary   : ' + primaryHost);
print('secondaries: ' + secondaryHosts.join(', '));

// ---------------------------------------------------------------------
heading('A2. Load LagoonPay customers; every write is copied to all three members');
// ---------------------------------------------------------------------
db.dropDatabase();
db.createCollection('customers', { validator: { $jsonSchema: {
  bsonType: 'object', required: ['name', 'accounts'],
  properties: { accounts: { bsonType: 'array', items: { bsonType: 'object',
    properties: { balance: { bsonType: 'decimal', minimum: 0 } } } } } } } });

const docs = fs.readFileSync('../portfolio-4-nosql/data/customers.json', 'utf8')
               .split('\n').filter(l => l.trim() !== '').map(l => EJSON.parse(l));
db.customers.insertMany(docs, { writeConcern: { w: 3 } });       // wait for all three members
db.customers.createIndex({ 'accounts.accountNumber': 1 }, { unique: true });

print('documents on each member (counted over a direct connection to that member):');
hello.hosts.forEach(h => print('  ' + h + (h === primaryHost ? ' (primary)  ' : ' (secondary)') +
                               '  ' + direct(h).customers.countDocuments({})));

// ---------------------------------------------------------------------
heading('A3. Write concern: how many members must confirm before the client is told "done"');
// ---------------------------------------------------------------------
function timeWrites(label, wc) {
  const t0 = Date.now();
  for (let i = 0; i < 200; i++) {
    db.audit_events.insertOne({ label: label, seq: i, at: new Date() }, { writeConcern: wc });
  }
  const ms = Date.now() - t0;
  print('  ' + label.padEnd(28) + (ms / 200).toFixed(2) + ' ms per write');
}
timeWrites('w: 1 (primary only)',          { w: 1 });
timeWrites('w: "majority" (2 of 3)',       { w: 'majority' });
timeWrites('w: 3 (every member)',          { w: 3 });
timeWrites('w: "majority", j: true',       { w: 'majority', j: true });
print('  default write concern of this replica set: ' +
      JSON.stringify(db.adminCommand({ getDefaultRWConcern: 1 }).defaultWriteConcern));

// ---------------------------------------------------------------------
heading('A4. A lagging secondary: stale reads, and what each write concern does about it');
// ---------------------------------------------------------------------
// fsyncLock on one secondary stops it applying new changes. This stands in
// for a member that is slow or cut off by a network problem.
const slowHost = secondaryHosts[0];
const slow = direct(slowHost);
print('pausing replication on ' + slowHost);
slow.fsyncLock();

const acct = '3000001500';
const balanceOn = d => d.customers.findOne({ 'accounts.accountNumber': acct }, { 'accounts.$': 1 }).accounts[0].balance.toString();
print('balance before, on primary          : ' + balanceOn(db));

print('\n-- deposit 5,000 with w: "majority" (the primary plus the healthy secondary are enough)');
printjson(db.customers.updateOne({ 'accounts.accountNumber': acct },
          { $inc: { 'accounts.$.balance': Decimal128('5000') } }, { writeConcern: { w: 'majority', wtimeout: 5000 } }));

print('balance on primary                  : ' + balanceOn(db));
print('balance on healthy secondary        : ' + balanceOn(direct(secondaryHosts[1])));
print('balance on the lagging secondary    : ' + balanceOn(slow) + '   <-- stale read');

print('\n-- the same deposit with w: 3 cannot be confirmed while one member is behind');
try {
  db.customers.updateOne({ 'accounts.accountNumber': acct },
     { $inc: { 'accounts.$.balance': Decimal128('5000') } }, { writeConcern: { w: 3, wtimeout: 3000 } });
  print('confirmed (unexpected)');
} catch (e) {
  print('NOT confirmed: ' + String(e.message).split('\n')[0].slice(0, 100));
  print('(the write itself was applied on the primary; only the confirmation timed out)');
}

print('\nresuming replication on ' + slowHost);
slow.fsyncUnlock();
let caughtUp = false;
for (let i = 0; i < 40 && !caughtUp; i++) { sleep(250); caughtUp = balanceOn(slow) === balanceOn(db); }
print('balance on primary                  : ' + balanceOn(db));
print('balance on the secondary, caught up : ' + balanceOn(slow));

// ---------------------------------------------------------------------
heading('A5. Read preference: sending report queries to a secondary');
// ---------------------------------------------------------------------
const report = [{ $unwind: '$accounts' },
                { $group: { _id: '$accounts.type.name', accounts: { $sum: 1 }, total: { $sum: '$accounts.balance' } } },
                { $sort: { _id: 1 } }];
const sec = new Mongo(db.getMongo().getURI());
sec.setReadPref('secondary');
const secDb = sec.getDB('lagoonpay');
const servedBy = secDb.customers.explain().aggregate(report).serverInfo;
const servedHost = '127.0.0.1:' + servedBy.port;
print('read preference "secondary": the query was served by ' + servedHost +
      (servedHost === primaryHost ? ' (the PRIMARY, unexpected)' : ' (a SECONDARY; the primary is ' + primaryHost + ')'));
secDb.customers.aggregate(report).forEach(d => print('  ' + EJSON.stringify(d)));

print('\n-- final state');
members();
