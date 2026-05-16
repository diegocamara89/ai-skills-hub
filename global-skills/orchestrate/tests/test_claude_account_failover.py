from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS_DIR = Path(__file__).resolve().parents[1] / "scripts"
TEST_TMP_ROOT = Path(__file__).resolve().parent / ".tmp"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import claude_codex_orchestrator as orchestrator  # noqa: E402
from run_ai_cli import CallResult  # noqa: E402


class ClaudeAccountFailoverTests(unittest.TestCase):
    def test_classify_not_logged_in_as_auth_required(self) -> None:
        self.assertEqual(
            orchestrator.get_claude_failure_kind("Not logged in · Please run /login", "", 1),
            "auth_required",
        )

    def test_classify_rate_limit_as_rate_limited_transient(self) -> None:
        self.assertEqual(
            orchestrator.get_claude_failure_kind("rate limit exceeded", "", 1),
            "rate_limited_transient",
        )

    def test_classify_quota_as_quota_exhausted(self) -> None:
        self.assertEqual(
            orchestrator.get_claude_failure_kind("usage limit reached", "", 1),
            "quota_exhausted",
        )

    def test_classify_try_again_later_as_backend_unavailable(self) -> None:
        self.assertEqual(
            orchestrator.get_claude_failure_kind("Please try again later", "", 1),
            "backend_unavailable",
        )

    def test_classify_plain_15h_message_is_not_quota(self) -> None:
        self.assertEqual(
            orchestrator.get_claude_failure_kind("retry in 15h", "", 1),
            "local_host_failure",
        )

    def test_apply_profile_failure_marks_auth_required_and_logs_out(self) -> None:
        state = orchestrator.new_profile_runtime_state("claude-a", "C:/tmp/claude-a")
        state["loggedIn"] = True
        updated = orchestrator.apply_profile_failure(state, "auth_required")

        self.assertEqual(updated["state"], "auth_required")
        self.assertFalse(updated["loggedIn"])
        self.assertEqual(updated["lastFailureKind"], "auth_required")
        self.assertIsNotNone(updated["lastFailureAt"])

    def test_call_claude_with_failover_persists_exhausted_profile_state(self) -> None:
        TEST_TMP_ROOT.mkdir(parents=True, exist_ok=True)
        root = TEST_TMP_ROOT / "quota-state-case"
        root.mkdir(parents=True, exist_ok=True)
        state_file = root / "state.json"
        if state_file.exists():
            state_file.unlink()

        config = {
            "state_file": str(state_file),
            "quota_patterns": ["usage limit reached"],
            "profiles": [
                {"name": "claude-a", "config_dir": str(root / "claude-a")},
                {"name": "claude-b", "config_dir": str(root / "claude-b")},
            ],
            "commands": {"claude": {"path": ""}},
        }

        def fake_call_provider(provider, prompt, current_config, model=None, timeout_s=0, cwd=None, env=None):  # type: ignore[no-untyped-def]
            profile_dir = env["CLAUDE_CONFIG_DIR"]
            if profile_dir.endswith("claude-b"):
                return CallResult(
                    ok=True,
                    returncode=0,
                    stdout='{"mode":"codex","execution_required":true}',
                    stderr="",
                    command=["claude-b"],
                )
            return CallResult(
                ok=False,
                returncode=1,
                stdout="",
                stderr="usage limit reached",
                command=["claude-a"],
            )

        with mock.patch.object(orchestrator, "call_provider", side_effect=fake_call_provider):
            result = orchestrator.call_claude_with_failover(
                "planejar",
                config,
                timeout_s=30,
                preferred_profile="claude-a",
                allow_failover=True,
            )

        store = orchestrator.load_state(str(state_file))

        self.assertEqual(result["profile"], "claude-b")
        self.assertEqual(store["active_profile"], "claude-b")
        self.assertEqual(store["profiles"]["claude-a"]["state"], "exhausted")
        self.assertEqual(store["profiles"]["claude-a"]["lastFailureKind"], "quota_exhausted")
        self.assertEqual(store["profiles"]["claude-b"]["state"], "available")

    def test_profile_order_skips_known_unavailable_profiles_but_keeps_bootstrap_candidates(self) -> None:
        profiles = [
            {"name": "claude-a", "config_dir": "C:/tmp/claude-a"},
            {"name": "claude-b", "config_dir": "C:/tmp/claude-b"},
        ]
        state = {
            "active_profile": "claude-a",
            "profiles": {
                "claude-a": {
                    "profileId": "claude-a",
                    "configDir": "C:/tmp/claude-a",
                    "loggedIn": True,
                    "state": "exhausted",
                    "lastFailureKind": "quota_exhausted",
                    "lastFailureAt": "2026-04-03T00:00:00Z",
                }
            },
        }

        ordered = orchestrator.profile_order(profiles, state, preferred_profile="claude-a")

        self.assertEqual([item["name"] for item in ordered], ["claude-b"])

    def test_active_profile_returns_to_available_when_lease_expires(self) -> None:
        state = {
            "profileId": "claude-a",
            "configDir": "C:/tmp/claude-a",
            "state": "active",
            "leaseOwner": "task-123",
            "leaseExpiresAt": "2000-01-01T00:00:00Z",
            "loggedIn": True,
        }

        new_state = orchestrator.expire_lease_if_stale(state, now="2000-01-01T00:05:00Z")

        self.assertEqual(new_state["state"], "available")
        self.assertEqual(new_state["leaseOwner"], "")
        self.assertIsNone(new_state["leaseExpiresAt"])

    def test_profile_order_releases_stale_active_profile_before_selection(self) -> None:
        profiles = [
            {"name": "claude-a", "config_dir": "C:/tmp/claude-a"},
            {"name": "claude-b", "config_dir": "C:/tmp/claude-b"},
        ]
        state = {
            "active_profile": "claude-a",
            "profiles": {
                "claude-a": {
                    "profileId": "claude-a",
                    "configDir": "C:/tmp/claude-a",
                    "loggedIn": True,
                    "state": "active",
                    "leaseOwner": "task-123",
                    "leaseExpiresAt": "2000-01-01T00:00:00Z",
                },
                "claude-b": {
                    "profileId": "claude-b",
                    "configDir": "C:/tmp/claude-b",
                    "loggedIn": True,
                    "state": "available",
                },
            },
        }

        ordered = orchestrator.profile_order(
            profiles,
            state,
            preferred_profile="claude-a",
            now="2000-01-01T00:05:00Z",
        )

        self.assertEqual([item["name"] for item in ordered], ["claude-a", "claude-b"])
        self.assertEqual(state["profiles"]["claude-a"]["state"], "available")


if __name__ == "__main__":
    unittest.main()
