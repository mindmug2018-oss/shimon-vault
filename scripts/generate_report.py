#!/usr/bin/env python3
"""
scripts/generate_report.py

Reads all incidents from DynamoDB and produces a human-readable
incident summary JSON, then uploads it to S3.
Run this after a demo session to create a clean evidence file
for the PPT and submission.

Usage:
    python3 scripts/generate_report.py
    python3 scripts/generate_report.py --since 2026-06-10
    python3 scripts/generate_report.py --output-local report.json
"""

import argparse
import json
import os
import subprocess
from datetime import datetime, timezone
from collections import defaultdict

try:
    import boto3
except ImportError:
    print("Install boto3: pip install boto3")
    import sys; sys.exit(1)


def get_terraform_output(key: str) -> str:
    result = subprocess.run(
        ["terraform", "-chdir=../terraform", "output", "-raw", key],
        capture_output=True, text=True
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def main():
    parser = argparse.ArgumentParser(description="Generate ShimonVault incident report")
    parser.add_argument("--since",        help="Filter incidents from date (YYYY-MM-DD)")
    parser.add_argument("--output-local", help="Also save to local file")
    args = parser.parse_args()

    region            = os.environ.get("AWS_REGION", "ap-northeast-2")
    incidents_table   = os.environ.get("DYNAMODB_INCIDENTS_TABLE",
                        get_terraform_output("dynamodb_incidents_table"))
    s3_bucket_reports = os.environ.get("S3_BUCKET_REPORTS",
                        get_terraform_output("s3_bucket_reports"))

    if not incidents_table:
        print("ERROR: Set DYNAMODB_INCIDENTS_TABLE env var or run from project root with terraform outputs")
        import sys; sys.exit(1)

    dynamo = boto3.resource("dynamodb", region_name=region)
    s3     = boto3.client("s3",         region_name=region)

    print(f"Reading incidents from DynamoDB table: {incidents_table}")

    table = dynamo.Table(incidents_table)
    response = table.scan()
    items = response["Items"]

    # Handle pagination
    while "LastEvaluatedKey" in response:
        response = table.scan(ExclusiveStartKey=response["LastEvaluatedKey"])
        items.extend(response["Items"])

    # Filter by date if requested
    if args.since:
        items = [i for i in items if i.get("timestamp", "") >= args.since]

    # Sort by timestamp descending
    items.sort(key=lambda x: x.get("timestamp", ""), reverse=True)

    # ── Build summary ─────────────────────────────────────────────────────────
    by_type = defaultdict(int)
    by_severity = defaultdict(int)
    blocked_ips = set()

    for item in items:
        by_type[item.get("incident_type", "unknown")] += 1
        by_severity[item.get("severity", "UNKNOWN")] += 1
        if ip := item.get("attacking_ip"):
            if ip != "N/A":
                blocked_ips.add(ip)

    report = {
        "report_generated_at": datetime.now(timezone.utc).isoformat(),
        "project":             "ShimonVault",
        "since":               args.since or "all time",
        "summary": {
            "total_incidents":    len(items),
            "by_type":            dict(by_type),
            "by_severity":        dict(by_severity),
            "unique_blocked_ips": len(blocked_ips),
            "blocked_ips":        sorted(blocked_ips),
        },
        "incidents": items,
    }

    report_json = json.dumps(report, indent=2, default=str)

    # ── Print summary to console ──────────────────────────────────────────────
    print(f"\n{'═'*50}")
    print(f"  ShimonVault — Incident Report")
    print(f"  Total incidents: {len(items)}")
    print(f"  Severity breakdown:")
    for sev, count in sorted(by_severity.items()):
        print(f"    {sev}: {count}")
    print(f"  Incident types:")
    for t, count in sorted(by_type.items()):
        print(f"    {t}: {count}")
    print(f"  Unique IPs blocked: {len(blocked_ips)}")
    print(f"{'═'*50}\n")

    # ── Save locally if requested ─────────────────────────────────────────────
    if args.output_local:
        with open(args.output_local, "w") as f:
            f.write(report_json)
        print(f"Report saved locally: {args.output_local}")

    # ── Upload to S3 ──────────────────────────────────────────────────────────
    if s3_bucket_reports:
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        s3_key = f"reports/incident-summary-{timestamp}.json"
        try:
            s3.put_object(
                Bucket=s3_bucket_reports,
                Key=s3_key,
                Body=report_json.encode("utf-8"),
                ContentType="application/json",
            )
            print(f"Report uploaded: s3://{s3_bucket_reports}/{s3_key}")
        except Exception as exc:
            print(f"S3 upload failed: {exc}")
    else:
        print("S3_BUCKET_REPORTS not set — skipping S3 upload")


if __name__ == "__main__":
    main()
