#!/bin/sh
# =====================================================================
# Portfolio 3 - run every demonstration in order.
# Run from inside the portfolio-3-transactions-concurrency folder:
#     sh run_all.sh
# The output of each demo, including the expected ERROR messages, is
# written to the results/ folder. Several demos exist to show PostgreSQL
# refusing something, so ERROR lines in those files are intended.
# =====================================================================
DB="${1:-lagoonpay_db}"
cd "$(dirname "$0")" || exit 1
mkdir -p results

run() {
    echo "$2"
    psql -X -d "$DB" -f "$1" > "results/${1%.sql}.txt" 2>&1
}

run 00_setup.sql                   "Setup..."
run 01_commit_rollback.sql         "Demo 1 of 5: commit, rollback, savepoint"
run 02_isolation_levels.sql        "Demo 2 of 5: isolation levels"
run 03_lost_update_locking.sql     "Demo 3 of 5: lost update and locking"
run 04_serializable_write_skew.sql "Demo 4 of 5: write skew and SERIALIZABLE"
run 05_deadlock.sql                "Demo 5 of 5: deadlock"

echo
echo "Final check: accounts whose stored balance differs from the ledger (must be 0)"
psql -X -d "$DB" -c "SELECT COUNT(*) AS accounts_out_of_balance FROM lagoonpay.v_balance_reconciliation WHERE difference <> 0"
echo "Done. Output of each demo is in the results folder."
