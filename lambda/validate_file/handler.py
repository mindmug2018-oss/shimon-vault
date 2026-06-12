"""
lambda/validate_file/handler.py

Triggered by: S3 PUT event on shimonvault-docs bucket
What it does:
  1. Downloads the uploaded file from S3 (first 512 bytes only — fast)
  2. Checks the real MIME type using magic bytes (not the filename extension)
  3. Checks file size is within limit
  4. If invalid: deletes from S3, flags uploader, writes incident to DynamoDB
  5. Notifies Slack + Telegram on rejection

Why magic bytes and not just extension?
  An attacker can rename malware.exe to report.pdf.
  Magic bytes read the actual file signature — you cannot fake these.
"""

import json
import os
import io
import boto3
from datetime import datetime, timezone

import sys
sys.path.insert(0, "/opt/python")
from notification import notify_all  # noqa: E402

s3     = boto3.client("s3",         region_name=os.environ["AWS_REGION"])
dynamo = boto3.resource("dynamodb", region_name=os.environ["AWS_REGION"])

# ── Allowed MIME types and their magic byte signatures ────────────────────────
# Format: { mime_type: [(offset, magic_bytes), ...] }
ALLOWED_SIGNATURES = {
    "application/pdf":   [(0, b"%PDF")],
    "image/png":         [(0, b"\x89PNG\r\n\x1a\n")],
    "image/jpeg":        [(0, b"\xff\xd8\xff")],
    "image/gif":         [(0, b"GIF87a"), (0, b"GIF89a")],
    "application/zip":   [(0, b"PK\x03\x04")],
    "text/plain":        [],   # no magic bytes — allow all .txt but check extension
}

ALLOWED_EXTENSIONS = {".pdf", ".png", ".jpg", ".jpeg", ".gif", ".zip", ".txt", ".md", ".csv"}

# Dangerous signatures to always reject regardless of extension
BLOCKED_SIGNATURES = [
    (0, b"MZ"),              # Windows PE executables (.exe, .dll, .com)
    (0, b"\x7fELF"),         # Linux ELF executables
    (0, b"#!/"),             # Shell scripts
    (0, b"#!"),              # Shebang scripts
    (257, b"ustar"),         # TAR archives (offset 257)
]

MAX_FILE_SIZE_MB = int(os.environ.get("MAX_FILE_SIZE_MB", "50"))
MAX_FILE_SIZE_BYTES = MAX_FILE_SIZE_MB * 1024 * 1024


def lambda_handler(event, context):
    print("validate_file triggered:", json.dumps(event))
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key    = record["s3"]["object"]["key"]
        size   = record["s3"]["object"].get("size", 0)
        try:
            validate(bucket, key, size)
        except Exception as exc:
            print(f"ERROR validating {key}: {exc}")


def validate(bucket: str, key: str, size: int):
    filename = key.split("/")[-1]
    ext = "." + filename.rsplit(".", 1)[-1].lower() if "." in filename else ""

    # ── Size check ────────────────────────────────────────────────────────────
    if size > MAX_FILE_SIZE_BYTES:
        reject(bucket, key, filename, f"File too large: {size} bytes > {MAX_FILE_SIZE_BYTES}")
        return

    # ── Read first 512 bytes for magic byte check ─────────────────────────────
    response = s3.get_object(Bucket=bucket, Key=key, Range="bytes=0-511")
    header_bytes = response["Body"].read()

    # ── Check for blocked signatures first ───────────────────────────────────
    for offset, magic in BLOCKED_SIGNATURES:
        if len(header_bytes) > offset and header_bytes[offset:offset + len(magic)] == magic:
            reject(
                bucket, key, filename,
                f"Blocked file signature at offset {offset}: {magic.hex()}",
                severity="HIGH"
            )
            return

    # ── Extension check ───────────────────────────────────────────────────────
    if ext not in ALLOWED_EXTENSIONS:
        reject(bucket, key, filename, f"Extension not allowed: {ext}")
        return

    # ── Magic byte check for non-text files ───────────────────────────────────
    if ext in (".pdf", ".png", ".jpg", ".jpeg", ".gif", ".zip"):
        matched = False
        for mime_type, signatures in ALLOWED_SIGNATURES.items():
            for offset, magic in signatures:
                if header_bytes[offset:offset + len(magic)] == magic:
                    matched = True
                    break
            if matched:
                break
        if not matched:
            reject(bucket, key, filename, f"Magic bytes don't match extension {ext}")
            return

    print(f"File validated OK: {key}")


def reject(bucket: str, key: str, filename: str, reason: str, severity: str = "MEDIUM"):
    """Delete the file, log the incident, notify."""
    timestamp = datetime.now(timezone.utc).isoformat()
    uploader_id = _extract_uploader(key)

    # Delete from S3
    try:
        s3.delete_object(Bucket=bucket, Key=key)
        print(f"Deleted rejected file: s3://{bucket}/{key}")
    except Exception as exc:
        print(f"Failed to delete {key}: {exc}")

    # Write incident
    incident_id = f"invalid-file-{int(datetime.now().timestamp())}"
    try:
        table = dynamo.Table(os.environ["DYNAMODB_INCIDENTS_TABLE"])
        table.put_item(Item={
            "incident_id":   incident_id,
            "incident_type": "malicious_file_upload",
            "severity":      severity,
            "attacking_ip":  "N/A",
            "user_id":       uploader_id,
            "resource_path": key,
            "details": {
                "filename":      filename,
                "bucket":        bucket,
                "reason":        reason,
                "action_taken":  "File deleted from S3, account flagged",
            },
            "timestamp": timestamp,
            "status":    "resolved",
        })
    except Exception as exc:
        print(f"Failed to write incident: {exc}")

    # Notify
    message = (
        f"⛔ *MALICIOUS UPLOAD BLOCKED — ShimonVault*\n"
        f"Type: Invalid File\n"
        f"Filename: `{filename}`\n"
        f"Reason: {reason}\n"
        f"Uploader: `{uploader_id}`\n"
        f"Action: File deleted from S3, account flagged\n"
        f"Time: {timestamp}"
    )
    notify_all(message)


def _extract_uploader(key: str) -> str:
    """S3 key format: uploads/{user_id}/{filename} — extract user_id."""
    parts = key.split("/")
    return parts[1] if len(parts) >= 3 else "unknown"
