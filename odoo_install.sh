#!/bin/bash
set -Eeuo pipefail
trap 'echo "Installation failed at line $LINENO" >&2' ERR
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
################################################################################
# Odoo 17 fresh-server installer for Ubuntu 24.04 AMD64 / Python 3.12.
# Based on the installer by Yenthe Van Ginneken and André Schenkels.
# Read README.md, supply SSL files and configure the variables below first.
# Run: sudo bash odoo_install.sh
################################################################################

OE_USER="odoo"
OE_HOME="/$OE_USER"
OE_HOME_EXT="/$OE_USER/${OE_USER}-server"
OE_VENV="$OE_HOME/venv"
PINNED_REQUIREMENTS="$SCRIPT_DIR/odoo-requirements-pinned.txt"
# The default port where this Odoo instance will run under (provided you use the command -c in the terminal)
# Set to true if you want to install it, false if you don't need it or have it already installed.
INSTALL_WKHTMLTOPDF="True"
# Set the default Odoo port (you still have to use -c /etc/odoo-server.conf for example to use this.)
OE_PORT="8069"
# The package pins and configuration target Odoo 17.0 only.
# IMPORTANT! This script contains extra libraries that are specifically needed for Odoo 17.0
OE_VERSION="17.0"
# Set this to True if you want to install the Odoo enterprise version!
IS_ENTERPRISE="False"
# Install a version-specific PostgreSQL package to avoid the distro meta-package
# pulling in an unexpected major upgrade on newer Ubuntu releases.
INSTALL_POSTGRESQL_SIXTEEN="True"
# Set this to True if you want to install Nginx!
INSTALL_NGINX="True"
# Set the superadmin password - if GENERATE_RANDOM_PASSWORD is set to "True" we will automatically generate a random password, otherwise we use this one
OE_SUPERADMIN="CHANGE_ME"
# Set to "True" to generate a random password, "False" to use the variable in OE_SUPERADMIN
GENERATE_RANDOM_PASSWORD="True"
OE_CONFIG="${OE_USER}-server"
# Set the website name
WEBSITE_NAME="odoo.example.com"
# Optional addon repository; modules must be at its root. Leave empty to skip.
CUSTOM_ADDONS_REPO=""
CUSTOM_ADDONS_BRANCH=""
# Restrict web ingress to Cloudflare; preserve the configured SSH port.
CLOUDFLARE_FIREWALL="True"
SSH_PORT="22"
# Set the default Odoo longpolling port (you still have to use -c /etc/odoo-server.conf for example to use this.)
LONGPOLLING_PORT="8072"
# Set to True for Cloudflare Origin SSL; source files default to the script directory.
ENABLE_SSL="True"
CF_CERT_HOME="${CF_CERT_HOME:-$SCRIPT_DIR}"
# Expected source files before installation:
#   $CF_CERT_HOME/origin_cert
#   $CF_CERT_HOME/private_key
CF_ORIGIN_CERT="$CF_CERT_HOME/origin_cert"
CF_PRIVATE_KEY="$CF_CERT_HOME/private_key"
CF_SSL_DIR="/etc/nginx/ssl"
# Validate local inputs before changing the server.
if [ "$EUID" -ne 0 ]; then
  echo "Run this installer as root (sudo bash $0)." >&2
  exit 1
