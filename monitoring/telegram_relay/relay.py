# monitoring/telegram_relay/relay.py
#
# Small relay that receives Alertmanager / Grafana webhooks and forwards them
# to Telegram. Runs as a container next to Prometheus/Grafana on proj-mgmt.
#
# Endpoints:
#   GET  /health          -> 200 {"status":"ok"}   (used by the Ansible check)
#   POST /telegram-relay  -> receives a webhook, sends each alert to Telegram

import os
import requests
from fastapi import FastAPI, Request

app = FastAPI(title="ShimonVault Telegram Relay")

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "")
TELEGRAM_API = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"


def send_to_telegram(text: str) -> None:
    """Send one message to Telegram. Never raise — a failed alert must not crash the relay."""
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        print("[relay] TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set")
        return
    try:
        resp = requests.post(
            TELEGRAM_API,
            json={"chat_id": TELEGRAM_CHAT_ID, "text": text, "parse_mode": "Markdown"},
            timeout=5,
        )
        if resp.status_code != 200:
            print(f"[relay] Telegram returned {resp.status_code}: {resp.text[:200]}")
    except Exception as exc:
        print(f"[relay] Telegram send failed: {exc}")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/telegram-relay")
async def relay(request: Request):
    try:
        payload = await request.json()
    except Exception:
        send_to_telegram("*ShimonVault*: received a non-JSON alert payload")
        return {"forwarded": 0}

    alerts = payload.get("alerts", [])

    # Not an Alertmanager-style payload (e.g. a plain Grafana webhook):
    # forward a short summary so nothing is lost.
    if not alerts:
        text = payload.get("message") or payload.get("title") or str(payload)[:500]
        send_to_telegram(f"*ShimonVault alert*\n{text}")
        return {"forwarded": 1}

    for a in alerts:
        status = a.get("status", "unknown").upper()
        labels = a.get("labels", {})
        ann = a.get("annotations", {})
        name = labels.get("alertname", "alert")
        instance = labels.get("instance", "")
        summary = ann.get("summary", "")
        desc = ann.get("description", "")
        emoji = "✅" if status == "RESOLVED" else "🚨"
        msg = (
            f"{emoji} *{name}* ({status})\n"
            f"{summary}\n{desc}\n"
            f"Instance: `{instance}`"
        )
        send_to_telegram(msg)

    return {"forwarded": len(alerts)}
