# terraform/asg.tf
#
# OPTION 1 CHANGE — the Auto Scaling Group is now a STANDALONE scale-out demo,
# fully decoupled from the blue/green production path.
#
# What changed and why:
#   1. Removed `target_group_arns = [aws_lb_target_group.blue.arn]`.
#      Previously the ASG registered its instance into the BLUE target group,
#      duplicating the standalone blue instance (two instances both serving
#      "blue") and making "retire blue" impossible — the ASG would always keep
#      one instance alive in blue. The blue/green pair (app_ec2_blue/green.tf)
#      is now the only thing in the ALB.
#   2. health_check_type changed "ELB" → "EC2". An ELB health check requires
#      membership in a target group; since the ASG is no longer in one, it now
#      uses plain EC2 status checks instead.
#   3. min_size / desired_capacity set to 0 so the ASG costs NOTHING at rest.
#      It still exists (launch template, scaling policies, CPU alarms) so it's
#      fully demonstrable for the rubric.
#
# How to run the auto-scaling demo (ACT 5):
#   aws autoscaling set-desired-capacity \
#     --auto-scaling-group-name shimonvault-asg --desired-capacity 1
#   # then SSH into the ASG instance via the bastion and generate CPU load, e.g.
#   #   sudo dnf install -y stress-ng && stress-ng --cpu 2 --timeout 300s
#   # CPUUtilization > 80% for 2 min → high_cpu_asg alarm → scale_out → 2 instances
#   # load stops → low_cpu_asg alarm → scale_in → back down
# (Want the load to flow through the ALB instead of stress-ng? Send me
#  security_groups.tf and I'll add a dedicated listener for the ASG.)

resource "aws_launch_template" "app" {
  name_prefix   = "${var.project_name}-app-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"
  key_name      = aws_key_pair.main.key_name

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = 30
      delete_on_termination = true
    }
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.app.id]
    subnet_id                   = aws_subnet.private.id
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  user_data = base64encode(templatefile("${path.module}/templates/app_user_data.sh.tpl", {
    project_name  = var.project_name
    app_version   = "0.1.0"
    container_tag = "blue"

    db_user      = var.db_username
    db_password  = var.db_password
    rds_endpoint = aws_db_instance.main.address
    rds_port     = aws_db_instance.main.port
    db_name      = var.db_name
    read_db_host = var.replica_tailscale_ip

    jwt_secret_key = var.jwt_secret_key

    aws_region     = var.aws_region
    aws_account_id = data.aws_caller_identity.current.account_id

    s3_bucket_docs    = aws_s3_bucket.docs.bucket
    s3_bucket_reports = aws_s3_bucket.reports.bucket

    dynamodb_audit_table     = aws_dynamodb_table.audit_log.name
    dynamodb_incidents_table = aws_dynamodb_table.incidents.name
    dynamodb_meetings_table  = aws_dynamodb_table.meetings.name

    sns_topic_security_alert      = aws_sns_topic.security_alert.arn
    sns_topic_credential_stuffing = aws_sns_topic.security_alert.arn
    sns_topic_infra_alert         = aws_sns_topic.infra_alert.arn
    sns_topic_meeting_reminders   = aws_sns_topic.meeting_reminders.arn

    lambda_block_ip_name = aws_lambda_function.block_ip.function_name

    slack_webhook_url  = var.slack_webhook_url
    telegram_bot_token = var.telegram_bot_token
    telegram_chat_id   = var.telegram_chat_id

    app_security_group_id = aws_security_group.app.id
    tailscale_auth_key    = var.tailscale_auth_key
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.project_name}-app-asg"
      Project = var.project_name
      Role    = "app"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "app" {
  name                = "${var.project_name}-asg"
  vpc_zone_identifier = [aws_subnet.private.id]
  min_size            = 0   # idle at rest — costs nothing until you demo it
  max_size            = 2
  desired_capacity    = 0   # bump to 1 to start the scale-out demo

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  # NOT in the blue target group anymore — standalone scale-out demo only.
  health_check_type         = "EC2"
  health_check_grace_period = 300

  tag {
    key                 = "Name"
    value               = "${var.project_name}-app-asg"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project_name
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "scale_out" {
  name                   = "${var.project_name}-scale-out"
  autoscaling_group_name = aws_autoscaling_group.app.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 120
}

resource "aws_cloudwatch_metric_alarm" "high_cpu_asg" {
  alarm_name          = "${var.project_name}-high-cpu-asg"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_out.arn]
}

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "${var.project_name}-scale-in"
  autoscaling_group_name = aws_autoscaling_group.app.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 300
}

resource "aws_cloudwatch_metric_alarm" "low_cpu_asg" {
  alarm_name          = "${var.project_name}-low-cpu-asg"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 5
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 30

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_in.arn]
}