fi
[[ ! -e "$OE_HOME_EXT" && ! -e "/etc/${OE_CONFIG}.conf" ]] || { echo "Existing Odoo installation found; use a fresh server." >&2; exit 1; }
[[ "$(dpkg --print-architecture)" = amd64 ]] || { echo "AMD64 is required for the bundled wkhtmltopdf build." >&2; exit 1; }
if [[ "$INSTALL_NGINX" = True ]]; then
  [[ "$WEBSITE_NAME" != odoo.example.com && "$WEBSITE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]] || { echo "Set WEBSITE_NAME to your real hostname." >&2; exit 1; }
fi
if [[ "$GENERATE_RANDOM_PASSWORD" != True ]]; then
  [[ "$OE_SUPERADMIN" != CHANGE_ME && "$OE_SUPERADMIN" =~ ^[a-zA-Z0-9_-]{16,}$ ]] || { echo "Set a master password of at least 16 letters, digits, underscores or hyphens." >&2; exit 1; }
fi
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || { echo "Invalid SSH_PORT" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/setup_cloudflare.py" ]] || { echo "Download the complete repository." >&2; exit 1; }
source /etc/os-release
[[ "$ID" = ubuntu && "$VERSION_ID" = 24.04 ]] || { echo "These pins require Ubuntu 24.04 / Python 3.12" >&2; exit 1; }
[[ -r "$PINNED_REQUIREMENTS" ]] || { echo "Missing $PINNED_REQUIREMENTS" >&2; exit 1; }
if [ "$INSTALL_NGINX" = "True" ] && [ "$ENABLE_SSL" = "True" ]; then
  [[ -r "$CF_ORIGIN_CERT" && -r "$CF_PRIVATE_KEY" ]] || { echo "Missing SSL certificate or private key" >&2; exit 1; }
  openssl x509 -in "$CF_ORIGIN_CERT" -noout -checkend 86400
  openssl x509 -in "$CF_ORIGIN_CERT" -noout -checkhost "$WEBSITE_NAME"
  openssl pkey -in "$CF_PRIVATE_KEY" -passin pass: -check -noout
  cert_pub=$(openssl x509 -in "$CF_ORIGIN_CERT" -pubkey -noout)
  key_pub=$(openssl pkey -in "$CF_PRIVATE_KEY" -passin pass: -pubout)
  [[ "$cert_pub" = "$key_pub" ]] || { echo "SSL certificate and key do not match" >&2; exit 1; }
  openssl verify -CAfile "$SCRIPT_DIR/cloudflare-origin-ca.pem" -verify_hostname "$WEBSITE_NAME" "$CF_ORIGIN_CERT"
  chmod 600 "$CF_PRIVATE_KEY"
fi

#--------------------------------------------------
# Update Server
#--------------------------------------------------
echo -e "\n---- Update Server ----"
sudo apt-get -o DPkg::Lock::Timeout=300 update
sudo apt-get -o DPkg::Lock::Timeout=300 install libpq-dev curl ca-certificates gnupg git -y

#--------------------------------------------------
# Install PostgreSQL Server
#--------------------------------------------------
echo -e "\n---- Install PostgreSQL Server ----"
if [ "$INSTALL_POSTGRESQL_SIXTEEN" = "True" ]; then
    echo -e "\n---- Installing version-specific PostgreSQL package to avoid an automatic major upgrade ----"
    sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc|sudo gpg --batch --yes --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
    sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    sudo apt-get -o DPkg::Lock::Timeout=300 update
    sudo apt-get -o DPkg::Lock::Timeout=300 install postgresql-16 -y
else
    echo -e "\n---- Installing the default postgreSQL version based on Linux version ----"
    sudo apt-get -o DPkg::Lock::Timeout=300 install postgresql postgresql-server-dev-all -y
fi


echo -e "\n---- Creating the ODOO PostgreSQL User  ----"
sudo -u postgres createuser --createdb --no-superuser --no-createrole "$OE_USER"

#--------------------------------------------------
# Install Dependencies
#--------------------------------------------------
echo -e "\n--- Installing Python 3 + pip3 --"
sudo apt-get -o DPkg::Lock::Timeout=300 install python3 python3-pip -y
sudo apt-get -o DPkg::Lock::Timeout=300 install git python3-cffi build-essential wget python3-dev python3-venv python3-wheel libxslt-dev libzip-dev libldap2-dev libsasl2-dev python3-setuptools libcairo2-dev libgirepository1.0-dev pkg-config libsystemd-dev libdbus-1-dev python3-pandas python3-kiwisolver python3-mpmath python3-lz4 libpng-dev libjpeg-dev -y

echo -e "\n---- Install python packages/requirements ----"
sudo python3 -m venv --system-site-packages "$OE_VENV"
sudo "$OE_VENV/bin/python" -m pip install -r "$PINNED_REQUIREMENTS"
sudo "$OE_VENV/bin/python" -m pip install --ignore-installed --no-deps zope.interface==6.1
sudo "$OE_VENV/bin/python" -m pip check

echo -e "\n---- Installing Node JS and rtlcss for LTR support ----"
if command -v node >/dev/null 2>&1; then
    echo "Node is already installed at $(command -v node); keeping the existing version."
else
    sudo apt-get -o DPkg::Lock::Timeout=300 install nodejs npm -y
fi
if command -v npm >/dev/null 2>&1; then
    sudo npm install -g rtlcss
else
    echo "npm is not available; skipping rtlcss installation."
fi

#--------------------------------------------------
# Install Wkhtmltopdf if needed
#--------------------------------------------------
if [ $INSTALL_WKHTMLTOPDF = "True" ]; then
  echo -e "\n---- Install patched-Qt wkhtmltopdf ----"
  WKHTMLTOPDF_DEB="wkhtmltox_0.12.6.1-2.jammy_amd64.deb"
  WKHTMLTOPDF_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/${WKHTMLTOPDF_DEB}"
  wget -q -O "/tmp/${WKHTMLTOPDF_DEB}" "$WKHTMLTOPDF_URL"
  apt-get -o DPkg::Lock::Timeout=300 install -y "/tmp/${WKHTMLTOPDF_DEB}"

else
  echo "Wkhtmltopdf isn't installed due to the choice of the user!"
fi

echo -e "\n---- Create ODOO system user ----"
sudo adduser --system --quiet --shell=/bin/bash --home=$OE_HOME --gecos 'ODOO' --group $OE_USER

echo -e "\n---- Create Log directory ----"
sudo mkdir -p /var/log/$OE_USER
sudo chown $OE_USER:$OE_USER /var/log/$OE_USER

#--------------------------------------------------
# Install ODOO
#--------------------------------------------------
echo -e "\n==== Installing ODOO Server ===="
sudo --preserve-env=SSH_AUTH_SOCK,SSH_AGENT_PID git clone --depth 1 --branch $OE_VERSION https://github.com/odoo/odoo.git $OE_HOME_EXT/

if [ $IS_ENTERPRISE = "True" ]; then
    # Odoo Enterprise install!
    echo -e "\n--- Create symlink for node"
    if ! command -v node >/dev/null 2>&1 && command -v nodejs >/dev/null 2>&1; then
        sudo ln -s /usr/bin/nodejs /usr/bin/node
    fi
    sudo su $OE_USER -c "mkdir $OE_HOME/enterprise"
    sudo su $OE_USER -c "mkdir $OE_HOME/enterprise/addons"

    GITHUB_RESPONSE=$(sudo --preserve-env=SSH_AUTH_SOCK,SSH_AGENT_PID git clone --depth 1 --branch $OE_VERSION git@github.com:odoo/enterprise.git "$OE_HOME/enterprise/addons" 2>&1) || {
        echo "------------------------WARNING------------------------------"
        echo "Your authentication with Github failed while cloning the Odoo enterprise repository."
        printf "In order to clone and install the Odoo enterprise version you \nneed to be an offical Odoo partner and you need access to\nhttp://github.com/odoo/enterprise.\n"
        echo "Git returned:"
        echo "$GITHUB_RESPONSE"
        exit 1
    }

    echo -e "\n---- Added Enterprise code under $OE_HOME/enterprise/addons ----"
    echo -e "\n---- Installing Enterprise specific libraries ----"
    sudo npm install -g less
    sudo npm install -g less-plugin-clean-css
fi

echo -e "\n---- Create custom module directory ----"
sudo chown "$OE_USER:$OE_USER" "$OE_HOME"
sudo su $OE_USER -c "mkdir -p $OE_HOME/custom"
sudo su $OE_USER -c "mkdir -p $OE_HOME/custom/addons"
if [[ -n "$CUSTOM_ADDONS_REPO" ]]; then
  clone_args=(--depth 1)
  [[ -z "$CUSTOM_ADDONS_BRANCH" ]] || clone_args+=(--branch "$CUSTOM_ADDONS_BRANCH")
  git clone "${clone_args[@]}" -- "$CUSTOM_ADDONS_REPO" "$OE_HOME/custom/addons"
fi

echo -e "\n---- Setting permissions on home folder ----"
sudo chown $OE_USER:$OE_USER "$OE_HOME"
sudo chown -R $OE_USER:$OE_USER $OE_HOME/*

echo -e "* Create server config file"


sudo install -m 0640 /dev/null /etc/${OE_CONFIG}.conf
echo -e "* Creating server config file"
sudo su root -c "printf '[options] \n; This is the password that allows database operations:\n' >> /etc/${OE_CONFIG}.conf"
if [ $GENERATE_RANDOM_PASSWORD = "True" ]; then
    echo -e "* Generating random admin password"
    OE_SUPERADMIN=$(openssl rand -hex 24)
fi
sudo su root -c "printf 'admin_passwd = ${OE_SUPERADMIN}\n' >> /etc/${OE_CONFIG}.conf"
sudo su root -c "printf 'http_port = ${OE_PORT}\n' >> /etc/${OE_CONFIG}.conf"
if [ "$INSTALL_NGINX" = "True" ]; then
  sudo su root -c "printf 'http_interface = 127.0.0.1\nproxy_mode = True\nworkers = 3\nlimit_memory_hard = 1929379840\nlimit_memory_soft = 1442840576\nlimit_request = 8192\nlimit_time_cpu = 600\nlimit_time_real = 1200\nmax_cron_threads = 1\nlist_db = False\ngevent_port = ${LONGPOLLING_PORT}\n' >> /etc/${OE_CONFIG}.conf"
fi
sudo su root -c "printf 'logfile = /var/log/${OE_USER}/${OE_CONFIG}.log\n' >> /etc/${OE_CONFIG}.conf"

if [ $IS_ENTERPRISE = "True" ]; then
    sudo su root -c "printf 'addons_path=${OE_HOME}/enterprise/addons,${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons\n' >> /etc/${OE_CONFIG}.conf"
else
    sudo su root -c "printf 'addons_path=${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons\n' >> /etc/${OE_CONFIG}.conf"
fi
sudo chown $OE_USER:$OE_USER /etc/${OE_CONFIG}.conf
sudo chmod 640 /etc/${OE_CONFIG}.conf

echo -e "* Create startup file"
sudo su root -c "echo '#!/bin/sh' > $OE_HOME_EXT/start.sh"
sudo su root -c "echo 'sudo -u $OE_USER $OE_VENV/bin/python $OE_HOME_EXT/odoo-bin --config=/etc/${OE_CONFIG}.conf' >> $OE_HOME_EXT/start.sh"
sudo chmod 755 $OE_HOME_EXT/start.sh

#--------------------------------------------------
# Install a native systemd service.
#--------------------------------------------------
cat > /etc/systemd/system/${OE_CONFIG}.service <<EOF
[Unit]
Description=Odoo 17
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=$OE_USER
Group=$OE_USER
WorkingDirectory=$OE_HOME_EXT
ExecStart=$OE_VENV/bin/python $OE_HOME_EXT/odoo-bin -c /etc/${OE_CONFIG}.conf
Restart=on-failure
RestartSec=5
TimeoutStopSec=120
KillSignal=SIGINT
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${OE_CONFIG}.service"

#--------------------------------------------------
# Install Nginx if needed
#--------------------------------------------------
if [ "$INSTALL_NGINX" = "True" ]; then
  echo -e "\n---- Installing and setting up Nginx ----"
  sudo apt-get -o DPkg::Lock::Timeout=300 install nginx ufw -y
  python3 "$SCRIPT_DIR/setup_cloudflare.py" --ssh-port "$SSH_PORT" --firewall "$CLOUDFLARE_FIREWALL"
  if [ "$ENABLE_SSL" = "True" ]; then
    if [ ! -f "$CF_ORIGIN_CERT" ] || [ ! -f "$CF_PRIVATE_KEY" ]; then
      echo "Cloudflare Origin Certificate files were not found."
      echo "Expected certificate: $CF_ORIGIN_CERT"
      echo "Expected private key: $CF_PRIVATE_KEY"
      exit 1
    fi
    sudo install -d -m 0700 "$CF_SSL_DIR"
    sudo install -m 0644 "$CF_ORIGIN_CERT" "$CF_SSL_DIR/origin_cert.pem"
    sudo install -m 0600 "$CF_PRIVATE_KEY" "$CF_SSL_DIR/origin_key.pem"
    cat <<EOF > ~/odoo
server {
  listen 80;
  listen [::]:80;
  server_name $WEBSITE_NAME;
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name $WEBSITE_NAME;

  ssl_certificate $CF_SSL_DIR/origin_cert.pem;
  ssl_certificate_key $CF_SSL_DIR/origin_key.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers on;

  # Add Headers for odoo proxy mode
  proxy_http_version 1.1;
  proxy_set_header Host \$host;
  proxy_set_header X-Forwarded-Host \$host;
  proxy_set_header X-Forwarded-For \$remote_addr;
  proxy_set_header X-Forwarded-Proto https;
  proxy_set_header X-Real-IP \$remote_addr;
  add_header X-Frame-Options "SAMEORIGIN";
  add_header X-XSS-Protection "1; mode=block";
  proxy_set_header X-Client-IP \$remote_addr;
  proxy_set_header HTTP_X_FORWARDED_HOST \$remote_addr;
  proxy_redirect off;

  #   odoo    log files
  access_log  /var/log/nginx/$OE_USER-access.log;
  error_log       /var/log/nginx/$OE_USER-error.log;

  #   increase    proxy   buffer  size
  proxy_buffers   16  64k;
  proxy_buffer_size   128k;

  proxy_read_timeout 1200s;
  proxy_connect_timeout 300s;
  proxy_send_timeout 1200s;
  send_timeout 300s;

  #   force   timeouts    if  the backend dies
  proxy_next_upstream error   timeout invalid_header  http_500    http_502
  http_503;

  types {
    text/less less;
    text/scss scss;
  }

  #   enable  data    compression
  gzip    on;
  gzip_min_length 1100;
  gzip_buffers    4   32k;
  gzip_types  text/css text/less text/plain text/xml application/xml application/json application/javascript application/pdf image/jpeg image/png;
  gzip_vary   on;
  client_header_buffer_size 4k;
  large_client_header_buffers 4 64k;
  client_max_body_size 0;

  location / {
    proxy_pass    http://127.0.0.1:$OE_PORT;
    # by default, do not forward anything
    proxy_redirect off;
  }

  location /longpolling {
    proxy_pass http://127.0.0.1:$LONGPOLLING_PORT;
  }

  location /websocket {
    proxy_pass http://127.0.0.1:$LONGPOLLING_PORT;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 1200s;
  }

  location ~* \\.(js|css|png|jpg|jpeg|gif|ico|webp|svg)$ {
    expires 30d;
    add_header Cache-Control "public, immutable";
    proxy_pass http://127.0.0.1:$OE_PORT;
  }

  location ~ /[a-zA-Z0-9_-]*/static/ {
    proxy_cache_valid 200 302 60m;
    proxy_cache_valid 404 1m;
    proxy_buffering on;
    expires 30d;
    proxy_pass http://127.0.0.1:$OE_PORT;
  }
}
EOF
  else
    cat <<EOF > ~/odoo
server {
  listen 80;
  listen [::]:80;

  # set proper server name after domain set
  server_name $WEBSITE_NAME;

  # Add Headers for odoo proxy mode
  proxy_set_header X-Forwarded-Host \$host;
  proxy_set_header X-Forwarded-For \$remote_addr;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_set_header X-Real-IP \$remote_addr;
  add_header X-Frame-Options "SAMEORIGIN";
  add_header X-XSS-Protection "1; mode=block";
  proxy_set_header X-Client-IP \$remote_addr;
  proxy_set_header HTTP_X_FORWARDED_HOST \$remote_addr;

  #   odoo    log files
  access_log  /var/log/nginx/$OE_USER-access.log;
  error_log       /var/log/nginx/$OE_USER-error.log;

  #   increase    proxy   buffer  size
  proxy_buffers   16  64k;
  proxy_buffer_size   128k;

  proxy_read_timeout 900s;
  proxy_connect_timeout 900s;
  proxy_send_timeout 900s;

  #   force   timeouts    if  the backend dies
  proxy_next_upstream error   timeout invalid_header  http_500    http_502
  http_503;

  types {
    text/less less;
    text/scss scss;
  }

  #   enable  data    compression
  gzip    on;
  gzip_min_length 1100;
  gzip_buffers    4   32k;
  gzip_types  text/css text/less text/plain text/xml application/xml application/json application/javascript application/pdf image/jpeg image/png;
  gzip_vary   on;
  client_header_buffer_size 4k;
  large_client_header_buffers 4 64k;
  client_max_body_size 0;

  location / {
    proxy_pass    http://127.0.0.1:$OE_PORT;
    # by default, do not forward anything
    proxy_redirect off;
  }

  location /longpolling {
    proxy_pass http://127.0.0.1:$LONGPOLLING_PORT;
  }

  location ~* .(js|css|png|jpg|jpeg|gif|ico)$ {
    expires 2d;
    proxy_pass http://127.0.0.1:$OE_PORT;
    add_header Cache-Control "public, no-transform";
  }

  # cache some static data in memory for 60mins.
  location ~ /[a-zA-Z0-9_-]*/static/ {
    proxy_cache_valid 200 302 60m;
    proxy_cache_valid 404      1m;
    proxy_buffering    on;
    expires 864000;
    proxy_pass    http://127.0.0.1:$OE_PORT;
  }
}
EOF
  fi

  sudo mv ~/odoo /etc/nginx/sites-available/$WEBSITE_NAME
  sudo ln -sfn /etc/nginx/sites-available/$WEBSITE_NAME /etc/nginx/sites-enabled/$WEBSITE_NAME
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo nginx -t
  sudo service nginx reload
  echo "Done! The Nginx server is up and running. Configuration can be found at /etc/nginx/sites-available/$WEBSITE_NAME"
else
  echo "Nginx isn't installed due to choice of the user!"
fi

#--------------------------------------------------
# Enable ssl with Cloudflare Origin Certificate
#--------------------------------------------------

if [ "$INSTALL_NGINX" = "True" ] && [ "$ENABLE_SSL" = "True" ] && [ "$WEBSITE_NAME" != "_" ]; then
  echo "SSL/HTTPS is enabled with the Cloudflare Origin Certificate!"
else
  echo "SSL/HTTPS isn't enabled due to choice of the user or because of a misconfiguration!"
  if [ "$WEBSITE_NAME" = "_" ]; then
    echo "Website name is set as _. Cannot obtain SSL Certificate for _. You should use real website address."
  fi
fi

echo -e "* Starting Odoo Service"
sudo systemctl start "${OE_CONFIG}.service"
for attempt in {1..30}; do
  if curl -fsS "http://127.0.0.1:${OE_PORT}/web/health?db_server_status=1" >/dev/null; then
    break
  fi
  sleep 2
done
curl -fsS "http://127.0.0.1:${OE_PORT}/web/health?db_server_status=1"
systemctl is-active "${OE_CONFIG}.service"
echo "-----------------------------------------------------------"
echo "Done! The Odoo server is up and running. Specifications:"
echo "Port: $OE_PORT"
echo "User service: $OE_USER"
echo "Configuraton file location: /etc/${OE_CONFIG}.conf"
echo "Logfile location: /var/log/$OE_USER"
echo "User PostgreSQL: $OE_USER"
echo "Code location: $OE_HOME_EXT"
echo "Custom addons: $OE_HOME/custom/addons"
echo "No application database or login has been created. Database manager is disabled."
echo "Password superadmin (database): $OE_SUPERADMIN"
echo "Start Odoo service: sudo service $OE_CONFIG start"
echo "Stop Odoo service: sudo service $OE_CONFIG stop"
echo "Restart Odoo service: sudo service $OE_CONFIG restart"
if [ "$INSTALL_NGINX" = "True" ]; then
  echo "Nginx configuration file: /etc/nginx/sites-available/$WEBSITE_NAME"
fi
echo "-----------------------------------------------------------"
