#!/usr/bin/env python3
"""Decodes Ambxst sidebar attachments JSON into local image files for Goose."""

import base64
import json
import sys
import time
from pathlib import Path

OUT_DIR = Path("/tmp/ambxst-goose-screenshots")
MIME_EXT = {
    "image/png": ".png",
    "image/jpeg": ".jpg",
    "image/jpg": ".jpg",
    "image/webp": ".webp",
    "image/gif": ".gif",
}


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"paths": []}))
        return

    src = Path(sys.argv[1])
    if not src.exists():
        print(json.dumps({"paths": []}))
        return

    try:
        items = json.loads(src.read_text(encoding="utf-8"))
    except Exception:
        print(json.dumps({"paths": []}))
        return

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    saved = []
    stamp = int(time.time() * 1000)

    if isinstance(items, list):
        for idx, item in enumerate(items):
            if isinstance(item, str):
                p = Path(item.replace("file://", ""))
                if p.exists():
                    saved.append(str(p))
                continue
            if not isinstance(item, dict):
                continue

            # Already a file path
            for k in ("path", "filePath", "file"):
                if item.get(k):
                    p = Path(str(item[k]).replace("file://", ""))
                    if p.exists():
                        saved.append(str(p))
                        break
            else:
                b64 = item.get("content_base64") or item.get("base64") or item.get("data") or ""
                if not b64:
                    continue
                mime = (item.get("mime") or item.get("mimeType") or item.get("type") or "image/png").lower()
                if b64.startswith("data:") and "," in b64:
                    header, b64 = b64.split(",", 1)
                    if ";" in header:
                        mime = header[5:].split(";", 1)[0].lower()
                ext = MIME_EXT.get(mime, ".png")
                out_path = OUT_DIR / f"upload-{stamp}-{idx}{ext}"
                try:
                    out_path.write_bytes(base64.b64decode(b64))
                    saved.append(str(out_path))
                except Exception:
                    continue

    try:
        src.unlink(missing_ok=True)
    except Exception:
        pass

    print(json.dumps({"paths": saved}, ensure_ascii=False))


if __name__ == "__main__":
    main()
