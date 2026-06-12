#!/bin/bash
# scripts/package_lambdas.sh
#
# Packages all Lambda functions into ZIP files.
# Terraform uses archive_file data sources to reference these ZIPs.
# Run this before terraform apply whenever Lambda code changes.
#
# Usage: bash scripts/package_lambdas.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAMBDA_DIR="$REPO_ROOT/lambda"
DIST_DIR="$REPO_ROOT/lambda/dist"
SHARED_DIR="$LAMBDA_DIR/shared"

mkdir -p "$DIST_DIR"

FUNCTIONS=(block_ip log_incident validate_file meeting_notify meeting_expire)

for fn in "${FUNCTIONS[@]}"; do
  echo "──────────────────────────────────────────"
  echo "Packaging lambda: $fn"
  SRC="$LAMBDA_DIR/$fn"
  ZIP="$DIST_DIR/${fn}.zip"

  # Create a temp staging directory
  STAGING=$(mktemp -d)
  cp "$SRC/handler.py" "$STAGING/"
  cp "$SHARED_DIR/notification.py" "$STAGING/"   # shared helper in same ZIP

  # Install dependencies (only if requirements.txt has non-comment lines)
  if grep -qv "^#" "$SRC/requirements.txt" 2>/dev/null; then
    pip install \
      --quiet \
      --target "$STAGING" \
      -r "$SRC/requirements.txt"
  fi

  # Create ZIP from staging directory
  (cd "$STAGING" && zip -q -r "$ZIP" .)
  rm -rf "$STAGING"

  SIZE=$(du -sh "$ZIP" | cut -f1)
  echo "  → $ZIP ($SIZE)"
done

echo "──────────────────────────────────────────"
echo "All Lambda packages built in $DIST_DIR"
echo ""
echo "Now run: cd terraform && terraform apply"
