#!/usr/bin/env bash
# Turns a fresh Ubuntu 24.04 instance into a Django server: PostgreSQL, app user, virtualenv,
# gunicorn under systemd, nginx, HTTPS and nightly backups.
#
# Runs on the instance, with deploy.conf beside it:
#   scp deployment_bootstrap.sh deploy.conf <project>:~
#   ssh <project> "sudo bash deployment_bootstrap.sh"
# Safe to run again: re-run it after DNS moves to finish HTTPS, or after any change to deploy.conf.
set -euo pipefail

CONFIG="${CONFIG:-$(cd "$(dirname "$0")" && pwd)/deploy.conf}"
[ -f "$CONFIG" ] || { echo "Missing $CONFIG — copy it here alongside this script."; exit 1; }
# shellcheck source=/dev/null
. "$CONFIG"

APP_USER="$PROJECT"
APP_HOME="/srv/$PROJECT"
APP_DIR="$APP_HOME/app"
VENV="$APP_HOME/.venv"
ENV_FILE="/etc/$PROJECT/env"

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }
say() { printf "\n==> %s\n" "$*"; }
# -H sets HOME to the app user's, so git and ssh find the deploy key.
as_app() { sudo -H -u "$APP_USER" "$@"; }
manage() { sudo -H -u "$APP_USER" bash -c "set -a; . '$ENV_FILE'; set +a; cd '$APP_DIR'; '$VENV/bin/python' manage.py $*"; }

say "Packages"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get update -qq
apt-get install -y -qq python3-venv nginx git certbot python3-certbot-nginx postgresql >/dev/null

say "Swap file (small instances need the headroom)"
if [ -f /swapfile ]; then
    echo "already present"
else
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap -q /swapfile && swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

say "App user and folders"
id -u "$APP_USER" >/dev/null 2>&1 || adduser --system --group --home "$APP_HOME" --quiet "$APP_USER"
mkdir -p "$APP_DIR" "$APP_HOME/backups" "/etc/$PROJECT"
chown -R "$APP_USER:$APP_USER" "$APP_HOME"
chmod 755 "$APP_HOME"     # nginx reads staticfiles/ through this path
install -m 640 -o root -g "$APP_USER" "$CONFIG" "/etc/$PROJECT/deploy.conf"

say "PostgreSQL"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$APP_USER'" | grep -q 1 \
    || sudo -u postgres createuser "$APP_USER"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$PROJECT'" | grep -q 1 \
    || sudo -u postgres createdb --owner "$APP_USER" "$PROJECT"
