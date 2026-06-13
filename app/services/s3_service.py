# shimon-vault/app/services/s3_service.py

"""
services/s3_service.py — S3 file operations

All file interactions go through this service.
Never call boto3 S3 directly from routes — always use this module.

S3 bucket: config.S3_BUCKET_DOCS
All files are encrypted at rest (SSE-S3, configured in Terraform).
"""

import uuid
from datetime import datetime

import boto3
from botocore.exceptions import ClientError

import config

# Lazy-initialized S3 client
_s3 = None


def _get_s3():
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3", region_name=config.AWS_REGION)
    return _s3


def upload_to_s3(
    file_bytes: bytes,
    filename: str,
    content_type: str,
    owner_id: str,
) -> str:
    """
    Upload a file to S3.
    Returns the S3 key (path inside the bucket) for storage in RDS.

    Key format: {owner_id}/{date}/{uuid}-{filename}
    Example:    abc123/2026-06-02/550e8400-report.pdf

    Files are organized by owner then date so we can apply S3 lifecycle
    rules per-user if needed, and so keys are predictable in the audit log.
    """
    date_prefix = datetime.utcnow().strftime("%Y-%m-%d")
    unique_id = str(uuid.uuid4())[:8]
    s3_key = f"{owner_id}/{date_prefix}/{unique_id}-{filename}"

    _get_s3().put_object(
        Bucket=config.S3_BUCKET_DOCS,
        Key=s3_key,
        Body=file_bytes,
        ContentType=content_type,
        # SSE-S3 server-side encryption (Terraform also enforces this at bucket level)
        ServerSideEncryption="AES256",
    )
    return s3_key


def generate_presigned_url(s3_key: str, expires_seconds: int = 900) -> str:
    """
    Generate a pre-signed URL that gives temporary read access to one S3 object.
    The URL expires after expires_seconds (default: 15 minutes = 900 seconds).

    Pre-signed URLs work like this:
      1. We generate a URL that is cryptographically signed with our AWS credentials
      2. Anyone with the URL can GET the file for the next 15 minutes
      3. After 15 minutes the URL stops working — even if the client still has it
      4. The bucket remains fully private — only pre-signed URLs grant access

    This is how we prevent direct S3 access while still allowing file downloads.
    """
    url = _get_s3().generate_presigned_url(
        "get_object",
        Params={"Bucket": config.S3_BUCKET_DOCS, "Key": s3_key},
        ExpiresIn=expires_seconds,
    )
    return url


def delete_s3_file(s3_key: str) -> bool:
    """
    Delete a file from S3. Returns True on success, False if not found or error.
    Called when a document is soft-deleted via the API.
    """
    try:
        _get_s3().delete_object(Bucket=config.S3_BUCKET_DOCS, Key=s3_key)
        return True
    except ClientError as e:
        print(f"[s3_service] Failed to delete {s3_key}: {e}")
        return False


def list_object_versions(s3_key: str) -> list:
    """
    List all S3 versions of an object (requires versioning enabled on bucket).
    Used by GET /docs/{id}/versions to show version history.
    """
    try:
        response = _get_s3().list_object_versions(
            Bucket=config.S3_BUCKET_DOCS,
            Prefix=s3_key,
        )
        versions = response.get("Versions", [])
        return [
            {
                "version_id": v["VersionId"],
                "last_modified": v["LastModified"].isoformat(),
                "size_bytes": v["Size"],
                "is_latest": v["IsLatest"],
            }
            for v in versions
        ]
    except ClientError as e:
        print(f"[s3_service] Failed to list versions for {s3_key}: {e}")
        return []
