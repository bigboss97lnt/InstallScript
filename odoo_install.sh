#!/usr/bin/env bash
set -Eeuo pipefail

################################################################################
# Install Odoo 18 Enterprise on Ubuntu 22.04/24.04 with PostgreSQL 16,
# wkhtmltopdf 0.12.6.1 (patched Qt), Nginx, and Cloudflare Origin SSL.
# Based on Yenthe Van Ginneken's InstallScript and bigboss97lnt's Odoo 16 fixes.
################################################################################

# Odoo
OE_USER="odoo"
OE_HOME="/${OE_USER}"
OE_HOME_EXT="${OE_HOME}/${OE_USER}-server"
OE_VERSION="18.0"
OE_PORT="8069"
GEVENT_PORT="8072"
OE_CONFIG="${OE_USER}-server"
OE_SUPERADMIN="admin"
GENERATE_RANDOM_PASSWORD="True"
WORKERS="2"

# Components requested for this installation
IS_ENTERPRISE="True"
INSTALL_POSTGRESQL_SIXTEEN="True"
INSTALL_WKHTMLTOPDF="True"
INSTALL_NGINX="True"
ENABLE_SSL="True"

# Enterprise access requires an authorized GitHub account and SSH key.
# Private Git operations run as the user who invoked sudo, not as root.
ENTERPRISE_REPO="git@github.com:odoo/enterprise.git"

# Nginx / Cloudflare. Change WEBSITE_NAME before running the script.
WEBSITE_NAME="odoo.example.com"
CF_CERT_SOURCE="/root/certificate"
CF_KEY_SOURCE="/root/private_key"
REMOVE_CF_SOURCE_FILES="True"
NGINX_SSL_DIR="/etc/nginx/ssl/${WEBSITE_NAME}"
CF_CERT_PATH="${NGINX_SSL_DIR}/origin.crt"
CF_KEY_PATH="${NGINX_SSL_DIR}/origin.key"

# wkhtmltopdf 0.12.6.1-3 is the patched-Qt release linked by Odoo 18 docs.
WKHTMLTOPDF_VERSION="0.12.6.1-3"
WKHTMLTOPDF_BASE_URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}"

TEMP_FILES=()
cleanup() {
    local file
    for file in "${TEMP_FILES[@]:-}"; do
        [ -n "$file" ] && rm -f "$file"
    done
}
trap cleanup EXIT

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

is_true() {
    [ "${1:-False}" = "True" ]
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

echo_section() {
    printf '\n---- %s ----\n' "$1"
}

INVOKING_USER="${SUDO_USER:-$(id -un)}"
run_as_invoking_user() {
    if [ "$(id -u)" -eq 0 ] && [ "$INVOKING_USER" != "root" ]; then
        sudo -u "$INVOKING_USER" -H "$@"
    else
        "$@"
    fi
}

#-------------------------------------------------------------------------------
# Preflight
#-------------------------------------------------------------------------------
require_command sudo
require_command dpkg

sudo -v

# shellcheck disable=SC1091
source /etc/os-release
UBUNTU_RELEASE="${VERSION_ID:-}"
UBUNTU_CODENAME="${VERSION_CODENAME:-}"
ARCH="$(dpkg --print-architecture)"

[ "${ID:-}" = "ubuntu" ] || fail "This installer supports Ubuntu only."
case "$UBUNTU_RELEASE" in
    22.04|24.04) ;;
    *) fail "This installer supports Ubuntu 22.04 or 24.04; found ${UBUNTU_RELEASE}." ;;
esac
case "$ARCH" in
    amd64|arm64) ;;
    *) fail "wkhtmltopdf ${WKHTMLTOPDF_VERSION} is configured for amd64/arm64; found ${ARCH}." ;;
esac

if is_true "$INSTALL_NGINX"; then
    [ "$WEBSITE_NAME" != "odoo.example.com" ] && [ "$WEBSITE_NAME" != "_" ] \
        || fail "Set WEBSITE_NAME to the Cloudflare-proxied hostname before running."
