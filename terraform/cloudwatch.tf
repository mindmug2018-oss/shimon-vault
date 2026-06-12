# ─────────────────────────────────────────────────────────────────────────────
# terraform/cloudwatch.tf — CloudWatch Alarms
#
# These alarms watch metrics and fire SNS notifications when thresholds are hit.
# SNS then delivers alerts to Slack and triggers Lambda functions.
#
# Alarms defined here:
#   1. High CPU    → triggers ASG scale-out + Slack alert
#   2. CPU OK      → triggers ASG scale-in + "recovered" Slack alert
#   3. Instance down → triggers Lambda terminate + SNS alert
# ─────────────────────────────────────────────────────────────────────────────

# ─── HIGH CPU ALARM ──────────────────────────────────────────────────────────
# Fires when CPU > 80% for 2 consecutive 1-minute periods (2 minutes total).
# This triggers the ASG scale-out policy AND sends an SNS notification.
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${var.project_name}-high-cpu"
  alarm_description   = "CPU utilization above 80% for 2 minutes — scaling out"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2          # must be high for 2 consecutive periods
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60         # check every 60 seconds
  statistic           = "Average"
  threshold           = 80         # percent

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  # When alarm fires: trigger scale-out AND notify team
  alarm_actions = [
    aws_autoscaling_policy.scale_out.arn,
    aws_sns_topic.infra_alert.arn,
  ]

  # When alarm clears (CPU drops back): scale in AND send recovery notification
  ok_actions = [
    aws_autoscaling_policy.scale_in.arn,
    aws_sns_topic.infra_alert.arn,
  ]

  treat_missing_data = "notBreaching"  # missing data = not a problem

  tags = {
    Name    = "${var.project_name}-high-cpu"
    Project = var.project_name
  }
}

# ─── INSTANCE STATUS CHECK ALARM ─────────────────────────────────────────────
# Fires when an EC2 instance fails its status check (hardware/OS failure).
# This triggers ASG to terminate the bad instance and launch a replacement.
resource "aws_cloudwatch_metric_alarm" "instance_status_check" {
  alarm_name          = "${var.project_name}-instance-status-check"
  alarm_description   = "EC2 instance status check failed — instance may be dead"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0  # any failure triggers the alarm

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  alarm_actions = [aws_sns_topic.infra_alert.arn]

  tags = {
    Name    = "${var.project_name}-status-check"
    Project = var.project_name
  }
}

# ─── ALB 5xx ERROR ALARM ─────────────────────────────────────────────────────
# Fires when the app returns too many server errors (500, 502, 503, 504).
# This tells us the app is crashing, not just busy.
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project_name}-alb-5xx-errors"
  alarm_description   = "ALB returning too many 5xx errors — app may be down"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10  # more than 10 errors per minute is a problem

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  alarm_actions = [aws_sns_topic.infra_alert.arn]
  ok_actions    = [aws_sns_topic.infra_alert.arn]

  treat_missing_data = "notBreaching"

  tags = {
    Name    = "${var.project_name}-alb-5xx"
    Project = var.project_name
  }
}
