#!/usr/bin/env bash
# Interactive web account manager (nginx). Run with: sudo ./webadmin.sh
set -u
DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
. "$DIR/lib.sh"

if [[ $EUID -ne 0 ]]; then
    err "Please run as root:  sudo $0"
    exit 1
fi
if [[ ! -d $META_DIR ]]; then
    err "Not set up yet. Run:  sudo $DIR/install.sh"
    exit 1
fi

# ------------------------------------------------------------ 1 list accounts
do_list() {
    local names n
    mapfile -t names < <(list_names)
    if ((${#names[@]} == 0)); then warn "No accounts exist yet."; return; fi
    printf "%-20s %-10s %-5s %-5s %s\n" ACCOUNT STATUS SSL PHP DOMAINS
    for n in "${names[@]}"; do
        load_account "$n"
        printf "%-20s %-19s %-14s %-5s %s\n" "$n" \
            "$(status_label "$STATUS")" "$(ssl_label "$SSL")" "$PHP" "$DOMAINS"
    done
}

# ----------------------------------------------------------- 2 create account
do_create() {
    local name domain php
    read -rp "Account name (a-z, 0-9, _ -): " name
    if ! valid_name "$name"; then err "Invalid account name."; return; fi
    if account_exists "$name"; then err "Account already exists."; return; fi

    read -rp "Primary domain (e.g. example.com): " domain
    domain=${domain,,}
    if ! valid_domain "$domain"; then err "Invalid domain."; return; fi
    local owner
    if owner=$(domain_owner "$domain"); then
        err "$domain already belongs to account '$owner'."; return
    fi

    local domains=$domain
    read -rp "Also serve www.$domain? [Y/n]: " a
    [[ ${a,,} != n* ]] && domains+=" www.$domain"

    read -rp "Enable PHP? [y/N]: " php
    ACCOUNT=$name DOMAINS=$domains STATUS=on SSL=off MAX_UPLOAD=32M
    [[ ${php,,} == y* ]] && PHP=on || PHP=off
    if [[ $PHP == on && -z $(php_socket) ]]; then
        warn "No php-fpm socket found; install php-fpm or PHP will not work."
    fi

    local root=$WWW_ROOT/$name/public_html
    mkdir -p "$root"
    cat > "$root/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Coming Soon</title>
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
    <h1>Web Site Coming Soon</h1>
    <p>We're working on something new. Please check back shortly.</p>
  </div>
</body>
</html>
EOF
    chown -R www-data:www-data "$WWW_ROOT/$name"
    chmod 755 "$WWW_ROOT/$name"

    save_account
    if apply_conf; then
        ok "Account '$name' created. Point DNS for: $domains"
    else
        rm -f "$META_DIR/$name.env"
        err "Creation failed; web files left in $WWW_ROOT/$name."
    fi
}

# Delete the currently loaded account (called from do_edit).
delete_account() {
    local v
    warn "This will remove the nginx config, settings and certificate for '$ACCOUNT'."
    read -rp "Type the account name to confirm: " v
    if [[ $v != "$ACCOUNT" ]]; then warn "Name did not match; nothing deleted."; return; fi

    local wipe=n
    read -rp "Also permanently delete web files in $WWW_ROOT/$ACCOUNT? [y/N]: " wipe

    rm -f "$NGINX_ENABLED/$ACCOUNT.conf" "$NGINX_AVAIL/$ACCOUNT.conf"
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
    else
        err "nginx config test failed after removal:"; nginx -t 2>&1 | sed 's/^/    /' >&2
    fi

    if cert_ready; then
        certbot delete --cert-name "$ACCOUNT" --non-interactive >/dev/null 2>&1 \
            || warn "Could not remove the certificate; run: certbot delete --cert-name $ACCOUNT"
    fi
    rm -f "$META_DIR/$ACCOUNT.env"

    if [[ ${wipe,,} == y* ]]; then
        rm -rf "${WWW_ROOT:?}/$ACCOUNT"
        ok "Account '$ACCOUNT' and its files deleted."
    else
        ok "Account '$ACCOUNT' deleted. Web files kept in $WWW_ROOT/$ACCOUNT."
    fi
}

# ------------------------------------------------------------ 3 edit account
do_edit() {
    choose_account || return
    echo; show_account; echo
    local v
    echo "  1) Change settings"
    echo "  2) Delete account"
    read -rp "Choose (blank to cancel): " v
    case $v in
        1) ;;
        2) delete_account; return ;;
        *) return ;;
    esac

    read -rp "PHP on/off [$PHP]: " v
    v=${v,,}
    if [[ $v == on || $v == off ]]; then PHP=$v
    elif [[ -n $v ]]; then err "Ignoring invalid PHP value."; fi

    read -rp "Max upload size [$MAX_UPLOAD]: " v
    if [[ -n $v ]]; then
        if valid_size "$v"; then MAX_UPLOAD=${v^^}; else err "Ignoring invalid size (use e.g. 64M)."; fi
    fi

    save_account
    apply_conf && ok "Account '$ACCOUNT' updated."
}

