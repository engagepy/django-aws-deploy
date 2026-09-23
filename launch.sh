#!/usr/bin/env bash
# One command to take a Django project live on AWS: infrastructure, server, HTTPS and email.
#
#   cp deploy.conf.example deploy.conf   # edit it
#   ./launch.sh
#
# Safe to run again at any point: each phase checks what already exists. If DNS isn't ready yet it
# stops cleanly and tells you to re-run later.
#
# Options:
#   --check-only        run the preflight checks and stop
#   --skip-ses          don't touch email this run
#   --wait-dns <min>    how long to wait for the nameserver change (default 20)
#   --yes               never prompt (for agents and CI)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${CONFIG:-$HERE/deploy.conf}"
CHECK_ONLY=false
SKIP_SES=false
WAIT_DNS=20
ASSUME_YES=false

while [ $# -gt 0 ]; do
    case "$1" in
        --check-only) CHECK_ONLY=true ;;
        --skip-ses)   SKIP_SES=true ;;
        --wait-dns)   WAIT_DNS="${2:?minutes}"; shift ;;
        --yes|-y)     ASSUME_YES=true ;;
        -h|--help)    sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
    esac
    shift
done

say()  { printf "\n\033[1m==> %s\033[0m\n" "$*"; }
ok()   { printf "    ok   %s\n" "$*"; }
warn() { printf "    warn %s\n" "$*"; }
fail() { printf "    FAIL %s\n" "$*"; FAILED=$((FAILED + 1)); }

# ---------------------------------------------------------------------------- preflight

FAILED=0
say "Preflight"

[ -f "$CONFIG" ] || { echo "Missing $CONFIG — copy deploy.conf.example and edit it."; exit 1; }
# shellcheck source=/dev/null
. "$CONFIG"

for required in PROJECT DOMAIN REPO WSGI_MODULE AWS_PROFILE REGION INSTANCE_TYPE CERT_EMAIL PUBLIC_KEY; do
    [ -n "${!required:-}" ] || fail "$required is not set in deploy.conf"
done
[ "$FAILED" -eq 0 ] || { echo; echo "Fix deploy.conf and run again."; exit 1; }
ok "deploy.conf: $PROJECT → $DOMAIN ($REGION, $INSTANCE_TYPE)"

if command -v aws >/dev/null; then
    aws_version=$(aws --version 2>&1 | sed -E 's|aws-cli/([0-9]+\.[0-9]+).*|\1|')
    case "$aws_version" in 2.*) ok "aws cli $aws_version" ;; *) fail "aws cli 2.x required (found $aws_version)" ;; esac
else
    fail "aws cli not installed (brew install awscli)"
fi

if caller=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Arn --output text 2>/dev/null); then
    case "$caller" in
        *":root") fail "profile '$AWS_PROFILE' is the ROOT user — use the scoped user from bootstrap_iam.sh" ;;
        *) ok "aws profile '$AWS_PROFILE' → $caller" ;;
    esac
else
    fail "aws profile '$AWS_PROFILE' has no working credentials (run bootstrap_iam.sh, or aws configure --profile $AWS_PROFILE)"
fi

[ -f "$PUBLIC_KEY" ] && ok "ssh public key $PUBLIC_KEY" || fail "no public key at $PUBLIC_KEY"

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    ok "gh authenticated (deploy key will be added automatically)"
    GH_READY=true
else
    warn "gh missing or not signed in — you'll add the GitHub deploy key by hand"
    GH_READY=false
fi

# Optional: check the Django project itself, when its checkout is on this machine.
if [ -n "${APP_REPO_PATH:-}" ] && [ -d "$APP_REPO_PATH" ]; then
    [ -f "$APP_REPO_PATH/manage.py" ] && ok "django project at $APP_REPO_PATH" || fail "no manage.py in $APP_REPO_PATH"
    [ -f "$APP_REPO_PATH/.sample-env" ] && ok ".sample-env present" || warn "no .sample-env (bootstrap will generate a basic env file)"
    if [ -f "$APP_REPO_PATH/requirements.txt" ]; then
        grep -qi "^gunicorn" "$APP_REPO_PATH/requirements.txt" && ok "gunicorn in requirements" || fail "add gunicorn to requirements.txt"
        grep -qi "^psycopg" "$APP_REPO_PATH/requirements.txt" && ok "psycopg in requirements" || fail "add psycopg[binary] to requirements.txt"
    else
        fail "no requirements.txt in $APP_REPO_PATH"
    fi
    wsgi_path="$APP_REPO_PATH/$(echo "$WSGI_MODULE" | tr '.' '/').py"
    [ -f "$wsgi_path" ] && ok "WSGI_MODULE points at ${wsgi_path#"$APP_REPO_PATH"/}" || fail "WSGI_MODULE=$WSGI_MODULE — expected $wsgi_path"
    settings=$(find "$APP_REPO_PATH" -maxdepth 2 -name settings.py | head -1)
    if [ -n "$settings" ]; then
        grep -q "DJANGO_SECRET_KEY" "$settings" && ok "settings read DJANGO_SECRET_KEY" \
            || fail "settings.py doesn't read DJANGO_SECRET_KEY — copy templates/settings-snippet.py"
        grep -q "POSTGRES_DB" "$settings" && ok "settings read POSTGRES_DB" \
            || fail "settings.py doesn't read POSTGRES_DB — copy templates/settings-snippet.py"
    fi
