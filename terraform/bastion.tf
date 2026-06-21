# ─────────────────────────────────────────────────────────────
# BASTION HOST
#
# What is a Bastion Host?
#   A bastion is a "jump server" — the ONLY machine in your
#   infrastructure with a public IP that accepts SSH.
#   To SSH into any private subnet machine, you SSH into the
#   bastion first, then jump to the private instance from there.
#
# Why? Security:
#   - App EC2s and RDS have NO public IPs
#   - If an attacker wants in, they must get through the bastion first
#   - Bastion only accepts SSH from YOUR IP (var.your_ip_cidr)
#   - All other IPs are blocked at the Security Group level
# ─────────────────────────────────────────────────────────────

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"   # free tier eligible
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = aws_key_pair.main.key_name
  associate_public_ip_address = true

  # user_data: install Tailscale on the bastion so it joins your Tailnet
  # This lets Prometheus (on-prem) scrape the bastion's node_exporter too
  user_data = <<-EOF
    #!/bin/bash
    # Bastion bootstrap. Deliberately NO 'set -e': a failure in the optional
    # monitoring install must never abort boot. sshd must always come up.
    exec > /var/log/bastion_setup.log 2>&1

    # Join Tailscale so the bastion is reachable over the mesh even if the
    # public-IP / security-group path is wrong. --accept-routes=false per the
    # project Tailscale rule (never accept advertised subnets).
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up --authkey="${var.tailscale_auth_key}" --hostname="${var.project_name}-bastion" --accept-routes=false

    # Optional: node_exporter for Prometheus (best-effort, never fatal).
    useradd --no-create-home --shell /bin/false node_exporter || true
    cd /tmp
    wget -q https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz || true
    tar xzf node_exporter-1.7.0.linux-amd64.tar.gz || true
    cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/ || true
    chown node_exporter:node_exporter /usr/local/bin/node_exporter || true

    cat > /etc/systemd/system/node_exporter.service << 'UNIT'
    [Unit]
    Description=Prometheus Node Exporter
    After=network.target

    [Service]
    User=node_exporter
    ExecStart=/usr/local/bin/node_exporter
    Restart=always

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now node_exporter || true
    echo "Bastion setup complete"
  EOF

  tags = {
    Name = "${var.project_name}-bastion"
    Role = "bastion"
  }
}
