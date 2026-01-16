#!/bin/bash
# Export balances and ledger sequences from a Redis RDB file to CSV.
# Dependencies:
#   - rdb-cli (included in bin/)
#   - jq (brew install jq / apt install jq)
#
# Usage:
#   ./script/export_rdb_data.sh [path/to/dump.rdb]

set -e

RDB_FILE="${1:-dump.rdb}"

if [ ! -f "$RDB_FILE" ]; then
  echo "Error: RDB file '$RDB_FILE' not found."
  echo "Usage: $0 [path/to/dump.rdb]"
  exit 1
fi

# Check for rdb-cli (librdb)
if [ -n "$RDB_CLI_CMD" ]; then
  RDB_CMD="$RDB_CLI_CMD"
elif [ -f "./bin/rdb-cli" ]; then
  RDB_CMD="./bin/rdb-cli"
elif command -v rdb-cli &> /dev/null; then
  RDB_CMD="rdb-cli"
else
  echo "Error: 'rdb-cli' command not found. Please ensure bin/rdb-cli exists."
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "Error: 'jq' command not found. Please install jq."
  exit 1
fi

echo "Processing $RDB_FILE..."

echo "Exporting balances to balances.csv..."
echo "user_id,asset,available,reserved" > balances.csv

# rdb-cli json outputs: [{"key": value, "key2": value2}] (Array of objects, usually one per DB)
# We filter for keys starting with "balance:" using -k
$RDB_CMD "$RDB_FILE" -k "balance:*" json > balances_raw.json
# echo "Raw JSON:"
# cat balances_raw.json

cat balances_raw.json | jq -r '
  .[] | to_entries[] |
  .key as $k |
  .value | to_entries |
  map(
    (.key | split(":")) as $p |
    {asset: $p[0], bucket: $p[1], val: .value}
  ) |
  group_by(.asset)[] |
  {
    user: ($k | split(":")[1]),
    asset: .[0].asset,
    avail: (map(select(.bucket=="available"))[0].val // "0"),
    reserved: (map(select(.bucket=="reserved"))[0].val // "0")
  } |
  "\(.user),\(.asset),\(.avail),\(.reserved)"
' >> balances.csv

echo "  -> Wrote $(wc -l < balances.csv) lines (including header)"

echo "Exporting ledger sequences to ledger_sequences.csv..."
echo "user_id,asset,sequence" > ledger_sequences.csv

# Filter for keys starting with "ledger_seq:"
$RDB_CMD "$RDB_FILE" -k "ledger_seq:*" json > ledger_seq_raw.json

cat ledger_seq_raw.json | jq -r '
  .[] | to_entries[] |
  (.key | split(":")) as $p |
  "\( $p[1] ),\( $p[2] ),\( .value )"
' >> ledger_sequences.csv
  
echo "  -> Wrote $(wc -l < ledger_sequences.csv) lines (including header)"

# 3. Export Snapshot ID (Last Entry ID from account_ledger)
echo "Exporting snapshot ID from account_ledger..."

# rdb-cli output for stream: [{"account_ledger": {"entries": [{"id": "...", "items": {...}}]}}]
$RDB_CMD "$RDB_FILE" -k "account_ledger" json > stream_raw.json

SNAPSHOT_ID=$(cat stream_raw.json | jq -r '
  try (.[0].account_ledger.entries | last | .id) catch "0-0"
')

if [ -z "$SNAPSHOT_ID" ] || [ "$SNAPSHOT_ID" == "null" ]; then
  SNAPSHOT_ID="0-0"
fi

mv balances.csv balances_$SNAPSHOT_ID.csv
echo "Snapshot ID: $SNAPSHOT_ID"
echo "Renamed balances.csv to balances_$SNAPSHOT_ID.csv"

# Cleanup
rm -f balances_raw.json ledger_seq_raw.json stream_raw.json