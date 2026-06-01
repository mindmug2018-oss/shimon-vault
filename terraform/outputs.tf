# ─────────────────────────────────────────────────────────────
# OUTPUTS
#
# These values are printed after "terraform apply" completes.
# Scripts use "terraform output -raw <name>" to read them
# instead of ever hardcoding IPs.
# ─────────────────────────────────────────────────────────────

output "bastion_public_ip" {
  description = "Public IP of Bastion — use this to SSH in"
  value       = aws_instance.bastion.public_ip
}

output "nat_private_ip" {
  description = "Private IP of NAT instance — used in route table"
  value       = aws_instance.nat.private_ip
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "Public subnet ID"
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "Private subnet ID"
  value       = aws_subnet.private.id
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "project_name" {
  description = "Project name prefix"
  value       = var.project_name
}

output "account_id" {
  description = "AWS Account ID"
  value       = local.account_id
}

output "ssh_command" {
  description = "SSH command to connect to Bastion"
  value       = "ssh -i ~/.ssh/id_ed25519_shimonvault ec2-user@${aws_instance.bastion.public_ip}"
}