fi
if is_true "$INSTALL_NGINX" && is_true "$ENABLE_SSL"; then
    [ -s "$CF_CERT_SOURCE" ] || fail "Cloudflare Origin Certificate not found: ${CF_CERT_SOURCE}"
    [ -s "$CF_KEY_SOURCE" ] || fail "Cloudflare Origin private key not found: ${CF_KEY_SOURCE}"
fi
if sudo test -e "$OE_HOME_EXT" && ! sudo test -d "${OE_HOME_EXT}/.git"; then
    fail "Odoo target exists but is not a Git checkout: ${OE_HOME_EXT}"
fi

#-------------------------------------------------------------------------------
# Base packages and PostgreSQL
#-------------------------------------------------------------------------------
echo_section "Updating server and installing base dependencies"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl git gnupg lsb-release software-properties-common

if is_true "$IS_ENTERPRISE"; then
    echo_section "Verifying Odoo Enterprise GitHub access as ${INVOKING_USER}"
    if ! run_as_invoking_user env GIT_TERMINAL_PROMPT=0 \
        git ls-remote --exit-code "$ENTERPRISE_REPO" "refs/heads/${OE_VERSION}" >/dev/null; then
        fail "Cannot access Odoo Enterprise as ${INVOKING_USER}. Configure that user's SSH key for a GitHub account with odoo/enterprise access, then rerun. No Odoo packages or source were changed after this check."
    fi
fi

sudo add-apt-repository -y universe
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential ca-certificates curl git gnupg libffi-dev libjpeg-dev \
    libldap2-dev libpq-dev libsasl2-dev libssl-dev libxslt1-dev libzip-dev \
    lsb-release nodejs npm openssl python3 python3-cffi python3-dev python3-pip \
    python3-venv python3-wheel wget xfonts-75dpi xfonts-base zlib1g-dev

echo_section "Installing PostgreSQL"
if is_true "$INSTALL_POSTGRESQL_SIXTEEN"; then
    sudo install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | sudo gpg --dearmor --yes -o /etc/apt/keyrings/postgresql.gpg
    echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt ${UBUNTU_CODENAME}-pgdg main" \
        | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-16 postgresql-client-16
    if is_true "$IS_ENTERPRISE"; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-16-pgvector
        sudo systemctl start postgresql
        POSTGRES_READY="False"
        for _attempt in {1..30}; do
            if sudo -u postgres pg_isready >/dev/null 2>&1; then
                POSTGRES_READY="True"
                break
            fi
            sleep 1
        done
        is_true "$POSTGRES_READY" || fail "PostgreSQL did not become ready within 30 seconds."
        sudo -u postgres psql -v ON_ERROR_STOP=1 -d template1 \
            -c 'CREATE EXTENSION IF NOT EXISTS vector;'
    fi
else
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-client
fi

echo_section "Creating the Odoo PostgreSQL role"
# Odoo needs CREATEDB, but never PostgreSQL SUPERUSER privileges.
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${OE_USER}'" | grep -q 1; then
    sudo -u postgres createuser -d -R -S "$OE_USER"
fi

#-------------------------------------------------------------------------------
# wkhtmltopdf and Node tooling
#-------------------------------------------------------------------------------
echo_section "Installing Node tooling"
sudo npm install -g rtlcss

if is_true "$INSTALL_WKHTMLTOPDF"; then
    echo_section "Installing wkhtmltopdf 0.12.6.1 (patched Qt)"
    WKHTMLTOPDF_PACKAGE="wkhtmltox_${WKHTMLTOPDF_VERSION}.jammy_${ARCH}.deb"
    WKHTMLTOPDF_TEMP="$(mktemp --suffix=.deb)"
    TEMP_FILES+=("$WKHTMLTOPDF_TEMP")
    curl -fL --retry 3 --output "$WKHTMLTOPDF_TEMP" \
        "${WKHTMLTOPDF_BASE_URL}/${WKHTMLTOPDF_PACKAGE}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$WKHTMLTOPDF_TEMP"
    wkhtmltopdf --version | grep -Fq "wkhtmltopdf 0.12.6.1 (with patched qt)" \
        || fail "The expected patched-Qt wkhtmltopdf build was not installed."
fi

