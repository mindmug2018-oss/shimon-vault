# terraform/app_ec2_blue.tf

resource "aws_instance" "app_blue" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name
  key_name               = aws_key_pair.main.key_name

  # al2023 defaults to 2GB root — far too small for Docker + Python image.
  # 20GB keeps us well inside free tier (30GB total allowance).
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/app_user_data.sh.tpl", {
    project_name  = var.project_name
    app_version   = "0.1.0"
    container_tag = "blue"

    db_user      = var.db_username
    db_password  = var.db_password
    rds_endpoint = aws_db_instance.main.address
    rds_port     = aws_db_instance.main.port
    db_name      = var.db_name
    read_db_host = var.onprem_tailscale_ip

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
  })

  tags = {
    Name    = "${var.project_name}-app-blue"
    Project = var.project_name
    Role    = "app"
    Color   = "blue"
  }
}
