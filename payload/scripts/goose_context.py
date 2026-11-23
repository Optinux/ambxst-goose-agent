#!/usr/bin/env python3
"""Collects active-workspace Wayland window context and resolves directories for Goose."""

import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

TERMINAL_CLASSES = {
    "kitty", "alacritty", "foot", "wezterm", "org.wezfurlong.wezterm",
    "com.mitchellh.ghostty", "ghostty", "konsole", "gnome-terminal", "rio",
}

FILE_MANAGER_CLASSES = {
    "org.kde.dolphin", "dolphin", "org.gnome.nautilus", "nautilus",
    "thunar", "nemo", "pcmanfm", "pcmanfm-qt", "spacefm",
}

IGNORED_APPS = {"quickshell", "ambxst"}


def run_json(cmd):
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=1.5)
        text = out.decode("utf-8", errors="replace").strip()
        if not text:
            return None
        return json.loads(text)
    except Exception:
        return None


def get_compositor_state():
    """Return (active_ws, visible_ws_ids, active_win, all_windows)."""
    # Prefer hyprctl directly on Hyprland because activeworkspace.lastwindow and
    # client.focusHistoryID stay accurate even while layer-shell overlays hold focus.
    if os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        monitors = run_json(["hyprctl", "monitors", "-j"])
        active_ws_raw = run_json(["hyprctl", "activeworkspace", "-j"])
        active_win = run_json(["hyprctl", "activewindow", "-j"])
        clients = run_json(["hyprctl", "clients", "-j"])

        if isinstance(clients, list):
            visible_ws = []
            focused_mon_ws = None
            if isinstance(monitors, list):
                for m in monitors:
                    aws = m.get("activeWorkspace") or {}
                    ws_id = str(aws.get("id", ""))
                    if ws_id:
                        visible_ws.append(ws_id)
                        if m.get("focused"):
                            focused_mon_ws = {
                                "id": ws_id,
                                "name": str(aws.get("name") or ws_id),
                                "monitor": str(m.get("name") or ""),
                                "lastwindow": "",
                            }

            active_ws = focused_mon_ws or {"id": "", "name": "", "monitor": "", "lastwindow": ""}
            if isinstance(active_ws_raw, dict) and active_ws_raw.get("id") is not None:
                active_ws = {
                    "id": str(active_ws_raw.get("id")),
                    "name": str(active_ws_raw.get("name") or active_ws_raw.get("id")),
                    "monitor": str(active_ws_raw.get("monitor") or active_ws.get("monitor") or ""),
                    "lastwindow": str(active_ws_raw.get("lastwindow") or ""),
                }
                if active_ws["id"] not in visible_ws:
                    visible_ws.insert(0, active_ws["id"])

            return active_ws, visible_ws, (active_win if isinstance(active_win, dict) else {}), clients

    # Fallback: axctl (Hyprland / Niri / Mango)
    ax_windows = run_json(["axctl", "window", "list"])
    ax_active = run_json(["axctl", "window", "active"])
    ax_ws = run_json(["axctl", "workspace", "active"])
    ax_monitors = run_json(["axctl", "monitor", "list"])

    if isinstance(ax_windows, dict):
        ax_windows = ax_windows.get("windows") or ax_windows.get("result") or []
    if isinstance(ax_active, dict) and isinstance(ax_active.get("result"), dict):
        ax_active = ax_active["result"]
    if isinstance(ax_ws, dict) and isinstance(ax_ws.get("result"), dict):
        ax_ws = ax_ws["result"]
    if isinstance(ax_monitors, dict):
        ax_monitors = ax_monitors.get("monitors") or ax_monitors.get("result") or []

    if isinstance(ax_windows, list):
        active_ws = {"id": "", "name": "", "monitor": "", "lastwindow": ""}
        if isinstance(ax_ws, dict):
            ws_id = str(ax_ws.get("id") or ax_ws.get("name") or "")
            active_ws = {
                "id": ws_id,
                "name": str(ax_ws.get("name") or ws_id),
                "monitor": str(ax_ws.get("monitor") or ""),
                "lastwindow": "",
            }
        visible_ws = [active_ws["id"]] if active_ws["id"] else []
        if isinstance(ax_monitors, list):
            for m in ax_monitors:
                aws = m.get("active_workspace") or m.get("activeWorkspace")
                ws_id = str(aws.get("id") if isinstance(aws, dict) else (aws or ""))
                if ws_id and ws_id not in visible_ws:
                    visible_ws.append(ws_id)
        return active_ws, visible_ws, (ax_active if isinstance(ax_active, dict) else {}), ax_windows

    # Fallback: Niri CLI
    niri_windows = run_json(["niri", "msg", "-j", "windows"]) or []
    niri_active = run_json(["niri", "msg", "-j", "focused-window"]) or {}
    niri_wss = run_json(["niri", "msg", "-j", "workspaces"]) or []
    active_ws = {"id": "", "name": "", "monitor": "", "lastwindow": ""}
    visible_ws = []
    if isinstance(niri_wss, list):
        for w in niri_wss:
            ws_id = str(w.get("id") or "")
            if w.get("is_active") and ws_id:
                visible_ws.append(ws_id)
            if w.get("is_focused") and ws_id:
                active_ws = {
                    "id": ws_id,
                    "name": str(w.get("name") or w.get("idx") or ws_id),
                    "monitor": str(w.get("output") or ""),
                    "lastwindow": "",
                }
    return active_ws, visible_ws, (niri_active if isinstance(niri_active, dict) else {}), (
        niri_windows if isinstance(niri_windows, list) else []
    )


