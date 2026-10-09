#!/usr/bin/env bash
# Installs database servers on an Ubuntu 24.04 DB server and creates an app
# database and user that can only connect from the app server.
#
#   sudo bash dbserver/install-db.sh
#
# You choose which engines to install - tick as many as you like:
#   MySQL, PostgreSQL, MariaDB
# MySQL and MariaDB can't share a server (same packages, same port 3306, same
# data folder), so only one of those two can be ticked. PostgreSQL can be
# installed alongside either.
#
# To skip the questions, pass the answers as environment variables:
#   sudo ENGINES="mysql postgresql" DB_IP=172.26.0.10 APP_IP=172.26.0.20 \
#        DB_NAME=myapp DB_USER=myapp bash dbserver/install-db.sh
# (APP_IP="" installs the engines only, without creating a database or user.)
#
# Safe to re-run: existing databases are kept, and an existing user's password
# is only reset if you say so.
set -eu
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
. "$DIR/../lib.sh"

SWAP_SIZE=${SWAP_SIZE:-2G}
MYSQL_CONF_DIR=${MYSQL_CONF_DIR:-/etc/mysql/mysql.conf.d}
MARIADB_CONF_DIR=${MARIADB_CONF_DIR:-/etc/mysql/mariadb.conf.d}
PG_ETC=${PG_ETC:-/etc/postgresql}

ENGINE_KEYS=(mysql postgresql mariadb)
ENGINE_NAMES=(MySQL PostgreSQL MariaDB)
declare -A SEL=()
RESULTS=()

# ------------------------------------------------------------- engine choice
engine_name() {
    local i
    for i in "${!ENGINE_KEYS[@]}"; do
        if [[ ${ENGINE_KEYS[$i]} == "$1" ]]; then echo "${ENGINE_NAMES[$i]}"; return 0; fi
    done
    return 1
}

chosen_engines() {
    local k
    for k in "${ENGINE_KEYS[@]}"; do
        if [[ ${SEL[$k]:-0} == 1 ]]; then echo "$k"; fi
    done
    return 0
}

toggle_engine() {
    local key=$1 other=
    if [[ ${SEL[$key]:-0} == 1 ]]; then SEL[$key]=0; return 0; fi
    if [[ $key == mysql ]]; then other=mariadb; fi
    if [[ $key == mariadb ]]; then other=mysql; fi
    if [[ -n $other && ${SEL[$other]:-0} == 1 ]]; then
        warn "MySQL and MariaDB can't be installed on the same server (same packages, same port 3306)."
        warn "Untick $(engine_name "$other") first if you want $(engine_name "$key") instead."
        return 0
    fi
    SEL[$key]=1
}

select_engines() {
    local c i mark
    while true; do
        echo
        info "Which database server(s) do you want to install?"
        for i in "${!ENGINE_KEYS[@]}"; do
            mark=' '
            if [[ ${SEL[${ENGINE_KEYS[$i]}]:-0} == 1 ]]; then mark=x; fi
            printf "  [%s] %d  %s\n" "$mark" $((i + 1)) "${ENGINE_NAMES[$i]}"
        done
        echo "Type a number to tick or untick it. Press Enter on its own when you're done (q to quit)."
        read -rp "Choice: " c
        case ${c,,} in
            [1-3]) toggle_engine "${ENGINE_KEYS[$((c - 1))]}" ;;
            "")
                if [[ -n $(chosen_engines) ]]; then return 0; fi
                warn "Tick at least one." ;;
            q) exit 0 ;;
            *) err "Invalid option." ;;
        esac
    done
}

# ENGINES="mysql postgresql" skips the menu.
use_env_engines() {
    local k
    for k in ${ENGINES//,/ }; do
        k=${k,,}
        case $k in
            mysql|postgresql|mariadb) SEL[$k]=1 ;;
            postgres) SEL[postgresql]=1 ;;
            *) err "Unknown engine '$k' (use mysql, postgresql, mariadb)."; exit 1 ;;
        esac
    done
    if [[ ${SEL[mysql]:-0} == 1 && ${SEL[mariadb]:-0} == 1 ]]; then
        err "MySQL and MariaDB can't be installed on the same server."
        exit 1
    fi
    if [[ -z $(chosen_engines) ]]; then err "ENGINES is empty."; exit 1; fi
}

pkg_installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == "install ok installed" ]]; }

# Installing one of MySQL/MariaDB over the other would remove it.
preflight() {
    if [[ ${SEL[mysql]:-0} == 1 ]] && pkg_installed mariadb-server; then
        err "MariaDB is already installed on this server, and installing MySQL would replace it."
        exit 1
    fi
    if [[ ${SEL[mariadb]:-0} == 1 ]] && pkg_installed mysql-server; then
        err "MySQL is already installed on this server, and installing MariaDB would replace it."
        exit 1
    fi
}

# ------------------------------------------------------------------ prompts
detect_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}
local_ip() { ip -4 -o addr show 2>/dev/null | awk '{ print $4 }' | cut -d/ -f1 | grep -qxF "$1"; }
valid_local_ipv4() { valid_ipv4 "$1" && local_ip "$1"; }

