# terraform/iam.tf — IAM Roles and Policies
#
# Note: data "aws_caller_identity" and data "aws_region" are declared
# ONCE in main.tf. Reference them here as:
#   data.aws_caller_identity.current.account_id
#   data.aws_region.current.name

# ─── 1. EC2 App Role ──────────────────────────────────────────────────────────

resource "aws_iam_role" "app_ec2" {
  name = "${var.project_name}-app-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.project_name}-app-ec2-role" }
}

resource "aws_iam_role_policy" "app_ec2_policy" {
  name = "${var.project_name}-app-ec2-policy"
  role = aws_iam_role.app_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject", "s3:GetObject", "s3:DeleteObject",
          "s3:ListBucket", "s3:GetObjectVersion", "s3:ListBucketVersions"
        ]
        Resource = [
          aws_s3_bucket.docs.arn,
          "${aws_s3_bucket.docs.arn}/*",
          aws_s3_bucket.reports.arn,
          "${aws_s3_bucket.reports.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem",
          "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan"
        ]
        Resource = [
          aws_dynamodb_table.audit_log.arn,
          "${aws_dynamodb_table.audit_log.arn}/index/*",
          aws_dynamodb_table.incidents.arn,
          "${aws_dynamodb_table.incidents.arn}/index/*",
          aws_dynamodb_table.meetings.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [
          aws_sns_topic.security_alert.arn,
          aws_sns_topic.infra_alert.arn,
          aws_sns_topic.meeting_reminders.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = "arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:${var.project_name}-block-ip"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones"]
        Resource = "*"
      }
    ]
  })
}

# Instance profile wraps the role so EC2 can use it
resource "aws_iam_instance_profile" "app" {
  name = "${var.project_name}-app-instance-profile"
  role = aws_iam_role.app_ec2.name
}

locals {
  app_instance_role_name = aws_iam_role.app_ec2.name
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ─── 2. Lambda Base Execution Role ────────────────────────────────────────────

resource "aws_iam_role" "lambda_exec" {
  name = "${var.project_name}-lambda-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.project_name}-lambda-exec-role" }
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ─── 3. block_ip Lambda ───────────────────────────────────────────────────────

resource "aws_iam_role_policy" "lambda_block_ip" {
  name = "${var.project_name}-lambda-block-ip-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DescribeSecurityGroups",
          "ec2:CreateNetworkAclEntry",
          "ec2:DescribeNetworkAcls"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = [aws_dynamodb_table.incidents.arn, aws_dynamodb_table.audit_log.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.security_alert.arn
      }
    ]
  })
}

# ─── 4. log_incident Lambda ───────────────────────────────────────────────────

resource "aws_iam_role_policy" "lambda_log_incident" {
  name = "${var.project_name}-lambda-log-incident-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.reports.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = [aws_dynamodb_table.incidents.arn, aws_dynamodb_table.audit_log.arn]
      }
    ]
  })
}

# ─── 5. validate_file Lambda ──────────────────────────────────────────────────

resource "aws_iam_role_policy" "lambda_validate_file" {
  name = "${var.project_name}-lambda-validate-file-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.docs.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.audit_log.arn
      }
    ]
  })
}

# ─── 6. meeting_notify + meeting_expire Lambda ────────────────────────────────

resource "aws_iam_role_policy" "lambda_meetings" {
  name = "${var.project_name}-lambda-meetings-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:PutItem", "dynamodb:Query"]
        Resource = aws_dynamodb_table.meetings.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.meeting_reminders.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.reports.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["events:DeleteRule", "events:RemoveTargets", "events:ListTargetsByRule"]
        Resource = "*"
      }
    ]
  })
}
