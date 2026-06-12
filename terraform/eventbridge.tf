# ─────────────────────────────────────────────────────────────────────────────
# terraform/eventbridge.tf — AWS EventBridge
#
# EventBridge is a serverless scheduler. We use it to:
#   1. Trigger meeting_notify Lambda 10 minutes before each meeting starts
#   2. Trigger meeting_expire Lambda at meeting end time
#
# How it works:
#   When a meeting is created via POST /meetings/create:
#     → FastAPI calls eventbridge_service.schedule_meeting_notify(meeting_id, scheduled_at)
#     → That creates an EventBridge rule: "fire at scheduled_at - 10 minutes"
#     → EventBridge fires → Lambda reads meeting from DynamoDB → sends SNS reminder
#
# The rules are created DYNAMICALLY by the FastAPI app via boto3.
# This .tf file only creates the DEFAULT rules used for demo purposes.
# Per-meeting rules are managed by the app at runtime.
# ─────────────────────────────────────────────────────────────────────────────

# ─── EventBridge Event Bus ────────────────────────────────────────────────────
# We use the default event bus — no custom bus needed for this project.
# Custom buses cost nothing extra but add complexity we don't need.

# ─── Static demo rule: health check every 5 minutes ─────────────────────────
# This rule fires every 5 minutes and invokes a simple Lambda ping.
# It exists so the EventBridge integration shows up in the AWS console
# and you can demonstrate it's working even without a meeting scheduled.
resource "aws_cloudwatch_event_rule" "health_ping" {
  name                = "${var.project_name}-health-ping"
  description         = "Ping the meeting_notify Lambda every 5 minutes to keep it warm"
  schedule_expression = "rate(5 minutes)"
  state               = "ENABLED"

  tags = { Name = "${var.project_name}-health-ping" }
}

resource "aws_cloudwatch_event_target" "health_ping_target" {
  rule      = aws_cloudwatch_event_rule.health_ping.name
  target_id = "meeting-notify-warmup"
  arn       = aws_lambda_function.meeting_notify.arn

  # Pass a payload that tells the Lambda this is a ping, not a real meeting
  input = jsonencode({
    source     = "shimonvault.health-ping"
    meeting_id = "ping"
  })
}

# ─── IAM: allow EventBridge to invoke Lambda ──────────────────────────────────
# The per-meeting rules created by the FastAPI app also need this permission.
# The blanket permission in lambda.tf covers those dynamic rules too.
resource "aws_cloudwatch_event_target" "meeting_notify_default" {
  rule      = aws_cloudwatch_event_rule.health_ping.name
  target_id = "meeting-notify-warmup-2"
  arn       = aws_lambda_function.meeting_notify.arn

  input = jsonencode({ source = "warmup" })
}

# ─── Outputs for the FastAPI eventbridge_service.py ──────────────────────────
output "eventbridge_meeting_notify_lambda_arn" {
  description = "ARN passed to eventbridge_service when scheduling meeting reminders"
  value       = aws_lambda_function.meeting_notify.arn
}

output "eventbridge_meeting_expire_lambda_arn" {
  description = "ARN passed to eventbridge_service when scheduling meeting expiry"
  value       = aws_lambda_function.meeting_expire.arn
}
