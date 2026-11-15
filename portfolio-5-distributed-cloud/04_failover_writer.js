// Writes one document every half second for about 40 seconds. Started by
// 04_failover.sh just before the primary is killed. The connection uses
// the replica-set URI, so the driver discovers the new primary by itself.
// Like a real application, the writer retries a failed write until it is
// acknowledged, and records how long each write took in total.
db = db.getSiblingDB('lagoonpay');
db.failover_log.drop();
const startPrimary = db.hello().primary;
const results = [];
for (let seq = 1; seq <= 60; seq++) {
  const t0 = Date.now();
  let attempts = 0, ok = false, firstError = '';
  while (!ok && Date.now() - t0 < 60000) {
    attempts++;
    try {
      // _id = seq, so a retry can never store the same payment twice
      db.failover_log.updateOne({ _id: seq }, { $setOnInsert: { at: new Date() } },
                                { upsert: true, writeConcern: { w: 'majority', wtimeout: 30000 } });
      ok = true;
    } catch (e) {
      if (!firstError) firstError = String(e.message).split('\n')[0].slice(0, 70);
      sleep(250);
    }
  }
  results.push({ seq: seq, ok: ok, attempts: attempts, ms: Date.now() - t0, err: firstError });
  sleep(500);
}
const endPrimary = db.hello().primary;
const retried = results.filter(r => r.attempts > 1);
const slowest = results.reduce((a, b) => (b.ms > a.ms ? b : a));
const sorted = results.map(r => r.ms).sort((a, b) => a - b);
print('primary when the writer started   : ' + startPrimary);
print('primary when the writer finished  : ' + endPrimary);
print('writes requested                  : ' + results.length);
print('writes acknowledged               : ' + results.filter(r => r.ok).length);
print('documents now in the collection   : ' + db.failover_log.countDocuments({}));
print('writes that needed a retry        : ' + retried.length +
      (retried.length ? '  (seq ' + retried.map(r => r.seq).join(', ') + ')' : ''));
retried.forEach(r => print('    seq ' + r.seq + ': ' + r.attempts + ' attempts over ' + r.ms + ' ms; first error: ' + r.err));
print('typical write (median)            : ' + sorted[Math.floor(sorted.length / 2)] + ' ms');
print('longest wait for one write        : ' + slowest.ms + ' ms  <-- how long the database was unavailable for writes');
const i = results.indexOf(slowest);
print('write time around the failover (seq: ms):');
print('    ' + results.slice(Math.max(0, i - 3), i + 4).map(r => r.seq + ': ' + r.ms).join('   '));
