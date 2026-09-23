#!/usr/bin/env bash
# Sets up AWS SES so the app can send real email: domain identity with DKIM, every DNS record in
# Route 53, an SMTP-only IAM user, and the production-access request. Writes the SMTP settings
# straight onto the server over SSH, so no secret is printed.
#
# Runs on your Mac.   Usage:  ./setup_ses.sh [ssh-host] [--rotate]
# Safe to run again: existing SMTP credentials are left alone unless you pass --rotate.
set -euo pipefail

CONFIG="${CONFIG:-$(cd "$(dirname "$0")" && pwd)/deploy.conf}"
[ -f "$CONFIG" ] || { echo "Missing $CONFIG — copy deploy.conf.example and edit it."; exit 1; }
# shellcheck source=/dev/null
. "$CONFIG"

SERVER=""
ROTATE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --rotate) ROTATE=true ;;
        *) SERVER="$1" ;;
    esac
    shift
done
SERVER="${SERVER:-$PROJECT}"
TEST_EMAIL="${TEST_EMAIL:-$CERT_EMAIL}"
SMTP_USER_NAME="$PROJECT-ses-smtp"

aws() { command aws --profile "$AWS_PROFILE" --region "$REGION" "$@"; }
say() { printf "\n==> %s\n" "$*"; }

say "SES identity for $DOMAIN"
if aws sesv2 get-email-identity --email-identity "$DOMAIN" >/dev/null 2>&1; then
    echo "already created"
else
    aws sesv2 create-email-identity --email-identity "$DOMAIN" \
        --dkim-signing-attributes "NextSigningKeyLength=RSA_2048_BIT" >/dev/null
    echo "created with Easy DKIM"
fi
aws sesv2 put-email-identity-mail-from-attributes --email-identity "$DOMAIN" \
    --mail-from-domain "mail.$DOMAIN" --behavior-on-mx-failure USE_DEFAULT_VALUE >/dev/null

say "DNS records in Route 53"
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" \
    --query "HostedZones[?Name=='$DOMAIN.'].Id | [0]" --output text)
[ "$ZONE_ID" != "None" ] || { echo "No hosted zone for $DOMAIN; run ./provision_aws.sh first"; exit 1; }
ZONE_ID="${ZONE_ID##*/}"

changes=""
for token in $(aws sesv2 get-email-identity --email-identity "$DOMAIN" --query 'DkimAttributes.Tokens' --output text); do
    changes+="{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$token._domainkey.$DOMAIN.\",\"Type\":\"CNAME\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"$token.dkim.amazonses.com\"}]}},"
done
changes+="{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"mail.$DOMAIN.\",\"Type\":\"MX\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"10 feedback-smtp.$REGION.amazonses.com\"}]}},"
changes+="{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"mail.$DOMAIN.\",\"Type\":\"TXT\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"\\\"v=spf1 include:amazonses.com ~all\\\"\"}]}},"
changes+="{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"_dmarc.$DOMAIN.\",\"Type\":\"TXT\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"\\\"v=DMARC1; p=none;\\\"\"}]}}"

batch=$(mktemp)
printf '{"Changes": [%s]}' "$changes" > "$batch"
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "file://$batch" \
    --query 'ChangeInfo.Status' --output text
rm -f "$batch"

say "SMTP credentials"
aws iam get-user --user-name "$SMTP_USER_NAME" >/dev/null 2>&1 \
    || aws iam create-user --user-name "$SMTP_USER_NAME" --tags "Key=Project,Value=$PROJECT" >/dev/null
aws iam put-user-policy --user-name "$SMTP_USER_NAME" --policy-name send-email \
    --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["ses:SendRawEmail"],"Resource":"*"}]}'

# Credentials are only issued when the server hasn't got working ones, so re-running this script
# (or launch.sh) doesn't churn them. Pass --rotate to replace them deliberately.
if ! $ROTATE && ssh "$SERVER" "sudo grep -qE '^EMAIL_HOST_USER=.+' /etc/$PROJECT/env" 2>/dev/null; then
    echo "server already has SMTP credentials — leaving them alone (use --rotate to replace)"
else
    existing_keys=$(aws iam list-access-keys --user-name "$SMTP_USER_NAME" --query 'AccessKeyMetadata[].AccessKeyId' --output text)
    if [ -n "$existing_keys" ] && [ "$existing_keys" != "None" ]; then
        echo "removing the old access key so a fresh SMTP password can be issued"
        for key in $existing_keys; do
            aws iam delete-access-key --user-name "$SMTP_USER_NAME" --access-key-id "$key"
        done
    fi
    read -r SMTP_USERNAME SMTP_SECRET <<< "$(aws iam create-access-key --user-name "$SMTP_USER_NAME" \
        --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)"

    # The SES SMTP password is derived from the IAM secret; AWS documents this exact derivation.
    SMTP_PASSWORD=$(SMTP_SECRET="$SMTP_SECRET" REGION="$REGION" python3 - <<'PY'
import base64, hashlib, hmac, os

def sign(key, message):
    return hmac.new(key, message.encode(), hashlib.sha256).digest()

signature = sign(("AWS4" + os.environ["SMTP_SECRET"]).encode(), "11111111")
for part in (os.environ["REGION"], "ses", "aws4_request", "SendRawEmail"):
    signature = sign(signature, part)
print(base64.b64encode(bytes([0x04]) + signature).decode())
PY
)

    say "Writing email settings onto the server"
    printf 'EMAIL_BACKEND=django.core.mail.backends.smtp.EmailBackend\nEMAIL_HOST=email-smtp.%s.amazonaws.com\nEMAIL_PORT=587\nEMAIL_USE_TLS=true\nEMAIL_HOST_USER=%s\nEMAIL_HOST_PASSWORD=%s\n' \
        "$REGION" "$SMTP_USERNAME" "$SMTP_PASSWORD" \
        | ssh "$SERVER" "sudo /usr/local/sbin/$PROJECT-set-env && sudo systemctl restart gunicorn"
    echo "done (gunicorn restarted)"
fi

say "Test recipient while SES is in the sandbox"
if aws sesv2 get-email-identity --email-identity "$TEST_EMAIL" >/dev/null 2>&1; then
    echo "$TEST_EMAIL already verified or pending"
else
    aws sesv2 create-email-identity --email-identity "$TEST_EMAIL" >/dev/null
    echo "verification email sent to $TEST_EMAIL — click the link in it"
fi

say "Production access"
aws sesv2 put-account-details \
    --production-access-enabled \
    --mail-type TRANSACTIONAL \
    --website-url "https://$DOMAIN" \
    --contact-language EN \
    --use-case-description "$PROJECT (https://$DOMAIN) sends transactional email to people who entered their own address on our signup form: account verification codes, and later an opt-out summary email. Bounces and complaints are handled by the SES account-level suppression list, and code requests are rate limited per user." \
    >/dev/null 2>&1 && echo "requested (AWS usually replies within a day)" \
    || echo "already requested, granted, or denied — check: aws sesv2 get-account --profile $AWS_PROFILE"

say "Status"
aws sesv2 get-account --output json | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('production access:', d.get('ProductionAccessEnabled'))
print('review status    :', d.get('Details', {}).get('ReviewDetails', {}).get('Status', '(none)'))
print('quota per day    :', d.get('SendQuota', {}).get('Max24HourSend'))
"
