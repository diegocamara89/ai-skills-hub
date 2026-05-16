from __future__ import annotations

import tempfile
import unittest

import sys
from pathlib import Path


SCRIPTS_DIR = Path(__file__).resolve().parents[1] / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import run_ai_cli  # noqa: E402


class RunAiCliTests(unittest.TestCase):
    def test_build_provider_command_adds_model_for_claude(self) -> None:
        command, stdin_text = run_ai_cli.build_provider_command(
            "claude",
            "opus",
            "planeje a tarefa",
            None,
            False,
            executable="claude.exe",
        )

        self.assertIn("--model", command)
        self.assertIn("opus", command)
        self.assertIn("--print", command)
        self.assertEqual(stdin_text, "planeje a tarefa")

    def test_discover_claude_executable_prefers_local_bin_over_cached_package(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            local_bin = root / ".local" / "bin"
            local_bin.mkdir(parents=True, exist_ok=True)
            preferred = local_bin / "claude.exe"
            preferred.write_text("", encoding="utf-8")

            local_app_data = root / "AppData" / "Local"
            cached = (
                local_app_data
                / "Packages"
                / "Claude_123"
                / "LocalCache"
                / "Roaming"
                / "Claude"
                / "claude-code"
                / "2.1.999"
                / "claude.exe"
            )
            cached.parent.mkdir(parents=True, exist_ok=True)
            cached.write_text("", encoding="utf-8")

            resolved = run_ai_cli.discover_claude_executable(
                local_app_data=str(local_app_data),
                home_dir=str(root),
            )

        self.assertEqual(resolved, str(preferred))


if __name__ == "__main__":
    unittest.main()