# ask_valid VAR "Prompt" "default" validator [allow_blank]
ask_valid() {
    local __var=$1 prompt=$2 default=$3 check=$4 allow_blank=${5:-0} v
    while true; do
        read -rp "$prompt${default:+ [$default]}: " v
        v=${v:-$default}
        if [[ -z $v && $allow_blank == 1 ]]; then printf -v "$__var" '%s' ""; return 0; fi
        if [[ -n $v ]] && "$check" "$v"; then printf -v "$__var" '%s' "$v"; return 0; fi
        err "That doesn't look right, try again."
    done
}

confirm() {
    local a
    read -rp "$1 [y/N]: " a || a=n
    [[ ${a,,} == y* ]]
}

gather_settings() {
    local detected
    detected=$(detect_ip)

    if [[ -n ${DB_IP:-} ]]; then
        valid_local_ipv4 "$DB_IP" || { err "DB_IP $DB_IP is not an IPv4 address on this server."; exit 1; }
    else
        ask_valid DB_IP "This server's private IP" "$detected" valid_local_ipv4
    fi

    if [[ -z ${APP_IP+x} ]]; then
        ask_valid APP_IP "App server's private IP (blank = install only, no database or user)" "" valid_ipv4 1
    elif [[ -n $APP_IP ]] && ! valid_ipv4 "$APP_IP"; then
        err "APP_IP $APP_IP is not a valid IPv4 address."; exit 1
    fi

    if [[ -n $APP_IP ]]; then
        if [[ -n ${DB_NAME:-} ]]; then
            valid_dbname "$DB_NAME" || { err "DB_NAME must be a-z, 0-9, _ and start with a letter."; exit 1; }
        else
            ask_valid DB_NAME "Database name" "app" valid_dbname
        fi
        if [[ -n ${DB_USER:-} ]]; then
            valid_dbname "$DB_USER" || { err "DB_USER must be a-z, 0-9, _ and start with a letter."; exit 1; }
        else
            ask_valid DB_USER "Database user" "$DB_NAME" valid_dbname
        fi
    fi
}

show_summary() {
    local k names=
    for k in $(chosen_engines); do names+="$(engine_name "$k") "; done
    echo
    info "About to set up:"
    echo "  Engines   : $names"
    echo "  Listen on : $DB_IP (this server's private IP only)"
    if [[ -n $APP_IP ]]; then
        echo "  Database  : $DB_NAME"
        echo "  User      : $DB_USER (can only connect from $APP_IP)"
    else
        echo "  Database  : none (engines only)"
    fi
}

# ------------------------------------------------------------------- sizing
clamp() {
    local v=$1 lo=$2 hi=$3
    if ((v < lo)); then v=$lo; fi
    if ((v > hi)); then v=$hi; fi
    echo "$v"
}

# Memory settings scaled to this server's RAM (about 193M / 120M on 1 GB).
size_settings() {
    local mem_mb
    mem_mb=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
    INNODB_POOL=$(clamp $((mem_mb / 5)) 128 2048)
    PG_SHARED=$(clamp $((mem_mb / 8)) 64 2048)
    if ((mem_mb < 2048)); then MAX_CONN=50; else MAX_CONN=100; fi
}

# ------------------------------------------------------------------ install
install_packages() {
    local pkgs=() k
    for k in $(chosen_engines); do
        case $k in
            mysql) pkgs+=(mysql-server) ;;
            mariadb) pkgs+=(mariadb-server) ;;
            postgresql) pkgs+=(postgresql) ;;
        esac
    done
    export DEBIAN_FRONTEND=noninteractive
    info "Installing: ${pkgs[*]}"
    apt-get update
    apt-get upgrade -y
    apt-get install -y "${pkgs[@]}"
}

# ------------------------------------------------------------ MySQL / MariaDB
configure_mysql_family() {   # $1 = mysql | mariadb
    local dir svc
    if [[ $1 == mysql ]]; then dir=$MYSQL_CONF_DIR; svc=mysql; else dir=$MARIADB_CONF_DIR; svc=mariadb; fi
    info "Configuring $(engine_name "$1")..."
    mkdir -p "$dir"
    cat > "$dir/99-dbserver.cnf" <<EOF
# Written by dbserver/install-db.sh
[mysqld]
bind-address = $DB_IP
innodb_buffer_pool_size = ${INNODB_POOL}M
performance_schema = OFF
max_connections = $MAX_CONN
EOF
    systemctl enable --now "$svc"
    systemctl restart "$svc"
}

