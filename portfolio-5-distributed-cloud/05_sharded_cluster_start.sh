#!/bin/sh
# =====================================================================
# Portfolio 5, part B: start a small sharded cluster on this machine
#   config server (cfgRS)  : 127.0.0.1:27201   cluster metadata
#   shard 1 (shard1RS)     : 127.0.0.1:27211   data
#   shard 2 (shard2RS)     : 127.0.0.1:27212   data
#   mongos router          : 127.0.0.1:27200   what applications connect to
# In production each of the three would be a three-member replica set
# like the one in part A. One member each is used here to keep the demo
# light on a laptop.
# =====================================================================
cd "$(dirname "$0")" || exit 1
. ./00_env.sh

stop_everything
rm -rf "$BASE"/cfg "$BASE"/shard1 "$BASE"/shard2

start_mongod cfg    "$CFG_PORT"    --configsvr --replSet cfgRS
start_mongod shard1 "$SHARD1_PORT" --shardsvr  --replSet shard1RS
start_mongod shard2 "$SHARD2_PORT" --shardsvr  --replSet shard2RS
for p in $CFG_PORT $SHARD1_PORT $SHARD2_PORT; do wait_for_port "$p" || exit 1; done

init_rs() {   # init_rs PORT NAME EXTRA
    mongosh --quiet --port "$1" --eval "
      rs.initiate({ _id: '$2', $3 members: [{ _id: 0, host: '127.0.0.1:$1' }] });
      for (let i = 0; i < 60 && !db.hello().isWritablePrimary; i++) sleep(500);
      print('  $2 on 127.0.0.1:$1 is ' + (db.hello().isWritablePrimary ? 'PRIMARY' : 'not ready'));"
}
init_rs "$CFG_PORT"    cfgRS    "configsvr: true,"
init_rs "$SHARD1_PORT" shard1RS ""
init_rs "$SHARD2_PORT" shard2RS ""

nohup mongos --port "$MONGOS_PORT" --bind_ip 127.0.0.1 --configdb "cfgRS/127.0.0.1:$CFG_PORT" > "$BASE/mongos.log" 2>&1 &
echo $! > "$BASE/pids/mongos.pid"
wait_for_port "$MONGOS_PORT" || exit 1
echo "  mongos router on 127.0.0.1:$MONGOS_PORT is up"
