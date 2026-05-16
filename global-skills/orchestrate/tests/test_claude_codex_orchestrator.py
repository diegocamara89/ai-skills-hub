from __future__ import annotations

import json
import unittest
from pathlib import Path
from unittest import mock

import sys


SCRIPTS_DIR = Path(__file__).resolve().parents[1] / "scripts"
TEST_TMP_ROOT = Path(__file__).resolve().parent / ".tmp"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import claude_codex_orchestrator as orchestrator  # noqa: E402
from run_ai_cli import CallResult  # noqa: E402


class OrchestratorTests(unittest.TestCase):
    def test_build_default_config_provides_ten_profiles(self) -> None:
        config = orchestrator.build_default_config()

        self.assertEqual(len(config["profiles"]), 10)
        self.assertEqual(config["profiles"][0]["name"], "claude-a")
        self.assertEqual(config["profiles"][-1]["name"], "claude-j")

    def test_is_quota_error_detects_limit_message(self) -> None:
        self.assertTrue(
            orchestrator.is_quota_error(
                "",
                "Usage limit reached for this account.",
                ["usage limit reached"],
            )
        )
        self.assertFalse(orchestrator.is_quota_error("", "other failure", ["usage limit reached"]))

    def test_should_validate_on_high_risk_and_missing_tests(self) -> None:
        handoff = {
            "status": "ok",
            "task_summary": "Atualizar autenticacao",
            "changed_files": ["auth.py", "session.py"],
            "tests_run": [],
            "risks": ["security"],
            "analyst_summary": "Mudancas sensiveis",
            "next_action": "validar",
        }
        planner = {"force_validation": False}
        validation_cfg = {
            "max_changed_files_without_validation": 3,
            "require_tests_when_files_change": True,
            "always_validate_flags": ["security", "migration"],
        }

        use_validation, reasons = orchestrator.should_validate(handoff, planner, validation_cfg)

        self.assertTrue(use_validation)
        self.assertIn("high-risk", reasons)
        self.assertIn("tests-missing", reasons)

    def test_call_claude_with_failover_rotates_to_second_profile(self) -> None:
        TEST_TMP_ROOT.mkdir(parents=True, exist_ok=True)
        root = TEST_TMP_ROOT / "failover-case"
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

        self.assertEqual(result["profile"], "claude-b")
        self.assertEqual(len(result["attempts"]), 2)
        self.assertTrue(result["result"].ok)

    def test_normalize_handoff_fallback_uses_executor_output_excerpt(self) -> None:
        result = CallResult(
            ok=True,
            returncode=0,
            stdout="Implementei a tarefa e atualizei os arquivos principais.",
            stderr="",
            command=["codex"],
        )

        handoff = orchestrator.normalize_handoff(
            result,
            task_summary="Atualizar fluxo de login",
            planner_risks=["multi-file"],
        )

        self.assertEqual(handoff["status"], "ok")
        self.assertEqual(handoff["task_summary"], "Atualizar fluxo de login")
        self.assertEqual(handoff["changed_files"], [])
        self.assertIn("multi-file", handoff["risks"])
        self.assertIn("Implementei a tarefa", handoff["analyst_summary"])

    def test_route_task_can_use_claude_as_executor(self) -> None:
        config = {
            "state_file": str(TEST_TMP_ROOT / "route-state.json"),
            "quota_patterns": ["usage limit reached"],
            "profiles": [
                {"name": "claude-a", "config_dir": str(TEST_TMP_ROOT / "claude-a")},
            ],
            "commands": {"claude": {"path": ""}, "codex": {"path": ""}},
            "validation": {
                "max_changed_files_without_validation": 3,
                "require_tests_when_files_change": True,
                "always_validate_flags": ["security"],
            },
        }

        planner_call = {
            "profile": "claude-a",
            "quota_hit": False,
            "attempts": [{"profile": "claude-a", "ok": True}],
            "result": CallResult(
                ok=True,
                returncode=0,
                stdout='{"mode":"codex","execution_required":true,"task_summary":"Atualizar painel","execution_prompt":"implementar painel","risks":["multi-file"]}',
                stderr="",
                command=["claude", "planner"],
            ),
        }
        executor_call = {
            "profile": "claude-a",
            "quota_hit": False,
            "attempts": [{"profile": "claude-a", "ok": True}],
            "result": CallResult(
                ok=True,
                returncode=0,
                stdout='{"status":"ok","changed_files":["ui/claude-auth.html"],"tests_run":["python -m unittest"],"analyst_summary":"painel implementado"}',
                stderr="",
                command=["claude", "executor"],
            ),
        }

        with mock.patch.object(
            orchestrator,
            "call_claude_with_failover",
            side_effect=[planner_call, executor_call],
        ):
            result = orchestrator.route_task(
                "Atualizar painel",
                config,
                working_dir=str(TEST_TMP_ROOT),
                preferred_profile="claude-a",
                force_validation=False,
                skip_validation=True,
                timeout_claude_s=30,
                timeout_codex_s=30,
                simulate_quota_profiles=None,
                planner_model="opus",
                executor_provider="claude",
                executor_model="sonnet",
                validation_model="sonnet",
            )

        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["flow"]["executor"], "claude")
        self.assertEqual(result["handoff"]["changed_files"], ["ui/claude-auth.html"])
        self.assertEqual(result["executor_profile"], "claude-a")

    def test_rehydration_blocks_when_budget_exceeded(self) -> None:
        context = {
            "task_summary": "Implementar fluxo de failover",
            "current_goal": "Trocar de conta sem perder contexto",
            "constraints": ["Nao replayar transcript inteiro"],
            "relevant_files": [{"path": "big.txt", "reason": "debug", "content_mode": "summary_only"}],
            "token_budget_hint": 10,
        }

        result = orchestrator.build_rehydration_payload(context)

        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["blocking_reason"], "rehydration_budget_exceeded")

    def test_rehydration_drops_relevant_files_before_blocking(self) -> None:
        context = {
            "task_summary": "Implementar fluxo de failover",
            "current_goal": "Trocar de conta sem perder contexto",
            "constraints": ["Nao replayar transcript inteiro"],
            "relevant_files": [
                {
                    "path": "big.txt",
                    "reason": "debug",
                    "content_mode": "summary_only",
                    "summary": "x" * 200,
                }
            ],
            "token_budget_hint": 100,
        }

        result = orchestrator.build_rehydration_payload(context)

        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["payload"]["relevant_files"], [])

    def test_rehydration_zero_budget_does_not_expand_to_default(self) -> None:
        context = {
            "task_summary": "Implementar fluxo de failover",
            "current_goal": "Trocar de conta sem perder contexto",
            "constraints": ["Nao replayar transcript inteiro"],
            "relevant_files": [],
            "token_budget_hint": 0,
        }

        result = orchestrator.build_rehydration_payload(context)

        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["blocking_reason"], "rehydration_budget_exceeded")

    def test_plugin_failure_falls_back_to_cli_without_switching_account(self) -> None:
        result = orchestrator.normalize_executor_failure(
            backend_used="plugin",
            failure_kind="plugin_backend_failure",
            plugin_failed=True,
            cli_failed=False,
        )

        self.assertFalse(result["account_switch_recommended"])
        self.assertEqual(result["next_backend"], "cli")

    def test_cli_failure_after_plugin_failure_blocks_backend_without_switching_account(self) -> None:
        result = orchestrator.normalize_executor_failure(
            backend_used="cli",
            failure_kind="cli_backend_failure",
            plugin_failed=True,
            cli_failed=True,
        )

        self.assertFalse(result["account_switch_recommended"])
        self.assertEqual(result["next_backend"], "")

    def test_load_state_accepts_utf8_bom(self) -> None:
        TEST_TMP_ROOT.mkdir(parents=True, exist_ok=True)
        state_file = TEST_TMP_ROOT / "bom-state.json"
        payload = {"active_profile": "claude-a", "profiles": {}}
        state_file.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8-sig")

        loaded = orchestrator.load_state(str(state_file))

        self.assertEqual(loaded["active_profile"], "claude-a")


if __name__ == "__main__":
    unittest.main()
