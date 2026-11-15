# =====================================================================
# MIT 8103 Advanced Database Systems - Portfolio 5
# Case study : LagoonPay
# Author     : Ajilore Opeyemi (301930319)
# Shared settings and helper functions. Sourced by the other scripts.
# Everything runs on this machine (127.0.0.1) on ports that do not clash
# with the default MongoDB port 27017.
# =====================================================================
BASE="${LAGOONPAY_P5_DIR:-/tmp/lagoonpay-p5}"

# replica set "lagoonRS": three data-bearing members
RS_NAME="lagoonRS"
RS_PORTS="27101 27102 27103"
# serverSelectionTimeoutMS: wait up to 30 s for a primary instead of giving up
# after 2 s, so a connection made in the middle of an election still succeeds
RS_URI="mongodb://127.0.0.1:27101,127.0.0.1:27102,127.0.0.1:27103/lagoonpay?replicaSet=${RS_NAME}&serverSelectionTimeoutMS=30000"

# sharded cluster: one config server, two shards, one mongos router
CFG_PORT=27201
SHARD1_PORT=27211
SHARD2_PORT=27212
MONGOS_PORT=27200
MONGOS_URI="mongodb://127.0.0.1:${MONGOS_PORT}/lagoonpay"

DATA_DIR="../portfolio-4-nosql/data"       # documents exported in Portfolio 4

mkdir -p "$BASE/pids" results

# start_mongod NAME PORT [extra mongod options...]
start_mongod() {
    name="$1"; port="$2"; shift 2
    mkdir -p "$BASE/$name"
    nohup mongod --port "$port" --bind_ip 127.0.0.1 --dbpath "$BASE/$name" \
          --wiredTigerCacheSizeGB 0.25 "$@" > "$BASE/$name.log" 2>&1 &
    echo $! > "$BASE/pids/$name.pid"
}

# wait_for_port PORT : waits until a server answers on that port
wait_for_port() {
    i=0
    while [ $i -lt 60 ]; do
        if mongosh --quiet --port "$1" --eval "db.adminCommand('ping').ok" >/dev/null 2>&1; then return 0; fi
        i=$((i + 1)); sleep 1
    done
    echo "Server on port $1 did not start. See the .log files in $BASE"; return 1
}

# kill_node NAME : simulates a crash (no clean shutdown)
kill_node() {
    kill -9 "$(cat "$BASE/pids/$1.pid")" 2>/dev/null
}

# stop_everything : stops every process started by these scripts
stop_everything() {
    for f in "$BASE"/pids/*.pid; do
        [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
    done
    sleep 3
    for f in "$BASE"/pids/*.pid; do
        [ -f "$f" ] && kill -9 "$(cat "$f")" 2>/dev/null
        rm -f "$f"
    done
}
