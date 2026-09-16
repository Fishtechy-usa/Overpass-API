#!/usr/bin/env bash
# Entrypoint for the Overpass API container.
#
# On first start (empty /db volume) it imports an .osm.bz2 extract, then on
# every start it launches:
#   - the dispatcher (owns the on-disk database, serves the CGI frontend)
#   - the minutely diff-update loop (optional, only if a replicate_id exists)
#   - Apache, running the CGI "interpreter" that answers /api/interpreter
set -uo pipefail

DB_DIR="${OVERPASS_DB_DIR:-/db/}"
[[ "$DB_DIR" == */ ]] || DB_DIR="${DB_DIR}/"
EXEC_DIR="/usr/local"
IMPORT_FILE="${OVERPASS_IMPORT_FILE:-/data/import.osm.bz2}"
DIFF_URL="${OVERPASS_DIFF_URL:-https://planet.openstreetmap.org/replication/minute}"
DIFF_UPDATES="${OVERPASS_DIFF_UPDATES:-1}"
REPLICATION_SEQ="${OVERPASS_REPLICATION_SEQUENCE_NUMBER:-}"

META_FLAG=""
if [[ "${OVERPASS_META:-yes}" == "yes" ]]; then
  META_FLAG="--meta"
fi

export OVERPASS_DB_DIR="$DB_DIR"

mkdir -p "$DB_DIR"

log() { echo "[entrypoint] $*"; }

# ---------------------------------------------------------------------------
# First-run import
# ---------------------------------------------------------------------------
if [[ ! -f "${DB_DIR}nodes.bin" ]]; then
  if [[ ! -s "$IMPORT_FILE" ]]; then
    log "ERROR: no database found in $DB_DIR and no import file at $IMPORT_FILE."
    log "Mount a compressed OSM extract (.osm.bz2) at that path (or set"
    log "OVERPASS_IMPORT_FILE) before starting the container the first time."
    exit 1
  fi

  log "No existing database in $DB_DIR - importing $IMPORT_FILE ..."
  "$EXEC_DIR/bin/init_osm3s.sh" "$IMPORT_FILE" "$DB_DIR" "$EXEC_DIR" "$META_FLAG"

  if [[ -n "$REPLICATION_SEQ" ]]; then
    echo "$REPLICATION_SEQ" > "${DB_DIR}replicate_id"
    log "Wrote replicate_id=$REPLICATION_SEQ (diff updates will resume from here)."
  else
    log "OVERPASS_REPLICATION_SEQUENCE_NUMBER not set - diff updates stay disabled"
    log "until you create ${DB_DIR}replicate_id yourself (see osm.org replication state)."
  fi
else
  log "Existing database found in $DB_DIR - skipping import."
fi

# Stale shared-memory / socket files from a previous, uncleanly-stopped run.
# The dispatcher's unix socket lives at ${DB_DIR}osm3s_osm_base (and
# osm3s_areas for the area dispatcher). If the container was killed rather
# than stopped gracefully, these files survive and the next dispatcher fails
# with "Address already in use". Remove every osm3s* runtime artifact, the
# same way the upstream debian/overpass init script does.
rm -f /dev/shm/osm3s* 2>/dev/null || true
rm -f "${DB_DIR}"osm3s* 2>/dev/null || true

# ---------------------------------------------------------------------------
# Start the dispatcher, (optional) diff updater, and Apache
# ---------------------------------------------------------------------------
PIDS=()

cleanup() {
  log "Shutting down..."
  apache2ctl stop >/dev/null 2>&1 || true
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  exit 0
}
trap cleanup TERM INT

log "Starting dispatcher (db-dir=$DB_DIR, meta=${OVERPASS_META:-yes}) ..."
"$EXEC_DIR/bin/dispatcher" $META_FLAG --osm-base --db-dir="$DB_DIR" &
PIDS+=("$!")

# Give the dispatcher a moment to create its socket before anything queries it.
sleep 3

if [[ "$DIFF_UPDATES" == "1" && -s "${DB_DIR}replicate_id" ]]; then
  log "Starting minutely diff updates from $DIFF_URL ..."
  "$EXEC_DIR/bin/fetch_osc_and_apply.sh" "$DIFF_URL" &
  PIDS+=("$!")
else
  log "Diff updates disabled (no replicate_id, or OVERPASS_DIFF_UPDATES=0)."
fi

log "Starting Apache (CGI frontend on :80) ..."
apache2ctl -D FOREGROUND &
PIDS+=("$!")

# Exit (and let Docker restart the container, per its restart policy) as soon
# as any of the supervised processes dies.
wait -n "${PIDS[@]}"
log "One of the supervised processes exited - stopping the container."
cleanup
