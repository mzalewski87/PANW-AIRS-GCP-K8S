#!/usr/bin/env python3
"""
AI Chatbot – AIRS Network Intercept Demo

Web application integrating with Vertex AI (Gemini).
Traffic is protected by Palo Alto Networks Prisma AIRS.

Localization: UI and system messages are loaded from i18n/<APP_LANG>.json.
The active language is selected with the APP_LANG environment variable
(default: "en"). To add a new language, drop a new <code>.json file in
the i18n/ directory and set APP_LANG=<code>. Note: APP_LANG is used
instead of LANG to avoid colliding with the POSIX locale variable.
"""

import os
import logging
import json
import random
from datetime import datetime
from pathlib import Path

from flask import Flask, request, jsonify, render_template
from flask_cors import CORS
import google.auth
import google.auth.transport.requests

# ─────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("ai-chatbot")

# ─────────────────────────────────────────────────────────────────────
# i18n loader
# ─────────────────────────────────────────────────────────────────────
I18N_DIR = Path(__file__).parent / "i18n"
DEFAULT_LANG = "en"


def load_translations(lang_code: str) -> dict:
    """Loads translations for the given language code, falls back to English."""
    lang_code = (lang_code or DEFAULT_LANG).lower()
    candidate = I18N_DIR / f"{lang_code}.json"
    if not candidate.exists():
        logger.warning(
            f"i18n: language '{lang_code}' not found, falling back to '{DEFAULT_LANG}'"
        )
        candidate = I18N_DIR / f"{DEFAULT_LANG}.json"
    with candidate.open(encoding="utf-8") as f:
        data = json.load(f)
    logger.info(f"i18n: loaded translations for '{data.get('_meta', {}).get('lang_code', lang_code)}'")
    return data


APP_LANG = os.getenv("APP_LANG", DEFAULT_LANG)
T = load_translations(APP_LANG)

# ─────────────────────────────────────────────────────────────────────
# Flask app
# ─────────────────────────────────────────────────────────────────────
app = Flask(__name__)
CORS(app, resources={r"/api/*": {"origins": "*"}})

# Configuration via env vars
GCP_PROJECT_ID = os.getenv("GCP_PROJECT_ID", "")
VERTEX_AI_LOCATION = os.getenv("VERTEX_AI_LOCATION", "us-central1")
VERTEX_AI_MODEL = os.getenv("VERTEX_AI_MODEL", "gemini-2.5-flash")
APP_PORT = int(os.getenv("APP_PORT", "8080"))
SYSTEM_PROMPT = os.getenv("SYSTEM_PROMPT", T["system"]["default_system_prompt"])


def call_gemini(prompt: str, history: list = None) -> str:
    """Calls the Gemini API (generativelanguage.googleapis.com) with Workload Identity."""
    import urllib.request as urlreq
    try:
        credentials, _ = google.auth.default(scopes=[
            'https://www.googleapis.com/auth/cloud-platform',
            'https://www.googleapis.com/auth/generative-language',
        ])
        auth_req_obj = google.auth.transport.requests.Request()
        credentials.refresh(auth_req_obj)

        logger.info(f"{T['system']['log_sending_prompt']} [{VERTEX_AI_MODEL}]: {prompt[:100]}...")

        url = f'https://generativelanguage.googleapis.com/v1beta/models/{VERTEX_AI_MODEL}:generateContent'
        payload = json.dumps({
            'contents': [{'parts': [{'text': prompt}]}]
        }).encode()

        req = urlreq.Request(url, data=payload, headers={
            'Authorization': f'Bearer {credentials.token}',
            'Content-Type': 'application/json',
            'x-goog-user-project': GCP_PROJECT_ID,
        })

        resp = urlreq.urlopen(req, timeout=30)
        result = json.loads(resp.read())
        answer = result['candidates'][0]['content']['parts'][0]['text']

        logger.info(f"{T['system']['log_response']}: {answer[:100]}...")
        return answer

    except Exception as e:
        logger.error(f"{T['system']['log_error_gemini']}: {e}")
        raise


@app.route("/", methods=["GET"])
def index():
    """Chatbot home page."""
    return render_template(
        "index.html",
        t=T,
        t_json=json.dumps(T),
        model=VERTEX_AI_MODEL,
        project=GCP_PROJECT_ID,
        location=VERTEX_AI_LOCATION,
    )


