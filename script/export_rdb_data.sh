#!/bin/bash
# Export balances and ledger sequences from a Redis RDB file to CSV.
#
# Outputs:
#   - balances_{SNAPSHOT_ID}_{TIMESTAMP}.csv: User balances (available, reserved).
#   - ledger_sequences_{SNAPSHOT_ID}_{TIMESTAMP}.csv: Ledger sequence numbers.
#
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
#   -u, --url <url>       Redis URL (e.g. redis://[:password@]host:port[/db])
#

set -e

REDIS_HOST="127.0.0.1"
REDIS_PORT="6379"
REDIS_PASS=""
REDIS_URL=""
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
    -u|--url)
      REDIS_URL="$2"
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

  # Create tmp directory if it doesn't exist
  mkdir -p tmp

  RDB_FILE="tmp/dump_$(date +%s).rdb"

  if [ -n "$REDIS_URL" ]; then
    echo "Dumping data from Redis URL to ${RDB_FILE}..."
    
    # Check if URL contains password but empty username (e.g. redis://:password@host...)
    # This causes redis-cli to fail with "invalid uri scheme" or similar errors depending on version
    # If detected, inject 'default' as username
    if [[ "$REDIS_URL" =~ redis://:[^@]+@ ]]; then
      echo "  Detected empty username with password in REDIS_URL. Injecting 'default' username..."
      REDIS_URL="${REDIS_URL/redis:\/\/:/redis:\/\/default:}"
    fi

    CMD="redis-cli -u $REDIS_URL --rdb $RDB_FILE"
  else
    echo "Dumping data from ${REDIS_HOST}:${REDIS_PORT} to ${RDB_FILE}..."

    CMD="redis-cli -h $REDIS_HOST -p $REDIS_PORT"
    if [ -n "$REDIS_PASS" ]; then
      CMD="$CMD -a $REDIS_PASS"
    fi
    CMD="$CMD --rdb $RDB_FILE"
  fi

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

# Create tmp directory if it doesn't exist
mkdir -p tmp

echo "Exporting balances to tmp/balances.csv..."
echo "user_id,asset,available,reserved" > tmp/balances.csv

# rdb-cli json outputs: [{"key": value, "key2": value2}] (Array of objects, usually one per DB)
# We filter for keys starting with "balance:" using -k
$RDB_CMD "$RDB_FILE" -k "balance:*" json > tmp/balances_raw.json
# echo "Raw JSON:"
# cat tmp/balances_raw.json

cat tmp/balances_raw.json | jq -r '
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
' >> tmp/balances.csv

echo "  -> Wrote $(wc -l < tmp/balances.csv) lines (including header)"

echo "Exporting ledger sequences to tmp/ledger_sequences.csv..."
echo "user_id,asset,sequence" > tmp/ledger_sequences.csv

# Filter for keys starting with "ledger_seq:"
$RDB_CMD "$RDB_FILE" -k "ledger_seq:*" json > tmp/ledger_seq_raw.json

cat tmp/ledger_seq_raw.json | jq -r '
  .[] | to_entries[] |
  (.key | split(":")) as $p |
  "\( $p[1] ),\( $p[2] ),\( .value )"
' >> tmp/ledger_sequences.csv

echo "  -> Wrote $(wc -l < tmp/ledger_sequences.csv) lines (including header)"

# 3. Export Snapshot ID (Last Entry ID from account_ledger)
echo "Exporting snapshot ID from account_ledger..."

# rdb-cli output for stream varies based on Redis stream structure
# Try to get the last entry from account_ledger stream
# Note: rdb-cli outputs invalid JSON ("account_ledger":) for empty streams, so we need to fix that
$RDB_CMD "$RDB_FILE" -k "account_ledger" json | sed 's/"account_ledger":$/&null/' > tmp/stream_raw.json

# Debug: show the raw JSON structure (commented out)
# cat stream_raw.json

# Actual JSON structure from rdb-cli for Redis streams:
# [{"account_ledger": {"entries": [{"id": "...", "items": {"ts": "...", ...}}, ...]}}]
# Note: Some databases may have empty account_ledger, so we need to filter them out
SNAPSHOT_DATA=$(cat tmp/stream_raw.json | jq -r '
  try (
    .[] |
    select(has("account_ledger") and .account_ledger != null and (.account_ledger.entries // null) != null) |
    .account_ledger.entries |
    select(length > 0) |
    last | "\(.id) \(.items.ts // 0)"
  ) catch "0-0 0"
')

# Take the last non-empty line (from the database with actual data)
SNAPSHOT_LINE=$(echo "$SNAPSHOT_DATA" | grep -v '^0-0 0$' | tail -n 1)
if [ -z "$SNAPSHOT_LINE" ]; then
  SNAPSHOT_LINE="0-0 0"
fi

SNAPSHOT_ID=$(echo "$SNAPSHOT_LINE" | awk '{print $1}')
SNAPSHOT_TS=$(echo "$SNAPSHOT_LINE" | awk '{print $2}')

if [ -z "$SNAPSHOT_ID" ] || [ "$SNAPSHOT_ID" == "null" ]; then
  SNAPSHOT_ID="0-0"
fi

mv tmp/balances.csv tmp/balances_${SNAPSHOT_ID}_${SNAPSHOT_TS}.csv
mv tmp/ledger_sequences.csv tmp/ledger_sequences_${SNAPSHOT_ID}_${SNAPSHOT_TS}.csv
echo "Snapshot ID: $SNAPSHOT_ID, Timestamp: $SNAPSHOT_TS"
echo "Renamed balances.csv to tmp/balances_${SNAPSHOT_ID}_${SNAPSHOT_TS}.csv"
echo "Renamed ledger_sequences.csv to tmp/ledger_sequences_${SNAPSHOT_ID}_${SNAPSHOT_TS}.csv"

# Cleanup
if [ "$CLEANUP_RDB" = true ]; then
  echo "Cleaning up temporary RDB file $RDB_FILE..."
  rm "$RDB_FILE"
fi

rm -f tmp/balances_raw.json tmp/ledger_seq_raw.json tmp/stream_raw.json