#!/usr/bin/env bash
# One entry point for a new server. Asks what the server is for, then runs the
# right installers.
#
#   sudo bash setup.sh
set -eu
DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
. "$DIR/lib.sh"

[[ $EUID -eq 0 ]] || { err "Run as root: sudo $0"; exit 1; }

# yes_no "Question?" y|n   (the second argument is the default answer)
yes_no() {
    local a def=${2:-n} hint='[y/N]'
    if [[ $def == y ]]; then hint='[Y/n]'; fi
    read -rp "$1 $hint: " a
    a=${a:-$def}
    [[ ${a,,} == y* ]]
}

echo "${CYN}=========== Server Setup ===========${RST}"
echo "  1  App server   (nginx, PHP, Composer, web account manager)"
echo "  2  DB server    (MySQL, PostgreSQL and/or MariaDB)"
echo "  x  Exit"
read -rp "What are you setting up? " choice
echo

case ${choice,,} in
    1)
        bash "$DIR/install.sh"
        if yes_no "Install the PHP stack (PHP-FPM, Composer, Supervisor, swap)?" y; then
            bash "$DIR/appserver/install-php.sh"
        fi
        if yes_no "Install the \"Hello\" holding page for the server IP?" n; then
            bash "$DIR/appserver/install-holding.sh"
        fi
        if yes_no "Start the web account manager now?" y; then
            exec bash "$DIR/webadmin.sh"
        fi
        ;;
    2)
        bash "$DIR/dbserver/install-db.sh"
        ;;
    x) exit 0 ;;
    *) err "Invalid option."; exit 1 ;;
esac
