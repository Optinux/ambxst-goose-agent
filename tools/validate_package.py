#!/usr/bin/env python3
"""Validate this Ambxst mod package before publishing.

Checks
  1. ambxst.mod.json and settings.json against Ambxst's JSON schemas
  2. every file referenced by the manifest exists and uses a safe relative path
  3. the changelog is valid UTF-8, <= 64 KiB and has a heading for the current version
  4. no private IP addresses, secrets or personal paths in the package (leak scan)
  5. (optional) the overlays and patches compose onto one or more Ambxst revisions

Usage
  python3 tools/validate_package.py --schemas ../Ambxst/docs/mods
  python3 tools/validate_package.py --schemas ../Ambxst/docs/mods --ambxst ../Ambxst
  python3 tools/validate_package.py --schemas ../Ambxst/docs/mods --ambxst ../Ambxst --rev origin/main

Requires: python3, `pip install jsonschema`, git (only for the patch check).
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SELF = Path(__file__).resolve()
SKIP_DIRS = {".git", "__pycache__", ".venv", "venv", "node_modules"}

LEAK_PATTERNS = [
    ("private IPv4 address",
     re.compile(r"\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}"
                r"|169\.254(?:\.\d{1,3}){2}|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])(?:\.\d{1,3}){2})\b")),
    ("OpenAI-style API key", re.compile(r"\bsk-(?!local\b)[A-Za-z0-9_-]{16,}")),
    ("GitHub token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}")),
    ("AWS access key id", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("private key block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("hard-coded credential",
     re.compile(r"(?i)\b(?:api[_-]?key|secret|token|password)\b\s*[:=]\s*[\"'][^\"'\s]{12,}[\"']")),
    ("personal home directory",
     re.compile(r"(?:/home/(?!user\b|username\b|you\b|me\b)[a-z_][a-z0-9_-]*/|/Users/[A-Za-z0-9._-]+/)")),
    ("email address",
     re.compile(r"\b[A-Za-z0-9._%+-]+@(?!example\.(?:com|org)\b)[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")),
]


class Report:
    def __init__(self):
        self.errors = 0
        self.warnings = 0

    def ok(self, msg):
        print(f"  ok    {msg}")

    def warn(self, msg):
        self.warnings += 1
        print(f"  WARN  {msg}")

    def error(self, msg):
        self.errors += 1
        print(f"  FAIL  {msg}")


def load_json(path, report):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        report.error(f"{path.name}: cannot parse ({exc})")
        return None


def safe_relative(path_str):
    p = Path(path_str)
    return bool(path_str) and not p.is_absolute() and ".." not in p.parts


def check_schemas(manifest, settings, schema_dir, report):
    print("[1] Schemas")
    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        report.error("python package 'jsonschema' is missing (pip install jsonschema)")
        return
    pairs = (("manifest.schema.json", manifest, "ambxst.mod.json"),
             ("settings.schema.json", settings, "settings.json"))
    for schema_name, doc, doc_name in pairs:
        schema_path = schema_dir / schema_name
        if not schema_path.exists():
            report.error(f"{schema_path} not found (use --schemas <Ambxst>/docs/mods)")
            continue
        if doc is None:
            continue
        instance = dict(doc)
        if doc_name == "settings.json":
            # Ambxst's backend accepts "$schema" in settings.json, but the published JSON
            # schema forgot to declare it (additionalProperties is false), so drop it here.
            instance.pop("$schema", None)
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        errors = sorted(Draft202012Validator(schema).iter_errors(instance), key=lambda e: list(e.path))
        if errors:
            for err in errors:
                report.error(f"{doc_name}: {'/'.join(map(str, err.path)) or '<root>'}: {err.message}")
        else:
            report.ok(f"{doc_name} matches {schema_name}")


def check_settings_rules(settings, report):
    """Mirror the extra rules Ambxst's backend applies to settings fields."""
    if not settings:
        return
    seen = set()
    for field in settings.get("fields", []):
        key, ftype, default = field.get("key"), field.get("type"), field.get("default")
        if key in seen:
            report.error(f"settings.json: duplicate key {key}")
        seen.add(key)
        lo, hi = field.get("minimum"), field.get("maximum")
        if ftype in ("integer", "number") and isinstance(default, (int, float)):
            if (lo is not None and default < lo) or (hi is not None and default > hi):
                report.error(f"settings.json: default of {key} is outside minimum/maximum")
        if ftype == "enum" and default not in [o.get("value") for o in field.get("options", [])]:
            report.error(f"settings.json: default of enum {key} is not one of its options")
    report.ok(f"{len(seen)} settings fields pass backend rules")


