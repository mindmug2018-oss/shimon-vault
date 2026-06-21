#!/bin/bash
# scripts/deploy.sh
# Run at the START of each work session.
# Usage: bash scripts/deploy.sh
#
# To ALSO trigger the GitHub Actions deploy pipeline at the end (opt-in):
#   SHIP=true bash scripts/deploy.sh
# (Leave it off for a normal session bring-up — see the note at step 14.)

set -e
# pipefail: without this, a command like `terraform apply ... | tail -30` would
# report SUCCESS even when apply FAILED (the pipe's exit code is tail's, not
# terraform's), and the script would keep running into broken steps. With
# pipefail, a failed apply stops the script immediately. All the other pipes
# below are guarded with `|| true`, so they are unaffected.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
ANSIBLE_DIR="$REPO_ROOT/ansible"
TFVARS="$TF_DIR/terraform.tfvars"

echo "🚀 ShimonVault — Starting deployment..."
echo ""

# ── 0. Auto-detect public IP and update terraform.tfvars ─────────────────────
# Korean residential ISPs rotate IPs frequently. If your_ip_cidr is stale,
# the bastion security group will refuse SSH and break steps 10-13.
# This block detects your current IP and silently updates terraform.tfvars
# before any terraform apply runs, so you never need to do this manually.
echo "0️⃣  Checking your public IP..."

CURRENT_IP=$(curl -s --max-time 5 ifconfig.me \
    || curl -s --max-time 5 api.ipify.org \
    || curl -s --max-time 5 checkip.amazonaws.com \
    || echo "")

if [ -z "$CURRENT_IP" ]; then
    echo "   ⚠️  Could not detect public IP (no internet?) — skipping IP update"
else
    CURRENT_CIDR="${CURRENT_IP}/32"
    # Read whatever is currently in terraform.tfvars
    STORED_CIDR=$(grep '^your_ip_cidr' "$TFVARS" \
        | sed 's/.*=\s*"\(.*\)".*/\1/' \
        | tr -d '[:space:]' \
        || echo "")

    if [ "$STORED_CIDR" = "$CURRENT_CIDR" ]; then
        echo "   ✅ IP unchanged: $CURRENT_CIDR"
    else
        echo "   🔄 IP changed: $STORED_CIDR → $CURRENT_CIDR"
        # In-place replacement — works on both Linux and macOS
        sed -i "s|your_ip_cidr\s*=\s*\".*\"|your_ip_cidr = \"$CURRENT_CIDR\"|" "$TFVARS"
        echo "   ✅ terraform.tfvars updated → your_ip_cidr = \"$CURRENT_CIDR\""
    fi
fi
echo ""

# ── 1. Terraform init ─────────────────────────────────────────────────────────
cd "$TF_DIR"
echo "1️⃣  terraform init..."
terraform init -input=false -upgrade 2>&1 | grep -E "(Initializing|Upgrading|error|Error)" || true
echo "✅ Init complete"
echo ""

# ── 2. Terraform apply ────────────────────────────────────────────────────────
# -input=false: never pause for an interactive prompt. If a required variable is
# missing from terraform.tfvars, fail fast with a clear message instead of hanging.
echo "2️⃣  terraform apply (this takes ~10-15 min for RDS)..."
terraform apply -auto-approve -input=false 2>&1 | tail -30
echo ""

# ── 3. Generate .env ──────────────────────────────────────────────────────────
echo "3️⃣  Generating .env from Terraform outputs..."
cd "$REPO_ROOT"
bash scripts/generate_env.sh
echo ""

# ── 4. Update SSH config ──────────────────────────────────────────────────────
echo "4️⃣  Updating SSH config..."
bash scripts/update_ssh_config.sh 2>/dev/null || echo "   (skipped)"
echo ""

# ── 5. Read outputs ───────────────────────────────────────────────────────────
cd "$TF_DIR"
ALB_DNS=$(terraform output -raw alb_dns_name)
BASTION_IP=$(terraform output -raw bastion_public_ip)
BLUE_TG_ARN=$(terraform output -raw alb_target_group_blue_arn)
AWS_REGION=$(terraform output -raw aws_region)

BLUE_IP=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=shimonvault-app-blue" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" \
  --output text 2>/dev/null || echo "unknown")

echo "📋 Infrastructure ready:"
echo "   ALB DNS:    $ALB_DNS"
echo "   Bastion IP: $BASTION_IP"
echo "   Blue EC2:   $BLUE_IP"
echo ""

