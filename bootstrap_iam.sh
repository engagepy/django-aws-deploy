#!/usr/bin/env bash
# Creates the AWS identities a team needs to deploy, so nobody ever uses the root user:
#   - group  <project>-deployers  holding a policy scoped to this project
#   - user   <project>-deployer   for automation, with keys written to your AWS CLI profile
#   - adds named teammates to the group (each keeps their own keys)
#
# Runs on your Mac, once per project, as an ADMIN IAM user (not root):
#   ADMIN_PROFILE=admin ./bootstrap_iam.sh [teammate-iam-username ...]
# Safe to run again.
set -euo pipefail

CONFIG="${CONFIG:-$(cd "$(dirname "$0")" && pwd)/deploy.conf}"
[ -f "$CONFIG" ] || { echo "Missing $CONFIG — copy deploy.conf.example and edit it."; exit 1; }
# shellcheck source=/dev/null
. "$CONFIG"

ADMIN_PROFILE="${ADMIN_PROFILE:-default}"     # an administrator IAM user, used only for this script
GROUP="$PROJECT-deployers"
DEPLOY_USER="$PROJECT-deployer"
POLICY_NAME="$PROJECT-deploy"

aws() { command aws --profile "$ADMIN_PROFILE" --region "$REGION" "$@"; }
say() { printf "\n==> %s\n" "$*"; }

CALLER=$(aws sts get-caller-identity --query Arn --output text)
case "$CALLER" in
    *":root") echo "Refusing to run as the root user ($CALLER)."
              echo "Create an admin IAM user first (root → IAM → Users), then: ADMIN_PROFILE=<profile> $0"; exit 1;;
esac
say "Running as $CALLER"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
POLICY_FILE=$(mktemp)
PROJECT="$PROJECT" ACCOUNT="$ACCOUNT" python3 - > "$POLICY_FILE" <<'PY'
import json, os
project, account = os.environ["PROJECT"], os.environ["ACCOUNT"]
print(json.dumps({
    "Version": "2012-10-17",
    "Statement": [
        {"Sid": "ReadAndConnect", "Effect": "Allow",
         "Action": ["ec2:Describe*", "ssm:GetParameter", "ec2-instance-connect:SendSSHPublicKey"],
         "Resource": "*"},
        {"Sid": "ManageCompute", "Effect": "Allow",
         "Action": ["ec2:RunInstances", "ec2:CreateTags", "ec2:StartInstances", "ec2:StopInstances",
                    "ec2:RebootInstances", "ec2:ModifyInstanceAttribute", "ec2:AllocateAddress",
                    "ec2:AssociateAddress", "ec2:ReleaseAddress", "ec2:ImportKeyPair",
                    "ec2:CreateSecurityGroup", "ec2:AuthorizeSecurityGroupIngress",
                    "ec2:RevokeSecurityGroupIngress"],
         "Resource": "*"},
        {"Sid": "DnsRead", "Effect": "Allow",
         "Action": ["route53:List*", "route53:Get*", "route53:CreateHostedZone"], "Resource": "*"},
        {"Sid": "DnsWrite", "Effect": "Allow",
         "Action": ["route53:ChangeResourceRecordSets"], "Resource": "arn:aws:route53:::hostedzone/*"},
        {"Sid": "Email", "Effect": "Allow", "Action": ["ses:*"], "Resource": "*"},
        {"Sid": "ProjectSmtpUsersOnly", "Effect": "Allow",
         "Action": ["iam:GetUser", "iam:CreateUser", "iam:PutUserPolicy", "iam:TagUser",
                    "iam:ListAccessKeys", "iam:CreateAccessKey", "iam:DeleteAccessKey"],
         "Resource": f"arn:aws:iam::{account}:user/{project}-*"},
    ],
}))
PY

say "Group $GROUP"
aws iam get-group --group-name "$GROUP" >/dev/null 2>&1 || aws iam create-group --group-name "$GROUP" >/dev/null
aws iam put-group-policy --group-name "$GROUP" --policy-name "$POLICY_NAME" --policy-document "file://$POLICY_FILE"
rm -f "$POLICY_FILE"
echo "policy $POLICY_NAME attached"

say "Deploy user $DEPLOY_USER"
if aws iam get-user --user-name "$DEPLOY_USER" >/dev/null 2>&1; then
    echo "already exists"
else
    aws iam create-user --user-name "$DEPLOY_USER" --tags "Key=Project,Value=$PROJECT" >/dev/null
fi
aws iam add-user-to-group --group-name "$GROUP" --user-name "$DEPLOY_USER"

if aws --profile "$AWS_PROFILE" sts get-caller-identity >/dev/null 2>&1; then
    echo "profile '$AWS_PROFILE' already works; leaving its keys alone"
else
    for key in $(aws iam list-access-keys --user-name "$DEPLOY_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
        [ "$key" != "None" ] && aws iam delete-access-key --user-name "$DEPLOY_USER" --access-key-id "$key"
    done
    # Written straight into the profile: the secret is never printed or logged.
    read -r ACCESS_KEY SECRET_KEY <<< "$(aws iam create-access-key --user-name "$DEPLOY_USER" \
        --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)"
    command aws configure set aws_access_key_id "$ACCESS_KEY" --profile "$AWS_PROFILE"
    command aws configure set aws_secret_access_key "$SECRET_KEY" --profile "$AWS_PROFILE"
    command aws configure set region "$REGION" --profile "$AWS_PROFILE"
    command aws configure set output json --profile "$AWS_PROFILE"
    unset ACCESS_KEY SECRET_KEY
    echo "keys written to the '$AWS_PROFILE' profile"
fi

for teammate in "$@"; do
    say "Teammate $teammate"
    if aws iam get-user --user-name "$teammate" >/dev/null 2>&1; then
        aws iam add-user-to-group --group-name "$GROUP" --user-name "$teammate"
        echo "added to $GROUP (they create their own access key in the console)"
    else
        echo "no IAM user '$teammate' — create it first, then re-run"
    fi
done

say "Done"
cat <<SUMMARY

  Group        : $GROUP
  Deploy user  : $DEPLOY_USER
  Profile      : $AWS_PROFILE

Each teammate needs their own IAM user in $GROUP, their own access key, and
  aws configure --profile $AWS_PROFILE

Next: ./provision_aws.sh
SUMMARY
