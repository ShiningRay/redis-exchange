#!/bin/bash
# Export balances and ledger sequences from a Redis RDB file to CSV.
# Dependencies:
#   - rdb-cli (included in bin/)
#   - jq (brew install jq / apt install jq)
#
# Usage:
#   ./script/export_rdb_data.sh [options] [path/to/dump.rdb]
#
# Options:
#   -h, --host <host>     Redis host (default: 127.0.0.1)
#   -p, --port <port>     Redis port (default: 6379)
#   -a, --password <pwd>  Redis password
#

set -e

REDIS_HOST="127.0.0.1"
REDIS_PORT="6379"
REDIS_PASS=""
USE_REMOTE=false
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--host)
      REDIS_HOST="$2"
      USE_REMOTE=true
      shift 2
      ;;
    -p|--port)
      REDIS_PORT="$2"
      USE_REMOTE=true
      shift 2
      ;;
    -a|--password)
      REDIS_PASS="$2"
      USE_REMOTE=true
      shift 2
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}"

if [ ${#POSITIONAL_ARGS[@]} -gt 0 ]; then
  RDB_FILE="${POSITIONAL_ARGS[0]}"
  if [ ! -f "$RDB_FILE" ]; then
    echo "Error: RDB file '$RDB_FILE' not found."
    exit 1
  fi
  CLEANUP_RDB=false
elif [ "$USE_REMOTE" = true ]; then
  if ! command -v redis-cli &> /dev/null; then
    echo "Error: redis-cli not found. Cannot dump from remote Redis."
    exit 1
  fi
  
  RDB_FILE="dump_$(date +%s).rdb"
  echo "Dumping data from ${REDIS_HOST}:${REDIS_PORT} to ${RDB_FILE}..."
  
  CMD="redis-cli -h $REDIS_HOST -p $REDIS_PORT"
  if [ -n "$REDIS_PASS" ]; then
    CMD="$CMD -a $REDIS_PASS"
  fi
  CMD="$CMD --rdb $RDB_FILE"
  
  $CMD
  
  if [ ! -f "$RDB_FILE" ]; then
    echo "Error: Failed to dump RDB file from remote."
    exit 1
  fi
  CLEANUP_RDB=true
else
  # Default fallback
  RDB_FILE="dump.rdb"
  if [ ! -f "$RDB_FILE" ]; then
    echo "Error: RDB file '$RDB_FILE' not found."
    echo "Usage: $0 [options] [path/to/dump.rdb]"
    exit 1
  fi
  CLEANUP_RDB=false
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

SNAPSHOT_DATA=$(cat stream_raw.json | jq -r '
  try (map(select(.account_ledger != null)) | first | .account_ledger.entries | last | "\(.id) \(.items.ts // 0)") catch "0-0 0"
')

SNAPSHOT_ID=$(echo "$SNAPSHOT_DATA" | awk '{print $1}')
SNAPSHOT_TS=$(echo "$SNAPSHOT_DATA" | awk '{print $2}')

if [ -z "$SNAPSHOT_ID" ] || [ "$SNAPSHOT_ID" == "null" ]; then
  SNAPSHOT_ID="0-0"
fi

mv balances.csv balances_${SNAPSHOT_ID}_${SNAPSHOT_TS}.csv
echo "Snapshot ID: $SNAPSHOT_ID, Timestamp: $SNAPSHOT_TS"
echo "Renamed balances.csv to balances_${SNAPSHOT_ID}_${SNAPSHOT_TS}.csv"

# Cleanup
if [ "$CLEANUP_RDB" = true ]; then
  echo "Cleaning up temporary RDB file $RDB_FILE..."
  rm "$RDB_FILE"
fi

rm -f balances_raw.json ledger_seq_raw.json stream_raw.json