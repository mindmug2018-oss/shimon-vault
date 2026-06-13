# terraform/security_group_rule_rds_relay.tf
#
# Lets on-prem machines (proj-mgmt, proj-ubuntu01) reach the app EC2's socat
# relay on port 5432 over the Tailscale mesh. The relay forwards to RDS, which
# is how the on-prem PostgreSQL replica subscribes to the RDS primary.
#
# NOTE: this is a SEPARATE rule resource. If your security_groups.tf defines the
# app SG with inline `ingress {}` blocks, Terraform will fight over this rule on
# every apply. If `terraform plan` shows it wanting to recreate this every time,
# send me security_groups.tf and I'll move it inline instead.

resource "aws_security_group_rule" "app_rds_relay" {
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  cidr_blocks       = ["100.64.0.0/10"] # Tailscale CGNAT range
  security_group_id = aws_security_group.app.id
  description       = "RDS relay (socat) over Tailscale for PostgreSQL replication"
}
