# django-aws-deploy

Take any Django project live on AWS — HTTPS, PostgreSQL, real email — with four scripts, a config file,
and **no root credentials anywhere in the workflow**.

```
Browser ──HTTPS──▶ nginx ──unix socket──▶ gunicorn ──▶ Django ──socket──▶ PostgreSQL
                   │  Let's Encrypt cert                        └──SMTP──▶ AWS SES
                   └─ serves /static/ from disk
                      one EC2 instance, one region, about $20/month
```

| Script | Runs on | Does |
|---|---|---|
| `bootstrap_iam.sh` | your Mac, once per project | IAM group, scoped policy, deploy user; adds teammates |
| `provision_aws.sh` | your Mac | Key pair, security group, EC2 instance, Elastic IP, Route 53 zone and records |
| `deployment_bootstrap.sh` | the server | PostgreSQL, app user, code, virtualenv, env file, gunicorn, nginx, HTTPS, backups |
| `setup_ses.sh` | your Mac | SES identity, DKIM/SPF/DMARC records, SMTP credentials, production-access request |

Every script is **idempotent**: run it again any time and it fills in only what's missing.
After the first deploy, shipping changes is one command: `ssh <project> "sudo <project>-deploy"`.

**Cost**, ap-south-1 on demand: t4g.small ~$12/mo · 30 GB gp3 ~$3/mo · public IPv4 ~$3.60/mo ·
Route 53 zone $0.50/mo · SES $0.10 per 1,000 emails → **about $20/month**.

## 1. What your Django project needs

Four things, all small:

1. **Settings driven by environment variables.** Copy [`templates/settings-snippet.py`](templates/settings-snippet.py)
   into your `settings.py`. It keeps local development working with no variables set (SQLite, console email) and
   switches on PostgreSQL, HTTPS, HSTS, secure cookies, hashed static files and journal logging when
   `DJANGO_DEBUG=false`. It refuses to start in production without a secret key or a database.
2. **`.sample-env` committed at the repo root.** Start from [`templates/sample-env`](templates/sample-env).
   Blanks only, never real secrets.
3. **`requirements.txt` including** `gunicorn`, `psycopg[binary]` and `tzdata` (pin versions).
4. **A private GitHub repo.** The server clones it with its own read-only deploy key.

Worth adding: a test that runs `manage.py check --deploy` with production variables, so a settings change
can't silently weaken production.

## 2. AWS account setup (once per account)

