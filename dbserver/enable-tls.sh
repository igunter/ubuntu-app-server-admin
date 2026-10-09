#!/usr/bin/env bash
# TLS for PostgreSQL, with a private CA so the application can VERIFY the server.
#
#   sudo bash dbserver/enable-tls.sh            # create certificates and turn TLS on
#   sudo bash dbserver/enable-tls.sh enforce    # reject unencrypted connections
#   sudo bash dbserver/enable-tls.sh check      # show the current state
#   sudo bash dbserver/enable-tls.sh summary    # print the non-secret details for the app
#
# Two steps on purpose: set up the certificates first, give the application the
# CA certificate and switch it to verify-full, THEN enforce. Enforcing first
# would lock the application out.
#
# Secrets: the CA private key stays in /root/pg-tls (root only). Never share it.
# Only ca.crt (public) goes to the application / other parties.
set -eu
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
. "$DIR/../lib.sh"
[[ $EUID -eq 0 ]] || { err "Run as root: sudo $0"; exit 1; }

PG_ETC=${PG_ETC:-/etc/postgresql}
CA_DIR=${CA_DIR:-/root/pg-tls}
SERVER_DAYS=${SERVER_DAYS:-1095}   # server certificate lifetime (3 years)
CA_DAYS=${CA_DAYS:-3650}           # CA lifetime (10 years)

pg() { runuser -u postgres -- psql -v ON_ERROR_STOP=1 -Atq "$@"; }
yes_no() { local a def=${2:-n} hint='[y/N]'; [[ $def == y ]] && hint='[Y/n]'; read -rp "$1 $hint: " a; a=${a:-$def}; [[ ${a,,} == y* ]]; }

pg_version() { ls "$PG_ETC" 2>/dev/null | sort -n | tail -1; }
VER=$(pg_version)
[[ -n $VER ]] || { err "PostgreSQL not found in $PG_ETC."; exit 1; }
CONF_DIR=$PG_ETC/$VER/main
HBA=$CONF_DIR/pg_hba.conf

detect_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1; }

# Convert non-loopback "host" rules to "hostssl" (encrypted connections only).
enforce_hba() {
    awk '
        $1=="host" && $4 !~ /^(127\.0\.0\.1\/32|::1\/128)$/ && $4 != "samehost" { sub(/^host/, "hostssl") }
        { print }
    ' "$1"
}

make_certs() {
    local db_ip host san
    db_ip=$(detect_ip)
    read -rp "DB server private IP [$db_ip]: " v; db_ip=${v:-$db_ip}
    valid_ipv4 "$db_ip" || { err "Not a valid IPv4 address."; exit 1; }
    read -rp "Hostname the app will connect to (blank = use the IP): " host
    san="subjectAltName=IP:$db_ip,IP:127.0.0.1,DNS:localhost"
    [[ -n $host ]] && san="$san,DNS:$host"

    install -d -m 700 "$CA_DIR"
    if [[ ! -f $CA_DIR/ca.key ]]; then
        info "Creating the private CA..."
        openssl genrsa -out "$CA_DIR/ca.key" 3072 2>/dev/null
        openssl req -x509 -new -key "$CA_DIR/ca.key" -sha256 -days "$CA_DAYS" \
            -subj "/O=PostgreSQL private CA/CN=pg-ca-$(hostname)" -out "$CA_DIR/ca.crt"
        chmod 600 "$CA_DIR/ca.key"
    else
        info "Using the existing CA in $CA_DIR."
    fi

    info "Creating the server certificate (valid for: ${host:+$host, }$db_ip)..."
    openssl genrsa -out "$CA_DIR/server.key" 3072 2>/dev/null
    openssl req -new -key "$CA_DIR/server.key" -subj "/CN=${host:-$db_ip}" -out "$CA_DIR/server.csr"
    printf '%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$san" > "$CA_DIR/server.ext"
    openssl x509 -req -in "$CA_DIR/server.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
        -CAcreateserial -out "$CA_DIR/server.crt" -days "$SERVER_DAYS" -sha256 -extfile "$CA_DIR/server.ext" 2>/dev/null
    chmod 600 "$CA_DIR/server.key"
    printf '%s\n' "${host:-}" > "$CA_DIR/hostname"
    printf '%s\n' "$db_ip"   > "$CA_DIR/db_ip"
}

install_certs() {
    install -o postgres -g postgres -m 600 "$CA_DIR/server.key" "$CONF_DIR/server.key"
    install -o postgres -g postgres -m 644 "$CA_DIR/server.crt" "$CONF_DIR/server.crt"
    install -o postgres -g postgres -m 644 "$CA_DIR/ca.crt"     "$CONF_DIR/ca.crt"
    pg -c "ALTER SYSTEM SET ssl = 'on'"
    pg -c "ALTER SYSTEM SET ssl_cert_file = '$CONF_DIR/server.crt'"
    pg -c "ALTER SYSTEM SET ssl_key_file = '$CONF_DIR/server.key'"
    pg -c "ALTER SYSTEM SET ssl_min_protocol_version = 'TLSv1.2'"
    pg -c "SELECT pg_reload_conf()" >/dev/null
    sleep 2
}