else
    warn "APP_REPO_PATH not set — skipping the Django project checks"
fi

if [ "$FAILED" -gt 0 ]; then
    echo; echo "$FAILED check(s) failed. Nothing has been created."; exit 1
fi
$CHECK_ONLY && { echo; echo "Preflight passed."; exit 0; }

if ! $ASSUME_YES; then
    printf "\nCreate/refresh AWS resources for %s in %s? [y/N] " "$PROJECT" "$REGION"
    read -r answer
    case "$answer" in [yY]*) ;; *) echo "Nothing done."; exit 0 ;; esac
fi

# ---------------------------------------------------------------------------- infrastructure

say "Phase 1/5 · Infrastructure"
"$HERE/provision_aws.sh"

# ---------------------------------------------------------------------------- dns gate

say "Phase 2/5 · DNS"
deadline=$(( $(date +%s) + WAIT_DNS * 60 ))
while :; do
    if dig @1.1.1.1 NS "$DOMAIN" +short 2>/dev/null | grep -q awsdns; then
        ok "$DOMAIN is delegated to Route 53"
        break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        cat <<GATE

Still waiting on your registrar. Set the nameservers printed above on $DOMAIN,
then run ./launch.sh again — everything already created will be reused.

GATE
        exit 0
    fi
    printf "    waiting for the nameserver change (%s min left)\r" "$(( (deadline - $(date +%s)) / 60 ))"
    sleep 30
done

# ---------------------------------------------------------------------------- server

say "Phase 3/5 · Server"
scp -q "$HERE/deployment_bootstrap.sh" "$CONFIG" "$PROJECT:~"
if ! ssh "$PROJECT" "sudo bash deployment_bootstrap.sh"; then
    # The one expected failure: GitHub doesn't know this server's deploy key yet.
    if $GH_READY; then
        slug=$(echo "$REPO" | sed -E 's|.*github\.com[:/]||; s|\.git$||')
        key=$(mktemp)
        ssh "$PROJECT" "sudo cat /srv/$PROJECT/.ssh/id_ed25519.pub" > "$key"
        say "Adding the deploy key to $slug"
        gh repo deploy-key add "$key" --repo "$slug" --title "$PROJECT-server" || true
        rm -f "$key"
        ssh "$PROJECT" "sudo bash deployment_bootstrap.sh"
    else
        cat <<GATE

Add the deploy key printed above to your repo (Settings → Deploy keys, read-only),
then run ./launch.sh again.

GATE
        exit 0
    fi
fi

# ---------------------------------------------------------------------------- email

if $SKIP_SES; then
    say "Phase 4/5 · Email (skipped)"
else
    say "Phase 4/5 · Email"
    "$HERE/setup_ses.sh" "$PROJECT"
fi

# ---------------------------------------------------------------------------- verify

say "Phase 5/5 · Verify"
http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://$DOMAIN" || echo "000")
case "$http_code" in 30*) ok "http://$DOMAIN redirects to https ($http_code)" ;; *) warn "http://$DOMAIN returned $http_code" ;; esac

https_headers=$(curl -sI "https://$DOMAIN" || true)
echo "$https_headers" | grep -q "200" && ok "https://$DOMAIN serves 200" || warn "https://$DOMAIN did not return 200 yet"
echo "$https_headers" | grep -qi "strict-transport-security" && ok "HSTS header present" || warn "no HSTS header"

ssh "$PROJECT" "systemctl is-active gunicorn nginx postgresql" | tr '\n' ' ' | sed 's/^/    services: /; s/$/\n/'
ssh "$PROJECT" "sudo -H -u $PROJECT bash -c 'set -a; . /etc/$PROJECT/env; set +a; cd /srv/$PROJECT/app; /srv/$PROJECT/.venv/bin/python manage.py check --deploy'" \
    && ok "check --deploy is clean"

cat <<DONE

$(printf '\033[1m%s is live: https://%s\033[0m' "$PROJECT" "$DOMAIN")

Still yours to do:
  1. Create the admin account:
     ssh $PROJECT "sudo -H -u $PROJECT bash -c 'set -a; . /etc/$PROJECT/env; set +a; cd /srv/$PROJECT/app; /srv/$PROJECT/.venv/bin/python manage.py createsuperuser'"
  2. If SES is still in its sandbox, verify recipients or wait for production access:
     aws sesv2 get-account --profile $AWS_PROFILE --query '{access:ProductionAccessEnabled,review:Details.ReviewDetails.Status}'

Deploy new commits with:
  ssh $PROJECT "sudo $PROJECT-deploy"
DONE
