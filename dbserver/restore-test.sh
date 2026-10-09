#!/usr/bin/env bash
# Step 2 of the restore test. Run on a SCRATCH server, never the live one.
#
#   sudo bash dbserver/restore-test.sh
#
# Installs PostgreSQL + pgBackRest, restores the backups from the S3 bucket to the
# time you give, starts the restored database (local connections only) and
# shows what it contains. It uses a read-only key and archive-mode=off, so the
# restored copy cannot write anything into the live backup repository.
#
# It does NOT start any application. Nothing here can send email or DBS
# submissions. Re-run it with a different time to test another restore point.
set -eu
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
. "$DIR/../lib.sh"
[[ $EUID -eq 0 ]] || { err "Run as root: sudo $0"; exit 1; }

PGVER=${PGVER:-16}
STANZA=${STANZA:-main}
CONF=/etc/pgbackrest/pgbackrest.conf
DATA=/var/lib/postgresql/$PGVER/main

ask() { local v; read -rp "$1${3:+ [$3]}: " v; printf -v "$2" '%s' "${v:-${3:-}}"; }
ask_secret() { local v; read -rsp "$1: " v; echo; printf -v "$2" '%s' "$v"; }

echo "${YEL}This server's PostgreSQL data will be REPLACED by the restored copy."
echo "Only run this on a scratch server created for the test.${RST}"
read -rp "Type RESTORE-TEST to continue: " c
[[ $c == RESTORE-TEST ]] || { echo "Cancelled."; exit 1; }

# Refuse to run on a server that is itself archiving to a repository.
if command -v psql >/dev/null && systemctl is-active --quiet postgresql 2>/dev/null; then
    if [[ $(runuser -u postgres -- psql -Atc 'SHOW archive_mode' 2>/dev/null || true) == on ]]; then
        err "archive_mode is on here, so this looks like a live server. Stopping."; exit 1
    fi
fi

echo
ask "Bucket name" BUCKET
ask "Region" REGION eu-west-2
ask "READ-ONLY access key ID" S3_KEY
ask_secret "READ-ONLY secret access key (hidden)" S3_SECRET
ask_secret "Backup passphrase (hidden)" PASSPHRASE
ask "Restore to time (with offset, e.g. 2026-10-09 15:05:30+01)" TARGET
[[ -n $BUCKET && -n $S3_KEY && -n $S3_SECRET && -n $PASSPHRASE && -n $TARGET ]] || { err "All fields are required."; exit 1; }

SECONDS=0
info "Installing PostgreSQL $PGVER and pgBackRest..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "postgresql-$PGVER" pgbackrest

systemctl stop "postgresql@$PGVER-main" 2>/dev/null || true

install -d -o postgres -g postgres -m 750 /etc/pgbackrest /var/log/pgbackrest
( umask 077
cat > "$CONF" <<EOF
[global]
repo1-type=s3
repo1-s3-bucket=$BUCKET
repo1-s3-endpoint=s3.$REGION.amazonaws.com
repo1-s3-region=$REGION
repo1-s3-key=$S3_KEY
repo1-s3-key-secret=$S3_SECRET
repo1-path=/pgbackrest
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=$PASSPHRASE
log-path=/var/log/pgbackrest
log-level-console=info

[$STANZA]
pg1-path=$DATA
EOF
)
chown postgres:postgres "$CONF"; chmod 600 "$CONF"

info "Backups available in the bucket:"
runuser -u postgres -- pgbackrest --stanza="$STANZA" info

info "Restoring to $TARGET ..."
runuser -u postgres -- pgbackrest --stanza="$STANZA" --delta \
    --type=time "--target=$TARGET" --target-action=promote \
    --archive-mode=off restore
RESTORED=$SECONDS

# The live server's settings come with the data. Make this copy local-only.
AUTO=$DATA/postgresql.auto.conf
sed -i '/^listen_addresses/d' "$AUTO"
echo "listen_addresses = 'localhost'" >> "$AUTO"

info "Starting the restored database and waiting for recovery to finish..."
systemctl start "postgresql@$PGVER-main"
for _ in $(seq 1 120); do
    if [[ $(runuser -u postgres -- psql -Atc 'SELECT pg_is_in_recovery()' 2>/dev/null || echo t) == f ]]; then break; fi
    sleep 2
done
TOTAL=$SECONDS
[[ $(runuser -u postgres -- psql -Atc 'SELECT pg_is_in_recovery()') == f ]] || { err "Recovery did not finish. See: journalctl -u postgresql@$PGVER-main"; exit 1; }

echo
ok "============ Restore complete ============"
echo "Databases in the restored copy:"
runuser -u postgres -- psql -Atc "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY 1" | sed 's/^/  /'
if [[ $(runuser -u postgres -- psql -Atc "SELECT 1 FROM pg_database WHERE datname='restore_test'") == 1 ]]; then
    echo
    echo "restore_test.marker rows at $TARGET:"
    runuser -u postgres -- psql -d restore_test -Atc "SELECT count(*) || ' rows' FROM marker" | sed 's/^/  /'
fi
echo
echo "Timings: restore ${RESTORED}s (incl. install), database ready after ${TOTAL}s."
echo "Record these in the test checklist. Delete this scratch server when finished."