verify_tls() {
    local ip host target
    ip=$(cat "$CA_DIR/db_ip"); host=$(cat "$CA_DIR/hostname")
    target=${host:-$ip}
    info "Checking the server presents a certificate that verifies against the CA..."
    if echo | openssl s_client -starttls postgres -connect "$ip:5432" -CAfile "$CA_DIR/ca.crt" \
            ${host:+-verify_hostname "$host"} -verify_ip "$ip" -verify_return_error 2>&1 | grep -q "Verification: OK"; then
        ok "TLS verified for $target (certificate chain and name/IP match)."
    else
        err "Verification failed. Check: sudo tail /var/log/postgresql/postgresql-$VER-main.log"
        return 1
    fi
}

cmd_enforce() {
    [[ -f $CA_DIR/ca.crt ]] || { err "Set up the certificates first: sudo bash $0"; exit 1; }
    warn "Enforcing means unencrypted connections from other servers are REFUSED."
    warn "Make sure the application already uses the CA certificate with verify-full."
    yes_no "Enforce encrypted connections now?" n || exit 0
    cp -a "$HBA" "$HBA.bak.$(date +%Y%m%d%H%M%S)"
    enforce_hba "$HBA" > "$HBA.new"
    cat "$HBA.new" > "$HBA"; rm -f "$HBA.new"
    chown postgres:postgres "$HBA"
    pg -c "SELECT pg_reload_conf()" >/dev/null
    ok "Done. Rules now requiring TLS:"
    grep -E '^hostssl' "$HBA" || warn "No hostssl rules found - is a database user set up (install-db.sh)?"
}

cmd_check() {
    echo "ssl:                     $(pg -c 'SHOW ssl')"
    echo "ssl_min_protocol_version: $(pg -c 'SHOW ssl_min_protocol_version')"
    echo "listen_addresses:        $(pg -c 'SHOW listen_addresses')"
    echo "Active remote rules:"
    grep -E '^(host|hostssl|hostnossl)\s' "$HBA" | grep -vE '127\.0\.0\.1/32|::1/128' | sed 's/^/  /' || true
    if grep -qE '^host\s' <(grep -vE '127\.0\.0\.1/32|::1/128' "$HBA"); then
        warn "Some remote rules still allow unencrypted connections (type 'host')."
    else
        ok "No remote rule allows unencrypted connections."
    fi
    echo "Current client sessions (local socket sessions, such as this check, count as unencrypted):"
    pg -c "SELECT count(*) FILTER (WHERE NOT s.ssl) || ' unencrypted, ' || count(*) FILTER (WHERE s.ssl) || ' encrypted' FROM pg_stat_ssl s JOIN pg_stat_activity a USING (pid) WHERE a.backend_type = 'client backend'" | sed 's/^/  /'
}

cmd_summary() {
    [[ -f $CA_DIR/ca.crt ]] || { err "No CA yet. Run: sudo bash $0"; exit 1; }
    local ip host
    ip=$(cat "$CA_DIR/db_ip"); host=$(cat "$CA_DIR/hostname")
    echo
    ok "============ Non-secret details for the application ============"
    echo "Host (use this exactly):  ${host:-$ip}"
    echo "Port:                     5432"
    echo "SSL mode:                 verify-full"
    echo "TLS minimum version:      1.2"
    echo "CA certificate (public):  $CA_DIR/ca.crt"
    echo "CA SHA-256 fingerprint:   $(openssl x509 -in "$CA_DIR/ca.crt" -noout -fingerprint -sha256 | cut -d= -f2)"
    echo "CA expires:               $(openssl x509 -in "$CA_DIR/ca.crt" -noout -enddate | cut -d= -f2)"
    echo "Server certificate:       expires $(openssl x509 -in "$CA_DIR/server.crt" -noout -enddate | cut -d= -f2)"
    echo "Server cert valid for:    $(openssl x509 -in "$CA_DIR/server.crt" -noout -ext subjectAltName | tail -1 | sed 's/^ *//')"
    echo
    echo "CA certificate (PEM, safe to share; this is NOT the private key):"
    cat "$CA_DIR/ca.crt"
    echo
    echo "Node (pg):    ssl: { ca: fs.readFileSync('/path/to/ca.crt'), rejectUnauthorized: true }"
    echo "              (connect with host '${host:-$ip}' so the name check matches)"
    echo "Laravel .env: DB_SSLMODE=verify-full  and  PGSSLROOTCERT=/path/to/ca.crt  (config/database.php: 'sslmode' => env('DB_SSLMODE'))"
    echo
    warn "Do NOT share: $CA_DIR/ca.key or $CA_DIR/server.key. Move ca.key to your password manager/offline store."
    warn "Credentials (DB user/password) go through the agreed secure channel, not with these details."
}

main() {
    case ${1:-setup} in
        enforce) cmd_enforce ;;
        check)   cmd_check ;;
        summary) cmd_summary ;;
        setup)
            command -v openssl >/dev/null || { apt-get install -y -qq openssl; }
            make_certs
            install_certs
            verify_tls
            cmd_summary
            echo
            warn "TLS is on, but unencrypted connections are still ALLOWED until you run: sudo bash $0 enforce"
            ;;
        *) echo "Usage: $0 [setup|enforce|check|summary]"; exit 1 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
