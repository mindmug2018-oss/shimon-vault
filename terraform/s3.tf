# terraform/s3.tf — S3 Buckets
#
# data "aws_caller_identity" is declared in main.tf.
# Reference as: data.aws_caller_identity.current.account_id

# ─── Document Storage ─────────────────────────────────────────────────────────

resource "aws_s3_bucket" "docs" {
  bucket = "${var.project_name}-docs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true 
  tags = {
    Name    = "${var.project_name}-docs"
    Project = var.project_name
  }
}

resource "aws_s3_bucket_public_access_block" "docs" {
  bucket                  = aws_s3_bucket.docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "docs" {
  bucket = aws_s3_bucket.docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "docs" {
  bucket = aws_s3_bucket.docs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ─── Incident Reports ─────────────────────────────────────────────────────────

resource "aws_s3_bucket" "reports" {
  bucket = "${var.project_name}-reports-${data.aws_caller_identity.current.account_id}"
  force_destroy = true 
  tags = {
    Name    = "${var.project_name}-reports"
    Project = var.project_name
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id
  rule {
    id     = "delete-old-reports"
    status = "Enabled"
    filter {}   # empty filter = apply to all objects in bucket
    expiration {
      days = 30
    }
  }
}