for conf_dir in /etc/postgresql/*/main/conf.d; do
    cat > "$conf_dir/$PROJECT.conf" <<CONF
# Sized for this instance by deployment_bootstrap.sh
shared_buffers = $PG_SHARED_BUFFERS
effective_cache_size = $PG_EFFECTIVE_CACHE
CONF
done
systemctl reload postgresql
echo "database '$PROJECT' owned by '$APP_USER' (peer authentication, no password)"

say "Deploy key and code"
SSH_DIR="$APP_HOME/.ssh"
mkdir -p "$SSH_DIR" && chown "$APP_USER:$APP_USER" "$SSH_DIR" && chmod 700 "$SSH_DIR"
[ -f "$SSH_DIR/id_ed25519" ] || as_app ssh-keygen -q -t ed25519 -N "" -f "$SSH_DIR/id_ed25519" -C "$APP_USER@$DOMAIN"
if [ ! -f "$SSH_DIR/known_hosts" ]; then
    ssh-keyscan -t ed25519 github.com > "$SSH_DIR/known_hosts" 2>/dev/null
    chown "$APP_USER:$APP_USER" "$SSH_DIR/known_hosts"
fi
if [ ! -d "$APP_DIR/.git" ]; then
    if ! as_app git clone --quiet "$REPO" "$APP_DIR"; then
        cat <<KEY

Clone failed: GitHub does not know this server yet. Add the key below as a
read-only deploy key (repo → Settings → Deploy keys), then run this script again:

$(cat "$SSH_DIR/id_ed25519.pub")
KEY
        exit 1
    fi
fi
as_app git -C "$APP_DIR" pull --quiet --ff-only || true

say "Virtualenv"
[ -x "$VENV/bin/python" ] || as_app python3 -m venv "$VENV"
as_app "$VENV/bin/pip" install --quiet --upgrade pip
as_app "$VENV/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"

say "Environment file ($ENV_FILE)"
if [ -f "$ENV_FILE" ]; then
    echo "already written (edit by hand, or pipe KEY=VALUE lines to $PROJECT-set-env)"
else
    secret=$(python3 -c 'import secrets; print(secrets.token_urlsafe(50))')
    if [ -f "$APP_DIR/.sample-env" ]; then
        install -m 640 -o root -g "$APP_USER" "$APP_DIR/.sample-env" "$ENV_FILE"
        sed -i "s|^DJANGO_SECRET_KEY=.*|DJANGO_SECRET_KEY=$secret|" "$ENV_FILE"
        sed -i "s|^DJANGO_ALLOWED_HOSTS=.*|DJANGO_ALLOWED_HOSTS=$DOMAIN,www.$DOMAIN|" "$ENV_FILE"
        sed -i "s|^POSTGRES_DB=.*|POSTGRES_DB=$PROJECT|" "$ENV_FILE"
    else
        cat > "$ENV_FILE" <<ENV
DJANGO_DEBUG=false
DJANGO_SECRET_KEY=$secret
DJANGO_ALLOWED_HOSTS=$DOMAIN,www.$DOMAIN
POSTGRES_DB=$PROJECT
POSTGRES_USER=
POSTGRES_PASSWORD=
POSTGRES_HOST=
POSTGRES_PORT=
ENV
        chown root:"$APP_USER" "$ENV_FILE" && chmod 640 "$ENV_FILE"
    fi
    echo "created with a fresh secret key"
fi

# Lets setup_ses.sh (and you) add settings later without secrets passing through a terminal.
cat > /usr/local/sbin/$PROJECT-set-env <<SETENV
#!/usr/bin/env bash
# Merges KEY=VALUE lines read on stdin into $ENV_FILE, replacing any keys already there.
set -euo pipefail
incoming=\$(mktemp) && merged=\$(mktemp)
cat > "\$incoming"
keys=\$(grep -oE '^[A-Z_]+=' "\$incoming" | tr -d '=' | paste -sd '|' -)
grep -vE "^(\$keys)=" "$ENV_FILE" > "\$merged"
cat "\$incoming" >> "\$merged"
install -m 640 -o root -g "$APP_USER" "\$merged" "$ENV_FILE"
rm -f "\$incoming" "\$merged"
SETENV
chmod 750 /usr/local/sbin/$PROJECT-set-env

# One command for every future deploy: ssh <project> "sudo <project>-deploy"
cat > /usr/local/sbin/$PROJECT-deploy <<DEPLOY
#!/usr/bin/env bash
# Pull, install, migrate, collect static files, check, reload.
set -euo pipefail
[ "\$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }
run() { sudo -H -u $APP_USER bash -c "set -a; . '$ENV_FILE'; set +a; cd '$APP_DIR'; \$*"; }
echo "==> Current: \$(sudo -H -u $APP_USER git -C $APP_DIR rev-parse --short HEAD)"
sudo -H -u $APP_USER git -C $APP_DIR pull --ff-only
sudo -H -u $APP_USER $VENV/bin/pip install --quiet -r $APP_DIR/requirements.txt
run "$VENV/bin/python manage.py migrate --noinput"
run "$VENV/bin/python manage.py collectstatic --noinput" >/dev/null
run "$VENV/bin/python manage.py check --deploy"
systemctl reload gunicorn
echo "==> Deployed:  \$(sudo -H -u $APP_USER git -C $APP_DIR rev-parse --short HEAD)"
DEPLOY
chmod 750 /usr/local/sbin/$PROJECT-deploy

say "gunicorn service"
cat > /etc/systemd/system/gunicorn.socket <<UNIT
[Unit]
Description=$PROJECT gunicorn socket

[Socket]
ListenStream=/run/gunicorn.sock
SocketUser=www-data
SocketMode=600

[Install]
WantedBy=sockets.target
UNIT
cat > /etc/systemd/system/gunicorn.service <<UNIT
[Unit]
Description=$PROJECT (gunicorn)
Requires=gunicorn.socket
After=network.target postgresql.service

[Service]
Type=notify
NotifyAccess=main
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$VENV/bin/gunicorn $WSGI_MODULE --workers $WORKERS --timeout 30 --access-logfile - --error-logfile -
ExecReload=/bin/kill -s HUP \$MAINPID
KillMode=mixed
TimeoutStopSec=5
PrivateTmp=true
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
# Enabling the service as well as the socket means it is already running after a reboot,
# so the first visitor doesn't wait for it to start.
systemctl enable --quiet --now gunicorn.socket gunicorn.service

say "nginx site"
if [ -f /etc/nginx/sites-available/$PROJECT ]; then
    echo "already configured (leaving certbot's changes alone)"
else
    cat > /etc/nginx/sites-available/$PROJECT <<NGINX
upstream $PROJECT {
    server unix:/run/gunicorn.sock fail_timeout=0;
}

server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    client_max_body_size 1m;

    # collectstatic writes hashed file names, so these are safe to cache for a year.
    location /static/ {
        alias $APP_DIR/staticfiles/;
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    location / {
        proxy_pass http://$PROJECT;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
    }
}
NGINX
    ln -sf /etc/nginx/sites-available/$PROJECT /etc/nginx/sites-enabled/$PROJECT
    rm -f /etc/nginx/sites-enabled/default
fi
nginx -t >/dev/null && systemctl reload nginx

say "Django (migrate, static files, deployment checks)"
manage migrate --noinput
manage collectstatic --noinput >/dev/null
manage check --deploy

say "Nightly database backup"
cat > /etc/cron.d/$PROJECT-backup <<CRON
30 2 * * * $APP_USER pg_dump --format=custom $PROJECT > $APP_HOME/backups/$PROJECT-\$(date +\%F).dump && find $APP_HOME/backups -name '*.dump' -mtime +14 -delete
CRON

say "HTTPS certificate"
token=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)
public_ip=$(curl -fsS -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/public-ipv4 || true)
domain_ip=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}' || true)
if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    echo "certificate already installed; certbot renews it automatically"
elif [ -n "$public_ip" ] && [ "$domain_ip" = "$public_ip" ]; then
    certbot --nginx --redirect --non-interactive --agree-tos -m "$CERT_EMAIL" -d "$DOMAIN" -d "www.$DOMAIN"
else
    echo "SKIPPED: $DOMAIN resolves to '${domain_ip:-nothing}', not to this server ($public_ip)."
    echo "Finish the nameserver change, wait for it to take effect, then run this script again."
fi

systemctl restart gunicorn
say "Server ready"
cat <<NEXT

  Site      : https://$DOMAIN (http until the certificate is installed)
  Logs      : journalctl -u gunicorn -f
  Deploy    : ssh $PROJECT "sudo $PROJECT-deploy"
  Admin user: sudo -H -u $APP_USER bash -c 'set -a; . $ENV_FILE; set +a; cd $APP_DIR; $VENV/bin/python manage.py createsuperuser'

NEXT
