"""
notification.py — Slack + Telegram notifier for Lambda functions.
Mirrors the pattern in app/services/notify_service.py but self-contained
since Lambda functions can't import from the FastAPI app's package tree.
"""
import os
import json
import urllib.request


def notify_slack(message: str) -> None:
    url = os.environ.get("SLACK_WEBHOOK_URL", "")
    if not url:
        print("[notify_slack] SLACK_WEBHOOK_URL not set — skipping")
        return
    data = json.dumps({"text": message}).encode("utf-8")
    req = urllib.request.Request(url, data=data,
                                  headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=5)


def notify_telegram(message: str) -> None:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")
    if not token or not chat_id:
        print("[notify_telegram] TELEGRAM_BOT_TOKEN/CHAT_ID not set — skipping")
        return
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    data = json.dumps({
        "chat_id": chat_id,
        "text": message,
        "parse_mode": "Markdown"
    }).encode("utf-8")
    req = urllib.request.Request(url, data=data,
                                  headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=5)


def notify_all(message: str) -> None:
    """Send to all notification channels. Never raise — log errors instead."""
    try:
        notify_slack(message)
    except Exception as e:
        print(f"[notify_all] Slack error: {e}")
    try:
        notify_telegram(message)
    except Exception as e:
        print(f"[notify_all] Telegram error: {e}")
