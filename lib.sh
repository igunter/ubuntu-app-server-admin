#!/usr/bin/env bash
# Shared helpers for the admin scripts. Sourced by them - not run directly.
#
# Layout
#   /etc/webaccounts/<name>.env      account metadata (source of truth)
#   /etc/webaccounts/settings.env    global settings (certbot email)
#   /etc/nginx/sites-available/<name>.conf   generated from metadata
#   /etc/nginx/sites-enabled/<name>.conf     symlink to the above
#   /var/www/<name>/public           document root (Laravel's public/ folder fits here)
#   /var/www/_disabled/              "account suspended" page
#   /var/www/_acme/                  Let's Encrypt webroot challenges

META_DIR=/etc/webaccounts
SETTINGS=$META_DIR/settings.env
WWW_ROOT=/var/www
DISABLED_ROOT=$WWW_ROOT/_disabled
ACME_ROOT=$WWW_ROOT/_acme
NGINX_AVAIL=/etc/nginx/sites-available
NGINX_ENABLED=/etc/nginx/sites-enabled

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'

info() { echo "${CYN}$*${RST}"; }
ok()   { echo "${GRN}$*${RST}"; }
warn() { echo "${YEL}$*${RST}"; }
err()  { echo "${RED}$*${RST}" >&2; }

pause() { read -rp "Press Enter to continue..." _; }