**Root is used exactly twice, ever:** to turn on MFA for root, and to create the first admin IAM user.
After that, nobody signs in as root for day-to-day work. (AWS still requires root for a handful of account
chores: changing the account's email, closing the account, and some billing settings.)

As root, one time:
1. **IAM → Users → Create user**, e.g. `you-admin`, with `AdministratorAccess`.
2. Turn on **MFA for that user and for root**.
3. Create an access key for the admin user: `aws configure --profile admin`.
4. Sign out of root.

Then, per project (as the admin user, not root):

```bash
cp deploy.conf.example deploy.conf     # edit: PROJECT, DOMAIN, REPO, WSGI_MODULE, AWS_PROFILE…
ADMIN_PROFILE=admin ./bootstrap_iam.sh
```

That creates the `<project>-deployers` group holding a policy scoped to this project (EC2, Route 53, SES,
and IAM limited to `<project>-*` users), a `<project>-deployer` user in it, and writes that user's keys into
the `AWS_PROFILE` named in your config. The script **refuses to run as root**.

**Adding a teammate:** create an IAM user for them (console, with MFA), then:

```bash
ADMIN_PROFILE=admin ./bootstrap_iam.sh their-iam-username
```

They create their own access key and run `aws configure --profile <project>`. Everyone keeps their own
credentials: individually revocable, and attributable in CloudTrail. Never share one key between people.

## 3. Deploy a project

```bash
./provision_aws.sh
```

Creates the infrastructure and prints four nameservers plus an `ssh <project>` shortcut. **Point your
registrar at those nameservers.** Watch for the switch with `dig @1.1.1.1 NS <domain> +short`; resolvers
update at different speeds, so check a couple. HTTPS can't be issued until this lands.

```bash
scp deployment_bootstrap.sh deploy.conf <project>:~
ssh <project> "sudo bash deployment_bootstrap.sh"
```

The **first run stops** and prints a deploy key, because GitHub doesn't know the server yet:

```bash
ssh <project> "sudo cat /srv/<project>/.ssh/id_ed25519.pub" > /tmp/deploy-key.pub
gh repo deploy-key add /tmp/deploy-key.pub --repo you/yourrepo --title <project>-server
ssh <project> "sudo bash deployment_bootstrap.sh"      # run it again
```

The full run installs everything, generates the production secret key on the server, runs migrations and
`check --deploy`, sets up nightly backups, and requests the certificate once DNS points at the instance.
If DNS isn't ready it says so and skips — just run it again later.

Then the admin account, interactively so no password lands in a transcript:

```bash
ssh <project>
sudo -H -u <project> bash -c 'set -a; . /etc/<project>/env; set +a; cd /srv/<project>/app; /srv/<project>/.venv/bin/python manage.py createsuperuser'
```

Finally, email:

```bash
./setup_ses.sh
```

New SES accounts are in a **sandbox**: 200 emails a day, only to verified addresses. The script verifies your
`CERT_EMAIL` as a test recipient and submits the production-access request. A first denial is common — reply
in the support case with specifics about recipients, volume, bounce handling and rate limits, and they
reconsider. Check status any time:

```bash
aws sesv2 get-account --profile <project> --query '{access:ProductionAccessEnabled,review:Details.ReviewDetails.Status}'
```

## 4. Check it worked

```bash
curl -I http://<domain>          # 301 to https
curl -I https://<domain>         # 200 with strict-transport-security
ssh <project> "systemctl is-active gunicorn nginx postgresql"
ssh <project> "sudo reboot"      # then re-check: everything should come back by itself
```

Also confirm pages render **with styling** (that proves collectstatic and nginx's `/static/` alias), and that
a real signup email arrives.

## 5. Day-to-day

| Task | Command |
|---|---|
| Deploy latest commit | `ssh <project> "sudo <project>-deploy"` |
| Logs | `ssh <project> "journalctl -u gunicorn -f"` |
| Change a setting | edit `/etc/<project>/env`, then `sudo systemctl restart gunicorn` |
| Add settings without echoing secrets | `printf 'KEY=value\n' \| ssh <project> "sudo <project>-set-env && sudo systemctl restart gunicorn"` |
| Roll back | `ssh <project> "sudo -H -u <project> git -C /srv/<project>/app checkout <commit> && sudo <project>-deploy"` |
| Restore a backup | `pg_restore --clean --dbname <project> /srv/<project>/backups/<file>.dump` |
| Resize the instance | stop it, `aws ec2 modify-instance-attribute --instance-id <id> --instance-type t4g.medium`, start it, then raise `WORKERS` and the PostgreSQL sizes in `deploy.conf` and re-run the bootstrap |
| Rotate deploy keys | delete the old access key in IAM, re-run `bootstrap_iam.sh` |
| Move to RDS | `pg_dump`/`pg_restore` across, then fill `POSTGRES_HOST/USER/PASSWORD` in the env file and restart |

Backups are nightly `pg_dump` files in `/srv/<project>/backups`, kept 14 days. Copy them off the instance
(`aws s3 sync` with an instance role) and test a restore before you need one.

## 6. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `502 Bad Gateway` | gunicorn is down or won't start: `journalctl -u gunicorn -n 50`. Usually a bad value in the env file. |
| `Permission denied (publickey)` after launch | Status checks may still be running, or your personal key needs a passphrase a script can't answer. Use the generated deploy key: `ssh <project>`. |
| Locked out entirely | `aws ec2-instance-connect send-ssh-public-key --instance-id <id> --availability-zone <az> --instance-os-user ubuntu --ssh-public-key file://~/.ssh/<project>_deploy.pub` gives you 60 seconds to get in. |
| certbot: "Domain does not resolve" | Nameserver change hasn't propagated. Verify with `dig @1.1.1.1 NS <domain>`, then re-run the bootstrap. |
| Old parking page still showing | A resolver's cache. Confirm the server directly: `curl -s --resolve <domain>:443:<elastic-ip> https://<domain> \| grep title`. |
| Pages load unstyled | `collectstatic` didn't run, or `/srv/<project>` lost its `755` so nginx can't read `staticfiles/`. |
| `DisallowedHost` | Hostname missing from `DJANGO_ALLOWED_HOSTS`. |
| Email fails with "could not send" | SES not set up, wrong credentials, or the recipient isn't verified while in the sandbox. |
| `MalformedPolicyDocument` from IAM | Shell quoting mangled the JSON. Generate policy files with python, never inline heredocs. |
| AWS calls fail with "authorization grant is invalid" | A root/`aws login` session expired. That's exactly what the scoped IAM profile avoids. |

## 7. What this deliberately doesn't do

One instance, one region, no load balancer, no CI/CD, no containers, no CDN, and PostgreSQL on the same box.
That's the point: it's cheap, legible and debuggable by one person. Outgrow it when you need more than one
app server, zero-downtime database failover, or independent scaling — at which point RDS (step 5) and an
ALB in front of two instances are the natural next steps, and nothing here has to be thrown away.

Built while deploying [India Polls](https://indiapolls.app); every step here has been run for real.
