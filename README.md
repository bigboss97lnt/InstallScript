# [Odoo](https://www.odoo.com "Odoo's Homepage") Install Script

This script is based on the install script from André Schenkels (https://github.com/aschenkels-ictstudio/openerp-install-scripts)
but goes a bit further and has been improved. This script will also give you the ability to define an xmlrpc_port in the .conf file that is generated under /etc/
This script can be safely used in a multi-odoo code base server because the default Odoo port is changed BEFORE the Odoo is started.

## Supported platform

This version targets **Ubuntu 22.04 LTS (Jammy) on AMD64** and installs Odoo
16.0. The platform check is intentional because the included wkhtmltopdf package
is built specifically for Jammy AMD64.

## Nginx and Cloudflare SSL

Set `INSTALL_NGINX="True"` to install Nginx. You should also configure Odoo
workers for production use; see the [Odoo deployment guide](https://www.odoo.com/documentation/16.0/administration/install/deploy.html).

HTTPS uses a **Cloudflare Origin Certificate**, not Certbot or Let's Encrypt.
Before running the installer:

1. Create an Origin Certificate in the Cloudflare dashboard for your hostname.
2. Save the certificate as `/root/certificate`.
3. Save its private key as `/root/private_key`.
4. Set `WEBSITE_NAME` to the proxied Cloudflare hostname.
5. Set both `INSTALL_NGINX="True"` and `ENABLE_SSL="True"`.
6. After installation, enable the Cloudflare proxy and select **Full (strict)**
   under SSL/TLS encryption mode.

The installer moves the files to
`/etc/nginx/ssl/<website>/origin.crt` and `origin.key`, restricts the private key
to mode `0600`, and removes the originals from `/root`. Never commit the private
key to this repository.

Nginx downloads Cloudflare's current IPv4 and IPv6 network lists and trusts
`CF-Connecting-IP` only for connections originating from those networks. This
restores the visitor address in Nginx logs and in the headers forwarded to Odoo.

## Installation procedure

##### 1. Download the script:
```
sudo wget https://raw.githubusercontent.com/bigboss97lnt/InstallScript/16.0/odoo_install.sh
```
##### 2. Modify the parameters as you wish.
There are a few things you can configure, this is the most used list:<br/>
`OE_USER` is the Odoo system user name.<br/>
`GENERATE_RANDOM_PASSWORD` generates a secure database master password when set
to `True`; otherwise `OE_SUPERADMIN` is used.<br/>
`INSTALL_WKHTMLTOPDF` installs wkhtmltopdf 0.12.6.1 with patched Qt when set to
`True`.<br/>
`OE_PORT` is Odoo's HTTP port, normally `8069`.<br/>
`LONGPOLLING_PORT` is Odoo's long-polling port, normally `8072`.<br/>
`OE_VERSION` selects the Odoo branch and defaults to `16.0`.<br/>
`IS_ENTERPRISE` installs Enterprise addons when set to `True`; GitHub access to
the private Odoo Enterprise repository is required.<br/>
`INSTALL_POSTGRESQL_FOURTEEN` installs PostgreSQL 14 from the official PGDG
repository when set to `True`.<br/>
`INSTALL_NGINX` installs and configures Nginx when set to `True`.<br/>
`WEBSITE_NAME` must be changed from `_` to the Cloudflare hostname when Nginx is
enabled.<br/>
`ENABLE_SSL` enables the supplied Cloudflare Origin Certificate.<br/>
`CF_CERT_SOURCE` and `CF_KEY_SOURCE` are the source certificate and private-key
paths; they default to `/root/certificate` and `/root/private_key`.<br/>

Python packages are installed in an isolated virtual environment at
`/odoo/venv`. For Python 3.10 compatibility, gevent 21.8.0 is built separately
with build isolation disabled and a compatible Cython version; the rest of the
official Odoo 16 requirements are then installed normally.

#### 3. Make the script executable
```
sudo chmod +x odoo_install.sh
```
##### 4. Execute the script:
```
sudo ./odoo_install.sh
```

## Where should I host Odoo?
There are plenty of great services that offer good hosting. The script has been tested with a few major players such as [Google Cloud](https://cloud.google.com/), [Hetzner](https://www.hetzner.com/), [Amazon AWS](https://aws.amazon.com/) and [DigitalOcean](https://www.digitalocean.com/products/droplets/).
If you'd like you can use my [DigitalOcean referral link](https://m.do.co/c/d605cc420682) which gives you a 200$ voucher for free for the first 60 days.

## Minimal server requirements
While technically you can run an Odoo instance on 1GB (1024MB) of RAM it is absolutely not advised. A Linux instance typically uses 300MB-500MB and the rest has to be split among Odoo, postgreSQL and others. If you install an Odoo you should make sure to use at least 2GB of RAM. This script might fail with less resources too.
There are known issues on DigitalOcean for example where the installation crashes on 1GB RAM machines. See https://github.com/Yenthe666/InstallScript/issues/243
