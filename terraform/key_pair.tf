# ─────────────────────────────────────────────────────────────
# KEY PAIR
#
# This imports your existing SSH public key into AWS so EC2
# instances can be configured to accept it.
#
# Before applying:
#   1. You need an SSH key pair on your Mac.
#      Check if you have one: ls ~/.ssh/id_rsa.pub
#      If not, create one: ssh-keygen -t rsa -b 4096 -C "shimonvault"
#
#   2. The key_pair_name variable must match what you named your
#      key pair when downloading from the AWS Console.
#      OR just use this Terraform resource to import your local key.
# ─────────────────────────────────────────────────────────────

resource "aws_key_pair" "main" {
  key_name   = "${var.project_name}-key"
  public_key = var.ssh_public_key  # ← was file("~/.ssh/...")
}
