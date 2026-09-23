# Instructions for coding agents

This repo deploys a Django project to a single AWS EC2 instance: nginx + gunicorn + PostgreSQL + HTTPS + SES email,
for about $20/month. Your job is to drive it, not to reinvent it. **Read this file before running anything.**

## Ask the human first

Do not create any AWS resource until you have all of these. Never guess them.

| Ask | Why it matters |
|---|---|
| **Project name** (short, lowercase) | Becomes the Linux user, database, IAM users, systemd units and SSH alias |
| **Domain**, and whether they control DNS at the registrar | They must paste nameservers at the registrar; without that, HTTPS can't be issued |
| **GitHub repo** (private is fine) | The server clones it with its own read-only deploy key |
| **WSGI module** (e.g. `config.wsgi`) | gunicorn's entry point; wrong value means a dead site |
| **Contact email** | Certificate notices and the SES test recipient. **Never default to a personal address** — ask for a project mailbox |
| **Region** and **instance size** | Defaults: `ap-south-1`, `t4g.small`. Confirm, don't assume |
| **Which AWS profile** to use | Must be a scoped IAM user, never root |

## Rules

**Never:**
- Run anything as the AWS root user, or with root access keys. `bootstrap_iam.sh`, `provision_aws.sh` and
  `launch.sh` all refuse, and you should too. The single exception is `bootstrap_account.sh`, which exists
  precisely to get an account off root, and is run once ever (see "Starting from a brand-new AWS account").
- Print, echo, `cat` or commit a secret: access keys, SMTP passwords, `DJANGO_SECRET_KEY`, `.pem` files.
  Write server-side values by piping into `<project>-set-env` over SSH instead.
- Commit `deploy.conf` (it's git-ignored) or rewrite git history.
- Hand-edit the server when re-running a script would do it. The scripts are idempotent by design.

**Always:**
- Use `./launch.sh`. It runs the phases in the right order and is safe to re-run.
- Run `./launch.sh --check-only` first and report what fails.
- Verify with real commands and report the real output. Never claim a deployment works without a 200 from the site.
- Tell the user plainly when something is waiting on *them* (see Gates).

## The normal path

```bash
cp deploy.conf.example deploy.conf      # then edit the values you collected above
./launch.sh --check-only                # preflight only
./launch.sh                             # infrastructure → DNS → server → email → verify
```

Per AWS account, once, an administrator (not root) also runs:

```bash
ADMIN_PROFILE=admin ./bootstrap_iam.sh [teammate-iam-username ...]
```

### Starting from a brand-new AWS account

If `aws sts get-caller-identity` finds no credentials at all, the user is at rung zero. Walk them through this,
in this order, and don't skip the MFA reminder:

```bash
aws login                 # they sign in through the browser as root; sessions expire, no keys to leak
./bootstrap_account.sh    # creates an admin IAM user, stores its keys as the 'admin' profile
```

Then tell them: *"Turn on MFA for root and for the new admin user using the two links just printed, then stop
using root."* From here on, use `--profile admin` for account-level work and the project's own scoped profile
for everything else. If a root session expires mid-task, that's expected — the whole point of the scoped
profile is that it doesn't.

The Django project itself needs `templates/settings-snippet.py` merged into its `settings.py`, a `.sample-env` at
its repo root, and `gunicorn` + `psycopg[binary]` + `tzdata` in `requirements.txt`. Preflight checks all of this
when `APP_REPO_PATH` points at a local checkout.

## Gates: the two things only a human can do

1. **Nameservers at the registrar.** `launch.sh` prints four Route 53 nameservers and waits (default 20 minutes).
   Tell the user: *"Set these four nameservers on `<domain>` at your registrar; I'll continue once it propagates.
   HTTPS can't be issued before this."* If it times out, the script exits cleanly — re-run later.
2. **GitHub deploy key.** Handled automatically when `gh` is signed in. Otherwise tell the user:
   *"Add this key to the repo under Settings → Deploy keys, read-only,"* then re-run.

Afterwards, the human also creates the admin account (`createsuperuser`), because the password must not pass
through a transcript.

## What to expect, and how long

| Phase | Time | Notes |
|---|---|---|
| Infrastructure | ~2 min | Waits for the instance's status checks; SSH is refused before they pass |
| DNS delegation | minutes to hours | Resolvers disagree for a while; check `dig @1.1.1.1 NS <domain> +short` |
| Server bootstrap | ~4 min | Packages, PostgreSQL, virtualenv, gunicorn, nginx, certificate |
| SES setup | ~1 min | Domain verification lands within minutes |
| SES production access | ~1 day | Sandbox until then: only verified recipients receive mail. A first denial is normal; reply in the support case with recipients, volume, bounce handling and rate limits |

## When something breaks

| Symptom | Fix |
|---|---|
| `502 Bad Gateway` | `ssh <project> "journalctl -u gunicorn -n 50"` — nearly always a bad value in `/etc/<project>/env` |
| `Permission denied (publickey)` | Status checks may still be running, or a passphrase-protected personal key. Use `ssh <project>`, which uses the generated deploy key |
| Locked out completely | `aws ec2-instance-connect send-ssh-public-key --instance-id <id> --availability-zone <az> --instance-os-user ubuntu --ssh-public-key file://~/.ssh/<project>_deploy.pub` opens a 60-second window |
| certbot says the domain doesn't resolve | Delegation hasn't propagated; re-run `./launch.sh` later |
| Site shows an old parking page | A resolver cache. Prove the server with `curl -s --resolve <domain>:443:<ip> https://<domain> \| grep title` |
| Changes pushed but not on the site | The server never pulled. Compare `git -C /srv/<project>/app rev-parse HEAD` with GitHub, then `sudo <project>-deploy`. Always deploy with that command, never a script inside the app's repo: the server's copy may predate it |
| Rolling back | `sudo <project>-deploy <commit>`, never a manual `git checkout` (a detached HEAD breaks later pulls). Reverse any migrations first |
| Pages render unstyled | `collectstatic` didn't run, or `/srv/<project>` lost `755` so nginx can't read `staticfiles/` |
| `DisallowedHost` | Add the hostname to `DJANGO_ALLOWED_HOSTS` in the env file, then restart gunicorn |
| `MalformedPolicyDocument` | Generate IAM policy JSON with python, never inline shell heredocs |
| "authorization grant is invalid" | A root/`aws login` session expired — switch to the scoped IAM profile |

## Changing these scripts

Keep every script idempotent and re-runnable. Run `bash -n` on each before committing. When behaviour changes,
update `README.md` and this file in the same commit. If you learn something the hard way during a deploy, add it
to the failure table — that's how this stays useful.
