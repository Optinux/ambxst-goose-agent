#!/usr/bin/env python3
"""Captures a Wayland screenshot (focused monitor, active window, or all outputs) for Goose vision."""

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

OUT_DIR = Path("/tmp/ambxst-goose-screenshots")


def run_json(cmd):
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=1.5)
        return json.loads(out.decode("utf-8", errors="replace"))
    except Exception:
        return None


def cleanup_old(keep=10):
    try:
        files = sorted(OUT_DIR.glob("shot-*.png"), key=lambda p: p.stat().st_mtime, reverse=True)
        for old in files[keep:]:
            old.unlink(missing_ok=True)
    except Exception:
        pass


def get_focused_monitor():
    # Try axctl first
    monitors = run_json(["axctl", "monitor", "list"])
    if isinstance(monitors, dict):
        monitors = monitors.get("monitors") or monitors.get("result") or []
    if isinstance(monitors, list):
        for m in monitors:
            if m.get("focused") or m.get("active") or m.get("is_focused"):
                name = m.get("name") or m.get("id")
                if name:
                    return str(name)

    # Fallback to hyprctl
    hmon = run_json(["hyprctl", "monitors", "-j"])
    if isinstance(hmon, list):
        for m in hmon:
            if m.get("focused"):
                return str(m.get("name", ""))

    # Fallback to niri
    nmon = run_json(["niri", "msg", "-j", "focused-output"])
    if isinstance(nmon, dict) and nmon.get("name"):
        return str(nmon["name"])

    return ""


def get_active_window_geometry():
    win = run_json(["hyprctl", "activewindow", "-j"])
    if isinstance(win, dict):
        at = win.get("at")
        size = win.get("size")
        if (
            isinstance(at, list) and len(at) == 2
            and isinstance(size, list) and len(size) == 2
            and size[0] > 0 and size[1] > 0
        ):
            return f"{int(at[0])},{int(at[1])} {int(size[0])}x{int(size[1])}"
    return ""


def capture(mode):
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    cleanup_old()
    out_path = OUT_DIR / f"shot-{int(time.time() * 1000)}.png"

    grim = shutil.which("grim")
    if grim:
        attempts = []
        if mode == "window":
            geom = get_active_window_geometry()
            if geom:
                attempts.append([grim, "-g", geom, str(out_path)])
        if mode in ("monitor", "window"):
            mon = get_focused_monitor()
            if mon:
                attempts.append([grim, "-o", mon, str(out_path)])
        attempts.append([grim, str(out_path)])

        last_err = ""
        for cmd in attempts:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
            if proc.returncode == 0 and out_path.exists() and out_path.stat().st_size > 0:
                return {"ok": True, "path": str(out_path), "mode": mode, "tool": "grim"}
            last_err = proc.stderr.strip() or f"grim exited {proc.returncode}"
        return {"ok": False, "error": last_err}

    spectacle = shutil.which("spectacle")
    if spectacle:
        flag = "-a" if mode == "window" else ("-m" if mode == "monitor" else "-f")
        proc = subprocess.run(
            [spectacle, "-b", "-n", flag, "-o", str(out_path)],
            capture_output=True, text=True, timeout=6
        )
        if proc.returncode == 0 and out_path.exists():
            return {"ok": True, "path": str(out_path), "mode": mode, "tool": "spectacle"}

    return {"ok": False, "error": "No Wayland screenshot tool found. Install 'grim' (pacman -S grim)."}


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] in ("monitor", "window", "all") else "monitor"
    result = capture(mode)
    print(json.dumps(result, ensure_ascii=False))
    sys.exit(0 if result.get("ok") else 1)


if __name__ == "__main__":
    main()
