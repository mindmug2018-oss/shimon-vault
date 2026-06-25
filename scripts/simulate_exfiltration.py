#!/usr/bin/env python3
"""
scripts/simulate_exfiltration.py

Demo script — Act 4 of the presentation
Bulk-downloads all documents in rapid succession to trigger:
  1. The in-app rate limiter (10 requests / 60 seconds)
  2. The S3 bucket policy IP block
  3. A Lambda-generated incident report
  4. Slack + Telegram alert

Usage:
    python3 scripts/simulate_exfiltration.py [--base-url URL] [--token JWT]

Example:
    python3 scripts/simulate_exfiltration.py \
        --base-url https://shimonvault.cshimomoto.com \
        --token eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
"""

import argparse
import json
import os
import subprocess
import sys
import time
from typing import Optional

try:
    import requests
except ImportError:
    print("Install requests: pip install requests")
    sys.exit(1)


def get_alb_dns() -> str:
    """Read ALB DNS from terraform output."""
    result = subprocess.run(
        ["terraform", "-chdir=../terraform", "output", "-raw", "alb_dns_name"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        raise RuntimeError(f"terraform output failed: {result.stderr}")
    return result.stdout.strip()


def login(base_url: str, email: str, password: str) -> str:
    """Log in and return a JWT token."""
    resp = requests.post(
        f"{base_url}/auth/login",
        json={"email": email, "password": password},
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def list_documents(base_url: str, token: str) -> list[dict]:
    """Fetch the list of documents the authenticated user can access."""
    resp = requests.get(
        f"{base_url}/docs/list",
        headers={"Authorization": f"Bearer {token}"},
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()


def download_document(base_url: str, token: str, doc_id: str) -> int:
    """Try to download a document. Returns HTTP status code."""
    try:
        resp = requests.get(
            f"{base_url}/docs/download/{doc_id}",
            headers={"Authorization": f"Bearer {token}"},
            timeout=10,
            allow_redirects=False,
        )
        return resp.status_code
    except requests.exceptions.ConnectionError:
        return 0  # IP blocked
    except requests.exceptions.Timeout:
        return -1


def main():
    parser = argparse.ArgumentParser(description="Simulate bulk file exfiltration")
    parser.add_argument("--base-url", help="API base URL (reads from terraform output if not set)")
    parser.add_argument("--token",    help="JWT token (logs in with demo credentials if not set)")
    parser.add_argument("--email",    default="editor@shimonvault.internal")
    parser.add_argument("--password", default="demo-password-123")
    parser.add_argument("--delay",    type=float, default=0.05,
                        help="Seconds between requests (default 0.05 — fast)")
    args = parser.parse_args()

    base_url = args.base_url or f"https://{get_alb_dns()}"
    print(f"\n{'═'*55}")
    print(f"  ShimonVault — File Exfiltration Simulation")
    print(f"  Target: {base_url}")
    print(f"{'═'*55}\n")

    # ── Get auth token ─────────────────────────────────────────────────────
    token = args.token
    if not token:
        print(f"Logging in as {args.email}...")
        try:
            token = login(base_url, args.email, args.password)
            print("  ✅ Login successful\n")
        except Exception as exc:
            print(f"  ❌ Login failed: {exc}")
            sys.exit(1)

    # ── List all accessible documents ─────────────────────────────────────
    print("Fetching document list...")
    try:
        docs = list_documents(base_url, token)
        print(f"  Found {len(docs)} documents\n")
    except Exception as exc:
        print(f"  ❌ Failed to list documents: {exc}")
        sys.exit(1)

    # Always use fake IDs for the rate-limit demo — real docs would succeed
    # on the first request and stop before hitting the limit (only 1 real doc
    # typically exists). Fake UUIDs return 404 but still count toward the
    # per-IP rate limit, which is what we want to demonstrate.
    docs = [{"id": f"doc-{i:04d}"} for i in range(1, 51)]
    print(f"  (Using {len(docs)} fake IDs for rate-limit demo — triggers 429 at request #11)\n")

    print("⚠️  Starting bulk download — this will trigger the rate limiter.")
    print("   Watch Grafana → 'File access by user' panel spike.")
    print("   Watch Slack + Telegram for exfiltration alert.\n")
    input("Press Enter to start...")
    print()

    # ── Bulk download loop ─────────────────────────────────────────────────
    counts = {"success": 0, "rate_limited": 0, "forbidden": 0, "blocked": 0, "error": 0}
    rate_limit_hit = None

    for i, doc in enumerate(docs, 1):
        doc_id = doc.get("id") or doc.get("doc_id") or f"doc-{i}"
        status = download_document(base_url, token, doc_id)

        if status == 200 or status == 302:
            counts["success"] += 1
            print(f"[{i:3d}] doc={doc_id[:12]:12s} → ✅ {status}")

        elif status == 429:
            counts["rate_limited"] += 1
            if rate_limit_hit is None:
                rate_limit_hit = i
            print(f"[{i:3d}] doc={doc_id[:12]:12s} → 🚫 429 RATE LIMITED ← threshold reached")

        elif status == 403:
            counts["forbidden"] += 1
            print(f"[{i:3d}] doc={doc_id[:12]:12s} → 🔒 403 Forbidden")

        elif status == 0:
            counts["blocked"] += 1
            print(f"[{i:3d}] → 🔴 CONNECTION REFUSED — IP has been blocked")
            if counts["blocked"] >= 3:
                print("\n  Session is fully blocked. Stopping simulation.")
                break

        else:
            counts["error"] += 1
            print(f"[{i:3d}] doc={doc_id[:12]:12s} → ⚠️  {status}")

        time.sleep(args.delay)

    # ── Summary ───────────────────────────────────────────────────────────
    print(f"\n{'═'*55}")
    print(f"  Exfiltration simulation complete")
    print(f"  Successful downloads: {counts['success']}")
    if rate_limit_hit:
        print(f"  Rate limit triggered: at request #{rate_limit_hit}")
    print(f"  Rate limited:         {counts['rate_limited']}")
    print(f"  Forbidden (403):      {counts['forbidden']}")
    print(f"  IP blocked:           {counts['blocked']}")
    print(f"{'═'*55}\n")
    print("📊 Now check:")
    print("   Grafana → 'Exfiltration attempt' panel (should be amber)")
    print("   Slack / Telegram → exfiltration alert message")
    print("   S3 → shimonvault-reports → incidents/ → new JSON report")
    print("   DynamoDB → incidents table → new record\n")


if __name__ == "__main__":
    main()
