# terraform/current_ip.tf
#
# Auto-detects the public IP of wherever Terraform runs (proj-mgmt) so the
# bastion SSH rule always matches your current IP — even when your home IP
# changes. Use local.current_ip_cidr in the bastion ingress instead of
# var.your_ip_cidr.

data "http" "my_public_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  current_ip_cidr = "${chomp(data.http.my_public_ip.response_body)}/32"
}
