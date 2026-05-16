from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, data: Any) -> None:
    ensure_dir(path.parent)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def append_log(path: Path, message: str) -> None:
    ensure_dir(path.parent)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"{now_iso()} {message}\n")


def as_int(value: Any, default: int = 0) -> int:
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return default


def as_float(value: Any, default: float = 0.0) -> float:
    if value is None:
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def as_text(value: Any, default: str = "") -> str:
    if value is None:
        return default
    return str(value)


def normalize_rate_window(window: Any) -> dict[str, Any]:
    if not isinstance(window, dict):
        return {}
    return {
        "usedPercentage": as_float(window.get("used_percentage"), 0.0),
        "resetsAt": as_int(window.get("resets_at"), 0),
    }


def normalize_current_usage(current_usage: Any) -> dict[str, int]:
    if not isinstance(current_usage, dict):
        return {}
    return {
        "inputTokens": as_int(current_usage.get("input_tokens")),
        "outputTokens": as_int(current_usage.get("output_tokens")),
        "cacheCreationInputTokens": as_int(current_usage.get("cache_creation_input_tokens")),
        "cacheReadInputTokens": as_int(current_usage.get("cache_read_input_tokens")),
    }


def build_snapshot(payload: dict[str, Any], profile_name: str, observed_at: str | None = None) -> dict[str, Any]:
    observed = observed_at or now_iso()
    model = payload.get("model") if isinstance(payload.get("model"), dict) else {}
    workspace = payload.get("workspace") if isinstance(payload.get("workspace"), dict) else {}
    cost = payload.get("cost") if isinstance(payload.get("cost"), dict) else {}
    context_window = payload.get("context_window") if isinstance(payload.get("context_window"), dict) else {}
    rate_limits = payload.get("rate_limits") if isinstance(payload.get("rate_limits"), dict) else {}
    output_style = payload.get("output_style") if isinstance(payload.get("output_style"), dict) else {}
    agent = payload.get("agent") if isinstance(payload.get("agent"), dict) else {}
    worktree = payload.get("worktree") if isinstance(payload.get("worktree"), dict) else {}

    return {
        "profile": profile_name,
        "sessionId": as_text(payload.get("session_id")) or "unknown-session",
        "observedAt": observed,
        "firstSeenAt": observed,
        "lastSeenAt": observed,
        "transcriptPath": as_text(payload.get("transcript_path")),
        "cwd": as_text(payload.get("cwd")),
        "workspace": {
            "currentDir": as_text(workspace.get("current_dir")),
            "projectDir": as_text(workspace.get("project_dir")),
        },
        "model": {
            "id": as_text(model.get("id")),
            "displayName": as_text(model.get("display_name")),
        },
        "version": as_text(payload.get("version")),
        "outputStyle": {"name": as_text(output_style.get("name"))},
        "agent": {"name": as_text(agent.get("name"))},
        "worktree": {
            "name": as_text(worktree.get("name")),
            "path": as_text(worktree.get("path")),
            "branch": as_text(worktree.get("branch")),
            "originalCwd": as_text(worktree.get("original_cwd")),
            "originalBranch": as_text(worktree.get("original_branch")),
        },
        "cost": {
            "totalCostUsd": as_float(cost.get("total_cost_usd")),
            "totalDurationMs": as_int(cost.get("total_duration_ms")),
            "totalApiDurationMs": as_int(cost.get("total_api_duration_ms")),
            "totalLinesAdded": as_int(cost.get("total_lines_added")),
            "totalLinesRemoved": as_int(cost.get("total_lines_removed")),
        },
        "contextWindow": {
            "totalInputTokens": as_int(context_window.get("total_input_tokens")),
            "totalOutputTokens": as_int(context_window.get("total_output_tokens")),
            "contextWindowSize": as_int(context_window.get("context_window_size")),
            "usedPercentage": as_float(context_window.get("used_percentage")),
            "remainingPercentage": as_float(context_window.get("remaining_percentage")),
            "currentUsage": normalize_current_usage(context_window.get("current_usage")),
        },
        "rateLimits": {
            "fiveHour": normalize_rate_window(rate_limits.get("five_hour")),
            "sevenDay": normalize_rate_window(rate_limits.get("seven_day")),
        },
        "rateLimitsSeenAt": observed if rate_limits else "",
        "exceeds200kTokens": bool(payload.get("exceeds_200k_tokens", False)),
    }