# ----------------------------------------------------- 4 toggle account status
do_toggle_status() {
    choose_account || return
    local old=$STATUS
    [[ $STATUS == on ]] && STATUS=off || STATUS=on
    save_account
    if apply_conf; then
        if [[ $STATUS == off ]]; then
            ok "'$ACCOUNT' DISABLED - visitors now see the suspended page (HTTP 503)."
        else
            ok "'$ACCOUNT' ENABLED - site is live again."
        fi
    else
        STATUS=$old; save_account
    fi
}

# ----------------------------------------------------------- 5 toggle SSL
do_toggle_ssl() {
    choose_account || return
    if [[ $SSL == on ]]; then
        SSL=off; save_account
        apply_conf && ok "SSL disabled for '$ACCOUNT' (certificate kept for re-enabling)."
        return
    fi
    warn "DNS for every domain must already point at this server."
    info "Requesting certificate for: $DOMAINS"
    if ! issue_cert "$DOMAINS"; then err "Certificate request failed; SSL unchanged."; return; fi
    SSL=on; save_account
    if apply_conf; then
        ok "SSL enabled for '$ACCOUNT'."
    else
        SSL=off; save_account
    fi
}

# ----------------------------------------------------------- 6 add a domain
do_add_domain() {
    choose_account || return
    local d owner
    read -rp "Domain to add: " d
    d=${d,,}
    if ! valid_domain "$d"; then err "Invalid domain."; return; fi
    if owner=$(domain_owner "$d"); then err "$d already belongs to '$owner'."; return; fi

    local new="$DOMAINS $d"
    if [[ $SSL == on ]]; then
        info "Expanding certificate..."
        issue_cert "$new" || { err "Certificate request failed; domain not added."; return; }
    fi
    local old=$DOMAINS
    DOMAINS=$new; save_account
    if apply_conf; then ok "Added $d to '$ACCOUNT'."; else DOMAINS=$old; save_account; fi
}

# -------------------------------------------------------- 7 remove a domain
do_remove_domain() {
    choose_account || return
    local arr=($DOMAINS) i d
    if ((${#arr[@]} < 2)); then err "Cannot remove the only domain on an account."; return; fi
    for i in "${!arr[@]}"; do printf "  %d) %s\n" $((i + 1)) "${arr[$i]}"; done
    read -rp "Domain to remove (number or name): " d
    if [[ $d =~ ^[0-9]+$ ]] && ((d >= 1 && d <= ${#arr[@]})); then d=${arr[$((d - 1))]}; fi
    d=${d,,}

    local keep=() x found=0
    for x in "${arr[@]}"; do
        if [[ $x == "$d" ]]; then found=1; else keep+=("$x"); fi
    done
    if ((!found)); then err "Domain not on this account."; return; fi

    local new="${keep[*]}"
    if [[ $SSL == on ]]; then
        info "Reissuing certificate without $d..."
        issue_cert "$new" || { err "Certificate request failed; domain not removed."; return; }
    fi
    local old=$DOMAINS
    DOMAINS=$new; save_account
    if apply_conf; then ok "Removed $d from '$ACCOUNT'."; else DOMAINS=$old; save_account; fi
}

# ---------------------------------------------------------------------- menu
while true; do
    clear
    cat <<EOF
${CYN}=========== Web Account Manager ===========${RST}
  1  List Accounts
  2  Create Account
  3  Edit Account
  4  Toggle Account Status
  5  Toggle SSL
  6  Add a Domain
  7  Remove a Domain
  x  Exit
EOF
    read -rp "Choose: " choice
    echo
    case ${choice,,} in
        1) do_list ;;
        2) do_create ;;
        3) do_edit ;;
        4) do_toggle_status ;;
        5) do_toggle_ssl ;;
        6) do_add_domain ;;
        7) do_remove_domain ;;
        x) exit 0 ;;
        *) err "Invalid option." ;;
    esac
    echo
    pause
done
