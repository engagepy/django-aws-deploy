#!/usr/bin/env bash
# The ONE script you may run as the AWS root user, and only once per account.
# It hands the account over to an administrator IAM user so root is never needed again.
#
#   aws login                       # browser sign-in as root (AWS CLI 2.32+); no access keys needed
#   ./bootstrap_account.sh          # creates the admin IAM user and stores its keys locally
#
# Afterwards: turn on MFA (see the printed steps), stop using root, and run
#   ADMIN_PROFILE=admin ./bootstrap_iam.sh
#
# Safe to run again: if the admin profile already works, it changes nothing.
set -euo pipefail

ADMIN_USER="${1:-${ADMIN_USER:-deploy-admin}}"
ADMIN_PROFILE="${ADMIN_PROFILE:-admin}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REGION="${REGION:-ap-south-1}"
# Reuse the project's region if a config is already filled in.
[ -f "$HERE/deploy.conf" ] && REGION="$(. "$HERE/deploy.conf" && echo "${REGION:-ap-south-1}")"

say() { printf "\n\033[1m==> %s\033[0m\n" "$*"; }

if command aws sts get-caller-identity --profile "$ADMIN_PROFILE" >/dev/null 2>&1; then
    admin_arn=$(command aws sts get-caller-identity --profile "$ADMIN_PROFILE" --query Arn --output text)
    say "Nothing to do"
    echo "Profile '$ADMIN_PROFILE' already works: $admin_arn"
    echo "Next: ADMIN_PROFILE=$ADMIN_PROFILE ./bootstrap_iam.sh"
    exit 0
fi

say "Who am I?"
if ! CALLER=$(command aws sts get-caller-identity --query Arn --output text 2>/dev/null); then
    cat <<SIGNIN
No working AWS credentials.

If this is a brand-new account, sign in with your browser first (AWS CLI 2.32 or later):

    aws login

then run this script again.
SIGNIN
    exit 1
fi
echo "$CALLER"

case "$CALLER" in
    *":root")
        echo
        echo "Running as root — correct for this one script, and for nothing else afterwards." ;;
    *)
        echo
        echo "Not root, which is fine: any identity that can create IAM users works here." ;;
esac

say "Administrator user ($ADMIN_USER)"
if command aws iam get-user --user-name "$ADMIN_USER" >/dev/null 2>&1; then
    echo "already exists"
else
    command aws iam create-user --user-name "$ADMIN_USER" --tags "Key=ManagedBy,Value=django-aws-deploy" >/dev/null
    echo "created"
fi
command aws iam attach-user-policy --user-name "$ADMIN_USER" \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
echo "AdministratorAccess attached"

say "Access key → profile '$ADMIN_PROFILE'"
# Written straight into the profile; the secret is never printed.
read -r ACCESS_KEY SECRET_KEY <<< "$(command aws iam create-access-key --user-name "$ADMIN_USER" \
    --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)"
command aws configure set aws_access_key_id "$ACCESS_KEY" --profile "$ADMIN_PROFILE"
command aws configure set aws_secret_access_key "$SECRET_KEY" --profile "$ADMIN_PROFILE"
command aws configure set region "$REGION" --profile "$ADMIN_PROFILE"
command aws configure set output json --profile "$ADMIN_PROFILE"
unset ACCESS_KEY SECRET_KEY
echo "stored (keys never printed)"

say "Done — now lock root away"
cat <<NEXT

  1. Turn on MFA for the root user:
       https://console.aws.amazon.com/iam/home#/security_credentials
  2. Turn on MFA for $ADMIN_USER:
       https://console.aws.amazon.com/iam/home#/users/$ADMIN_USER?section=security_credentials
  3. If you created root access keys at any point, delete them on that first page.
     (Browser sign-ins via 'aws login' expire on their own; nothing to clean up.)
  4. Never sign in as root again except for account-level chores AWS reserves for it:
     changing the account email, closing the account, and some billing settings.

Next, per project:

    cp deploy.conf.example deploy.conf     # edit it
    ADMIN_PROFILE=$ADMIN_PROFILE ./bootstrap_iam.sh
    ./launch.sh
NEXT
