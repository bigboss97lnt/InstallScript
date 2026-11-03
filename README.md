# Odoo 17 installer

Fresh-server installer for **Ubuntu 24.04 LTS, AMD64, Python 3.12**. Installs Odoo
17 Community, PostgreSQL 16, a native systemd service, Nginx, Cloudflare Origin
SSL, and the pinned Python packages used by the validated deployment.

Based on the installer by Yenthe Van Ginneken and André Schenkels. See LICENSE.
The `16.0` branch remains separate; this branch does not support Debian.

## Before installation

Use a fresh server with root/sudo access, outbound Internet access and sufficient
RAM for three HTTP workers plus cron and gevent (the reference deployment had
4 GB RAM). Memory limits below apply per worker; size the machine for workload.
This is not an upgrade script. Back up an existing installation and use a
migration procedure instead. Existing Odoo code/configuration causes an early exit.

Point your domain's Cloudflare DNS record at the server and enable proxying
(orange cloud). Choose **Full (strict)** in Cloudflare SSL/TLS settings.

### Download the entire branch

The installer needs the requirements file, Cloudflare helper and public CA file
alongside it; downloading only the shell script is insufficient.

```bash
sudo apt-get update
sudo apt-get install -y git
sudo git clone --branch 17.0 --single-branch https://github.com/bigboss97lnt/InstallScript.git /root/InstallScript
sudo nano /root/InstallScript/odoo_install.sh
```

Set the variables near the top of the script:

| Setting | Instructions |
| --- | --- |
| `WEBSITE_NAME` | Replace `odoo.example.com` with your actual hostname. |
| `CUSTOM_ADDONS_REPO` | Optional Git URL, e.g. `git@github.com:YOUR_ORG/YOUR_ADDONS.git`; empty skips cloning. |
| `CUSTOM_ADDONS_BRANCH` | Optional branch; empty uses the repository's default branch. |
| `SSH_PORT` | Set your actual SSH port **before** enabling the firewall. Default: `22`. |
| `CLOUDFLARE_FIREWALL` | `True` restricts web access to Cloudflare; `False` leaves firewall management to you. |
| `GENERATE_RANDOM_PASSWORD` | Keep `True` to generate a unique database master password. |
| `IS_ENTERPRISE` | Default `False`; `True` requires authorized SSH access to `odoo/enterprise`. |
| `INSTALL_NGINX`, `ENABLE_SSL` | Default `True`; recommended for the supplied configuration. |

Public Odoo source is cloned over HTTPS. For private custom/Enterprise repos,
configure a GitHub SSH key for the root account running the installer, verify
GitHub's host key and test repository access beforehand. Do not put tokens or
passwords in repository URLs. No GitHub credentials are included.

Custom modules must be directly inside the chosen repository root. It is cloned
into `/odoo/custom/addons`, which is already included in `addons_path`. Cloning
makes modules discoverable; it does not install or upgrade them in a database.

### Supply your SSL files

1. In Cloudflare, create an **RSA Origin Certificate** covering your hostname.
2. Save the PEM certificate as `/root/InstallScript/origin_cert`.
3. Save its matching PEM private key as `/root/InstallScript/private_key`.
4. Restrict the key permissions:

```bash
sudo chmod 600 /root/InstallScript/private_key
```

These files must contain actual PEM data, not filenames or dashboard text.
The private key must be unencrypted for unattended Nginx startup. To use a
different source directory, set `CF_CERT_HOME` when running the installer.

The installer validates hostname, dates, CA signature and matching public keys
before installation. The bundled `cloudflare-origin-ca.pem` is Cloudflare's
**public RSA CA certificate**, not a deployment certificate or private key.
Source: https://developers.cloudflare.com/ssl/static/origin_ca_rsa_root.pem

