#!/usr/bin/env bash
# Installs a simple "Hello" holding page that nginx serves for the server's bare
# IP address and for any host name that doesn't belong to an account.
# Safe to re-run.
#
#   sudo bash appserver/install-holding.sh
set -eu
DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
. "$DIR/../lib.sh"

[[ $EUID -eq 0 ]] || { err "Run as root: sudo $0"; exit 1; }
command -v nginx >/dev/null 2>&1 || { err "nginx is not installed. Run install.sh first."; exit 1; }

HOLD_ROOT=$WWW_ROOT/_holding
CONF=$NGINX_AVAIL/_holding.conf

mkdir -p "$HOLD_ROOT"
cp "$DIR/holding/index.html" "$HOLD_ROOT/index.html"
chown -R www-data:www-data "$HOLD_ROOT"

cp "$DIR/holding/_holding.conf" "$CONF"
ln -sf "$CONF" "$NGINX_ENABLED/_holding.conf"
rm -f "$NGINX_ENABLED/default"

if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    ok "Holding page live. Browse to this server's IP address to see it."
else
    err "nginx rejected the configuration; removing the holding page config:"
    nginx -t 2>&1 | sed 's/^/    /' >&2
    rm -f "$NGINX_ENABLED/_holding.conf" "$CONF"
    exit 1
fi
