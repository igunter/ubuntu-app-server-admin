# Laravel on Lightsail: AppServer + DBServer

A complete walkthrough for a two-server Laravel setup on AWS Lightsail running Ubuntu 24.04 LTS:

```
Internet ──80/443──> AppServer (nginx + PHP-FPM + Laravel)
                         │
                         └── private IP, 3306 / 5432 ──> DBServer (MySQL and/or PostgreSQL)
```

The AppServer is set up with the scripts in this folder. The DBServer is set up with the commands in section 3.

| Script | What it does |
| --- | --- |
| `install-php.sh` | Installs PHP-FPM with the extensions Laravel needs (MySQL and PostgreSQL drivers included), Composer, Supervisor, git, unzip and a swap file. |
| `install-holding.sh` | Serves a plain "Hello" page for the server's bare IP address and any host name that isn't an account. |

Throughout this guide, replace `myapp` with your app folder name, `yourdomain.com` with your domain, and `APP_PRIVATE_IP` / `DB_PRIVATE_IP` with the private IPs shown on each instance's **Networking** tab (they look like `172.26.x.x`).

---

## 1. Create the instances (Lightsail console)

Choose **Linux/Unix → OS only → Ubuntu 24.04 LTS** for both. Do not use the Nginx, LAMP or LEMP blueprints: they are Bitnami-packaged, keep everything under `/opt/bitnami`, and the commands here won't match.

| | AppServer | DBServer |
| --- | --- | --- |
| Region / zone | London, Zone A | London, Zone A (same as AppServer) |
| Plan | General purpose, 2 GB RAM, 2 vCPUs, 60 GB SSD | General purpose, 1 GB RAM, 2 vCPUs, 40 GB SSD |

If you run both MySQL and PostgreSQL on the DBServer, use the 2 GB plan instead of 1 GB.

For each instance:

1. **Networking → Create static IP** and attach it to the instance.
2. Note the **private IP** on the same tab.
3. Set the **IPv4 firewall** (and IPv6 firewall) as below.

| Instance | Firewall rules |
| --- | --- |
| AppServer | SSH 22 (restrict to your own IP), HTTP 80 (any), HTTPS 443 (any) |
| DBServer | SSH 22 (restrict to your own IP) only. No HTTP/HTTPS, and never open 3306 or 5432 to the internet. |

Point your domain's DNS A record at the **AppServer's** static IP.

Instances in the same account and region can talk to each other over their private IPs without a firewall rule, because the firewall only applies to public-internet traffic. Always connect to the DBServer's **private** IP from the AppServer.

---

## 2. AppServer

SSH in as `ubuntu` (PuTTY, the Lightsail browser terminal, or FileZilla over SFTP on port 22 using your key file).

### 2.1 Run the setup scripts

```bash
sudo apt install -y git
sudo git clone https://github.com/igunter/ubuntu-app-server-admin.git /ubuntu-app-server-admin
cd /ubuntu-app-server-admin
sudo bash install.sh                      # nginx + certbot, shared folders
sudo bash appserver/install-php.sh        # PHP 8.3 FPM, Composer, Supervisor, swap
sudo bash appserver/install-holding.sh    # optional "Hello" page on the server IP
```

Browse to the AppServer's IP address: you should see the Hello page. If it times out, the Lightsail firewall isn't allowing port 80.

Options for `install-php.sh` are set as environment variables: `sudo PHP_VER=8.3 SWAP_SIZE=2G bash appserver/install-php.sh`.

<details>
<summary>The same thing as plain commands (no scripts)</summary>

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y nginx git unzip supervisor \
  php8.3-fpm php8.3-cli php8.3-mysql php8.3-pgsql php8.3-mbstring \
  php8.3-xml php8.3-curl php8.3-zip php8.3-bcmath php8.3-intl php8.3-gd
curl -sS https://getcomposer.org/installer | php
sudo mv composer.phar /usr/local/bin/composer
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

</details>

### 2.2 Put the code on the server

```bash
sudo mkdir -p /var/www/myapp
sudo chown $USER:www-data /var/www/myapp
cd /var/www/myapp
git clone YOUR_REPO_URL .
```

For a private repo, create a deploy key with `ssh-keygen -t ed25519` and add the public key to the repo's deploy keys. Or upload the files with FileZilla into `/var/www/myapp`.