# ---------------------------------------------------------------- validation
valid_name()   { [[ $1 =~ ^[a-z][a-z0-9_-]{1,30}$ ]]; }
valid_domain() { [[ $1 =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; }
valid_size()   { [[ $1 =~ ^[0-9]+[mMkK]$ ]]; }
valid_dbname() { [[ $1 =~ ^[a-z][a-z0-9_]{0,30}$ ]]; }
valid_ipv4() {
    local o
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS=.
    for o in $1; do ((10#$o <= 255)) || return 1; done
}

account_exists() { [[ -f $META_DIR/$1.env ]]; }

# Echo the account that owns domain $1 (if any).
domain_owner() {
    local f d
    for f in "$META_DIR"/*.env; do
        [[ -e $f && $f != "$SETTINGS" ]] || continue
        d=$(DOMAINS=; . "$f"; echo " $DOMAINS ")
        if [[ $d == *" $1 "* ]]; then basename "$f" .env; return 0; fi
    done
    return 1
}

list_names() {
    local f
    for f in "$META_DIR"/*.env; do
        [[ -e $f && $f != "$SETTINGS" ]] && basename "$f" .env
    done
}

# ------------------------------------------------------------------ metadata
# Fields: DOMAINS (space separated, first = primary), STATUS (on|off),
#         SSL (on|off), PHP (on|off), MAX_UPLOAD (e.g. 32M)
load_account() {
    DOMAINS=; STATUS=on; SSL=off; PHP=off; MAX_UPLOAD=32M
    . "$META_DIR/$1.env"
    ACCOUNT=$1
}

save_account() {
    cat > "$META_DIR/$ACCOUNT.env" <<EOF
DOMAINS="$DOMAINS"
STATUS=$STATUS
SSL=$SSL
PHP=$PHP
MAX_UPLOAD=$MAX_UPLOAD
EOF
}

# Pick an account from a numbered list; sets ACCOUNT via load_account.
choose_account() {
    local names=() n i
    mapfile -t names < <(list_names)
    if ((${#names[@]} == 0)); then warn "No accounts exist yet."; return 1; fi
    for i in "${!names[@]}"; do
        n=${names[$i]}
        printf "  %d) %s\n" $((i + 1)) "$n"
    done
    read -rp "Select account (number or name, blank to cancel): " n
    [[ -z $n ]] && return 1
    if [[ $n =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#names[@]})); then
        n=${names[$((n - 1))]}
    fi
    if ! account_exists "$n"; then err "No such account: $n"; return 1; fi
    load_account "$n"
}

# ----------------------------------------------------------------------- PHP
php_socket() {
    local s
    s=$(ls /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n1)
    [[ -n $s ]] && echo "$s"
}

# ------------------------------------------------------------- nginx config
cert_name() { echo "$ACCOUNT"; }
cert_ready() { [[ -f /etc/letsencrypt/live/$ACCOUNT/fullchain.pem ]]; }

# Location blocks shared by the http and https servers.
emit_body() {
    local root=$WWW_ROOT/$ACCOUNT/public
    # PHP accounts fall back to index.php (front controller, as Laravel needs);
    # static accounts return 404 for unknown paths.
    local fallback='=404'
    [[ $PHP == on ]] && fallback='/index.php?$query_string'
    if [[ $STATUS == off ]]; then
        cat <<EOF
    root $DISABLED_ROOT;
    error_page 503 /index.html;
    location = /index.html { internal; }
    location / { return 503; }
EOF
        return
    fi
    cat <<EOF
    root $root;
    index index.php index.html index.htm;
    client_max_body_size $MAX_UPLOAD;

    location / {
        try_files \$uri \$uri/ $fallback;
    }

    location ~ /\.(?!well-known) { deny all; }
EOF
    if [[ $PHP == on ]]; then
        local sock; sock=$(php_socket)
        cat <<EOF

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${sock:-/run/php/php-fpm.sock};
    }
EOF
    fi
}

# The standalone "http2 on;" directive needs nginx 1.25.1+; older versions
# take http2 as a parameter on the listen line instead.
nginx_has_http2_directive() {
    local v
    v=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
    [[ -n $v && $(printf '%s\n' "$v" 1.25.1 | sort -V | head -n1) == 1.25.1 ]]
}

render_conf() {
    local logs=/var/log/nginx/$ACCOUNT
    echo "# Managed by webadmin - manual edits will be overwritten."
    echo "# Account: $ACCOUNT"
    echo
    echo "server {"
    echo "    listen 80;"
    echo "    listen [::]:80;"
    echo "    server_name $DOMAINS;"
    echo "    access_log $logs.access.log;"
    echo "    error_log  $logs.error.log;"
    echo
    echo "    location ^~ /.well-known/acme-challenge/ { root $ACME_ROOT; }"
    echo
    if [[ $SSL == on ]]; then
        echo "    location / { return 301 https://\$host\$request_uri; }"
        echo "}"
        echo
        echo "server {"
        if nginx_has_http2_directive; then
            echo "    listen 443 ssl;"
            echo "    listen [::]:443 ssl;"
            echo "    http2 on;"
        else
            echo "    listen 443 ssl http2;"
            echo "    listen [::]:443 ssl http2;"
        fi
        echo "    server_name $DOMAINS;"
        echo "    access_log $logs.access.log;"
        echo "    error_log  $logs.error.log;"
        echo
        echo "    ssl_certificate     /etc/letsencrypt/live/$ACCOUNT/fullchain.pem;"
        echo "    ssl_certificate_key /etc/letsencrypt/live/$ACCOUNT/privkey.pem;"
        echo "    ssl_protocols TLSv1.2 TLSv1.3;"
        echo
    fi
    emit_body
    echo "}"
}

# Older versions served /var/www/<name>/public_html. The document root is now
# /var/www/<name>/public, so move an old folder across the first time the
# account's conf is rewritten (never overwrites an existing public/).
migrate_docroot() {
    local base=$WWW_ROOT/$ACCOUNT
    if [[ -d $base/public_html && ! -e $base/public ]]; then
        mv "$base/public_html" "$base/public"
        info "Moved $base/public_html to $base/public"
    fi
}

# Write conf from current variables, enable it, test and reload nginx.
# Rolls back to the previous conf if nginx rejects the result.
apply_conf() {
    local avail=$NGINX_AVAIL/$ACCOUNT.conf backup=
    migrate_docroot
    if [[ -f $avail ]]; then
        backup=$(mktemp); cp "$avail" "$backup"
    fi
    render_conf > "$avail"
    ln -sf "$avail" "$NGINX_ENABLED/$ACCOUNT.conf"
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
        [[ -n $backup ]] && rm -f "$backup"
        return 0
    fi
    err "nginx rejected the configuration:"
    nginx -t 2>&1 | sed 's/^/    /' >&2
    if [[ -n $backup ]]; then
        mv "$backup" "$avail"
    else
        rm -f "$avail" "$NGINX_ENABLED/$ACCOUNT.conf"
    fi
    return 1
}

# ------------------------------------------------------------------- certbot
ensure_email() {
    [[ -f $SETTINGS ]] && . "$SETTINGS"
    if [[ -z ${CERTBOT_EMAIL:-} ]]; then
        read -rp "Email address for Let's Encrypt notices: " CERTBOT_EMAIL
        [[ -z $CERTBOT_EMAIL ]] && return 1
        echo "CERTBOT_EMAIL=$CERTBOT_EMAIL" > "$SETTINGS"
    fi
}

# Issue / expand / shrink the cert so it covers exactly $1 (space separated).
issue_cert() {
    local domains=$1 args=() d
    ensure_email || { err "An email address is required."; return 1; }
    for d in $domains; do args+=(-d "$d"); done
    certbot certonly --webroot -w "$ACME_ROOT" --cert-name "$ACCOUNT" \
        "${args[@]}" --non-interactive --agree-tos --expand \
        -m "$CERTBOT_EMAIL"
}

# ------------------------------------------------------------------- server
# 24 random letters and digits (safe to put inside SQL quotes).
random_password() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; }

# Create a swap file of size $1 (default 2G) if the server has no swap yet.
ensure_swap() {
    local size=${1:-2G}
    if [[ -n $(swapon --show --noheadings) ]]; then
        info "Swap already active, skipping."
        return 0
    fi
    info "Creating $size swap file..."
    fallocate -l "$size" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
}

# ------------------------------------------------------------------- display
ssl_label() { [[ $1 == on ]] && echo "${GRN}ON ${RST}" || echo "off"; }
status_label() { [[ $1 == on ]] && echo "${GRN}enabled ${RST}" || echo "${RED}DISABLED${RST}"; }

show_account() {
    echo "  Account : $ACCOUNT"
    echo "  Status  : $(status_label "$STATUS")"
    echo "  SSL     : $(ssl_label "$SSL")"
    echo "  PHP     : $PHP"
    echo "  Upload  : $MAX_UPLOAD"
    echo "  Domains : $DOMAINS"
    echo "  Web root: $WWW_ROOT/$ACCOUNT/public"
}
