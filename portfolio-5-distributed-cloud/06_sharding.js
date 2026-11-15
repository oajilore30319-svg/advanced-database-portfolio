// =====================================================================
// Portfolio 5, part B: sharding the LagoonPay activity feed
// Connects to the mongos router (run through run_all.sh)
// =====================================================================
const fs = require('fs');
db = db.getSiblingDB('lagoonpay');

function heading(text) {
  print('\n==================================================================');
  print(' ' + text);
  print('==================================================================');
}
const SHARDS = { shard1RS: '127.0.0.1:27211', shard2RS: '127.0.0.1:27212' };
function onShard(name) {
  return new Mongo('mongodb://' + SHARDS[name] + '/?directConnection=true').getDB('lagoonpay');
}
function perShard(coll, filter) {
  return Object.keys(SHARDS).map(s => s + ': ' + onShard(s).getCollection(coll).countDocuments(filter || {})).join('    ');
}
function chunks(ns) {
  const meta = db.getSiblingDB('config').collections.findOne({ _id: ns });
  return db.getSiblingDB('config').chunks.aggregate([
    { $match: { uuid: meta.uuid } }, { $group: { _id: '$shard', chunks: { $sum: 1 } } }, { $sort: { _id: 1 } }
  ]).toArray().map(c => c._id + ': ' + c.chunks).join('    ');
}
// which shards a query was sent to, and how much work they did
function routing(explain) {
  const wp = explain.queryPlanner.winningPlan;
  const s = explain.executionStats;
  return { routing: wp.stage, shardsContacted: (wp.shards || []).map(x => x.shardName).sort(),
           returned: s.nReturned, docsExamined: s.totalDocsExamined };
}

// ---------------------------------------------------------------------
heading('S1. Build the cluster: add two shards');
// ---------------------------------------------------------------------
Object.keys(SHARDS).forEach(s => { sh.addShard(s + '/' + SHARDS[s]); });
db.adminCommand({ listShards: 1 }).shards.forEach(s => print('  ' + s._id + '  ' + s.host));

// ---------------------------------------------------------------------
heading('S2. Shard the activity collection on a HASHED accountId');
// ---------------------------------------------------------------------
sh.enableSharding('lagoonpay');
sh.shardCollection('lagoonpay.activity', { accountId: 'hashed' });
print('chunks per shard straight after sharding (collection still empty): ' + chunks('lagoonpay.activity'));

const lines = fs.readFileSync('../portfolio-4-nosql/data/activity.json', 'utf8').split('\n').filter(l => l.trim() !== '');
const t0 = Date.now();
for (let i = 0; i < lines.length; i += 2000) {
  db.activity.insertMany(lines.slice(i, i + 2000).map(l => EJSON.parse(l)), { ordered: false });
}
db.activity.createIndex({ accountId: 1, createdAt: -1 });
const total = db.activity.countDocuments({});
print('loaded ' + total + ' activity documents through the router in ' + (Date.now() - t0) + ' ms');
print('documents per shard : ' + perShard('activity'));
print('chunks per shard    : ' + chunks('lagoonpay.activity'));
print('accounts per shard  : ' + Object.keys(SHARDS).map(s => s + ': ' + onShard(s).activity.distinct('accountId').length).join('    '));
print('busiest account on each shard: ' + Object.keys(SHARDS).map(s => {
  const top = onShard(s).activity.aggregate([{ $group: { _id: '$accountId', n: { $sum: 1 } } }, { $sort: { n: -1 } }, { $limit: 1 }]).toArray()[0];
  return s + ': account ' + top._id + ' with ' + top.n + ' documents'; }).join('    '));

// ---------------------------------------------------------------------
heading('S3. Targeted query: the filter contains the shard key, so one shard answers');
// ---------------------------------------------------------------------
print('statement of account 7 (db.activity.find({ accountId: 7 }))');
printjson(routing(db.activity.find({ accountId: 7 }).sort({ createdAt: -1 }).limit(20).explain('executionStats')));
print('where account 7 lives: ' + perShard('activity', { accountId: 7 }));

// ---------------------------------------------------------------------
heading('S4. Scatter-gather query: no shard key in the filter, so every shard is asked');
// ---------------------------------------------------------------------
print('ATM withdrawals in Osogbo (db.activity.find({ channel: "ATM", "meta.location": "Osogbo" }))');
printjson(routing(db.activity.find({ channel: 'ATM', 'meta.location': 'Osogbo' }).explain('executionStats')));

print('\nmonthly report across the whole cluster (aggregation is run on each shard and merged by the router)');
db.activity.aggregate([
  { $match: { createdAt: { $gte: ISODate('2026-09-01T00:00:00Z'), $lt: ISODate('2026-10-01T00:00:00Z') } } },
  { $group: { _id: '$channel', entries: { $sum: 1 }, totalValue: { $sum: '$amount' } } },
  { $sort: { _id: 1 } }
]).forEach(d => print('  ' + EJSON.stringify(d)));

// ---------------------------------------------------------------------
heading('S5. A poor shard key for comparison: RANGED on createdAt');
// ---------------------------------------------------------------------
sh.shardCollection('lagoonpay.activity_by_time', { createdAt: 1 });
for (let i = 0; i < 30000; i += 2000) {
  db.activity_by_time.insertMany(lines.slice(i, i + 2000).map(l => EJSON.parse(l)), { ordered: false });
}
print('documents per shard : ' + perShard('activity_by_time'));
print('chunks per shard    : ' + chunks('lagoonpay.activity_by_time'));
print('A ranged key starts as one chunk on one shard, and because createdAt only ever increases,');
print('every new document belongs at the top end of the range: one shard takes all the writes.');

// ---------------------------------------------------------------------
heading('S6. An unsharded collection lives on one shard only (the primary shard of the database)');
// ---------------------------------------------------------------------
db.customers.insertMany(fs.readFileSync('../portfolio-4-nosql/data/customers.json', 'utf8')
    .split('\n').filter(l => l.trim() !== '').slice(0, 500).map(l => EJSON.parse(l)));
print('customers per shard : ' + perShard('customers'));

heading('S7. Cluster summary');
print('shards              : ' + Object.keys(SHARDS).join(', '));
print('activity            : ' + total + ' documents, hashed on accountId -> ' + perShard('activity'));
print('activity_by_time    : ranged on createdAt -> ' + perShard('activity_by_time'));