Files are copied to `/etc/nginx/ssl/origin_cert.pem` and `origin_key.pem`; the
private key is mode `0600`. Source files are retained and ignored by Git.
Never commit keys, deployment certificates, generated configurations or logs.
Origin certificates require Cloudflare proxying and are not browser-trusted for
direct origin access. See [Cloudflare Origin CA documentation](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/).

## Run

```bash
sudo bash /root/InstallScript/odoo_install.sh
```

The script exits on failure, waits for apt locks, and prints the generated
**Odoo database master password** at completion. Save it securely; it is also in
`/etc/odoo-server.conf`. Do not publish terminal output containing that password.
The PostgreSQL role uses local peer authentication; no PostgreSQL password is
set. No application database or application login is created. With `list_db =
False`, database management is disabled; create or restore your database using
your administrative deployment procedure before expecting an application login.

If installation stops partway through, inspect the error and partial state;
do not blindly rerun it over installed code/configuration.

## Installed configuration

The default Community configuration includes:

```ini
addons_path=/odoo/odoo-server/addons,/odoo/custom/addons
proxy_mode = True
http_interface = 127.0.0.1
http_port = 8069
gevent_port = 8072
limit_memory_hard = 1929379840
limit_memory_soft = 1442840576
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
max_cron_threads = 1
workers = 3
list_db = False
```

Enterprise mode also adds `/odoo/enterprise/addons`. Nginx routes WebSocket
traffic to gevent and trusts `CF-Connecting-IP` only from validated Cloudflare
networks. It tests its configuration before reload.

Python lives in `/odoo/venv`. The venv inherits Ubuntu system packages to retain
distro builds such as pandas `2.1.4+dfsg` and lz4 `4.0.2+dfsg`; pip writes stay
inside the venv. The 169 explicit pins are in `odoo-requirements-pinned.txt`.
The installer explicitly installs `zope.interface==6.1` inside the venv to avoid
a distro namespace conflict that prevents the gevent worker from starting.
OS utilities and security updates remain managed by apt; this does not recreate
every package/version from another server's system-wide `pip list`.

### Firewall behavior

When enabled, the helper fetches and validates both official lists:
https://www.cloudflare.com/ips-v4 and https://www.cloudflare.com/ips-v6.
It denies unsolicited incoming traffic and allows TCP 80/443 only from those
networks. **SSH remains an explicit exception on `SSH_PORT` from any address.**
Outgoing and established connections are allowed. Odoo and PostgreSQL are not
exposed directly with the default configuration.

This firewall mode requires a fresh UFW rule set and IPv6 filtering enabled.
It refuses existing UFW rules rather than resetting them or leaving broad web
allows in place. Existing provider firewalls must also permit Cloudflare traffic
and your administrative SSH access. Review Cloudflare range changes periodically;
automatic updates are not installed. For an existing firewall, manage equivalent
rules yourself and set `CLOUDFLARE_FIREWALL="False"`.

## Validate and operate

```bash
sudo systemctl status odoo-server nginx postgresql
sudo journalctl -u odoo-server -n 50 --no-pager
sudo tail -n 50 /var/log/odoo/odoo-server.log
sudo nginx -t
sudo ufw status verbose
/odoo/venv/bin/python -m pip check
/odoo/venv/bin/python -m pip list
curl -fsS 'http://127.0.0.1:8069/web/health?db_server_status=1'
curl -fsS 'http://127.0.0.1:8072/web/health?db_server_status=1'
curl -fsS 'https://YOUR_HOSTNAME/web/health?db_server_status=1'
sudo systemctl restart odoo-server
```

Health checks should return `{"status": "pass", "db_server_status": true}`.
They verify service/database connectivity, not custom-module functionality.
Service: `/etc/systemd/system/odoo-server.service`.
Configuration: `/etc/odoo-server.conf`.
Nginx site: `/etc/nginx/sites-available/YOUR_HOSTNAME`.

For read-only preparation checks:

```bash
bash -n odoo_install.sh
python3 setup_cloudflare.py --check
```
