#!/bin/bash
# =============================================================================
# ThunderStack Bootstrap Script
# Stack: Nginx + Varnish + Apache + PHP-FPM + MariaDB + Redis + Memcached
# Port map: Nginx(:80) -> Varnish(:6081) -> Apache(:8080) -> PHP-FPM(socket)
# Target: Debian 11/12
# Author: Muhammad Hamza
# GitHub: https://github.com/hamzanaqvix-code/thunderstack-bootstrap
# =============================================================================

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export UCF_FORCE_CONFFOLD=true
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# -----------------------------------------------------------------------------
# VARIABLES
# -----------------------------------------------------------------------------
APP_NAME="myapp"
DB_NAME="${APP_NAME}_db"
DB_USER="${APP_NAME}_user"
DB_PASS=$(openssl rand -base64 16)
WEBROOT="/var/www/${APP_NAME}/public_html"
PHP_VERSION="8.2"
VARNISH_PORT="6081"
APACHE_PORT="8080"
REDIS_PORT="6379"
MEMCACHED_PORT="11211"

# -----------------------------------------------------------------------------
# COLORS
# -----------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()     { echo -e "${GREEN}[OK]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }

# -----------------------------------------------------------------------------
# ROOT CHECK
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root."
fi

# -----------------------------------------------------------------------------
# DETECT DEBIAN VERSION
# -----------------------------------------------------------------------------
section "Detecting OS"
DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)
if [[ "$DEBIAN_VERSION" -lt 11 ]]; then
    error "This script requires Debian 11 or 12."
fi
log "Debian $DEBIAN_VERSION detected."

# -----------------------------------------------------------------------------
# STEP 1: System update
# -----------------------------------------------------------------------------
section "Updating system packages"
apt-get update -qq
apt-get upgrade -y -qq \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
apt-get install -y -qq \
    curl wget gnupg2 ca-certificates lsb-release \
    apt-transport-https software-properties-common \
    ufw openssl
log "System updated."

# -----------------------------------------------------------------------------
# STEP 2: Create application directories FIRST
# (must exist before Apache and Nginx start)
# -----------------------------------------------------------------------------
section "Creating application directories"
mkdir -p "${WEBROOT}"
mkdir -p "/var/www/${APP_NAME}/logs"
chown -R www-data:www-data "/var/www/${APP_NAME}"
chmod -R 755 "/var/www/${APP_NAME}"
log "Directories created at /var/www/${APP_NAME}."

# -----------------------------------------------------------------------------
# STEP 3: Install Nginx (frontend :80 -> Varnish :6081)
# -----------------------------------------------------------------------------
section "Installing Nginx"
apt-get install -y -qq nginx

