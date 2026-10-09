#!/usr/bin/env bash
# One-time setup: installs nginx + certbot and creates the shared directories
# and the "account disabled" page. Safe to re-run.
set -eu
DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
. "$DIR/lib.sh"

[[ $EUID -eq 0 ]] || { err "Run as root: sudo $0"; exit 1; }

apt-get update
apt-get install -y nginx certbot

mkdir -p "$META_DIR" "$DISABLED_ROOT" "$ACME_ROOT"
chmod 700 "$META_DIR"
chmod +x "$DIR/webadmin.sh"

cat > "$DISABLED_ROOT/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Site Unavailable</title>
<style>
  body { font-family: system-ui, sans-serif; background: #f4f5f7; color: #333;
         display: flex; min-height: 100vh; margin: 0; align-items: center; justify-content: center; }
  .box { background: #fff; padding: 2.5rem 3rem; border-radius: 8px; text-align: center;
         box-shadow: 0 2px 12px rgba(0,0,0,.1); max-width: 28rem; }
  h1 { margin-top: 0; }
</style>
</head>
<body>
  <div class="box">
    <h1>Site Unavailable</h1>
    <p>This website is currently disabled. Please contact the site owner or try again later.</p>
  </div>
</body>
</html>
EOF
chown -R www-data:www-data "$DISABLED_ROOT" "$ACME_ROOT"

# Drop the stock site so it doesn't catch unknown hosts on port 80.
rm -f "$NGINX_ENABLED/default"

systemctl enable --now nginx
nginx -t && systemctl reload nginx

ok "Setup complete. Start the manager with:  sudo $DIR/webadmin.sh"
warn "Optional for PHP accounts:  sudo apt install php-fpm"
