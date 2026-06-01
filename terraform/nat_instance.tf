# ─────────────────────────────────────────────────────────────
# NAT INSTANCE (open-source replacement for NAT Gateway)
#
# Why not NAT Gateway?
#   AWS NAT Gateway costs ~$33/month minimum. That's real money.
#   A t2.micro EC2 with iptables masquerade does the same job
#   for free (under free tier). This is a common cost-saving
#   technique used by real companies too.
#
# How it works:
#   1. NAT instance sits in the PUBLIC subnet (has internet access)
#   2. Private subnet instances route outbound traffic to NAT instance
#   3. NAT instance uses iptables to masquerade (rewrite source IP)
#      so the reply comes back to NAT instance, which forwards it
#      back to the private instance
# ─────────────────────────────────────────────────────────────

resource "aws_instance" "nat" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nat.id]
  key_name                    = var.key_pair_name

  # CRITICAL: source/destination check must be DISABLED for NAT to work
  # Normally AWS drops packets not destined for the instance itself.
  # NAT needs to forward traffic, so we disable this check.
  source_dest_check = false

  # user_data runs once when the instance first boots.
  # This script enables IP forwarding and sets up iptables masquerade.
  user_data = <<-EOF
    #!/bin/bash
    set -e

    # Enable IP forwarding (allows the instance to route packets)
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p

    # Install iptables-services so rules survive reboots
    yum install -y iptables-services

    # Get the network interface name (usually eth0 or ens5)
    INTERFACE=$(ip route | grep default | awk '{print $5}')

    # Masquerade rule: rewrite source IP of forwarded packets
    # to the NAT instance's public IP so replies come back here
    iptables -t nat -A POSTROUTING -o "$INTERFACE" -j MASQUERADE

    # Allow forwarded traffic in both directions
    iptables -A FORWARD -i "$INTERFACE" -j ACCEPT
    iptables -A FORWARD -o "$INTERFACE" -j ACCEPT

    # Save rules so they persist after reboot
    service iptables save
    systemctl enable iptables

    echo "NAT instance setup complete" >> /var/log/nat_setup.log
  EOF

  tags = {
    Name = "${var.project_name}-nat-instance"
    Role = "nat"
  }
}

# Add a route to the private route table:
# "All outbound traffic (0.0.0.0/0) → go through NAT instance"
resource "aws_route" "private_to_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id

  # This route depends on the NAT instance existing first
  depends_on = [aws_instance.nat]
}
