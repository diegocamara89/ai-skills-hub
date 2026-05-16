from __future__ import annotations

import unittest
from pathlib import Path

import sys


SCRIPTS_DIR = Path(__file__).resolve().parents[1] / "scripts"
TEST_TMP_ROOT = Path(__file__).resolve().parent / ".tmp-statusline"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import claude_statusline_collector as collector  # noqa: E402


class ClaudeStatuslineCollectorTests(unittest.TestCase):
    def test_build_snapshot_captures_official_fields(self) -> None:
        payload = {
            "session_id": "session-1",
            "cwd": "C:/repo",
            "workspace": {"current_dir": "C:/repo", "project_dir": "C:/repo"},
            "model": {"id": "claude-opus-4-6", "display_name": "Opus"},
            "cost": {
                "total_cost_usd": 1.25,
                "total_duration_ms": 120000,
                "total_api_duration_ms": 15000,
            },
            "context_window": {
                "total_input_tokens": 1000,
                "total_output_tokens": 250,
                "context_window_size": 200000,
                "used_percentage": 12.5,
                "remaining_percentage": 87.5,
                "current_usage": {
                    "input_tokens": 800,
                    "output_tokens": 200,
                    "cache_creation_input_tokens": 100,
                    "cache_read_input_tokens": 50,
                },
            },
            "rate_limits": {
                "five_hour": {"used_percentage": 33.3, "resets_at": 1738425600},
                "seven_day": {"used_percentage": 41.2, "resets_at": 1738857600},
            },
        }

        snapshot = collector.build_snapshot(payload, "claude-a", observed_at="2026-04-01T10:00:00Z")

        self.assertEqual(snapshot["profile"], "claude-a")
        self.assertEqual(snapshot["sessionId"], "session-1")
        self.assertEqual(snapshot["model"]["displayName"], "Opus")
        self.assertEqual(snapshot["cost"]["totalCostUsd"], 1.25)
        self.assertEqual(snapshot["contextWindow"]["currentUsage"]["cacheReadInputTokens"], 50)
        self.assertEqual(snapshot["rateLimits"]["fiveHour"]["usedPercentage"], 33.3)
        self.assertEqual(snapshot["rateLimitsSeenAt"], "2026-04-01T10:00:00Z")

    def test_merge_preserves_first_seen_and_last_known_rate_limits(self) -> None:
        previous = {
            "firstSeenAt": "2026-04-01T09:00:00Z",
            "lastSeenAt": "2026-04-01T09:10:00Z",
            "rateLimits": {
                "fiveHour": {"usedPercentage": 10.0, "resetsAt": 1},
                "sevenDay": {"usedPercentage": 20.0, "resetsAt": 2},
            },
            "rateLimitsSeenAt": "2026-04-01T09:10:00Z",
        }
        current = {
            "firstSeenAt": "2026-04-01T09:15:00Z",
            "lastSeenAt": "2026-04-01T09:15:00Z",
            "observedAt": "2026-04-01T09:15:00Z",
            "rateLimits": {"fiveHour": {}, "sevenDay": {}},
        }

        merged = collector.merge_session_snapshot(previous, current)

        self.assertEqual(merged["firstSeenAt"], "2026-04-01T09:00:00Z")
        self.assertEqual(merged["rateLimits"]["fiveHour"]["usedPercentage"], 10.0)
        self.assertEqual(merged["rateLimitsSeenAt"], "2026-04-01T09:10:00Z")

    def test_persist_snapshot_updates_session_and_latest_files(self) -> None:
        payload = {
            "session_id": "session-2",
            "model": {"id": "claude-sonnet-4-6", "display_name": "Sonnet"},
            "cost": {"total_cost_usd": 0.75},
            "context_window": {"used_percentage": 22.0},
        }

        state_root = TEST_TMP_ROOT / "persist-case"
        state_root.mkdir(parents=True, exist_ok=True)
        snapshot = collector.build_snapshot(payload, "claude-b", observed_at="2026-04-01T11:00:00Z")
        stored = collector.persist_snapshot(state_root, snapshot)

        session_path = collector.get_session_path(state_root, "claude-b", "session-2")
        latest_path = collector.get_latest_path(state_root, "claude-b")

        self.assertTrue(session_path.exists())
        self.assertTrue(latest_path.exists())
        self.assertEqual(stored["model"]["displayName"], "Sonnet")

    def test_format_statusline_includes_model_context_cost_and_limits(self) -> None:
        snapshot = {
            "model": {"displayName": "Opus"},
            "contextWindow": {"usedPercentage": 44.0},
            "cost": {"totalCostUsd": 2.5},
            "rateLimits": {
                "fiveHour": {"usedPercentage": 21.0},
                "sevenDay": {"usedPercentage": 54.0},
            },
        }

        line = collector.format_statusline(snapshot)

        self.assertIn("[Opus]", line)
        self.assertIn("ctx 44%", line)
        self.assertIn("$2.50", line)
        self.assertIn("5h 21%", line)
        self.assertIn("7d 54%", line)


if __name__ == "__main__":
    unittest.main()
