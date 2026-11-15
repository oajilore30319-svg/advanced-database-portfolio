#!/bin/sh
# =====================================================================
# Portfolio 4 - export from PostgreSQL, load into MongoDB, run the demos.
# Run from inside the portfolio-4-nosql folder:
#     sh run_all.sh
# Needs: PostgreSQL with the Portfolio 2 dataset, and MongoDB running
# locally (brew services start mongodb-community).
# =====================================================================
PGDB="${PGDB:-lagoonpay_db}"
MONGO_URI="${MONGO_URI:-mongodb://127.0.0.1:27017/lagoonpay}"
cd "$(dirname "$0")" || exit 1
mkdir -p results data

echo "Step 1 of 4: exporting documents from PostgreSQL..."
psql -X -q -d "$PGDB" -f 01_export_from_postgres.sql > results/01_export.txt 2>&1
wc -l data/customers.json data/activity.json >> results/01_export.txt
tail -4 results/01_export.txt

echo "Step 2 of 4: creating collections and loading into MongoDB..."
mongosh --quiet "$MONGO_URI" --file 02_load_data.js > results/02_load_data.txt 2>&1
head -5 results/02_load_data.txt

echo "Step 3 of 4: queries, indexes, updates, validation..."
mongosh --quiet "$MONGO_URI" --file 03_queries.js > results/03_queries.txt 2>&1

echo "Step 4 of 4: aggregation pipelines..."
mongosh --quiet "$MONGO_URI" --file 04_aggregations.js > results/04_aggregations.txt 2>&1

echo
echo "Lines containing an error (REJECTED lines in section F are expected):"
grep -n -i "error\|REJECTED\|ACCEPTED (unexpected)" results/02_load_data.txt results/03_queries.txt results/04_aggregations.txt
echo "Done. Output of each step is in the results folder."