# ── 5.5: Update Cloudflare DNS to point to current ALB ────────────────────────
# ALB DNS name changes on every terraform apply (AWS appends a new random
# suffix each time the load balancer is recreated). Without this step,
# portfolio.cshimomoto.com silently breaks after every fresh deploy.
echo "🌐 Updating Cloudflare DNS (portfolio.cshimomoto.com → $ALB_DNS)..."
CF_TOKEN=$(grep cloudflare_api_token "$TF_DIR/terraform.tfvars" | cut -d'"' -f2)
CF_ZONE_ID="9552af6942ec853c0bc814e9689795aa"
CF_RECORD_ID="a80065b4abff38457f85f2da79e06e3b"
if [ -n "$CF_TOKEN" ]; then
  CF_RESULT=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"portfolio.cshimomoto.com\",\"content\":\"$ALB_DNS\",\"proxied\":false,\"ttl\":1}")
  CF_SUCCESS=$(echo "$CF_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "false")
  if [ "$CF_SUCCESS" = "True" ]; then
    echo "   ✅ Cloudflare DNS updated successfully"
  else
    echo "   ⚠️  Cloudflare DNS update failed — check manually: $CF_RESULT"
  fi
else
  echo "   ⚠️  No cloudflare_api_token found in terraform.tfvars — skipping DNS update"
fi
echo ""

# ── 6. Wait for bastion SSH to be ready ──────────────────────────────────────
# The bastion takes 30-60s after Terraform reports it created before sshd is
# actually accepting connections. Steps 10-13 all need SSH via the bastion.
# Without this wait, those steps silently fail with "Connection refused".
echo "5️⃣  Waiting for bastion SSH to be ready..."
BASTION_READY=false
for i in $(seq 1 18); do  # 18 × 10s = 3 minutes max
    if ssh -o StrictHostKeyChecking=no \
           -o ConnectTimeout=5 \
           -o BatchMode=yes \
           -i ~/.ssh/id_ed25519_shimonvault \
           "ec2-user@$BASTION_IP" "echo ok" >/dev/null 2>&1; then
        echo "   ✅ Bastion SSH ready (attempt $i)"
        BASTION_READY=true
        break
    fi
    printf "   [attempt %d/18] waiting for sshd on bastion...\r" "$i"
    sleep 10
done

if [ "$BASTION_READY" = "false" ]; then
    echo "   ⚠️  Bastion SSH not ready after 3 minutes"
    echo "   Check: ssh -i ~/.ssh/id_ed25519_shimonvault ec2-user@$BASTION_IP"
    echo "   Possible cause: your_ip_cidr in terraform.tfvars doesn't match your current IP"
    echo "   Current IP detected: ${CURRENT_IP:-unknown}"
fi
echo ""

# ── 7. Wait for app healthy ───────────────────────────────────────────────────
echo "5️⃣  Waiting for app to become healthy (up to 4 minutes)..."
echo ""

MAX_WAIT=240
INTERVAL=20
ELAPSED=0
HEALTHY=false

while [ $ELAPSED -lt $MAX_WAIT ]; do
    HEALTH_COUNT=$(aws elbv2 describe-target-health \
        --target-group-arn "$BLUE_TG_ARN" \
        --region "$AWS_REGION" \
        --query "TargetHealthDescriptions[?TargetHealth.State=='healthy'] | length(@)" \
        --output text 2>/dev/null || echo "0")

    ALL_STATES=$(aws elbv2 describe-target-health \
        --target-group-arn "$BLUE_TG_ARN" \
        --region "$AWS_REGION" \
        --query "TargetHealthDescriptions[].TargetHealth.State" \
        --output text 2>/dev/null || echo "unknown")

    printf "   [%3ds] Target states: %-30s\r" "$ELAPSED" "$ALL_STATES"

    if [ "${HEALTH_COUNT:-0}" -ge 1 ] 2>/dev/null; then
        echo ""
        echo "   ✅ Target is healthy!"
        HEALTHY=true
        break
    fi

    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""

# ── 8. Final curl check ───────────────────────────────────────────────────────
echo "6️⃣  Running health check against ALB..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://$ALB_DNS/health" --max-time 10 2>/dev/null || echo "000")

if [ "$HTTP_STATUS" = "200" ]; then
    echo "   ✅ App is healthy! → HTTP 200"
    echo "   Health:   http://$ALB_DNS/health"
    echo "   API docs: http://$ALB_DNS/docs"
else
    echo "   ⚠️  ALB returned HTTP $HTTP_STATUS"
    aws elbv2 describe-target-health \
        --target-group-arn "$BLUE_TG_ARN" \
        --region "$AWS_REGION" \
        --query "TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}" \
        --output table 2>/dev/null || true
    if [ "$BLUE_IP" != "unknown" ]; then
        ssh-add ~/.ssh/id_ed25519_shimonvault 2>/dev/null || true
        ssh -A -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            -o ProxyJump="ec2-user@$BASTION_IP" \
            "ec2-user@$BLUE_IP" \
            "sudo docker service logs shimonvault_app 2>&1 | tail -30" \
            2>/dev/null | sed 's/^/  /' || true
    fi
fi

echo ""

# ── 9. Update Ansible SSH config ──────────────────────────────────────────────
echo "7️⃣  Updating Ansible SSH jump host..."
python3 -c "
import re
with open('$ANSIBLE_DIR/ansible.cfg', 'r') as f:
    content = f.read()
content = re.sub(
    r'ssh_args.*',
    'ssh_args = -o StrictHostKeyChecking=no -o ProxyJump=ec2-user@$BASTION_IP -i ~/.ssh/id_ed25519_shimonvault',
    content
)
with open('$ANSIBLE_DIR/ansible.cfg', 'w') as f:
    f.write(content)