#-------------------------------------------------------------------------------
# Odoo Community and Enterprise source
#-------------------------------------------------------------------------------
echo_section "Creating the Odoo service account"
if ! id "$OE_USER" >/dev/null 2>&1; then
    sudo adduser --system --quiet --shell=/bin/bash --home="$OE_HOME" \
        --gecos "Odoo" --group "$OE_USER"
fi
sudo install -d -o "$OE_USER" -g "$OE_USER" -m 0750 "/var/log/${OE_USER}"

echo_section "Cloning Odoo ${OE_VERSION} Community"
if sudo test -d "${OE_HOME_EXT}/.git"; then
    INSTALLED_BRANCH="$(sudo git -C "$OE_HOME_EXT" branch --show-current)"
    [ "$INSTALLED_BRANCH" = "$OE_VERSION" ] \
        || fail "Existing Community checkout is branch ${INSTALLED_BRANCH}, expected ${OE_VERSION}."
    echo "Reusing the existing Odoo Community ${OE_VERSION} checkout."
else
    sudo git clone --depth 1 --branch "$OE_VERSION" https://github.com/odoo/odoo.git "$OE_HOME_EXT"
fi

if is_true "$IS_ENTERPRISE"; then
    echo_section "Cloning Odoo ${OE_VERSION} Enterprise"
    sudo install -d -o "$OE_USER" -g "$OE_USER" "${OE_HOME}/enterprise"
    if sudo test -d "${OE_HOME}/enterprise/addons/.git"; then
        INSTALLED_ENTERPRISE_BRANCH="$(sudo git -C "${OE_HOME}/enterprise/addons" branch --show-current)"
        [ "$INSTALLED_ENTERPRISE_BRANCH" = "$OE_VERSION" ] \
            || fail "Existing Enterprise checkout is branch ${INSTALLED_ENTERPRISE_BRANCH}, expected ${OE_VERSION}."
        echo "Reusing the existing Odoo Enterprise ${OE_VERSION} checkout."
    elif sudo test -e "${OE_HOME}/enterprise/addons"; then
        fail "Enterprise target exists but is not a Git checkout: ${OE_HOME}/enterprise/addons"
    else
        ENTERPRISE_TEMP="$(run_as_invoking_user mktemp -d /tmp/odoo-enterprise.XXXXXX)"
        if ! run_as_invoking_user env GIT_TERMINAL_PROMPT=0 \
            git clone --depth 1 --branch "$OE_VERSION" "$ENTERPRISE_REPO" \
            "${ENTERPRISE_TEMP}/addons"; then
            run_as_invoking_user rmdir "$ENTERPRISE_TEMP" 2>/dev/null || true
            fail "Enterprise clone failed after its access check. Verify the GitHub connection and rerun."
        fi
        sudo mv "${ENTERPRISE_TEMP}/addons" "${OE_HOME}/enterprise/addons"
        run_as_invoking_user rmdir "$ENTERPRISE_TEMP"
    fi
fi

sudo install -d -o "$OE_USER" -g "$OE_USER" "${OE_HOME}/custom/addons"

echo_section "Installing Odoo Python requirements in an isolated environment"
sudo python3 -m venv "${OE_HOME}/venv"
PYTHON_MINOR="$("${OE_HOME}/venv/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
if [ "$PYTHON_MINOR" = "3.10" ]; then
    # Odoo 18 pins gevent 21.8.0 on Jammy; its build must not pull Cython 3.
    sudo "${OE_HOME}/venv/bin/pip" install --upgrade "pip<24.1" "setuptools<66" wheel "Cython<3"
    sudo "${OE_HOME}/venv/bin/pip" install "gevent==21.8.0" --no-build-isolation
    REQUIREMENTS_WITHOUT_GEVENT="$(mktemp)"
    TEMP_FILES+=("$REQUIREMENTS_WITHOUT_GEVENT")
    grep -vE '^[[:space:]]*gevent([=<>!~]|[[:space:]])' \
        "${OE_HOME_EXT}/requirements.txt" > "$REQUIREMENTS_WITHOUT_GEVENT"
    sudo "${OE_HOME}/venv/bin/pip" install -r "$REQUIREMENTS_WITHOUT_GEVENT"
