# ubuntu-app-server-admin

Menu-driven scripts for managing nginx web accounts on an Ubuntu server over SSH (PuTTY, Terminal, etc).

```
=========== Web Account Manager ===========
  1  List Accounts
  2  Create Account
  3  Edit Account        (change settings / delete account)
  4  Toggle Account Status
  5  Toggle SSL
  6  Add a Domain
  7  Remove a Domain
  x  Exit
```

## How to Run the Script

Connect to your server in a terminal window (PuTTY, Terminal, etc) and run the following command.

### First time

If this is the first time you are running the script, clone it, run the one-off setup, then start the manager:

```bash
sudo git clone https://github.com/igunter/ubuntu-app-server-admin.git /ubuntu-app-server-admin && cd /ubuntu-app-server-admin && sudo bash install.sh && sudo bash webadmin.sh
```

`install.sh` only needs to be run once. It installs nginx and certbot, creates the shared folders and writes the "Site Unavailable" page shown for disabled accounts. It is safe to run again.

### Every time after that

```bash
cd /ubuntu-app-server-admin && sudo bash webadmin.sh
```

### Updating the script

```bash
cd /ubuntu-app-server-admin && sudo git pull && sudo bash webadmin.sh
```

## What the options do

| Option | Description |
| --- | --- |
| List Accounts | Shows every account with its status, SSL, PHP and domains. |
| Create Account | Creates the web root, a placeholder `index.html` and the nginx conf. |
| Edit Account | Change PHP on/off and max upload size, or delete the account (asks you to type the account name, and separately whether to delete the web files). |
| Toggle Account Status | When **off**, the site returns HTTP 503 and shows a "Site Unavailable" page on both HTTP and HTTPS. |
| Toggle SSL | Requests a Let's Encrypt certificate for all the account's domains and enables HTTPS with an HTTP redirect. Turning it off keeps the certificate. |
| Add a Domain | Adds a domain to an account (the certificate is expanded if SSL is on). |
| Remove a Domain | Removes a domain (the certificate is reissued if SSL is on). The last domain cannot be removed. |

## How it works

| What | Where |
| --- | --- |
| Account settings (source of truth) | `/etc/webaccounts/<name>.env` |
| Generated nginx conf | `/etc/nginx/sites-available/<name>.conf`, symlinked into `sites-enabled/` |
| Web root | `/var/www/<name>/public_html` |
| Disabled-site page | `/var/www/_disabled/index.html` |
| Let's Encrypt challenges | `/var/www/_acme/` |

- Confs are regenerated from the settings file on every change, so **manual edits to the generated conf will be overwritten** - use the menu instead.
- Every change is checked with `nginx -t` before nginx is reloaded. If nginx rejects it, the previous conf is restored.
- For SSL, DNS for every domain on the account must already point at the server.
- For PHP accounts, install PHP-FPM first: `sudo apt install php-fpm`.

## Requirements

- Ubuntu server with root/sudo access
- Ports 80 and 443 open