print('   ✅ Ansible SSH config updated → bastion $BASTION_IP')
"
echo ""

# ── 10. Start SSH agent ───────────────────────────────────────────────────────
if [ -z "$SSH_AUTH_SOCK" ]; then
    eval $(ssh-agent -s) > /dev/null
fi
ssh-add ~/.ssh/id_ed25519_shimonvault 2>/dev/null || true

# ── 11. Install node_exporter BEFORE verify so verify sees it ─────────────────
echo "8️⃣  Installing node_exporter on EC2 instances..."
cd "$ANSIBLE_DIR"
ansible role_app -b -m shell \
    -a "docker run -d --name node_exporter \
        --restart unless-stopped \
        --net=host --pid=host \
        -v /:/host:ro,rslave \
        prom/node-exporter:latest \
        --path.rootfs=/host \
        2>/dev/null || echo 'node_exporter already running'" \
    2>/dev/null | grep -E "(SUCCESS|FAILED|already|changed)" || true
echo "   ✅ node_exporter deployed"
echo ""

# ── 12. Configure PostgreSQL replication ──────────────────────────────────────
echo "9️⃣  Setting up PostgreSQL replication (RDS → proj-ubuntu01)..."
export DB_NAME=$(grep "^db_name" "$REPO_ROOT/terraform/terraform.tfvars" | cut -d'"' -f2 || echo "shimonvault")
export DB_USER=$(grep "^db_username" "$REPO_ROOT/terraform/terraform.tfvars" | cut -d'"' -f2 || echo "shimonvault")
export DB_PASSWORD=$(grep "^db_password" "$REPO_ROOT/terraform/terraform.tfvars" | cut -d'"' -f2 || echo "")
bash "$REPO_ROOT/scripts/setup_replica.sh" && \
    echo "   ✅ Replication configured" || \
    echo "   ⚠️  Replication setup failed — run manually: bash scripts/setup_replica.sh"
echo ""

# ── 13. Run Ansible verify ────────────────────────────────────────────────────
echo "🔟  Running Ansible stack verification..."
cd "$ANSIBLE_DIR"
ansible-playbook playbooks/verify_stack.yml 2>/dev/null | \
    grep -E "(PLAY|TASK|ok:|fatal:|✅|❌|RECAP)" || true
echo ""

# ── 14. Fetch Docker TLS certs and update Portainer ──────────────────────────
echo "1️⃣1️⃣  Fetching Docker TLS certs → updating Portainer..."
if [ "$BLUE_IP" != "unknown" ]; then
    bash "$REPO_ROOT/scripts/fetch_docker_certs.sh" "$BASTION_IP" "$BLUE_IP" && \
        echo "   ✅ Portainer ready" || \
        echo "   ⚠️  Cert fetch failed — retry: bash scripts/fetch_docker_certs.sh $BASTION_IP $BLUE_IP"
else
    echo "   ⚠️  Blue EC2 IP unknown — skipping"
fi
echo ""

# ── 15. Reload Prometheus ─────────────────────────────────────────────────────
echo "1️⃣2️⃣  Reloading Prometheus..."
curl -s -X POST http://localhost:9090/-/reload 2>/dev/null && \
    echo "   ✅ Prometheus reloaded" || \
    echo "   ⚠️  Prometheus reload failed (check docker-compose --web.enable-lifecycle)"
echo ""

echo "🎉 Deployment complete!"
echo ""
echo "   App:          http://$ALB_DNS"
echo "   API docs:     http://$ALB_DNS/docs"
echo "   Prometheus:   http://localhost:9090"
echo "   Grafana:      http://localhost:3000"
echo "   Alertmanager: http://localhost:9093"
echo "   Portainer:    http://localhost:9000  (admin / ${PORTAINER_ADMIN_PASSWORD:-shimonvault2026})"
echo ""
echo "📋 Terraform outputs:"
cd "$TF_DIR"
terraform output
echo ""

# ── 16. (OPT-IN) Trigger the GitHub Actions deploy pipeline ───────────────────
# This is OFF by default. deploy.sh already ran `terraform apply` locally (blue);
# the CD pipeline runs its OWN `terraform apply` (green) on the SAME remote state.
# Firing both in one go gives you blue AND green running at once (free-tier burn),
# and the next plain deploy.sh would then tear green back down. So only enable
# this when you actually want to roll out a NEW app version on top of the infra:
#   SHIP=true bash scripts/deploy.sh
# (For day-to-day code deploys, prefer:  bash scripts/ship.sh "your message")
if [ "${SHIP:-false}" = "true" ]; then
    echo ""
    echo "🚢  SHIP=true → triggering GitHub Actions CD pipeline..."
    cd "$REPO_ROOT"
    if command -v gh >/dev/null 2>&1; then
        gh workflow run cd.yml --ref main && \
            echo "   ✅ Pipeline triggered → https://github.com/mindmug2018-oss/shimon-vault/actions" || \
            echo "   ⚠️  Could not trigger. Is gh authenticated (gh auth login) and is workflow_dispatch in cd.yml?"
    else
        echo "   ⚠️  GitHub CLI (gh) not installed. Either install it, or just: git push origin main"
    fi
fi
