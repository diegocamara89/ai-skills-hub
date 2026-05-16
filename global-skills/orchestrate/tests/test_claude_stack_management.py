from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import sys


SCRIPTS_DIR = Path(__file__).resolve().parents[1] / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import claude_codex_orchestrator as orchestrator  # noqa: E402


class ClaudeStackManagementTests(unittest.TestCase):
    def test_normalize_managed_settings_strips_proxy_env_and_sets_official_alias(self) -> None:
        settings = {
            "env": {
                "MAX_THINKING_TOKENS": "12000",
                "ANTHROPIC_BASE_URL": "http://127.0.0.1:8080",
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-6[1m]",
                "CLAUDE_CODE_SUBAGENT_MODEL": "claude-sonnet-4-6-thinking[1m]",
            },
            "model": "opusplan",
            "permissions": {"defaultMode": "auto"},
        }

        normalized = orchestrator.normalize_managed_settings(settings, default_model="opus[1m]")

        self.assertEqual(normalized["model"], "opus[1m]")
        self.assertEqual(normalized["env"]["MAX_THINKING_TOKENS"], "12000")
        self.assertNotIn("ANTHROPIC_BASE_URL", normalized["env"])
        self.assertNotIn("ANTHROPIC_DEFAULT_OPUS_MODEL", normalized["env"])
        self.assertNotIn("CLAUDE_CODE_SUBAGENT_MODEL", normalized["env"])

    def test_build_initial_stack_config_preserves_safe_profile_override_without_model_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base_dir = root / ".claude"
            profile_root = root / ".claude-profiles"
            profile_a = profile_root / "claude-a"
            profile_b = profile_root / "claude-b"
            base_dir.mkdir(parents=True, exist_ok=True)
            profile_a.mkdir(parents=True, exist_ok=True)
            profile_b.mkdir(parents=True, exist_ok=True)

            base_settings = {
                "env": {
                    "MAX_THINKING_TOKENS": "12000",
                    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-6[1m]",
                },
                "permissions": {"defaultMode": "bypassPermissions"},
                "model": "opusplan",
            }
            profile_a_settings = {
                "env": {
                    "MAX_THINKING_TOKENS": "12000",
                    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-7[1m]",
                },
                "permissions": {"defaultMode": "auto"},
                "model": "claude-opus-4-7[1m]",
            }

            (base_dir / "settings.json").write_text(json.dumps(base_settings), encoding="utf-8")
            (profile_a / "settings.json").write_text(json.dumps(profile_a_settings), encoding="utf-8")
            (profile_b / "settings.json").write_text(json.dumps(base_settings), encoding="utf-8")

            config = {
                "claude_base_dir": str(base_dir),
                "profile_root": str(profile_root),
                "state_file": str(root / ".claude-orchestrator" / "state.json"),
                "profiles": [
                    {"name": "claude-a", "config_dir": str(profile_a)},
                    {"name": "claude-b", "config_dir": str(profile_b)},
                ],
                "commands": {"claude": {"path": ""}},
            }

            with mock.patch.object(orchestrator, "discover_official_claude_runtime", return_value="C:/tools/claude.exe"):
                stack = orchestrator.build_initial_stack_config(config)

        profiles = {profile["name"]: profile for profile in stack["profiles"]}
        self.assertEqual(stack["official"]["runtime_path"], "C:/tools/claude.exe")
        self.assertEqual(stack["official"]["settings_baseline"]["model"], "opus[1m]")
        self.assertEqual(
            profiles["claude-a"]["settings_override"],
            {"permissions": {"defaultMode": "auto"}},
        )
        self.assertEqual(profiles["claude-b"]["settings_override"], {})

    def test_sync_managed_profile_files_preserves_profile_state_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base_dir = root / ".claude"
            profile_dir = root / ".claude-profiles" / "claude-a"
            backup_root = root / "backups"
            base_dir.mkdir(parents=True, exist_ok=True)
            profile_dir.mkdir(parents=True, exist_ok=True)

            credentials_file = profile_dir / ".credentials.json"
            claude_state_file = profile_dir / ".claude.json"
            credentials_file.write_text('{"token":"secret"}', encoding="utf-8")
            claude_state_file.write_text('{"session":"keep"}', encoding="utf-8")

            before_credentials = orchestrator.compute_sha256(credentials_file)
            before_claude_state = orchestrator.compute_sha256(claude_state_file)

            stack = {
                "claude_base_dir": str(base_dir),
                "official": {
                    "settings_baseline": {
                        "env": {"MAX_THINKING_TOKENS": "12000"},
                        "permissions": {"defaultMode": "bypassPermissions"},
                        "model": "opus[1m]",
                    },
                    "trusted_folders_baseline": {},
                },
                "profiles": [
                    {
                        "name": "claude-a",
                        "config_dir": str(profile_dir),
                        "settings_override": {"permissions": {"defaultMode": "auto"}},
                        "trusted_folders_override": {},
                    }
                ],
            }

            result = orchestrator.sync_managed_profile_files(stack, backup_root=str(backup_root))

            after_credentials = orchestrator.compute_sha256(credentials_file)
            after_claude_state = orchestrator.compute_sha256(claude_state_file)
            rendered_settings = json.loads((profile_dir / "settings.json").read_text(encoding="utf-8"))
            rendered_trusted = json.loads((profile_dir / "trustedFolders.json").read_text(encoding="utf-8"))

        self.assertEqual(before_credentials, after_credentials)
        self.assertEqual(before_claude_state, after_claude_state)
        self.assertEqual(rendered_settings["model"], "opus[1m]")
        self.assertEqual(rendered_settings["permissions"]["defaultMode"], "auto")
        self.assertEqual(rendered_trusted, {})
        self.assertEqual(result["profiles"][0]["profile"], "claude-a")

    def test_set_active_profile_synchronizes_state_marker_and_active_link(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile_root = root / ".claude-profiles"
            profile_a = profile_root / "claude-a"
            profile_b = profile_root / "claude-b"
            profile_a.mkdir(parents=True, exist_ok=True)
            profile_b.mkdir(parents=True, exist_ok=True)
            state_file = root / ".claude-orchestrator" / "state.json"
            orchestrator.write_json(
                str(state_file),
                {
                    "active_profile": "claude-a",
                    "profiles": {
                        "claude-a": orchestrator.new_profile_runtime_state("claude-a", str(profile_a)),
                        "claude-b": orchestrator.new_profile_runtime_state("claude-b", str(profile_b)),
                    },
                },
            )

            config = {
                "state_file": str(state_file),
                "profiles": [
                    {"name": "claude-a", "config_dir": str(profile_a)},
                    {"name": "claude-b", "config_dir": str(profile_b)},
                ],
            }
            stack = {
                "active_dir_marker": str(root / ".claude-active-dir"),
                "active_profile_link": str(profile_root / "active"),
            }

            result = orchestrator.set_active_profile(config, stack, "claude-b")
            stored = orchestrator.load_state(str(state_file), profiles=config["profiles"])
            marker_value = Path(stack["active_dir_marker"]).read_text(encoding="utf-8").strip()
            active_target = Path(stack["active_profile_link"]).resolve()

            self.assertEqual(result["active_profile"], "claude-b")
            self.assertEqual(stored["active_profile"], "claude-b")
            self.assertEqual(marker_value, stack["active_profile_link"])
            self.assertEqual(active_target, profile_b.resolve())

    def test_select_best_antigravity_model_prefers_opus_1m(self) -> None:
        selected = orchestrator.select_best_antigravity_model(
            [
                "claude-sonnet-4-6",
                "claude-opus-4-6-thinking",
                "claude-opus-4-6-thinking[1m]",
            ]
        )

        self.assertEqual(selected, "claude-opus-4-6-thinking[1m]")

    def test_doctor_stack_detects_path_precedence_and_active_profile_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile_root = root / ".claude-profiles"
            profile_a = profile_root / "claude-a"
            profile_b = profile_root / "claude-b"
            profile_a.mkdir(parents=True, exist_ok=True)
            profile_b.mkdir(parents=True, exist_ok=True)
            active_link = profile_root / "active"
            orchestrator.set_directory_link(active_link, profile_a)
            marker = root / ".claude-active-dir"
            marker.write_text(str(active_link), encoding="utf-8")
            state_file = root / ".claude-orchestrator" / "state.json"
            orchestrator.write_json(
                str(state_file),
                {
                    "active_profile": "claude-b",
                    "profiles": {
                        "claude-a": orchestrator.new_profile_runtime_state("claude-a", str(profile_a)),
                        "claude-b": orchestrator.new_profile_runtime_state("claude-b", str(profile_b)),
                    },
                },
            )

            config = {
                "state_file": str(state_file),
                "profiles": [
                    {"name": "claude-a", "config_dir": str(profile_a)},
                    {"name": "claude-b", "config_dir": str(profile_b)},
                ],
            }
            stack = {
                "state_file": str(state_file),
                "active_dir_marker": str(marker),
                "active_profile_link": str(active_link),
                "official": {
                    "runtime_path": "C:/Users/marce/.local/bin/claude.exe",
                    "settings_baseline": {"model": "opus[1m]"},
                },
                "profiles": config["profiles"],
                "antigravity": {"models_snapshot_file": str(root / "models.json")},
            }

            report = orchestrator.doctor_stack(
                config,
                stack,
                claude_candidates=[
                    "C:/Users/marce/AppData/Local/Microsoft/WinGet/Packages/Anthropic.ClaudeCode/claude.exe",
                    "C:/Users/marce/.local/bin/claude.exe",
                ],
                antigravity_models=["claude-opus-4-6-thinking[1m]"],
            )

        issue_codes = {issue["code"] for issue in report["issues"]}
        self.assertIn("official_runtime_not_first_in_path", issue_codes)
        self.assertIn("active_profile_target_mismatch", issue_codes)
