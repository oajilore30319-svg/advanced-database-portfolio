#!/bin/sh
# Stops every MongoDB process started by the Portfolio 5 scripts and
# removes their temporary data. Does not touch the normal MongoDB service
# on port 27017.
cd "$(dirname "$0")" || exit 1
. ./00_env.sh
stop_everything
rm -rf "$BASE"
echo "Portfolio 5 processes stopped and temporary data removed."