def check_references(manifest, report):
    print("[2] Referenced files")
    if not manifest:
        return
    refs = [manifest.get("changelog"), (manifest.get("settings") or {}).get("schema")]
    for op in manifest.get("operations", []):
        refs.append(op.get("source"))
        if op.get("type") == "overlay":
            if not safe_relative(op.get("target", "")):
                report.error(f"overlay target is not a safe relative path: {op.get('target')!r}")
    for ref in filter(None, refs):
        if not safe_relative(ref):
            report.error(f"unsafe path in manifest: {ref!r}")
        elif not (ROOT / ref).is_file():
            report.error(f"referenced file is missing: {ref}")
        else:
            report.ok(ref)


def check_changelog(manifest, report):
    print("[3] Changelog")
    if not manifest or not manifest.get("changelog"):
        report.warn("manifest has no changelog")
        return
    path = ROOT / manifest["changelog"]
    if not path.is_file():
        return  # already reported
    raw = path.read_bytes()
    if len(raw) > 64 * 1024:
        report.error("changelog is larger than 64 KiB")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        report.error("changelog is not valid UTF-8")
        return
    version = manifest.get("version", "")
    if re.search(rf"^##\s+v?{re.escape(version)}\b", text, re.M):
        report.ok(f"changelog has an entry for {version}")
    else:
        report.error(f"changelog has no '## {version}' heading")


def iter_package_files():
    for path in sorted(ROOT.rglob("*")):
        if path.is_dir() or any(part in SKIP_DIRS for part in path.relative_to(ROOT).parts):
            continue
        if path.resolve() == SELF:
            continue
        yield path


def check_leaks(report):
    print("[4] Leak scan")
    scanned = 0
    for path in iter_package_files():
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        scanned += 1
        for lineno, line in enumerate(text.splitlines(), 1):
            for label, pattern in LEAK_PATTERNS:
                if pattern.search(line):
                    report.error(f"{path.relative_to(ROOT)}:{lineno}: {label}")
    if report.errors == 0:
        report.ok(f"{scanned} text files scanned, nothing suspicious")


def git(*args, cwd, check=True):
    return subprocess.run(["git", *args], cwd=cwd, check=check, capture_output=True, text=True)


def check_patches(manifest, ambxst, revs, report):
    print("[5] Composition against Ambxst")
    if not manifest:
        return
    if not shutil.which("git"):
        report.error("git not found")
        return
    for rev in revs:
        tmp = Path(tempfile.mkdtemp(prefix="ambxst-compose-"))
        wt = tmp / "tree"
        try:
            added = git("worktree", "add", "--detach", str(wt), rev, cwd=ambxst, check=False)
            if added.returncode != 0:
                report.error(f"{rev}: cannot check out ({added.stderr.strip()})")
                continue
            short = git("rev-parse", "--short", "HEAD", cwd=wt).stdout.strip()
            failed = False
            for op in manifest.get("operations", []):
                src = ROOT / op["source"]
                if op["type"] == "overlay":
                    target = wt / op["target"]
                    if target.exists():
                        report.error(f"{rev} ({short}): overlay target already exists: {op['target']}")
                        failed = True
                        continue
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(src, target)
                    continue
                strict = git("apply", "--whitespace=error-all", str(src), cwd=wt, check=False)
                if strict.returncode == 0:
                    continue
                merged = git("apply", "--3way", str(src), cwd=wt, check=False)
                if merged.returncode == 0:
                    report.warn(f"{rev} ({short}): {op['source']} needed a 3-way merge")
                else:
                    report.error(f"{rev} ({short}): {op['source']} does not apply: "
                                 f"{(strict.stderr or merged.stderr).strip().splitlines()[0]}")
                    failed = True
            if not failed:
                report.ok(f"{rev} ({short}): all operations compose")
        finally:
            git("worktree", "remove", "--force", str(wt), cwd=ambxst, check=False)
            shutil.rmtree(tmp, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--schemas", type=Path, required=True,
                        help="directory with manifest.schema.json and settings.schema.json (Ambxst/docs/mods)")
    parser.add_argument("--ambxst", type=Path, help="Ambxst git checkout to compose the patches onto")
    parser.add_argument("--rev", action="append", default=[],
                        help="revision to check (repeatable); default: testedBaseCommits plus HEAD")
    args = parser.parse_args()

    report = Report()
    manifest = load_json(ROOT / "ambxst.mod.json", report)
    settings = load_json(ROOT / "settings.json", report)

    check_schemas(manifest, settings, args.schemas, report)
    check_settings_rules(settings, report)
    check_references(manifest, report)
    check_changelog(manifest, report)
    check_leaks(report)

    if args.ambxst:
        revs = args.rev or (manifest or {}).get("compatibility", {}).get("testedBaseCommits", []) + ["HEAD"]
        check_patches(manifest, args.ambxst.resolve(), list(dict.fromkeys(revs)), report)
    else:
        print("[5] Composition against Ambxst\n  skip  pass --ambxst <checkout> to test the patches")

    print(f"\n{report.errors} error(s), {report.warnings} warning(s)")
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main())
