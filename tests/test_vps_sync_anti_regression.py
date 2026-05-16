#!/usr/bin/env python3
"""
Unit tests for vps_ai_auth_sync.needs_sync() anti-regression guard
and build_sync_plan() --only filter.

Invoked from Pester (VpsAuthSyncSelective.Tests.ps1) via subprocess so we can
exercise the real Python module imported from
~/Diego/VPS/Oracle/ClowdBot/scripts/.

Output: a single JSON object on stdout for every assertion. Exit 0 if every
case matches, exit 1 otherwise so the Pester wrapper can fail loudly.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
from pathlib import Path


def load_sync_module():
    script_path = Path(os.path.expanduser("~")) / "Diego" / "VPS" / "Oracle" / "ClowdBot" / "scripts" / "vps_ai_auth_sync.py"
    if not script_path.exists():
        raise SystemExit(f"sync_script_not_found:{script_path}")
    spec = importlib.util.spec_from_file_location("vps_ai_auth_sync", script_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    # Register before exec so @dataclass can look up the module in sys.modules
    # (Python 3.12 requirement: dataclasses._is_type dereferences sys.modules[cls.__module__]).
    sys.modules["vps_ai_auth_sync"] = module
    spec.loader.exec_module(module)
    return module


def run() -> int:
    mod = load_sync_module()
    ProviderState = mod.ProviderState
    needs_sync = mod.needs_sync
    build_sync_plan = mod.build_sync_plan

    cases = []

    # --- needs_sync anti-regression matrix ---
    # Case A: remote newer than local + 60s -> must NOT push (anti-regression)
    local_a = ProviderState(present=True, refresh_fingerprint="fp_local", expires=1_000_000_000_000, account_id="acc")
    remote_a = ProviderState(present=True, refresh_fingerprint="fp_remote_newer", expires=1_000_000_000_000 + 5 * 60_000, account_id="acc")
    res_a = needs_sync(local_a, remote_a)
    cases.append(("anti_regression_remote_newer", res_a, False))

    # Case B: remote expires exactly equal to local -> same token, no push
    local_b = ProviderState(present=True, refresh_fingerprint="fp_same", expires=1_000_000_000_000, account_id="acc")
    remote_b = ProviderState(present=True, refresh_fingerprint="fp_same", expires=1_000_000_000_000, account_id="acc")
    res_b = needs_sync(local_b, remote_b)
    cases.append(("equal_expires_same_fp_no_push", res_b, False))

    # Case C: remote older than local -> local fresher, push
    local_c = ProviderState(present=True, refresh_fingerprint="fp_local", expires=1_000_000_000_000 + 10 * 60_000, account_id="acc")
    remote_c = ProviderState(present=True, refresh_fingerprint="fp_remote", expires=1_000_000_000_000, account_id="acc")
    res_c = needs_sync(local_c, remote_c)
    cases.append(("local_newer_pushes", res_c, True))

    # Case D: remote absent, local present -> push
    local_d = ProviderState(present=True, refresh_fingerprint="fp", expires=1, account_id="acc")
    remote_d = ProviderState(present=False, refresh_fingerprint=None, expires=None, account_id=None)
    res_d = needs_sync(local_d, remote_d)
    cases.append(("remote_absent_pushes", res_d, True))

    # Case E: local absent -> never push
    local_e = ProviderState(present=False, refresh_fingerprint=None, expires=None, account_id=None)
    remote_e = ProviderState(present=True, refresh_fingerprint="fp", expires=1, account_id="acc")
    res_e = needs_sync(local_e, remote_e)
    cases.append(("local_absent_no_push", res_e, False))

    # --- build_sync_plan --only filter ---
    local_present = ProviderState(present=True, refresh_fingerprint="fp_l", expires=1, account_id="acc")
    remote_absent = ProviderState(present=False, refresh_fingerprint=None, expires=None, account_id=None)

    plan_claude = build_sync_plan(
        local_codex=local_present,
        remote_codex=remote_absent,
        local_claude=local_present,
        remote_claude=remote_absent,
        remote_openclaw_codex_ok=True,
        remote_openclaw_claude_ok=True,
        only="claude",
    )
    cases.append(("only_claude_blocks_codex_push", plan_claude.push_codex, False))
    cases.append(("only_claude_allows_claude_push", plan_claude.push_claude, True))

    plan_codex = build_sync_plan(
        local_codex=local_present,
        remote_codex=remote_absent,
        local_claude=local_present,
        remote_claude=remote_absent,
        remote_openclaw_codex_ok=True,
        remote_openclaw_claude_ok=True,
        only="codex",
    )
    cases.append(("only_codex_blocks_claude_push", plan_codex.push_claude, False))
    cases.append(("only_codex_allows_codex_push", plan_codex.push_codex, True))

    plan_both = build_sync_plan(
        local_codex=local_present,
        remote_codex=remote_absent,
        local_claude=local_present,
        remote_claude=remote_absent,
        remote_openclaw_codex_ok=True,
        remote_openclaw_claude_ok=True,
        only="both",
    )
    cases.append(("only_both_pushes_codex", plan_both.push_codex, True))
    cases.append(("only_both_pushes_claude", plan_both.push_claude, True))

    failures = [c for c in cases if c[1] != c[2]]
    report = {
        "passed": len(cases) - len(failures),
        "total": len(cases),
        "failures": [
            {"case": name, "got": got, "expected": expected}
            for name, got, expected in failures
        ],
    }
    print(json.dumps(report, ensure_ascii=False))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(run())
