# ─────────────────────────────────────────────────────────────────────────────
# terraform/dynamodb.tf — DynamoDB Tables
#
# DynamoDB is serverless — no instance to pay for. You pay per read/write.
# Free tier: 25 GB storage + 25 read/write capacity units forever.
# We use PAY_PER_REQUEST (on-demand) mode so we never pre-provision capacity.
# For a student project with low traffic, on-demand costs nearly zero.
#
# Tables:
#   audit-log      → every platform action (written by AuditMiddleware)
#   incidents      → security incidents (written by Lambda + FastAPI)
#   meetings       → meeting state (for Lambda meeting_notify/expire)
#   tfstate-lock   → Terraform state locking (prevents concurrent applies)
# ─────────────────────────────────────────────────────────────────────────────

# ─── Audit Log ────────────────────────────────────────────────────────────────
resource "aws_dynamodb_table" "audit_log" {
  name         = "${var.project_name}-audit-log"
  billing_mode = "PAY_PER_REQUEST"  # on-demand, no capacity planning needed
  hash_key     = "id"               # partition key
  range_key    = "created_at"       # sort key — lets us query by time range

  attribute {
    name = "id"
    type = "S"  # String
  }

  attribute {
    name = "created_at"
    type = "S"  # ISO-8601 timestamp string, sortable lexicographically
  }

  # Global Secondary Index on event_type so we can query
  # "all login failures in the last hour" efficiently
  attribute {
    name = "event_type"
    type = "S"
  }

  global_secondary_index {
    name            = "event_type-index"
    hash_key        = "event_type"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  # Keep audit records for 90 days, then auto-delete
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = {
    Name    = "${var.project_name}-audit-log"
    Project = var.project_name
  }
}

# ─── Security Incidents ───────────────────────────────────────────────────────
resource "aws_dynamodb_table" "incidents" {
  name         = "${var.project_name}-incidents"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  range_key    = "created_at"

  attribute {
    name = "id"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  # Index on status ("open" / "resolved") for the Grafana incidents panel
  attribute {
    name = "status"
    type = "S"
  }

  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  tags = {
    Name    = "${var.project_name}-incidents"
    Project = var.project_name
  }
}

# ─── Meetings ─────────────────────────────────────────────────────────────────
# Used by Lambda functions (meeting_notify, meeting_expire) to track state.
resource "aws_dynamodb_table" "meetings" {
  name         = "${var.project_name}-meetings"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  tags = {
    Name    = "${var.project_name}-meetings"
    Project = var.project_name
  }
}

# ─── Terraform State Lock ─────────────────────────────────────────────────────
# Prevents two people (or two CI runs) from running terraform apply at the same time.
# This table must be created MANUALLY ONCE and never destroyed.
# Create it with: aws dynamodb create-table \
#   --table-name shimonvault-tfstate-lock \
#   --attribute-definitions AttributeName=LockID,AttributeType=S \
#   --key-schema AttributeName=LockID,KeyType=HASH \
#   --billing-mode PAY_PER_REQUEST \
#   --region ap-northeast-2
#
# Note: This table is NOT in this .tf file because we don't want
# terraform destroy to delete it. It is created manually once.
# Reference it in backend.tf as: dynamodb_table = "shimonvault-tfstate-lock"
