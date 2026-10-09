#!/usr/bin/env bash
# Step 1 of the restore test. Run on the LIVE DB server.
#
#   sudo bash dbserver/restore-test-prepare.sh
#
# Creates a separate database called restore_test (your app data is not touched),
# inserts marked rows, waits, notes the time, deletes the rows, then forces the
# last WAL to the bucket. It prints the timestamp to restore to: at that moment
# the rows existed; after it, they were deleted.
set -eu
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
. "$DIR/../lib.sh"
[[ $EUID -eq 0 ]] || { err "Run as root: sudo $0"; exit 1; }

STANZA=${STANZA:-main}
OUT=/var/tmp/restore-test.txt
pg() { runuser -u postgres -- psql -v ON_ERROR_STOP=1 -Atq "$@"; }
ts() { pg -c "SELECT to_char(now(), 'YYYY-MM-DD HH24:MI:SS.USOF')"; }

command -v pgbackrest >/dev/null || { err "pgBackRest is not installed. Run install-backup.sh first."; exit 1; }

if [[ $(pg -c "SELECT 1 FROM pg_database WHERE datname='restore_test'") != 1 ]]; then
    runuser -u postgres -- createdb restore_test
fi
pg -d restore_test -c "CREATE TABLE IF NOT EXISTS marker (id serial PRIMARY KEY, note text, created_at timestamptz DEFAULT now())"
pg -d restore_test -c "TRUNCATE marker"

info "Inserting 5 marked rows..."
pg -d restore_test -c "INSERT INTO marker(note) SELECT 'restore-test row ' || g FROM generate_series(1,5) g"
INSERTED=$(ts)
echo "  Rows inserted at $INSERTED"

info "Waiting 90 seconds so the restore target is clearly after the insert..."
sleep 90
TARGET=$(ts)
echo "  Restore target (rows still present): $TARGET"
sleep 5

info "Deleting the rows..."
pg -d restore_test -c "DELETE FROM marker"
DELETED=$(ts)   # taken after the commit, with microseconds: a restore to it is after the delete
echo "  Rows deleted at $DELETED"

# PostgreSQL finds the time of a point from commit records, so a restore target
# only works if a later commit exists in the archive. Write a harmless one.
pg -d restore_test -c "CREATE TABLE IF NOT EXISTS heartbeat (t timestamptz); INSERT INTO heartbeat VALUES (now())"

info "Forcing the last changes into the bucket..."
pg -c "SELECT pg_switch_wal()" >/dev/null
sleep 5
runuser -u postgres -- pgbackrest --stanza="$STANZA" check

cat > "$OUT" <<EOF
rows_inserted_at=$INSERTED
restore_target_rows_present=$TARGET
rows_deleted_at=$DELETED
EOF
echo
ok "Ready for the restore test. Times saved to $OUT:"
cat "$OUT"
echo
echo "On the scratch server, restore to:  $TARGET   (expect 5 rows)"
echo "Then restore again to:              $DELETED  (expect 0 rows)"
