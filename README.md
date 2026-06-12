# ShimonVault

**A secure, fully audited internal operations platform.**  
Teams upload documents, schedule meetings, and every action is logged, monitored, and defended in real time.

[![CI](https://github.com/mindmug2018-oss/shimon-vault/actions/workflows/ci.yml/badge.svg)](https://github.com/mindmug2018-oss/shimon-vault/actions/workflows/ci.yml)
[![CD](https://github.com/mindmug2018-oss/shimon-vault/actions/workflows/cd.yml/badge.svg)](https://github.com/mindmug2018-oss/shimon-vault/actions/workflows/cd.yml)

---

## What it does

ShimonVault has three modules:

**SecureDocs** — Upload, download, and version sensitive documents. Files are stored encrypted in S3 with role-based access control (admin / editor / viewer). Download links expire after 15 minutes. Every access attempt is logged.

**ShimonMeet** — Create and manage virtual meetings. Each meeting gets a unique join token. AWS EventBridge automatically sends reminders 10 minutes before start time and archives attendance records when meetings end.

**AuditStream** — A live Grafana dashboard showing every platform action in real time. Suspicious patterns (bulk downloads, repeated 401s, unauthorized access) trigger automatic IP blocks and Slack/Telegram alerts with zero human intervention.

---

## Tech stack

| Layer | Technology |
|---|---|
| Cloud | AWS (EC2, RDS, S3, DynamoDB, Lambda, ALB, CloudWatch, SNS, EventBridge) |
| IaC | Terraform |
| App | FastAPI (Python 3.12) |
| Containers | Docker + Docker Hub |
| CI/CD | GitHub Actions (blue/green deployment) |
| Monitoring | Prometheus + Grafana + Alertmanager |
| VPN | Tailscale (on-prem ↔ AWS) |
| DNS + HTTPS | Cloudflare |
| Database | PostgreSQL on RDS (write) + on-prem replica (read) |

---

## Project layout

```
shimon-vault/
├── app/                  FastAPI application
│   ├── routers/          API endpoints (auth, docs, meetings, audit)
│   ├── services/         S3, DynamoDB, EventBridge, notifications
│   └── middleware/       Request audit logger
├── terraform/            All AWS infrastructure as code
├── monitoring/           Prometheus, Grafana, Alertmanager (on-prem)
├── lambda/               Five Lambda functions (Week 3)
├── db/                   Schema and seed SQL
├── scripts/              deploy, destroy, simulate attacks
└── tests/                pytest test suite
```

---

## First-time setup

### Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.7 installed
- Docker Desktop running
- SSH key at `~/.ssh/id_ed25519_shimonvault` (generate if missing: `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_shimonvault`)

### Step 1 — Create state infrastructure (once only)

```bash
# Get your account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create S3 state bucket
aws s3 mb s3://shimonvault-tfstate-$AWS_ACCOUNT_ID --region ap-northeast-2
aws s3api put-bucket-versioning \
  --bucket shimonvault-tfstate-$AWS_ACCOUNT_ID \
  --versioning-configuration Status=Enabled

# Create DynamoDB lock table
aws dynamodb create-table \
  --table-name shimonvault-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-2
```

### Step 2 — Configure Terraform

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars — fill in all CHANGEME values
# Also update terraform/main.tf backend bucket name with your account ID
```

### Step 3 — Deploy

```bash
bash scripts/deploy.sh
```

This takes about 10 minutes. RDS is the slowest resource to provision.

### Step 4 — Start monitoring (on-prem server)

```bash
# On your proj-mgmt server:
cp .env.example monitoring/.env
# Edit monitoring/.env — fill in AWS keys, Slack, Telegram
cd monitoring
docker compose up -d
```

### End of session — destroy everything

```bash
bash scripts/destroy.sh
```

---

## GitHub Actions secrets required

Go to: **Settings → Secrets and variables → Actions → New repository secret**

| Secret | Where to get it |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS IAM → Users → Security credentials |
| `AWS_SECRET_ACCESS_KEY` | Same as above |
| `DOCKERHUB_USERNAME` | Your Docker Hub username (`mindmug`) |
| `DOCKERHUB_TOKEN` | Docker Hub → Account Settings → Security → Access Tokens |
| `DB_PASSWORD` | Same value as in `terraform.tfvars` |
| `JWT_SECRET_KEY` | Same value as in `terraform.tfvars` |
| `SLACK_WEBHOOK_URL` | Slack → Your workspace → Incoming Webhooks |
| `TELEGRAM_BOT_TOKEN` | @BotFather on Telegram → /newbot |
| `TELEGRAM_CHAT_ID` | Send a message to your bot, then GET `https://api.telegram.org/bot{TOKEN}/getUpdates` |

---

## Running tests locally

```bash
cd app
pip install -r requirements.txt pytest pytest-cov
cd ..
pytest tests/ -v
```

Tests use SQLite in-memory — no AWS credentials needed.

---

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for a detailed write-up of every component.

Live domain: [shimonvault.cshimomoto.com](https://shimonvault.cshimomoto.com)
