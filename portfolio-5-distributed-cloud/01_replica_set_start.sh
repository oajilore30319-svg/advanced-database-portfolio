#!/bin/sh
# =====================================================================
# Portfolio 5, part A: start a three-member replica set on this machine
# =====================================================================
cd "$(dirname "$0")" || exit 1
. ./00_env.sh

stop_everything
rm -rf "$BASE"/rs1 "$BASE"/rs2 "$BASE"/rs3

n=1
for port in $RS_PORTS; do
    start_mongod "rs$n" "$port" --replSet "$RS_NAME"
    n=$((n + 1))
done
for port in $RS_PORTS; do wait_for_port "$port" || exit 1; done

mongosh --quiet --port 27101 --eval '
  rs.initiate({ _id: "lagoonRS", members: [
    { _id: 0, host: "127.0.0.1:27101" },
    { _id: 1, host: "127.0.0.1:27102" },
    { _id: 2, host: "127.0.0.1:27103" } ] });
  // wait until a primary has been elected and both secondaries are ready
  let ready = false;
  for (let i = 0; i < 60 && !ready; i++) {
    sleep(1000);
    const s = rs.status().members.map(m => m.stateStr);
    ready = s.filter(x => x === "PRIMARY").length === 1 && s.filter(x => x === "SECONDARY").length === 2;
  }
  print("Replica set " + rs.status().set + " is up:");
  rs.status().members.forEach(m => print("  " + m.name + "  " + m.stateStr));
'
