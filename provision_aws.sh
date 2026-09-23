#!/usr/bin/env bash
# Creates the AWS infrastructure for a Django project: key pair, security group, EC2 instance,
# Elastic IP, and a Route 53 hosted zone with records pointing at it.
#
# Runs on your Mac.   Usage:  ./provision_aws.sh
# Safe to run again: every step checks what exists and fills in only what's missing.
set -euo pipefail

CONFIG="${CONFIG:-$(cd "$(dirname "$0")" && pwd)/deploy.conf}"
[ -f "$CONFIG" ] || { echo "Missing $CONFIG — copy deploy.conf.example and edit it."; exit 1; }
# shellcheck source=/dev/null
. "$CONFIG"

DEPLOY_KEY="${DEPLOY_KEY:-$HOME/.ssh/${PROJECT}_deploy}"   # passphrase-less, so scripted SSH never stalls
KEY_NAME="$PROJECT"
SG_NAME="$PROJECT-web"
# Canonical publishes the current Ubuntu 24.04 arm64 image id here, so no AMI id is ever hard-coded.
AMI_PARAM="/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"

aws() { command aws --profile "$AWS_PROFILE" --region "$REGION" "$@"; }
say() { printf "\n==> %s\n" "$*"; }

say "AWS identity"
CALLER=$(aws sts get-caller-identity --query Arn --output text)
case "$CALLER" in
    *":root") echo "Refusing to run as root. Use the scoped profile from bootstrap_iam.sh."; exit 1;;
esac
echo "$CALLER"

say "SSH key pair ($KEY_NAME)"
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
    echo "already imported"
else
    [ -f "$PUBLIC_KEY" ] || { echo "No public key at $PUBLIC_KEY"; exit 1; }
    aws ec2 import-key-pair --key-name "$KEY_NAME" --public-key-material "fileb://$PUBLIC_KEY" \
        --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=$PROJECT}]" >/dev/null
    echo "imported $PUBLIC_KEY"
fi

say "Security group ($SG_NAME)"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [ "$SG_ID" = "None" ]; then
    SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --vpc-id "$VPC_ID" \
        --description "$PROJECT web server" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$PROJECT}]" \
        --query 'GroupId' --output text)
fi
MY_IP=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
# Duplicate rules error harmlessly, which is what makes this re-runnable.
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$MY_IP/32" >/dev/null 2>&1 || true
echo "$SG_ID (SSH allowed from $MY_IP)"

say "Deployment key"
if [ -f "$DEPLOY_KEY" ]; then
    echo "already generated"
else
    ssh-keygen -q -t ed25519 -N "" -f "$DEPLOY_KEY" -C "$PROJECT-deploy"
    echo "created $DEPLOY_KEY"
fi

say "Instance ($INSTANCE_TYPE)"
INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$INSTANCE_ID" = "None" ]; then
    AMI_ID=$(aws ssm get-parameter --name "$AMI_PARAM" --query 'Parameter.Value' --output text)
    echo "launching from $AMI_ID"
    # cloud-init adds the deploy key, so scripted SSH works even if your personal key has a passphrase.
    CLOUD_INIT=$(mktemp)
    printf '#cloud-config\nssh_authorized_keys:\n  - %s\n' "$(cat "$DEPLOY_KEY.pub")" > "$CLOUD_INIT"
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
        --security-group-ids "$SG_ID" \
        --user-data "file://$CLOUD_INIT" \
        --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_GB,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}" \
        --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
        --instance-initiated-shutdown-behavior stop \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$PROJECT-web},{Key=Project,Value=$PROJECT}]" \
        --query 'Instances[0].InstanceId' --output text)
    rm -f "$CLOUD_INIT"
fi
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
# SSH is refused until the status checks pass, a minute or two on a fresh instance.
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"
echo "$INSTANCE_ID running and reachable"

say "Elastic IP"
ALLOC_ID=$(aws ec2 describe-addresses --filters "Name=tag:Project,Values=$PROJECT" \
    --query 'Addresses[0].AllocationId' --output text)
if [ "$ALLOC_ID" = "None" ]; then
    ALLOC_ID=$(aws ec2 allocate-address --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Project,Value=$PROJECT}]" \
        --query 'AllocationId' --output text)
fi
aws ec2 associate-address --allocation-id "$ALLOC_ID" --instance-id "$INSTANCE_ID" >/dev/null
EIP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC_ID" --query 'Addresses[0].PublicIp' --output text)
echo "$EIP"

say "SSH shortcut (ssh $PROJECT)"
if grep -q "^Host $PROJECT$" "$HOME/.ssh/config" 2>/dev/null; then
    PROJECT="$PROJECT" EIP="$EIP" python3 - "$HOME/.ssh/config" <<'PY'
import os, re, sys
path, host, ip = sys.argv[1], os.environ["PROJECT"], os.environ["EIP"]
config = open(path).read()
block = re.search(rf"(Host {host}\n(?:[ \t]+.*\n)*)", config)
if block:
    updated = re.sub(r"([ \t]+HostName[ \t]+)\S+", rf"\g<1>{ip}", block.group(1))
    open(path, "w").write(config.replace(block.group(1), updated))
PY
    echo "updated"
else
    cat >> "$HOME/.ssh/config" <<CFG

Host $PROJECT
    HostName $EIP
    User ubuntu
    IdentityFile $DEPLOY_KEY
    IdentitiesOnly yes
CFG
    echo "added"
fi

say "Route 53 zone for $DOMAIN"
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" \
    --query "HostedZones[?Name=='$DOMAIN.'].Id | [0]" --output text)
if [ "$ZONE_ID" = "None" ]; then
    ZONE_ID=$(aws route53 create-hosted-zone --name "$DOMAIN" --caller-reference "$PROJECT-$(date +%s)" \
        --hosted-zone-config "Comment=$PROJECT" --query 'HostedZone.Id' --output text)
    echo "created"
fi
ZONE_ID="${ZONE_ID##*/}"

RECORDS=$(mktemp)
cat > "$RECORDS" <<JSON
{"Changes": [
  {"Action": "UPSERT", "ResourceRecordSet": {
    "Name": "$DOMAIN.", "Type": "A", "TTL": 300, "ResourceRecords": [{"Value": "$EIP"}]}},
  {"Action": "UPSERT", "ResourceRecordSet": {
    "Name": "www.$DOMAIN.", "Type": "A", "TTL": 300, "ResourceRecords": [{"Value": "$EIP"}]}}
]}
JSON
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "file://$RECORDS" \
    --query 'ChangeInfo.Status' --output text
rm -f "$RECORDS"

say "Point your registrar at these nameservers:"
aws route53 get-hosted-zone --id "$ZONE_ID" --query 'DelegationSet.NameServers' --output text | tr '\t' '\n'

cat <<SUMMARY

  Instance : $INSTANCE_ID ($INSTANCE_TYPE)
  Address  : $EIP
  Zone     : $ZONE_ID
  SSH      : ssh $PROJECT

Next:
  scp deployment_bootstrap.sh deploy.conf $PROJECT:~
  ssh $PROJECT "sudo bash deployment_bootstrap.sh"
SUMMARY
