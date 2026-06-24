# ─────────────────────────────────────────────────────────────────────────────
# terraform/lambda.tf — Lambda Functions
#
# Five Lambda functions, each in their own directory under lambda/.
# Terraform zips the directory at apply time and uploads to Lambda.
#
# All five functions share the lambda_exec IAM role (defined in iam.tf),
# with per-function inline policies for least-privilege access.
#
# Triggers (who calls each Lambda):
#   block_ip        ← SNS topic: security-alert
#   log_incident    ← SNS topic: security-alert
#   validate_file   ← S3 PUT event on docs bucket
#   meeting_notify  ← EventBridge scheduled rule (per meeting)
#   meeting_expire  ← EventBridge scheduled rule (per meeting)
# ─────────────────────────────────────────────────────────────────────────────

# ─── Helper: zip each Lambda directory ───────────────────────────────────────
# data "archive_file" reads the source directory, zips it, and writes the ZIP
# to a temp location. The Lambda resource then uploads that ZIP to AWS.

data "archive_file" "block_ip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/block_ip"
  output_path = "${path.module}/../lambda/block_ip.zip"
}

data "archive_file" "log_incident" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/log_incident"
  output_path = "${path.module}/../lambda/log_incident.zip"
}

data "archive_file" "validate_file" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/validate_file"
  output_path = "${path.module}/../lambda/validate_file.zip"
}

data "archive_file" "meeting_notify" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/meeting_notify"
  output_path = "${path.module}/../lambda/meeting_notify.zip"
}

data "archive_file" "meeting_expire" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/meeting_expire"
  output_path = "${path.module}/../lambda/meeting_expire.zip"
}

# ─── Common environment variables for all Lambdas ────────────────────────────
locals {
  lambda_env = {
    PROJECT_NAME             = var.project_name
    AWS_ACCOUNT_ID_VAL       = data.aws_caller_identity.current.account_id
    DYNAMODB_AUDIT_TABLE     = aws_dynamodb_table.audit_log.name
    DYNAMODB_INCIDENTS_TABLE = aws_dynamodb_table.incidents.name
    DYNAMODB_MEETINGS_TABLE  = aws_dynamodb_table.meetings.name
    S3_BUCKET_REPORTS        = aws_s3_bucket.reports.id
    SNS_TOPIC_SECURITY_ARN   = aws_sns_topic.security_alert.arn
    SLACK_WEBHOOK_URL        = var.slack_webhook_url
    TELEGRAM_BOT_TOKEN       = var.telegram_bot_token
    TELEGRAM_CHAT_ID         = var.telegram_chat_id
    APP_SG_ID                = aws_security_group.app.id
  }
}

# ─── block_ip ─────────────────────────────────────────────────────────────────
resource "aws_lambda_function" "block_ip" {
  function_name    = "${var.project_name}-block-ip"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.block_ip.output_path
  source_code_hash = data.archive_file.block_ip.output_base64sha256
  timeout          = 30

  environment {
    variables = local.lambda_env
  }

  tags = { Name = "${var.project_name}-block-ip" }
}

# Allow SNS to invoke block_ip
resource "aws_lambda_permission" "block_ip_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.block_ip.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.security_alert.arn
}

resource "aws_sns_topic_subscription" "block_ip" {
  topic_arn = aws_sns_topic.security_alert.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.block_ip.arn
}

# ─── log_incident ─────────────────────────────────────────────────────────────
resource "aws_lambda_function" "log_incident" {
  function_name    = "${var.project_name}-log-incident"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.log_incident.output_path
  source_code_hash = data.archive_file.log_incident.output_base64sha256
  timeout          = 30

  environment {
    variables = local.lambda_env
  }

  tags = { Name = "${var.project_name}-log-incident" }
}

resource "aws_lambda_permission" "log_incident_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.log_incident.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.security_alert.arn
}

resource "aws_sns_topic_subscription" "log_incident" {
  topic_arn = aws_sns_topic.security_alert.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.log_incident.arn
}

# ─── log_incident: also subscribed to infra-alert topic ──────────────────────
resource "aws_lambda_permission" "log_incident_infra_sns" {
  statement_id  = "AllowInfraAlertSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.log_incident.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.infra_alert.arn
}

resource "aws_sns_topic_subscription" "log_incident_infra" {
  topic_arn = aws_sns_topic.infra_alert.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.log_incident.arn
}

# ─── validate_file ────────────────────────────────────────────────────────────
resource "aws_lambda_function" "validate_file" {
  function_name    = "${var.project_name}-validate-file"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.validate_file.output_path
  source_code_hash = data.archive_file.validate_file.output_base64sha256
  timeout          = 30

  environment {
    variables = local.lambda_env
  }

  tags = { Name = "${var.project_name}-validate-file" }
}

# Allow S3 to invoke validate_file when a new object is uploaded
resource "aws_lambda_permission" "validate_file_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.validate_file.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.docs.arn
}

# S3 notification: trigger validate_file on every PUT to the docs bucket
resource "aws_s3_bucket_notification" "docs_upload" {
  bucket = aws_s3_bucket.docs.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.validate_file.arn
    events              = ["s3:ObjectCreated:Put"]
  }

  depends_on = [aws_lambda_permission.validate_file_s3]
}

# ─── meeting_notify ───────────────────────────────────────────────────────────
resource "aws_lambda_function" "meeting_notify" {
  function_name    = "${var.project_name}-meeting-notify"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.meeting_notify.output_path
  source_code_hash = data.archive_file.meeting_notify.output_base64sha256
  timeout          = 30

  environment {
    variables = local.lambda_env
  }

  tags = { Name = "${var.project_name}-meeting-notify" }
}

resource "aws_lambda_permission" "meeting_notify_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.meeting_notify.function_name
  principal     = "events.amazonaws.com"
}

# ─── meeting_expire ───────────────────────────────────────────────────────────
resource "aws_lambda_function" "meeting_expire" {
  function_name    = "${var.project_name}-meeting-expire"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.meeting_expire.output_path
  source_code_hash = data.archive_file.meeting_expire.output_base64sha256
  timeout          = 30

  environment {
    variables = local.lambda_env
  }

  tags = { Name = "${var.project_name}-meeting-expire" }
}

resource "aws_lambda_permission" "meeting_expire_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.meeting_expire.function_name
  principal     = "events.amazonaws.com"
}

# ─── Outputs for use by the FastAPI app config ────────────────────────────────
output "lambda_block_ip_name" {
  value = aws_lambda_function.block_ip.function_name
}
output "lambda_meeting_notify_arn" {
  value = aws_lambda_function.meeting_notify.arn
}
output "lambda_meeting_expire_arn" {
  value = aws_lambda_function.meeting_expire.arn
}