cat > /etc/nginx/sites-available/${APP_NAME} << NGINXEOF
server {
    listen 80;
    listen [::]:80;
    server_name _;

    access_log /var/www/${APP_NAME}/logs/nginx_access.log;
    error_log  /var/www/${APP_NAME}/logs/nginx_error.log;

    location / {
        proxy_pass http://127.0.0.1:${VARNISH_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
        proxy_connect_timeout 10s;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|ttf|svg|webp)$ {
        root ${WEBROOT};
        expires 30d;
        add_header Cache-Control "public, no-transform";
        try_files \$uri @varnish;
    }

    location @varnish {
        proxy_pass http://127.0.0.1:${VARNISH_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/${APP_NAME} /etc/nginx/sites-enabled/${APP_NAME}
rm -f /etc/nginx/sites-enabled/default
systemctl enable nginx
systemctl start nginx
log "Nginx installed on port 80 -> Varnish ${VARNISH_PORT}."

# -----------------------------------------------------------------------------
# STEP 4: Install Varnish (cache layer :6081 -> Apache :8080)
# -----------------------------------------------------------------------------
section "Installing Varnish"
apt-get install -y -qq varnish

cat > /etc/varnish/default.vcl << 'VCLEOF'
vcl 4.1;

backend default {
    .host = "127.0.0.1";
    .port = "8080";
    .connect_timeout = 10s;
    .first_byte_timeout = 300s;
    .between_bytes_timeout = 60s;
}

sub vcl_recv {
    if (req.restarts == 0) {
        if (req.http.X-Forwarded-For) {
            set req.http.X-Forwarded-For = req.http.X-Forwarded-For + ", " + client.ip;
        } else {
            set req.http.X-Forwarded-For = client.ip;
        }
    }

    if (req.method == "PURGE") {
        if (client.ip != "127.0.0.1") {
            return (synth(405, "PURGE not allowed from " + client.ip));
        }
        return (purge);
    }

    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    if (req.http.Authorization) {
        return (pass);
    }

    if (req.url ~ "^/wp-(admin|login|cron)" ||
        req.url ~ "^/wp-json" ||
        req.url ~ "\?(wc-ajax|add-to-cart|remove_item)" ||
        req.url ~ "^/checkout" ||
        req.url ~ "^/my-account" ||
        req.url ~ "^/cart") {
        return (pass);
    }

    if (req.http.Cookie ~ "wordpress_logged_in" ||
        req.http.Cookie ~ "woocommerce_cart_hash" ||
        req.http.Cookie ~ "woocommerce_items_in_cart" ||
        req.http.Cookie ~ "wp_woocommerce_session") {
        return (pass);
    }

    if (req.http.Cookie) {
        set req.http.Cookie = regsuball(req.http.Cookie, "has_js=[^;]+(; )?", "");
        set req.http.Cookie = regsuball(req.http.Cookie, "__utm.=[^;]+(; )?", "");
        set req.http.Cookie = regsuball(req.http.Cookie, "_ga=[^;]+(; )?", "");
        set req.http.Cookie = regsuball(req.http.Cookie, "_gat=[^;]+(; )?", "");
        if (req.http.Cookie == "") {
            unset req.http.Cookie;
        }
    }

    return (hash);
}

sub vcl_hash {
    hash_data(req.url);
    if (req.http.host) {
        hash_data(req.http.host);
    } else {
        hash_data(server.ip);
    }
    return (lookup);
}

sub vcl_backend_response {
    set beresp.ttl = 1h;
    set beresp.grace = 15m;

    if (beresp.http.Set-Cookie) {
        set beresp.uncacheable = true;
        set beresp.ttl = 120s;
        return (deliver);
    }

    if (beresp.status >= 500) {
        set beresp.uncacheable = true;
        set beresp.ttl = 10s;
        return (deliver);
    }

    return (deliver);
}

sub vcl_deliver {
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
        set resp.http.X-Cache-Hits = obj.hits;
    } else {
        set resp.http.X-Cache = "MISS";
    }
    return (deliver);
}
VCLEOF

# Correct systemd override for Varnish on Debian 12
# -F keeps process in foreground so systemd tracks it correctly
# -j unix,user=vcache sets correct jail user
mkdir -p /etc/systemd/system/varnish.service.d
cat > /etc/systemd/system/varnish.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/varnishd \\
    -j unix,user=vcache \\
    -F \\
    -a 0.0.0.0:${VARNISH_PORT} \\
    -f /etc/varnish/default.vcl \\
    -s malloc,256m \\
    -p default_ttl=3600 \\
    -p default_grace=900
EOF

systemctl daemon-reload
systemctl enable varnish
systemctl start varnish
log "Varnish installed on port ${VARNISH_PORT} -> Apache ${APACHE_PORT}."

# -----------------------------------------------------------------------------
# STEP 5: Install Apache (backend :8080 -> PHP-FPM socket)
# -----------------------------------------------------------------------------
section "Installing Apache"
apt-get install -y -qq apache2 libapache2-mod-fcgid

cat > /etc/apache2/ports.conf << PORTSEOF
Listen ${APACHE_PORT}
PORTSEOF

a2enmod rewrite proxy_fcgi setenvif headers remoteip
a2dismod mpm_prefork 2>/dev/null || true
a2enmod mpm_event

cat > /etc/apache2/sites-available/${APP_NAME}.conf << APACHEEOF
<VirtualHost *:${APACHE_PORT}>
    ServerName localhost
    DocumentRoot ${WEBROOT}

    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php${PHP_VERSION}-fpm.sock|fcgi://localhost"
    </FilesMatch>

    <Directory ${WEBROOT}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    RemoteIPHeader X-Forwarded-For
    RemoteIPInternalProxy 127.0.0.1

    ErrorLog /var/www/${APP_NAME}/logs/apache_error.log
    CustomLog /var/www/${APP_NAME}/logs/apache_access.log combined
</VirtualHost>
APACHEEOF

a2ensite ${APP_NAME}
a2dissite 000-default 2>/dev/null || true
systemctl enable apache2
systemctl start apache2
log "Apache installed on port ${APACHE_PORT}."

# -----------------------------------------------------------------------------
# STEP 6: Install PHP 8.2
# -----------------------------------------------------------------------------
section "Installing PHP ${PHP_VERSION}"
curl -sSL https://packages.sury.org/php/README.txt | bash -x
apt-get update -qq

apt-get install -y -qq \
    php${PHP_VERSION}-fpm \
    php${PHP_VERSION}-mysql \
    php${PHP_VERSION}-redis \
    php${PHP_VERSION}-memcached \
    php${PHP_VERSION}-curl \
    php${PHP_VERSION}-gd \
    php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-xml \
    php${PHP_VERSION}-zip \
    php${PHP_VERSION}-bcmath \
    php${PHP_VERSION}-intl \
    php${PHP_VERSION}-soap \
    php${PHP_VERSION}-imagick \
    php${PHP_VERSION}-cli \
    php${PHP_VERSION}-opcache

systemctl enable php${PHP_VERSION}-fpm
systemctl start php${PHP_VERSION}-fpm
log "PHP ${PHP_VERSION} installed."

# -----------------------------------------------------------------------------
# STEP 7: Install MariaDB 10.11 LTS
# -----------------------------------------------------------------------------
section "Installing MariaDB 10.11"
curl -LsSO https://downloads.mariadb.com/MariaDB/mariadb_repo_setup
bash mariadb_repo_setup --mariadb-server-version="mariadb-10.11"
rm -f mariadb_repo_setup
apt-get update -qq
apt-get install -y -qq mariadb-server mariadb-client
systemctl enable mariadb
systemctl start mariadb

mysql -u root << EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
log "MariaDB installed and configured."

# -----------------------------------------------------------------------------
# STEP 8: Install Redis 7
# -----------------------------------------------------------------------------
section "Installing Redis"
apt-get install -y -qq redis-server
sed -i "s/^bind 127.0.0.1 ::1/bind 127.0.0.1/" /etc/redis/redis.conf
sed -i "s/^port 6379/port ${REDIS_PORT}/" /etc/redis/redis.conf
systemctl enable redis-server
systemctl restart redis-server
log "Redis installed on port ${REDIS_PORT}."

# -----------------------------------------------------------------------------
# STEP 9: Install Memcached
# -----------------------------------------------------------------------------
section "Installing Memcached"
apt-get install -y -qq memcached libmemcached-tools
sed -i "s/^-p 11211/-p ${MEMCACHED_PORT}/" /etc/memcached.conf
systemctl enable memcached
systemctl restart memcached
log "Memcached installed on port ${MEMCACHED_PORT}."

# -----------------------------------------------------------------------------
# STEP 10: Deploy test page
# -----------------------------------------------------------------------------
section "Deploying test page"
cat > "${WEBROOT}/index.php" << 'PHPEOF'
<?php
$checks = [];
$checks['PHP Version'] = PHP_VERSION;

try {
    $pdo = new PDO(
        'mysql:host=127.0.0.1;dbname=' . getenv('DB_NAME'),
        getenv('DB_USER'),
        getenv('DB_PASS')
    );
    $checks['MariaDB'] = 'Connected successfully';
} catch (Exception $e) {
    $checks['MariaDB'] = 'Failed: ' . $e->getMessage();
}

try {
    $redis = new Redis();
    $redis->connect('127.0.0.1', 6379);
    $redis->set('thunder_test', 'ok');
    $checks['Redis'] = $redis->get('thunder_test') === 'ok' ? 'Connected and verified' : 'Failed';
} catch (Exception $e) {
    $checks['Redis'] = 'Failed: ' . $e->getMessage();
}

try {
    $mc = new Memcached();
    $mc->addServer('127.0.0.1', 11211);
    $mc->set('thunder_test', 'ok');
    $checks['Memcached'] = $mc->get('thunder_test') === 'ok' ? 'Connected and verified' : 'Failed';
} catch (Exception $e) {
    $checks['Memcached'] = 'Failed: ' . $e->getMessage();
}

$checks['Web Server']  = $_SERVER['SERVER_SOFTWARE'] ?? 'Unknown';
$checks['X-Cache']     = $_SERVER['HTTP_X_CACHE'] ?? 'MISS (first request)';

echo "<h2>ThunderStack Status</h2><ul>";
foreach ($checks as $k => $v) {
    echo "<li><strong>{$k}:</strong> {$v}</li>";
}
echo "</ul><p><small>Route: Nginx -> Varnish -> Apache -> PHP-FPM</small></p>";
PHPEOF

chown -R www-data:www-data "/var/www/${APP_NAME}"
log "Test page deployed."

# -----------------------------------------------------------------------------
# STEP 11: Tune PHP-FPM
# -----------------------------------------------------------------------------
section "Tuning PHP-FPM"
PHP_FPM_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
sed -i "s/^pm = .*/pm = dynamic/" ${PHP_FPM_CONF}
sed -i "s/^pm.max_children = .*/pm.max_children = 10/" ${PHP_FPM_CONF}
sed -i "s/^pm.start_servers = .*/pm.start_servers = 2/" ${PHP_FPM_CONF}
sed -i "s/^pm.min_spare_servers = .*/pm.min_spare_servers = 1/" ${PHP_FPM_CONF}
sed -i "s/^pm.max_spare_servers = .*/pm.max_spare_servers = 3/" ${PHP_FPM_CONF}
systemctl restart php${PHP_VERSION}-fpm
log "PHP-FPM pool tuned."

# -----------------------------------------------------------------------------
# STEP 12: Restart all services in correct order
# -----------------------------------------------------------------------------
section "Starting all services"
systemctl restart php${PHP_VERSION}-fpm
systemctl restart mariadb
systemctl restart redis-server
systemctl restart memcached
systemctl restart apache2
systemctl restart varnish
systemctl restart nginx
log "All services started."

# -----------------------------------------------------------------------------
# STEP 13: Configure UFW Firewall
# -----------------------------------------------------------------------------
section "Configuring firewall"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp  comment 'SSH'
ufw allow 80/tcp  comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable
log "Firewall configured. Internal ports 6081 and 8080 are not exposed."

# -----------------------------------------------------------------------------
# SUMMARY
# -----------------------------------------------------------------------------
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo "=============================================="
echo "   ThunderStack Bootstrap Complete"
echo "=============================================="
echo ""
echo "  Server IP      : ${SERVER_IP}"
echo "  Webroot        : ${WEBROOT}"
echo "  PHP Version    : ${PHP_VERSION}"
echo ""
echo "  PORT MAP:"
echo "  Nginx    :80    -> Varnish  :${VARNISH_PORT}"
echo "  Varnish  :${VARNISH_PORT} -> Apache   :${APACHE_PORT}"
echo "  Apache   :${APACHE_PORT} -> PHP-FPM  (socket)"
echo "  MariaDB  :3306  (localhost only)"
echo "  Redis    :${REDIS_PORT}  (localhost only)"
echo "  Memcached:${MEMCACHED_PORT} (localhost only)"
echo ""
echo "  Database   : ${DB_NAME}"
echo "  DB User    : ${DB_USER}"
echo "  DB Password: ${DB_PASS}"
echo ""
echo "  Test URL   : http://${SERVER_IP}/index.php"
echo "  Cache test : curl -I http://${SERVER_IP}/index.php | grep X-Cache"
echo ""
echo "  SAVE YOUR DB PASSWORD - it will not be shown again."
echo "=============================================="
