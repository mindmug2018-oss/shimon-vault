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

echo "🚀 ShimonVault — Starting deployment..."
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

# ── 6. Wait for healthy ───────────────────────────────────────────────────────
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

# ── 7. Final curl check ───────────────────────────────────────────────────────
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

# ── 8. Update Ansible SSH config ──────────────────────────────────────────────
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

# ── 9. Start SSH agent ────────────────────────────────────────────────────────
if [ -z "$SSH_AUTH_SOCK" ]; then
    eval $(ssh-agent -s) > /dev/null
fi
ssh-add ~/.ssh/id_ed25519_shimonvault 2>/dev/null || true

# ── 10. Install node_exporter BEFORE verify so verify sees it ─────────────────
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

# ── 11. Configure PostgreSQL replication ──────────────────────────────────────
echo "9️⃣  Setting up PostgreSQL replication (RDS → proj-ubuntu01)..."
export DB_NAME=$(grep "^db_name" "$REPO_ROOT/terraform/terraform.tfvars" | cut -d'"' -f2 || echo "shimonvault")
export DB_USER=$(grep "^db_username" "$REPO_ROOT/terraform/terraform.tfvars" | cut -d'"' -f2 || echo "shimonvault")
export DB_PASSWORD=$(grep "^db_password" "$REPO_ROOT/terraform/terraform.tfvars" | cut -d'"' -f2 || echo "")
bash "$REPO_ROOT/scripts/setup_replica.sh" && \
    echo "   ✅ Replication configured" || \
    echo "   ⚠️  Replication setup failed — run manually: bash scripts/setup_replica.sh"
echo ""

# ── 12. Run Ansible verify ────────────────────────────────────────────────────
echo "🔟  Running Ansible stack verification..."
cd "$ANSIBLE_DIR"
ansible-playbook playbooks/verify_stack.yml 2>/dev/null | \
    grep -E "(PLAY|TASK|ok:|fatal:|✅|❌|RECAP)" || true
echo ""

# ── 13. Fetch Docker TLS certs and update Portainer ──────────────────────────
echo "1️⃣1️⃣  Fetching Docker TLS certs → updating Portainer..."
if [ "$BLUE_IP" != "unknown" ]; then
    bash "$REPO_ROOT/scripts/fetch_docker_certs.sh" "$BASTION_IP" "$BLUE_IP" && \
        echo "   ✅ Portainer ready" || \
        echo "   ⚠️  Cert fetch failed — retry: bash scripts/fetch_docker_certs.sh $BASTION_IP $BLUE_IP"
else
    echo "   ⚠️  Blue EC2 IP unknown — skipping"
fi
echo ""

# ── 14. Reload Prometheus ─────────────────────────────────────────────────────
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

# ── 15. (OPT-IN) Trigger the GitHub Actions deploy pipeline ───────────────────
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
