// =====================================================================
// Portfolio 4 - aggregation pipelines (MongoDB's answer to GROUP BY and JOIN)
// Run with : mongosh --quiet --file 04_aggregations.js
// =====================================================================
db = db.getSiblingDB('lagoonpay');

function heading(text) {
  print('\n==================================================================');
  print(' ' + text);
  print('==================================================================');
}
const show = cursor => cursor.forEach(d => print(EJSON.stringify(d)));

// ---------------------------------------------------------------------
heading('1. Monthly volume and value by channel, third quarter of 2026 (same report as Portfolio 2, Q5)');
// ---------------------------------------------------------------------
show(db.activity.aggregate([
  { $match: { createdAt: { $gte: ISODate('2026-07-01T00:00:00Z'), $lt: ISODate('2026-10-01T00:00:00Z') } } },
  { $group: { _id: { month: { $dateToString: { format: '%Y-%m', date: '$createdAt' } }, channel: '$channel' },
              entries: { $sum: 1 }, totalValue: { $sum: '$amount' } } },
  { $sort: { '_id.month': 1, '_id.channel': 1 } },
  { $project: { _id: 0, month: '$_id.month', channel: '$_id.channel', entries: 1, totalValue: 1 } }
]));

// ---------------------------------------------------------------------
heading('2. Money sent to other banks, by receiving bank (reads the embedded counterparty)');
// ---------------------------------------------------------------------
show(db.activity.aggregate([
  { $match: { 'counterparty.kind': 'EXTERNAL', direction: 'DEBIT' } },
  { $group: { _id: '$counterparty.bankName', transfers: { $sum: 1 }, totalValue: { $sum: '$amount' },
              averageValue: { $avg: '$amount' } } },
  { $sort: { totalValue: -1 } },
  { $project: { _id: 0, bank: '$_id', transfers: 1, totalValue: 1, averageValue: { $round: ['$averageValue', 2] } } }
]));

// ---------------------------------------------------------------------
heading('3. Top 5 customers by debits in September 2026, with names ($lookup = join to customers)');
// ---------------------------------------------------------------------
show(db.activity.aggregate([
  { $match: { direction: 'DEBIT',
              createdAt: { $gte: ISODate('2026-09-01T00:00:00Z'), $lt: ISODate('2026-10-01T00:00:00Z') } } },
  { $group: { _id: '$customerId', debits: { $sum: 1 }, totalDebited: { $sum: '$amount' } } },
  { $sort: { totalDebited: -1 } },
  { $limit: 5 },
  { $lookup: { from: 'customers', localField: '_id', foreignField: '_id', as: 'customer' } },
  { $unwind: '$customer' },
  { $project: { _id: 0, customerId: '$_id',
                name: { $concat: ['$customer.name.first', ' ', '$customer.name.last'] },
                kycTier: '$customer.kyc.tier', debits: 1, totalDebited: 1 } }
]));

// ---------------------------------------------------------------------
heading('4. Distribution of transaction sizes ($bucket)');
// ---------------------------------------------------------------------
show(db.activity.aggregate([
  { $match: { type: { $ne: 'DEPOSIT' } } },
  { $bucket: { groupBy: '$amount',
               boundaries: [Decimal128('0'), Decimal128('1000'), Decimal128('5000'), Decimal128('10000'),
                            Decimal128('25000'), Decimal128('50001')],
               default: 'over 50,000',
               output: { entries: { $sum: 1 }, totalValue: { $sum: '$amount' } } } }
]));

// ---------------------------------------------------------------------
heading('5. Deposits held, by account type (unwinds the embedded accounts array)');
// ---------------------------------------------------------------------
show(db.customers.aggregate([
  { $unwind: '$accounts' },
  { $group: { _id: '$accounts.type.name', accounts: { $sum: 1 }, totalBalance: { $sum: '$accounts.balance' } } },
  { $sort: { totalBalance: -1 } },
  { $project: { _id: 0, accountType: '$_id', accounts: 1, totalBalance: 1 } }
]));

// ---------------------------------------------------------------------
heading('6. Computed pattern: pre-aggregate daily totals per account into their own collection ($merge)');
// ---------------------------------------------------------------------
db.activity.aggregate([
  { $group: { _id: { accountId: '$accountId', day: { $dateToString: { format: '%Y-%m-%d', date: '$createdAt' } } },
              entries:  { $sum: 1 },
              credits:  { $sum: { $cond: [{ $eq: ['$direction', 'CREDIT'] }, '$amount', Decimal128('0')] } },
              debits:   { $sum: { $cond: [{ $eq: ['$direction', 'DEBIT'] },  '$amount', Decimal128('0')] } } } },
  { $merge: { into: 'daily_account_summary', whenMatched: 'replace', whenNotMatched: 'insert' } }
]);
print('daily_account_summary documents: ' + db.daily_account_summary.countDocuments({}));
print('-- busiest five days of merchant account 7, read from the summary instead of scanning its activity');
show(db.daily_account_summary.find({ '_id.accountId': 7 }).sort({ entries: -1 }).limit(5));
