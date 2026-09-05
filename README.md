# Odoo 18 Enterprise installation script

This branch installs **Odoo 18 Enterprise** from source on Ubuntu, with the
production stack used by this fork:

- Ubuntu 22.04 LTS (Jammy) or 24.04 LTS (Noble), on AMD64 or ARM64
- PostgreSQL 16 and pgvector
- Odoo Community plus the private Enterprise addons
- an isolated Python virtual environment
- wkhtmltopdf 0.12.6.1-3 with patched Qt
- a systemd service with two Odoo workers and a gevent worker
- Nginx with Cloudflare Origin Certificate TLS and real visitor IP restoration

The script is based on
[Yenthe666/InstallScript](https://github.com/Yenthe666/InstallScript) and keeps
the Cloudflare, patched-wkhtmltopdf, virtualenv, and hardening work from this
repository's 16.0 branch.

## Before running

Use a fresh Ubuntu server with at least 2 GB of RAM. Four GB or more is a more
comfortable baseline for PostgreSQL, two Odoo workers, and a production
database.

Edit the variables at the top of `odoo_install.sh`, especially:

- `WEBSITE_NAME`: the hostname proxied through Cloudflare
- `WORKERS`: size this for the server's CPU and memory
- `OE_USER`, ports, and database master-password settings if their defaults
  conflict with another Odoo installation
- `ENTERPRISE_REPO`: change this to an SSH URL if SSH authentication is
  preferred

Enterprise is enabled by default. The GitHub identity used while running the
script must have access to the private
[odoo/enterprise](https://github.com/odoo/enterprise) repository. With the
default HTTPS URL, use your GitHub username and a personal access token when Git
prompts for credentials; GitHub account passwords cannot authenticate Git
operations.

## Cloudflare Origin Certificate

Create a Cloudflare Origin Certificate covering `WEBSITE_NAME`, then place:

- the certificate at `/root/certificate`
- the private key at `/root/private_key`

The installer copies them to
`/etc/nginx/ssl/<hostname>/origin.crt` and `origin.key`. The private key is
mode `0600`. By default, the source files are removed after installation; set
`REMOVE_CF_SOURCE_FILES="False"` to retain them.

After installation, enable the Cloudflare proxy and select **Full (strict)** as
the SSL/TLS encryption mode. Nginx trusts `CF-Connecting-IP` only for requests
arriving from Cloudflare's published IPv4 and IPv6 ranges.

## Install

```bash
sudo wget https://raw.githubusercontent.com/bigboss97lnt/InstallScript/18.0/odoo_install.sh
sudo chmod +x odoo_install.sh
sudo ./odoo_install.sh
```

The preflight check stops before changing the server if the OS or architecture
is unsupported, the hostname is still the placeholder, the certificate files
are missing, or an Odoo installation already occupies the target path.

## What the script configures

Odoo is installed under `/odoo` by default:

- Community: `/odoo/odoo-server`
- Enterprise: `/odoo/enterprise/addons`
- custom addons: `/odoo/custom/addons`
- Python environment: `/odoo/venv`
- configuration: `/etc/odoo-server.conf`
- logs: `/var/log/odoo/odoo-server.log`
- service: `odoo-server.service`

The PostgreSQL role has `CREATEDB` but is deliberately not a superuser, in
line with Odoo's deployment guidance. Odoo listens only on loopback; Nginx
proxies normal requests to port 8069 and `/websocket` requests to the gevent
port 8072.

For Ubuntu 22.04 / Python 3.10, the installer retains the known-safe workaround
for Odoo's pinned gevent 21.8.0 build. Ubuntu 24.04 / Python 3.12 installs the
version selected by Odoo 18's current requirements file.

## After restoring the Odoo.sh database

This script installs the destination stack; it does not download or restore the
Odoo.sh backup. After restoring the database and filestore:

1. Confirm all custom addons used by the database are in
   `/odoo/custom/addons`.
2. Uncomment and set a strict `dbfilter` in `/etc/odoo-server.conf`.
3. Add `list_db = False` after database-management access is no longer needed.
4. Restart and inspect the service:

   ```bash
   sudo systemctl restart odoo-server
   sudo systemctl status odoo-server
   sudo journalctl -u odoo-server -n 200 --no-pager
   ```

The Odoo 18 documentation requires Python 3.10+, PostgreSQL 12+, and a manual
wkhtmltopdf 0.12.6 patched-Qt installation. Its production proxy example routes
`/websocket` to the gevent port:

- [Odoo 18 packaged installers](https://www.odoo.com/documentation/18.0/administration/on_premise/packages.html)
- [Odoo 18 source installation](https://www.odoo.com/documentation/18.0/administration/on_premise/source.html)
- [Odoo 18 system configuration](https://www.odoo.com/documentation/18.0/administration/on_premise/deploy.html)
