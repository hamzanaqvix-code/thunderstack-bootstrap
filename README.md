# ThunderStack Bootstrap

A production-grade bash script that provisions the full hybrid ThunderStack on a fresh Debian 11/12 server in a single command.

## Stack

| Component | Version | Port |
|-----------|---------|------|
| Nginx | Latest stable | 80 (public) |
| Varnish | 7.x | 6081 (internal) |
| Apache | 2.4.x | 8080 (internal) |
| PHP-FPM | 8.2 LTS | Unix socket |
| MariaDB | 10.11 LTS | 3306 (localhost) |
| Redis | 7.x | 6379 (localhost) |
| Memcached | Latest stable | 11211 (localhost) |

## Request flow

    Client
      |
    Nginx :80        <- SSL termination, static file serving
      |
    Varnish :6081    <- Full page cache, PURGE support, WordPress cookie rules
      |
    Apache :8080     <- PHP handler, .htaccess support, RemoteIP passthrough
      |
    PHP-FPM socket   <- Application execution
      |
    MariaDB / Redis / Memcached

## What the script does

- Creates application directory structure before any service starts
- Installs and configures Nginx as the public-facing frontend proxy
- Installs Varnish with production-ready VCL including WordPress and WooCommerce cache bypass rules
- Configures the correct systemd override for Varnish on Debian 12 (-F foreground flag required)
- Installs Apache on port 8080 with PHP-FPM socket passthrough and RemoteIP module
- Adds the Sury PHP repository and installs PHP 8.2 with all common production extensions
- Installs MariaDB 10.11 LTS, secures the installation, and creates an application database
- Installs Redis on port 6379 bound to localhost
- Installs Memcached on port 11211 bound to localhost
- Tunes PHP-FPM pool for a 1GB server
- Starts all services in the correct dependency order
- Configures UFW firewall exposing only ports 22, 80, and 443
- Deploys a PHP test page that verifies the full stack including cache hit/miss headers

## Usage

    git clone https://github.com/hamzanaqvix-code/thunderstack-bootstrap.git
    cd thunderstack-bootstrap
    chmod +x thunderstack.sh
    sudo bash thunderstack.sh

To change the application name edit APP_NAME at the top of thunderstack.sh before running.

## Requirements

- Debian 11 (Bullseye) or Debian 12 (Bookworm)
- Root access
- Fresh server with no existing web stack

## Verified on

- Debian 12.12 (Bookworm) on DigitalOcean Basic Droplet (1 vCPU, 1GB RAM)

## After installation

Visit http://YOUR_SERVER_IP/index.php to verify the stack.

Expected output:
- PHP Version: 8.2.x
- MariaDB: Connected successfully
- Redis: Connected and verified
- Memcached: Connected and verified
- Web Server: Apache/2.4.x (Debian)
- X-Cache: MISS (first request)

Run the same URL a second time and X-Cache will show HIT confirming Varnish is caching correctly.

## Varnish cache bypass rules included

- WordPress admin (/wp-admin, /wp-login, /wp-cron)
- WordPress REST API (/wp-json)
- WooCommerce cart, checkout, and account pages
- Logged-in users (wordpress_logged_in cookie)
- Active WooCommerce sessions
- Analytics cookies stripped before caching (ga, utm, gat)

## Security notes

- Apache is bound to port 8080 and not directly accessible from the internet
- Varnish is bound to port 6081 and not directly accessible from the internet
- PURGE requests are restricted to 127.0.0.1 only
- MariaDB, Redis, and Memcached are bound to localhost only
- UFW blocks all inbound traffic except SSH, HTTP, and HTTPS

## Related projects

- lemp-stack-bootstrap: https://github.com/hamzanaqvix-code/lemp-stack-bootstrap
  Nginx + PHP-FPM + MariaDB + Redis for WordPress Lightning Stack deployments