def merge_session_snapshot(previous: dict[str, Any] | None, current: dict[str, Any]) -> dict[str, Any]:
    if not previous:
        return current

    merged = dict(current)
    merged["firstSeenAt"] = as_text(previous.get("firstSeenAt")) or current["firstSeenAt"]
    merged["lastSeenAt"] = current["lastSeenAt"]

    previous_rate_limits = previous.get("rateLimits") if isinstance(previous.get("rateLimits"), dict) else {}
    current_rate_limits = current.get("rateLimits") if isinstance(current.get("rateLimits"), dict) else {}
    if not any(current_rate_limits.values()) and previous_rate_limits:
        merged["rateLimits"] = previous_rate_limits
        merged["rateLimitsSeenAt"] = as_text(previous.get("rateLimitsSeenAt"))
    elif current_rate_limits and any(current_rate_limits.values()):
        merged["rateLimitsSeenAt"] = current["observedAt"]
    else:
        merged["rateLimitsSeenAt"] = as_text(previous.get("rateLimitsSeenAt"))

    return merged


def get_profile_root(state_root: Path, profile_name: str) -> Path:
    return state_root / "profiles" / profile_name


def get_session_path(state_root: Path, profile_name: str, session_id: str) -> Path:
    return get_profile_root(state_root, profile_name) / "sessions" / f"{session_id}.json"


def get_latest_path(state_root: Path, profile_name: str) -> Path:
    return get_profile_root(state_root, profile_name) / "latest.json"


def persist_snapshot(state_root: Path, snapshot: dict[str, Any]) -> dict[str, Any]:
    profile_name = snapshot["profile"]
    session_id = snapshot["sessionId"]
    session_path = get_session_path(state_root, profile_name, session_id)
    latest_path = get_latest_path(state_root, profile_name)

    previous = read_json(session_path, None)
    merged = merge_session_snapshot(previous, snapshot)

    write_json(session_path, merged)
    write_json(latest_path, merged)
    return merged


def compact_percent(value: float) -> str:
    if float(value).is_integer():
        return str(int(value))
    return f"{value:.1f}".rstrip("0").rstrip(".")


def format_statusline(snapshot: dict[str, Any]) -> str:
    model = snapshot.get("model", {})
    context_window = snapshot.get("contextWindow", {})
    cost = snapshot.get("cost", {})
    rate_limits = snapshot.get("rateLimits", {})

    model_name = as_text(model.get("displayName")) or as_text(model.get("id")) or "Claude"
    used_pct = compact_percent(as_float(context_window.get("usedPercentage")))
    cost_usd = as_float(cost.get("totalCostUsd"))

    parts = [
        f"[{model_name}]",
        f"ctx {used_pct}%",
        f"${cost_usd:.2f}",
    ]

    five_hour = rate_limits.get("fiveHour") if isinstance(rate_limits.get("fiveHour"), dict) else {}
    seven_day = rate_limits.get("sevenDay") if isinstance(rate_limits.get("sevenDay"), dict) else {}
    if five_hour and five_hour.get("usedPercentage") is not None:
        parts.append(f"5h {compact_percent(as_float(five_hour.get('usedPercentage')))}%")
    if seven_day and seven_day.get("usedPercentage") is not None:
        parts.append(f"7d {compact_percent(as_float(seven_day.get('usedPercentage')))}%")

    return " | ".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description="Persist Claude Code statusLine snapshots by profile/session.")
    parser.add_argument("--profile", required=True, help="Claude profile name, e.g. claude-a")
    parser.add_argument("--state-root", required=True, help="Directory where usage snapshots are stored")
    args = parser.parse_args()

    state_root = Path(args.state_root)
    logs_root = state_root / "logs"
    raw_log_path = logs_root / f"{args.profile}-raw.jsonl"
    py_log_path = logs_root / f"{args.profile}-python.log"

    try:
        raw = sys.stdin.read()
        if raw.startswith("\ufeff"):
            raw = raw.lstrip("\ufeff")
        append_log(py_log_path, f"stdin-length={len(raw)}")
        if raw.strip():
            with raw_log_path.open("a", encoding="utf-8") as handle:
                handle.write(raw.rstrip() + "\n")

        payload = json.loads(raw)
        snapshot = build_snapshot(payload, args.profile)
        merged = persist_snapshot(state_root, snapshot)
        print(format_statusline(merged))
        return 0
    except Exception as exc:
        append_log(py_log_path, f"error={type(exc).__name__}: {exc}")
        raise


if __name__ == "__main__":
    raise SystemExit(main())
