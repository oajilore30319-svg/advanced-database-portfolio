// =====================================================================
// Portfolio 5, part A: multi-document ACID transactions.
// MongoDB only offers these on a replica set (or sharded cluster), which
// is why this belongs here and not in Portfolio 4.
// A transfer between two customers changes TWO documents.
// =====================================================================
db = db.getSiblingDB('lagoonpay');

function heading(text) {
  print('\n==================================================================');
  print(' ' + text);
  print('==================================================================');
}
const FROM = '3000000900', TO = '3000001100';
const bal = n => db.customers.findOne({ 'accounts.accountNumber': n }, { 'accounts.$': 1 }).accounts[0].balance.toString();
const show = label => print(label.padEnd(26) + FROM + ' = ' + bal(FROM) + '    ' + TO + ' = ' + bal(TO));

function transfer(amount) {
  const session = db.getMongo().startSession();
  const customers = session.getDatabase('lagoonpay').customers;
  try {
    session.withTransaction(() => {
      customers.updateOne({ 'accounts.accountNumber': TO },   { $inc: { 'accounts.$.balance': Decimal128(String(amount)) } });
      customers.updateOne({ 'accounts.accountNumber': FROM }, { $inc: { 'accounts.$.balance': Decimal128(String(-amount)) } });
      session.getDatabase('lagoonpay').transfers.insertOne({ from: FROM, to: TO, amount: Decimal128(String(amount)), at: new Date() });
    }, { readConcern: { level: 'snapshot' }, writeConcern: { w: 'majority' } });
    return 'COMMITTED';
  } catch (e) {
    return 'ABORTED: ' + String(e.message).split('\n')[0].slice(0, 90);
  } finally {
    session.endSession();
  }
}

heading('T1. A transfer of 10,000 that commits (two customer documents + one transfers document)');
show('before');
print('result: ' + transfer(10000));
show('after');

heading('T2. A transfer that fails halfway: the receiver is credited first, then the debit breaks the balance rule');
show('before');
print('result: ' + transfer(900000000));
show('after (unchanged)');
print('transfers recorded: ' + db.transfers.countDocuments({}) + ' (only the committed one)');

heading('T3. Isolation: a change inside an open transaction is invisible to other sessions until commit');
const s = db.getMongo().startSession();
s.startTransaction({ readConcern: { level: 'snapshot' }, writeConcern: { w: 'majority' } });
s.getDatabase('lagoonpay').customers.updateOne({ 'accounts.accountNumber': TO }, { $inc: { 'accounts.$.balance': Decimal128('777') } });
const inside = s.getDatabase('lagoonpay').customers.findOne({ 'accounts.accountNumber': TO }, { 'accounts.$': 1 }).accounts[0].balance.toString();
print('seen inside the transaction : ' + inside);
print('seen by another session     : ' + bal(TO));
s.abortTransaction();
s.endSession();
print('after abort                 : ' + bal(TO));
