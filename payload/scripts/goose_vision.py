#!/usr/bin/env python3
"""Calls an OpenAI-compatible vision endpoint (e.g. LiteLLM) to analyze attached images."""

import base64
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"ok": False, "error": "missing request json"}))
        sys.exit(1)

    req_file = Path(sys.argv[1])
    try:
        cfg = json.loads(req_file.read_text(encoding="utf-8"))
    except Exception as e:
        print(json.dumps({"ok": False, "error": f"bad request json: {e}"}))
        sys.exit(1)
    finally:
        req_file.unlink(missing_ok=True)

    api_base = (cfg.get("apiBase") or "").rstrip("/")
    model = (cfg.get("model") or "").strip()
    api_key = (cfg.get("apiKey") or os.environ.get("OPENAI_API_KEY") or "sk-local").strip()
    prompt = (cfg.get("prompt") or "Describe this screenshot in detail.").strip()
    images = cfg.get("images") or []

    if not api_base or not model or not images:
        print(json.dumps({"ok": False, "error": "vision apiBase, model, and images are required"}))
        sys.exit(1)

    url = api_base if api_base.endswith("/chat/completions") else f"{api_base}/chat/completions"

    content = [
        {
            "type": "text",
            "text": (
                "Analyze the attached desktop screenshot(s) accurately and concisely for a Linux desktop agent. "
                "Extract visible text, error messages, file paths, UI state, and details relevant to the user's request:\n\n"
                + prompt
            ),
        }
    ]

    for img_path in images:
        p = Path(img_path)
        if not p.exists():
            continue
        mime = mimetypes.guess_type(str(p))[0] or "image/png"
        b64 = base64.b64encode(p.read_bytes()).decode("ascii")
        content.append({
            "type": "image_url",
            "image_url": {"url": f"data:{mime};base64,{b64}"},
        })

    if len(content) == 1:
        print(json.dumps({"ok": False, "error": "No readable image files found"}))
        sys.exit(1)

    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": 1024,
        "temperature": 0.2,
    }).encode("utf-8")

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    }

    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = json.loads(resp.read().decode("utf-8", errors="replace"))
        text = data["choices"][0]["message"]["content"]
        if isinstance(text, list):
            text = "\n".join(part.get("text", "") for part in text if isinstance(part, dict))
        print(json.dumps({"ok": True, "analysis": str(text).strip()}, ensure_ascii=False))
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")[:400]
        print(json.dumps({"ok": False, "error": f"Vision HTTP {e.code}: {err_body}"}))
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"ok": False, "error": f"Vision request failed: {e}"}))
        sys.exit(1)


if __name__ == "__main__":
    main()