Then install and configure:

```bash
composer install --no-dev --optimize-autoloader
cp .env.example .env
php artisan key:generate
```

Edit `.env` (the database values are filled in at step 4):

```env
APP_ENV=production
APP_DEBUG=false
APP_URL=https://yourdomain.com

DB_CONNECTION=mysql        # or pgsql
DB_HOST=DB_PRIVATE_IP
DB_PORT=3306               # 5432 for pgsql
DB_DATABASE=myapp
DB_USERNAME=myapp
DB_PASSWORD=a-strong-password
```

Make the writable folders writable by PHP-FPM:

```bash
sudo chown -R $USER:www-data storage bootstrap/cache
sudo chmod -R ug+rwx storage bootstrap/cache
```

If the front end has a build step: `sudo apt install -y nodejs npm`, then `npm ci && npm run build`.

### 2.3 nginx site for Laravel

`webadmin.sh` generates confs that serve `public_html` and return 404 for unknown paths, which doesn't suit Laravel's `public/` folder and front-controller routing. Manual edits to those generated confs are overwritten, so create the Laravel site by hand, outside the manager, under its own file name:

```bash
sudo nano /etc/nginx/sites-available/myapp-laravel.conf
```

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name yourdomain.com www.yourdomain.com;
    root /var/www/myapp/public;

    index index.php;
    charset utf-8;
    client_max_body_size 20M;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
```

Check that the socket name matches your PHP version with `ls /run/php/`. Then enable it:

```bash
sudo ln -s /etc/nginx/sites-available/myapp-laravel.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

Don't also create a `webadmin.sh` account for the same domain, or the two confs will clash.

### 2.4 HTTPS

DNS for the domain must already point at the AppServer.

```bash
sudo apt install -y python3-certbot-nginx
sudo certbot --nginx -d yourdomain.com -d www.yourdomain.com
sudo certbot renew --dry-run
```

### 2.5 Scheduler and queue worker

Scheduler:

```bash
echo '* * * * * www-data cd /var/www/myapp && php artisan schedule:run >> /dev/null 2>&1' \
  | sudo tee /etc/cron.d/myapp-scheduler
```

Queue worker (skip if you use `QUEUE_CONNECTION=sync`). Create `/etc/supervisor/conf.d/myapp-worker.conf`:

```ini
[program:myapp-worker]
command=php /var/www/myapp/artisan queue:work --sleep=3 --tries=3 --max-time=3600
user=www-data
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
stdout_logfile=/var/log/myapp-worker.log
```

```bash
sudo supervisorctl reread && sudo supervisorctl update
```

If the queue driver is `database`, start the worker only after step 4.

---

## 3. DBServer

SSH in to the DBServer. You can install MySQL, PostgreSQL, or both. They use different ports (3306 / 5432) and don't conflict.

### 3.1 Swap and updates