def build_proc_children():
    children = defaultdict(list)
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            stat = Path(f"/proc/{entry}/stat").read_text(errors="ignore")
            rparen = stat.rfind(")")
            if rparen == -1:
                continue
            fields = stat[rparen + 2:].split()
            ppid = int(fields[1])
            children[ppid].append(int(entry))
        except Exception:
            continue
    return children


def read_proc_cwd(pid):
    try:
        cwd = os.readlink(f"/proc/{int(pid)}/cwd")
        if os.path.isdir(cwd):
            return cwd
    except OSError:
        pass
    return None


def deepest_child_cwd(pid, proc_children, depth=0):
    if depth > 5:
        return read_proc_cwd(pid)
    for cpid in reversed(proc_children.get(int(pid), [])):
        cwd = deepest_child_cwd(cpid, proc_children, depth + 1)
        if cwd:
            return cwd
    return read_proc_cwd(pid)


def xdg_user_dirs():
    home = Path.home()
    mapping = {
        "home": str(home),
        home.name.lower(): str(home),
        "downloads": str(home / "Downloads"),
        "documents": str(home / "Documents"),
        "desktop": str(home / "Desktop"),
        "pictures": str(home / "Pictures"),
        "music": str(home / "Music"),
        "videos": str(home / "Videos"),
    }
    xdg_file = home / ".config" / "user-dirs.dirs"
    if xdg_file.exists():
        for line in xdg_file.read_text(errors="ignore").splitlines():
            m = re.match(r'^XDG_(\w+)_DIR="(.+)"$', line.strip())
            if m:
                path = m.group(2).replace("$HOME", str(home))
                if os.path.isdir(path):
                    mapping[Path(path).name.lower()] = path
                    mapping[m.group(1).lower()] = path
    return mapping


def resolve_dolphin_dbus():
    for qdbus in ("qdbus6", "qdbus"):
        try:
            services = subprocess.check_output(
                [qdbus], stderr=subprocess.DEVNULL, timeout=0.6
            ).decode()
            for svc in services.splitlines():
                svc = svc.strip()
                if svc.startswith("org.kde.dolphin-"):
                    url = subprocess.check_output(
                        [qdbus, svc, "/dolphin/Dolphin_1", "org.kde.dolphin.MainWindow.currentUrl"],
                        stderr=subprocess.DEVNULL,
                        timeout=0.6,
                    ).decode().strip()
                    if url.startswith("file://"):
                        path = url[7:]
                        if os.path.isdir(path):
                            return path
        except Exception:
            continue
    return None


def resolve_path_from_title(title, xdg_map):
    if not title:
        return None
    segment = re.split(r"\s+[—–-]\s+", title.strip())[0].strip()

    expanded = os.path.expanduser(segment)
    if os.path.isdir(expanded):
        return os.path.abspath(expanded)

    key = segment.lower()
    if key in xdg_map and os.path.isdir(xdg_map[key]):
        return xdg_map[key]

    home = Path.home()
    for base in (home, home / "Downloads", home / "Documents", home / "Desktop"):
        candidate = base / segment
        if candidate.is_dir():
            return str(candidate)

    return None