setup_mysql_account() {   # $1 = label shown to the user
    local label=$1 pass count
    count=$(mysql -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE User='$DB_USER' AND Host='$APP_IP'")
    if ((count > 0)) && ! confirm "User '$DB_USER' from $APP_IP already exists on $label. Reset its password?"; then
        warn "Kept the existing $label user."
        mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
        return 0
    fi
    pass=$(random_password)
    mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'$APP_IP' IDENTIFIED BY '$pass';
ALTER USER '$DB_USER'@'$APP_IP' IDENTIFIED BY '$pass';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'$APP_IP';
SQL
    RESULTS+=("$label|3306|$pass")
}

# --------------------------------------------------------------- PostgreSQL
pg() { runuser -u postgres -- psql -v ON_ERROR_STOP=1 "$@"; }

configure_postgres() {
    local ver hba line
    info "Configuring PostgreSQL..."
    systemctl enable --now postgresql
    ver=$(ls "$PG_ETC" | sort -V | tail -n1)
    if [[ -z $ver || ! -d $PG_ETC/$ver/main ]]; then
        err "Could not find the PostgreSQL config folder under $PG_ETC."
        exit 1
    fi
    pg -c "ALTER SYSTEM SET listen_addresses = 'localhost,$DB_IP'"
    pg -c "ALTER SYSTEM SET shared_buffers = '${PG_SHARED}MB'"
    pg -c "ALTER SYSTEM SET max_connections = $MAX_CONN"
    if [[ -n $APP_IP ]]; then
        hba=$PG_ETC/$ver/main/pg_hba.conf
        line=$(printf 'host\t%s\t%s\t%s/32\tscram-sha-256' "$DB_NAME" "$DB_USER" "$APP_IP")
        grep -qxF "$line" "$hba" || echo "$line" >> "$hba"
    fi
    systemctl restart postgresql
}

ensure_pg_database() {
    if [[ $(pg -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'") != 1 ]]; then
        pg -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\""
    fi
}

setup_postgres_account() {
    local pass
    if [[ $(pg -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'") == 1 ]]; then
        if ! confirm "Role '$DB_USER' already exists on PostgreSQL. Reset its password?"; then
            warn "Kept the existing PostgreSQL role."
            ensure_pg_database
            return 0
        fi
        pass=$(random_password)
        pg -c "ALTER ROLE \"$DB_USER\" WITH LOGIN PASSWORD '$pass'"
    else
        pass=$(random_password)
        pg -c "CREATE ROLE \"$DB_USER\" WITH LOGIN PASSWORD '$pass'"
    fi
    ensure_pg_database
    RESULTS+=("PostgreSQL|5432|$pass")
}

# ------------------------------------------------------------------- report
report() {
    local r label port pass conn exposed
    echo
    ok "Database server is ready."
    echo
    info "Listening on:"
    ss -H -tln 2>/dev/null | awk '$4 ~ /:(3306|5432)$/ { print "  " $4 }'
    exposed=$(ss -H -tln 2>/dev/null | awk '$4 ~ /^(0\.0\.0\.0|\*|\[::\]):(3306|5432)$/ { print $4 }')
    if [[ -n $exposed ]]; then
        warn "A database is listening on every address ($exposed). Check the bind settings and the firewall."
    fi

    if ((${#RESULTS[@]} > 0)); then
        echo
        warn "Save these passwords now - they are only shown once."
        for r in "${RESULTS[@]}"; do
            IFS='|' read -r label port pass <<<"$r"
            if [[ $label == PostgreSQL ]]; then conn=pgsql; else conn=mysql; fi
            echo
            echo "${CYN}--- $label: for the app's .env ---${RST}"
            echo "DB_CONNECTION=$conn"
            echo "DB_HOST=$DB_IP"
            echo "DB_PORT=$port"
            echo "DB_DATABASE=$DB_NAME"
            echo "DB_USERNAME=$DB_USER"
            echo "DB_PASSWORD=$pass"
        done
    fi

    echo
    info "Next steps:"
    if [[ -n $APP_IP ]]; then
        echo "  - On the app server, test the connection:  nc -zv $DB_IP 3306   (or 5432 for PostgreSQL)"
    fi
    echo "  - Keep this server's Lightsail firewall to SSH only. Never open 3306 or 5432 to the internet."
    if [[ -n $APP_IP ]]; then
        echo "    Only if that test hangs, add a Custom TCP rule for the port restricted to $APP_IP."
    fi
    echo "  - Root access is by socket only: use  sudo mysql  or  sudo -u postgres psql  on this server."
}

# --------------------------------------------------------------------- main
main() {
    local k a
    [[ $EUID -eq 0 ]] || { err "Run as root: sudo $0"; exit 1; }
    cd /

    if [[ -n ${ENGINES:-} ]]; then use_env_engines; else select_engines; fi
    preflight
    gather_settings
    show_summary
    if [[ -z ${ENGINES:-} ]]; then
        echo
        read -rp "Continue? [Y/n]: " a
        if [[ ${a,,} == n* ]]; then warn "Cancelled."; exit 0; fi
    fi

    size_settings
    ensure_swap "$SWAP_SIZE"
    install_packages

    for k in $(chosen_engines); do
        case $k in
            mysql|mariadb) configure_mysql_family "$k" ;;
            postgresql) configure_postgres ;;
        esac
    done

    if [[ -n $APP_IP ]]; then
        for k in $(chosen_engines); do
            case $k in
                mysql) setup_mysql_account MySQL ;;
                mariadb) setup_mysql_account MariaDB ;;
                postgresql) setup_postgres_account ;;
            esac
        done
    fi

    report
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