else
    sudo "${OE_HOME}/venv/bin/pip" install --upgrade pip setuptools wheel
    sudo "${OE_HOME}/venv/bin/pip" install -r "${OE_HOME_EXT}/requirements.txt"
fi

if is_true "$IS_ENTERPRISE"; then
    sudo "${OE_HOME}/venv/bin/pip" install \
        dbfread ebaysdk firebase-admin pdfminer.six
    sudo npm install -g less less-plugin-clean-css
fi
sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME"

#-------------------------------------------------------------------------------
# Odoo configuration and systemd service
#-------------------------------------------------------------------------------
echo_section "Writing Odoo configuration"
if is_true "$GENERATE_RANDOM_PASSWORD"; then
    OE_SUPERADMIN="$(openssl rand -hex 16)"
fi

ADDONS_PATH="${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons"
if is_true "$IS_ENTERPRISE"; then
    ADDONS_PATH="${OE_HOME}/enterprise/addons,${ADDONS_PATH}"
fi

ODOO_CONFIG_TEMP="$(mktemp)"
TEMP_FILES+=("$ODOO_CONFIG_TEMP")
{
    echo "[options]"
    echo "admin_passwd = ${OE_SUPERADMIN}"
    echo "http_interface = 127.0.0.1"
    echo "http_port = ${OE_PORT}"
    echo "gevent_port = ${GEVENT_PORT}"
    echo "workers = ${WORKERS}"
    echo "max_cron_threads = 1"
    if is_true "$INSTALL_NGINX"; then
        echo "proxy_mode = True"
    else
        echo "proxy_mode = False"
    fi
    echo "logfile = /var/log/${OE_USER}/${OE_CONFIG}.log"
    echo "addons_path = ${ADDONS_PATH}"
    echo "; Set list_db = False after restoring/creating the production database."
    echo "; dbfilter = ^your_database_name$"
} > "$ODOO_CONFIG_TEMP"
sudo install -o "$OE_USER" -g "$OE_USER" -m 0640 "$ODOO_CONFIG_TEMP" "/etc/${OE_CONFIG}.conf"

SYSTEMD_TEMP="$(mktemp)"
TEMP_FILES+=("$SYSTEMD_TEMP")
{
    echo "[Unit]"
    echo "Description=Odoo ${OE_VERSION}"
    echo "After=network.target postgresql.service"
    echo "Requires=postgresql.service"
    echo
    echo "[Service]"
    echo "Type=simple"
    echo "User=${OE_USER}"
    echo "Group=${OE_USER}"
    echo "ExecStart=${OE_HOME}/venv/bin/python ${OE_HOME_EXT}/odoo-bin --config=/etc/${OE_CONFIG}.conf"
    echo "Restart=on-failure"
    echo "RestartSec=5s"
    echo "PrivateTmp=true"
    echo
    echo "[Install]"
    echo "WantedBy=multi-user.target"
} > "$SYSTEMD_TEMP"
sudo install -o root -g root -m 0644 "$SYSTEMD_TEMP" "/etc/systemd/system/${OE_CONFIG}.service"
sudo systemctl daemon-reload
sudo systemctl enable "$OE_CONFIG"

