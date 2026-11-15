#!/bin/sh
# =====================================================================
# Portfolio 5, part A: availability
#   F1. The primary crashes while a client is writing.
#   F2. The crashed member comes back and catches up.
#   F3. Two of three members are lost: no majority, so no primary.
# =====================================================================
cd "$(dirname "$0")" || exit 1
. ./00_env.sh

status() {
    mongosh --quiet --port "$1" --eval '
      try { rs.status().members.forEach(m => print("  " + m.name + "  " + m.stateStr)); }
      catch (e) { print("  cannot read status: " + e.message); }'
}
name_of_port() { case "$1" in 27101) echo rs1;; 27102) echo rs2;; 27103) echo rs3;; esac; }

echo
echo "=================================================================="
echo " F1. Crash of the primary during continuous writes"
echo "=================================================================="
PRIMARY_PORT=$(mongosh --quiet "$RS_URI" --eval 'print(db.hello().primary.split(":")[1])')
PRIMARY_NAME=$(name_of_port "$PRIMARY_PORT")
echo "members before:"; status "$PRIMARY_PORT"
echo "a client starts writing one document every 0.5 s (w: majority)..."
mongosh --quiet "$RS_URI" --file 04_failover_writer.js > "$BASE/writer.txt" 2>&1 &
WRITER=$!
sleep 6
echo "kill -9 on the primary (127.0.0.1:$PRIMARY_PORT) at $(date +%H:%M:%S)"
kill_node "$PRIMARY_NAME"
wait $WRITER
echo
cat "$BASE/writer.txt"
echo
SURVIVOR_PORT=$(mongosh --quiet "$RS_URI" --eval 'print(db.hello().primary.split(":")[1])')
echo "members after the election (seen from 127.0.0.1:$SURVIVOR_PORT):"; status "$SURVIVOR_PORT"

echo
echo "=================================================================="
echo " F2. The crashed member is restarted and catches up"
echo "=================================================================="
start_mongod "$PRIMARY_NAME" "$PRIMARY_PORT" --replSet "$RS_NAME"
wait_for_port "$PRIMARY_PORT"
mongosh --quiet "$RS_URI" --eval '
  let ok = false;
  for (let i = 0; i < 60 && !ok; i++) { sleep(1000); ok = rs.status().members.filter(m => m.stateStr === "SECONDARY").length === 2; }
  rs.status().members.forEach(m => print("  " + m.name + "  " + m.stateStr));
  const n = db.getSiblingDB("lagoonpay").failover_log.countDocuments({});
  print("failover_log documents on the primary           : " + n);
  const back = new Mongo("mongodb://127.0.0.1:'"$PRIMARY_PORT"'/?directConnection=true");
  back.setReadPref("secondaryPreferred");
  let m = -1;
  for (let i = 0; i < 40 && m !== n; i++) { sleep(250); m = back.getDB("lagoonpay").failover_log.countDocuments({}); }
  print("failover_log documents on the restarted member  : " + m);
'

echo
echo "=================================================================="
echo " F3. Loss of the majority: two of three members crash"
echo "=================================================================="
PRIMARY_PORT=$(mongosh --quiet "$RS_URI" --eval 'print(db.hello().primary.split(":")[1])')
for p in $RS_PORTS; do
    if [ "$p" != "$PRIMARY_PORT" ]; then kill_node "$(name_of_port "$p")"; echo "killed 127.0.0.1:$p"; fi
done
echo "waiting 15 s for the remaining member (127.0.0.1:$PRIMARY_PORT) to notice..."
sleep 15
mongosh --quiet "mongodb://127.0.0.1:$PRIMARY_PORT/lagoonpay?directConnection=true&serverSelectionTimeoutMS=3000" --eval '
  const h = db.hello();
  print("remaining member is now: " + (h.isWritablePrimary ? "PRIMARY" : "SECONDARY") + "  (it cannot see a majority, so it stepped down)");
  try { db.failover_log.insertOne({ seq: 9999 }); print("write: ACCEPTED (unexpected)"); }
  catch (e) { print("write: REFUSED - " + String(e.message).split("\n")[0].slice(0, 80)); }
  db.getMongo().setReadPref("secondaryPreferred");
  print("read : still answered, " + db.customers.countDocuments({}) + " customers (read preference secondaryPreferred)");
'
echo "restarting the two members..."
for p in $RS_PORTS; do
    if [ "$p" != "$PRIMARY_PORT" ]; then start_mongod "$(name_of_port "$p")" "$p" --replSet "$RS_NAME"; fi
done
for p in $RS_PORTS; do wait_for_port "$p"; done
mongosh --quiet "$RS_URI" --eval '
  let ok = false;
  for (let i = 0; i < 60 && !ok; i++) { sleep(1000);
    const s = rs.status().members.map(m => m.stateStr);
    ok = s.filter(x => x === "PRIMARY").length === 1 && s.filter(x => x === "SECONDARY").length === 2; }
  print("majority restored:");
  rs.status().members.forEach(m => print("  " + m.name + "  " + m.stateStr));
  db.failover_log.insertOne({ seq: 10000 }, { writeConcern: { w: "majority" } });
  print("write: ACCEPTED again");
'
