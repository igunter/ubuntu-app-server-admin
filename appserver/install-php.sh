#!/usr/bin/env bash
# Installs the PHP stack for Laravel on Ubuntu 24.04: PHP-FPM + extensions,
# Composer, Supervisor and a swap file. Safe to re-run.
#
#   sudo bash appserver/install-php.sh
#
# Optional overrides:  PHP_VER=8.3  SWAP_SIZE=2G
#
# nginx itself is installed by the top-level install.sh - run that first.
set -eu
DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
. "$DIR/../lib.sh"

[[ $EUID -eq 0 ]] || { err "Run as root: sudo $0"; exit 1; }

PHP_VER=${PHP_VER:-8.3}
SWAP_SIZE=${SWAP_SIZE:-2G}
export DEBIAN_FRONTEND=noninteractive

info "Updating packages..."
apt-get update
apt-get upgrade -y

info "Installing PHP $PHP_VER and supporting packages..."
apt-get install -y git unzip curl supervisor \
    "php$PHP_VER-fpm" "php$PHP_VER-cli" "php$PHP_VER-mysql" "php$PHP_VER-pgsql" \
    "php$PHP_VER-mbstring" "php$PHP_VER-xml" "php$PHP_VER-curl" "php$PHP_VER-zip" \
    "php$PHP_VER-bcmath" "php$PHP_VER-intl" "php$PHP_VER-gd"
systemctl enable --now "php$PHP_VER-fpm"

if ! command -v composer >/dev/null 2>&1; then
    info "Installing Composer..."
    tmp=$(mktemp -d)
    expected=$(curl -fsSL https://composer.github.io/installer.sig)
    curl -fsSL https://getcomposer.org/installer -o "$tmp/composer-setup.php"
    actual=$(php -r "echo hash_file('sha384', '$tmp/composer-setup.php');")
    if [[ $expected != "$actual" ]]; then
        rm -rf "$tmp"
        err "Composer installer checksum mismatch; aborting."
        exit 1
    fi
    php "$tmp/composer-setup.php" --quiet --install-dir=/usr/local/bin --filename=composer
    rm -rf "$tmp"
else
    info "Composer already installed, skipping."
fi

if [[ -z $(swapon --show --noheadings) ]]; then
    info "Creating $SWAP_SIZE swap file..."
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
    info "Swap already active, skipping."
fi

ok "PHP stack installed: $(php -v | head -n1)"
info "PHP accounts can now be switched on from webadmin.sh. See appserver/README.md for Laravel notes."