def normalize_window(win, xdg_map, proc_children):
    app_id = (win.get("app_id") or win.get("class") or win.get("initialClass") or "").strip()
    title = (win.get("title") or "").strip()
    pid = win.get("pid")

    ws_raw = win.get("workspace")
    if isinstance(ws_raw, dict):
        ws_id = str(ws_raw.get("id", ""))
        ws_name = str(ws_raw.get("name") or ws_id)
    elif ws_raw is not None:
        ws_id = str(ws_raw)
        ws_name = ws_id
    else:
        ws_id = str(win.get("workspace_id") or "")
        ws_name = ws_id

    cls_lower = app_id.lower()
    resolved_dir = None

    if cls_lower in FILE_MANAGER_CLASSES:
        if "dolphin" in cls_lower:
            resolved_dir = resolve_dolphin_dbus()
        if not resolved_dir:
            resolved_dir = resolve_path_from_title(title, xdg_map)
        if not resolved_dir and pid:
            resolved_dir = read_proc_cwd(pid)
    elif cls_lower in TERMINAL_CLASSES:
        if pid:
            resolved_dir = deepest_child_cwd(pid, proc_children)
        if not resolved_dir:
            resolved_dir = resolve_path_from_title(title, xdg_map)
    else:
        resolved_dir = resolve_path_from_title(title, xdg_map)
        if not resolved_dir and pid:
            cwd = read_proc_cwd(pid)
            if cwd and cwd != str(Path.home()):
                resolved_dir = cwd

    focus_rank = win.get("focusHistoryID")
    if not isinstance(focus_rank, int):
        focus_rank = 999999

    return {
        "id": str(win.get("id") or win.get("address") or ""),
        "app": app_id,
        "title": title,
        "pid": pid,
        "workspaceId": ws_id,
        "workspace": ws_name,
        "focused": bool(win.get("focused", win.get("is_focused", False))),
        "focusHistoryID": focus_rank,
        "resolvedDir": resolved_dir or "",
    }


def main():
    include_all = "--focused-only" not in sys.argv
    xdg_map = xdg_user_dirs()
    proc_children = build_proc_children()
    active_ws, visible_ws_ids, raw_active, raw_windows = get_compositor_state()

    active_ws_id = active_ws.get("id", "")
    last_win_addr = active_ws.get("lastwindow", "")
    if last_win_addr in ("0x0", "0x", ""):
        last_win_addr = ""

    normalized_all = []
    for w in raw_windows:
        if w.get("mapped") is False or w.get("hidden") is True:
            continue
        norm = normalize_window(w, xdg_map, proc_children)
        if not norm["app"] or norm["app"].lower() in IGNORED_APPS:
            continue
        norm["onActiveWorkspace"] = bool(active_ws_id and norm["workspaceId"] == active_ws_id)
        norm["onVisibleWorkspace"] = bool(norm["workspaceId"] in visible_ws_ids) if visible_ws_ids else norm["onActiveWorkspace"]
        normalized_all.append(norm)

    # Active-workspace windows ordered by most-recently-focused first
    active_ws_windows = [w for w in normalized_all if w["onActiveWorkspace"]] if active_ws_id else list(normalized_all)
    active_ws_windows.sort(key=lambda w: w["focusHistoryID"])

    # Determine the true focused window ON the current workspace
    focused = None
    if raw_active and (raw_active.get("class") or raw_active.get("app_id")):
        cand = normalize_window(raw_active, xdg_map, proc_children)
        if cand["app"].lower() not in IGNORED_APPS:
            if not active_ws_id or cand["workspaceId"] == active_ws_id:
                cand["focused"] = True
                cand["onActiveWorkspace"] = True
                cand["onVisibleWorkspace"] = True
                focused = cand

    if focused is None and last_win_addr:
        for w in active_ws_windows:
            if w["id"] == last_win_addr:
                w["focused"] = True
                focused = w
                break

    if focused is None and active_ws_windows:
        active_ws_windows[0]["focused"] = True
        focused = active_ws_windows[0]

    # Mark focused flag consistently across normalized_all
    for w in normalized_all:
        w["focused"] = bool(focused and w["id"] and w["id"] == focused["id"])

    # Only pick primaryDirectory from the CURRENT workspace (never leak another workspace's folder)
    primary_dir = ""
    if focused and focused.get("resolvedDir"):
        primary_dir = focused["resolvedDir"]
    else:
        for w in active_ws_windows:
            if w.get("resolvedDir"):
                primary_dir = w["resolvedDir"]
                break

    open_windows = normalized_all if include_all else active_ws_windows

    payload = {
        "activeWorkspace": {
            "id": active_ws.get("id", ""),
            "name": active_ws.get("name", ""),
            "monitor": active_ws.get("monitor", ""),
        },
        "visibleWorkspaces": visible_ws_ids,
        "focusedWindow": focused,
        "activeWorkspaceWindows": active_ws_windows,
        "primaryDirectory": primary_dir,
        "openWindows": open_windows,
    }
    print(json.dumps(payload, ensure_ascii=False))


if __name__ == "__main__":
    main()