#-------------------------------------------------------------------------------
# Nginx and Cloudflare Origin SSL
#-------------------------------------------------------------------------------
if is_true "$INSTALL_NGINX"; then
    echo_section "Installing and configuring Nginx"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nginx

    CF_REALIP_TEMP="$(mktemp)"
    TEMP_FILES+=("$CF_REALIP_TEMP")
    {
        echo "# Generated from Cloudflare's published network lists"
        curl -fsSL https://www.cloudflare.com/ips-v4 | sed 's/^/set_real_ip_from /; s/$/;/'
        echo
        curl -fsSL https://www.cloudflare.com/ips-v6 | sed 's/^/set_real_ip_from /; s/$/;/'
        echo
        echo "real_ip_header CF-Connecting-IP;"
        echo "real_ip_recursive on;"
    } > "$CF_REALIP_TEMP"
    grep -q '^set_real_ip_from ' "$CF_REALIP_TEMP" \
        || fail "Cloudflare IP ranges could not be downloaded."
    sudo install -o root -g root -m 0644 "$CF_REALIP_TEMP" /etc/nginx/conf.d/cloudflare-realip.conf

    if is_true "$ENABLE_SSL"; then
        sudo install -d -o root -g root -m 0755 "$NGINX_SSL_DIR"
        sudo install -o root -g root -m 0644 "$CF_CERT_SOURCE" "$CF_CERT_PATH"
        sudo install -o root -g root -m 0600 "$CF_KEY_SOURCE" "$CF_KEY_PATH"
        if is_true "$REMOVE_CF_SOURCE_FILES"; then
            sudo rm -f "$CF_CERT_SOURCE" "$CF_KEY_SOURCE"
        fi
    fi

    NGINX_TEMP="$(mktemp)"
    TEMP_FILES+=("$NGINX_TEMP")
    if is_true "$ENABLE_SSL"; then
        cat > "$NGINX_TEMP" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

upstream odoo_backend {
    server 127.0.0.1:${OE_PORT};
}

upstream odoo_gevent {
    server 127.0.0.1:${GEVENT_PORT};
}

server {
    listen 80;
    listen [::]:80;
    server_name ${WEBSITE_NAME};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${WEBSITE_NAME};

    ssl_certificate ${CF_CERT_PATH};
    ssl_certificate_key ${CF_KEY_PATH};
    ssl_protocols TLSv1.2 TLSv1.3;

    access_log /var/log/nginx/${OE_USER}-access.log;
    error_log /var/log/nginx/${OE_USER}-error.log;
    client_max_body_size 0;
    proxy_read_timeout 900s;
    proxy_connect_timeout 900s;
    proxy_send_timeout 900s;

    location /websocket {
        proxy_pass http://odoo_gevent;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location / {
        proxy_pass http://odoo_backend;
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location ~* /web/static/ {
        proxy_pass http://odoo_backend;
        proxy_cache_valid 200 60m;
        proxy_buffering on;
        expires 864000;
    }
}
EOF
    else
        cat > "$NGINX_TEMP" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}
upstream odoo_backend { server 127.0.0.1:${OE_PORT}; }
upstream odoo_gevent { server 127.0.0.1:${GEVENT_PORT}; }
server {
    listen 80;
    listen [::]:80;
    server_name ${WEBSITE_NAME};
    client_max_body_size 0;
    proxy_read_timeout 900s;
    location /websocket {
        proxy_pass http://odoo_gevent;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    location / {
        proxy_pass http://odoo_backend;
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF
    fi

    sudo install -o root -g root -m 0644 "$NGINX_TEMP" "/etc/nginx/sites-available/${WEBSITE_NAME}"
    sudo ln -sfn "/etc/nginx/sites-available/${WEBSITE_NAME}" "/etc/nginx/sites-enabled/${WEBSITE_NAME}"
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo nginx -t
    sudo systemctl enable nginx
    sudo systemctl reload nginx
fi

echo_section "Starting Odoo"
sudo systemctl start "$OE_CONFIG"
sleep 2
if ! sudo systemctl is-active --quiet "$OE_CONFIG"; then
    sudo systemctl --no-pager --full status "$OE_CONFIG" || true
    fail "Odoo failed to remain active after startup. Check the status and log above."
fi

cat <<EOF

-----------------------------------------------------------
Odoo ${OE_VERSION} installation completed.
Service:             ${OE_CONFIG}
Configuration:       /etc/${OE_CONFIG}.conf
Log:                 /var/log/${OE_USER}/${OE_CONFIG}.log
Community source:    ${OE_HOME_EXT}
Enterprise addons:  ${OE_HOME}/enterprise/addons
Custom addons:       ${OE_HOME}/custom/addons
PostgreSQL role:     ${OE_USER}
Database master password: ${OE_SUPERADMIN}

After restoring your production database, set list_db = False and a strict
dbfilter in /etc/${OE_CONFIG}.conf, then restart ${OE_CONFIG}.
For Cloudflare, enable the proxy and use SSL/TLS mode Full (strict).
-----------------------------------------------------------
EOF