```bash
sudo apt update && sudo apt upgrade -y
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### 3.2 MySQL

```bash
sudo apt install -y mysql-server
sudo mysql_secure_installation
```

Edit `/etc/mysql/mysql.conf.d/mysqld.cnf` so MySQL listens on the private IP only, with settings sized for 1 GB RAM:

```ini
bind-address = DB_PRIVATE_IP
innodb_buffer_pool_size = 192M
performance_schema = OFF
max_connections = 50
```

Create the database and an app user that can only connect from the AppServer (`sudo mysql`):

```sql
CREATE DATABASE myapp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'myapp'@'APP_PRIVATE_IP' IDENTIFIED BY 'a-strong-password';
GRANT ALL PRIVILEGES ON myapp.* TO 'myapp'@'APP_PRIVATE_IP';
```

### 3.3 PostgreSQL

```bash
sudo apt install -y postgresql
```

In `/etc/postgresql/16/main/postgresql.conf` (check the version number in the path):

```
listen_addresses = 'localhost,DB_PRIVATE_IP'
shared_buffers = 128MB
max_connections = 50
```

Add this line to `/etc/postgresql/16/main/pg_hba.conf`:

```
host  myapp  myapp  APP_PRIVATE_IP/32  scram-sha-256
```

Create the user and database (`sudo -u postgres psql`):

```sql
CREATE USER myapp WITH PASSWORD 'a-strong-password';
CREATE DATABASE myapp OWNER myapp;
```

### 3.4 Restart and verify

```bash
sudo systemctl restart mysql postgresql     # only the ones you installed
sudo ss -tlnp | grep -E '3306|5432'
```

The listening address should be `DB_PRIVATE_IP` (plus localhost for PostgreSQL), never `0.0.0.0`.

---

## 4. Connect the two servers

From the AppServer, test the connection:

```bash
sudo apt install -y mysql-client postgresql-client
nc -zv DB_PRIVATE_IP 3306       # or 5432
mysql -h DB_PRIVATE_IP -u myapp -p myapp
psql -h DB_PRIVATE_IP -U myapp myapp
```

- "succeeded" means the network path is fine.
- A hang or timeout means the firewall is blocking it. Add a **Custom TCP** rule on the DBServer for port 3306 or 5432 with the source restricted to `APP_PRIVATE_IP`, then retest.
- "Connection refused" means the firewall is fine but the database isn't listening on that IP. Check `bind-address` / `listen_addresses` and the service status.

Then, in `/var/www/myapp`:

```bash
php artisan migrate --force
php artisan config:cache && php artisan route:cache && php artisan view:cache
```

Switching between MySQL and PostgreSQL later is an `.env` change (`DB_CONNECTION`, `DB_PORT`) followed by `php artisan config:clear`, because both PHP drivers are already installed.

---

## 5. Backups

- Turn on **automatic snapshots** for both instances in the Lightsail console.
- Snapshots are crash-consistent only, so also take a nightly database dump on the DBServer and copy it off the box (for example to S3):

```bash
# /etc/cron.d/db-backup (runs at 02:30)
30 2 * * * root mysqldump --single-transaction myapp | gzip > /var/backups/myapp-mysql-$(date +\%F).sql.gz
30 2 * * * root sudo -u postgres pg_dump myapp | gzip > /var/backups/myapp-pg-$(date +\%F).sql.gz
```

Keep only the line for the engine you use. This writes to the same disk, so it isn't a backup until it is shipped elsewhere. The `spatie/laravel-backup` package on the AppServer is an alternative that dumps, compresses and uploads in one step.

---

## 6. Deploying updates

```bash
cd /var/www/myapp
git pull
composer install --no-dev --optimize-autoloader
php artisan migrate --force
php artisan config:cache && php artisan route:cache && php artisan view:cache
sudo systemctl reload php8.3-fpm
php artisan queue:restart
```

---

## 7. Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Page times out | Port 80/443 not open in the AppServer's Lightsail firewall. |
| 502 Bad Gateway | PHP-FPM not running or wrong socket path. Check `sudo systemctl status php8.3-fpm` and `ls /run/php/`. |
| 403 Forbidden | Permissions. Re-run the `chown` / `chmod` on `storage` and `bootstrap/cache`. |
| 404 on every route | `root` doesn't end in `/public`, or `try_files` was mistyped. |
| 500 error | Check `storage/logs/laravel.log` and `/var/log/nginx/error.log`. |
| "Welcome to nginx" page | The default site is still enabled. `sudo rm /etc/nginx/sites-enabled/default` and reload. |
| FileZilla shows only `/var` | You are connected to the wrong server (for example the DBServer). Check the host IP. |
| DB connection hangs | Firewall or wrong IP. Use the DBServer's private IP and see section 4. |
| DB "access denied" | The MySQL user's host or the `pg_hba.conf` line doesn't match `APP_PRIVATE_IP`. |

## 8. Building a second copy in another Lightsail account

Snapshots can't be shared between Lightsail accounts, so build fresh from this guide. Static IPs, private IPs and firewall rules don't carry over: recreate them and update `bind-address`, the DB user's host, `pg_hba.conf` and `.env` with the new private IPs. To copy data, dump the old database (`mysqldump --single-transaction` or `pg_dump`), restore it on the new DBServer, and copy `storage/app` across with `rsync` or `scp`.

## 9. Security notes

- Never commit `.env` files, database passwords or SSH keys. The repo's `.gitignore` covers `.env`, `*.pem` and `*.ppk`.
- Keep the database off the public internet: private-IP `bind-address`, no public firewall rule for 3306 / 5432, and DB users restricted to the AppServer's private IP.
- Restrict SSH to your own IP where you can. The Lightsail browser SSH remains available as a fallback.