@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint."""
    return jsonify({
        "status": "healthy",
        "timestamp": datetime.utcnow().isoformat(),
        "service": "ai-chatbot",
        "model": VERTEX_AI_MODEL,
        "project": GCP_PROJECT_ID,
    }), 200


@app.route("/ready", methods=["GET"])
def ready():
    """Readiness check endpoint."""
    try:
        credentials, project = google.auth.default()
        return jsonify({"status": "ready", "project": project or GCP_PROJECT_ID}), 200
    except Exception as e:
        logger.warning(f"Readiness check failed: {e}")
        return jsonify({"status": "not ready", "error": str(e)}), 503


@app.route("/api/chat", methods=["POST"])
def chat():
    """
    Main chat endpoint.

    HTTP traffic (request/response) is intercepted and analysed by the AIRS
    VM-Series Network Intercept. Both the prompt and the model response are
    inspected by the AIRS engine.
    """
    try:
        data = request.get_json()

        if not data or "message" not in data:
            return jsonify({"error": T["system"]["missing_message_field"]}), 400

        user_message = data.get("message", "").strip()
        session_id = data.get("session_id", "default")
        history = data.get("history", [])

        if not user_message:
            return jsonify({"error": T["system"]["empty_message"]}), 400

        if len(user_message) > 10000:
            return jsonify({"error": T["system"]["message_too_long"]}), 400

        logger.info(f"{T['system']['log_chat_request']} [session={session_id}]: {user_message[:100]}")

        response_text = call_gemini(user_message, history)

        return jsonify({
            "response": response_text,
            "model": VERTEX_AI_MODEL,
            "session_id": session_id,
            "timestamp": datetime.utcnow().isoformat(),
            "airs_protected": True,
        }), 200

    except Exception as e:
        logger.error(f"{T['system']['log_chat_endpoint_error']}: {e}")
        return jsonify({
            "error": T["system"]["ai_error_short"],
            "details": str(e),
        }), 500


@app.route("/api/info", methods=["GET"])
def info():
    """Application configuration info (for demo)."""
    return jsonify({
        "app": "AI Chatbot – AIRS Network Intercept Demo",
        "version": "1.0",
        "language": T.get("_meta", {}).get("lang_code", APP_LANG),
        "model": VERTEX_AI_MODEL,
        "location": VERTEX_AI_LOCATION,
        "project": GCP_PROJECT_ID,
        "airs_protection": {
            "enabled": True,
            "mode": "Network Intercept",
            "firewall": "Palo Alto VM-Series",
            "inspection_points": [
                "User → VM-Series (untrust): prompt inspection",
                "VM-Series → GKE App (trust): validated traffic",
                "GKE App → VM-Series (trust): response inspection",
                "VM-Series → Vertex AI: AI query inspection",
                "Vertex AI → VM-Series → GKE: AI response inspection",
            ]
        },
        "timestamp": datetime.utcnow().isoformat(),
    }), 200


@app.route("/api/demo-attack", methods=["POST"])
def demo_attack():
    """
    Demo endpoint – sends a prompt that AIRS should block.
    Used during the webinar to demonstrate AIRS in action.
    """
    demo_prompt = random.choice(T["attack_prompts"])

    logger.warning(f"{T['system']['log_demo_attack']}: {demo_prompt[:50]}")

    try:
        response_text = call_gemini(demo_prompt)
        return jsonify({
            "demo": True,
            "attack_prompt": demo_prompt,
            "response": response_text,
            "note": T["system"]["demo_attack_note_allowed"],
        }), 200
    except Exception as e:
        return jsonify({
            "demo": True,
            "attack_prompt": demo_prompt,
            "blocked": True,
            "note": f"{T['system']['demo_attack_note_blocked_prefix']}{str(e)}",
        }), 403


if __name__ == "__main__":
    logger.info(f"{T['system']['boot_starting']}{APP_PORT}")
    logger.info(f"{T['system']['boot_project']}{GCP_PROJECT_ID}")
    logger.info(f"{T['system']['boot_model']}{VERTEX_AI_MODEL} @ {VERTEX_AI_LOCATION}")
    logger.info(T["system"]["boot_protection"])

    app.run(
        host="0.0.0.0",
        port=APP_PORT,
        debug=False,
        threaded=True,
    )
