# ─────────────────────────────────────────────────────────────────────────────
# terraform/sns.tf — SNS Topics
#
# SNS is the "hub" of our alert routing:
#   CloudWatch alarm fires → SNS topic → email + Lambda + Slack
#
# Topics:
#   security-alert  → credential stuffing, access violations, exfiltration
#   infra-alert     → high CPU, instance down, DDoS, deployment events
#   meeting-reminders → Lambda meeting_notify sends here before meetings
# ─────────────────────────────────────────────────────────────────────────────

# ─── Security Alert Topic ─────────────────────────────────────────────────────
resource "aws_sns_topic" "security_alert" {
  name = "${var.project_name}-security-alert"

  tags = {
    Name    = "${var.project_name}-security-alert"
    Project = var.project_name
  }
}

# ─── Infrastructure Alert Topic ───────────────────────────────────────────────
resource "aws_sns_topic" "infra_alert" {
  name = "${var.project_name}-infra-alert"

  tags = {
    Name    = "${var.project_name}-infra-alert"
    Project = var.project_name
  }
}

# ─── Meeting Reminders Topic ──────────────────────────────────────────────────
resource "aws_sns_topic" "meeting_reminders" {
  name = "${var.project_name}-meeting-reminders"

  tags = {
    Name    = "${var.project_name}-meeting-reminders"
    Project = var.project_name
  }
}

# ─── Email Subscriptions ──────────────────────────────────────────────────────
# Your email receives all security and infra alerts.
# You must confirm the subscription by clicking the link in the email AWS sends.
#
# ⚠️  PLACEHOLDER: Replace "your-email@example.com" with your real email
#    in terraform.tfvars via the variable var.alert_email
resource "aws_sns_topic_subscription" "security_email" {
  topic_arn = aws_sns_topic.security_alert.arn
  protocol  = "email"
  endpoint  = var.alert_email  # set in terraform.tfvars — never hardcode
}

resource "aws_sns_topic_subscription" "infra_email" {
  topic_arn = aws_sns_topic.infra_alert.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
