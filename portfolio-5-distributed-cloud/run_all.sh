#!/bin/sh
# =====================================================================
# Portfolio 5 - run both parts in order.
# Run from inside the portfolio-5-distributed-cloud folder:
#     sh run_all.sh
# Needs Portfolio 4 to have been run first (it uses the documents in
# ../portfolio-4-nosql/data). Takes about three minutes.
# =====================================================================
cd "$(dirname "$0")" || exit 1
. ./00_env.sh

if [ ! -s "$DATA_DIR/activity.json" ] || [ ! -s "$DATA_DIR/customers.json" ]; then
    echo "Cannot find $DATA_DIR/activity.json. Run Portfolio 4 first (sh run_all.sh in portfolio-4-nosql)."
    exit 1
fi
for tool in mongod mongos mongosh; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool is not installed or not on the PATH."; exit 1; }
done

echo "PART A: replica set"
echo "Step 1 of 6: starting three members..."
sh 01_replica_set_start.sh > results/01_replica_set_start.txt 2>&1 || { cat results/01_replica_set_start.txt; exit 1; }
tail -4 results/01_replica_set_start.txt

echo "Step 2 of 6: replication, write concern, lagging secondary..."
mongosh --quiet "$RS_URI" --file 02_replication.js > results/02_replication.txt 2>&1

echo "Step 3 of 6: multi-document transactions..."
mongosh --quiet "$RS_URI" --file 03_transactions.js > results/03_transactions.txt 2>&1

echo "Step 4 of 6: failover tests (about 2 minutes)..."
sh 04_failover.sh > results/04_failover.txt 2>&1

echo "PART B: sharded cluster"
echo "Step 5 of 6: starting config server, two shards and router..."
sh 05_sharded_cluster_start.sh > results/05_sharded_cluster_start.txt 2>&1 || { cat results/05_sharded_cluster_start.txt; exit 1; }
tail -4 results/05_sharded_cluster_start.txt

echo "Step 6 of 6: sharding the activity collection..."
mongosh --quiet "$MONGOS_URI" --file 06_sharding.js > results/06_sharding.txt 2>&1

sh 07_stop_all.sh

echo
echo "Unexpected errors (nothing should be listed below this line):"
grep -n -i "error\|exception\|unexpected" results/0[2-6]*.txt | grep -v "NOT confirmed\|REFUSED\|ABORTED\|first error"
echo "Done. Output of each step is in the results folder."
