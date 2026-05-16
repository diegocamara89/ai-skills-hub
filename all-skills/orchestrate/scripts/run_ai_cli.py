from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


WINDOWS_CMD_SUFFIXES = {".cmd", ".bat"}
_CREATE_NEW_PROCESS_GROUP = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)


def _kill_process_tree(proc: "subprocess.Popen[str]") -> None:
    """Mata o processo e todos os seus filhos no Windows."""
    try:
        if os.name == "nt":
            subprocess.run(
                ["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                capture_output=True,
                timeout=10,
            )
        else:
            proc.kill()
        proc.wait(timeout=5)
    except Exception:
        pass


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _read_text_file(path: str) -> str:
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def extract_first_json(text: str) -> Optional[Any]:
    decoder = json.JSONDecoder()
    for idx, ch in enumerate(text):
        if ch not in "{[":
            continue
        try:
            obj, _end = decoder.raw_decode(text[idx:])
            return obj
        except Exception:
            continue
    return None


@dataclass
class CallResult:
    ok: bool
    returncode: int
    stdout: str
    stderr: str
    command: list[str]


def _safe_version(value: str) -> tuple[int, ...]:
    parts: list[int] = []
    for raw in value.split("."):
        digits = "".join(ch for ch in raw if ch.isdigit())
        if not digits:
            parts.append(0)
            continue
        parts.append(int(digits))
    return tuple(parts)


def discover_claude_executable(
    local_app_data: str | None = None,
    home_dir: str | None = None,
) -> str | None:
    home_root = Path(home_dir or Path.home())
    local_bin_candidates = [home_root / ".local" / "bin" / "claude.exe"]
    if os.name != "nt":
        local_bin_candidates.append(home_root / ".local" / "bin" / "claude")

    for candidate in local_bin_candidates:
        if candidate.exists():
            return str(candidate)

    search_root = Path(local_app_data or os.environ.get("LOCALAPPDATA", ""))
    if search_root:
        packages_root = search_root / "Packages"
        patterns = [
            "Claude_*\\LocalCache\\Roaming\\Claude\\claude-code\\*\\claude.exe",
            "Claude*\\LocalCache\\Roaming\\Claude\\claude-code\\*\\claude.exe",
        ]
        candidates: list[Path] = []
        for pattern in patterns:
            candidates.extend(packages_root.glob(pattern))

        if candidates:
            ranked = sorted(
                candidates,
                key=lambda item: _safe_version(item.parent.name),
                reverse=True,
            )
            return str(ranked[0])

    return shutil.which("claude")


def discover_npm_cmd(command_name: str, roaming_app_data: str | None = None) -> str | None:
    app_data = roaming_app_data or os.environ.get("APPDATA", "")
    if app_data:
        candidate = Path(app_data) / "npm" / f"{command_name}.cmd"
        if candidate.exists():
            return str(candidate)

    direct = shutil.which(f"{command_name}.cmd")
    if direct:
        return direct

    return shutil.which(command_name)


def discover_provider_command(
    provider: str,
    *,
    roaming_app_data: str | None = None,
    local_app_data: str | None = None,
) -> str:
    if provider == "claude":
        resolved = discover_claude_executable(local_app_data=local_app_data)
    elif provider in {"codex", "gemini", "qwen"}:
        resolved = discover_npm_cmd(provider, roaming_app_data=roaming_app_data)
    else:
        raise ValueError(f"provider invalido: {provider}")

    if not resolved:
        raise FileNotFoundError(f"Nao foi possivel localizar o executavel de {provider}.")

    return resolved


def wrap_process_command(executable: str, args: list[str]) -> list[str]:
    suffix = Path(executable).suffix.lower()
    if os.name == "nt" and suffix in WINDOWS_CMD_SUFFIXES:
        comspec = os.environ.get("COMSPEC", "cmd.exe")
        cmdline = subprocess.list2cmdline([executable, *args])
        return [comspec, "/d", "/s", "/c", cmdline]
    return [executable, *args]


def build_provider_command(
    provider: str,
    model: str | None,
    prompt: str,
    prompt_file: str | None,
    yolo: bool,
    *,
    executable: str | None = None,
    roaming_app_data: str | None = None,
    local_app_data: str | None = None,
) -> tuple[list[str], str | None]:
    """Retorna (cmd, stdin_text). stdin_text=None para providers que usam @arquivo."""
    resolved_executable = executable or discover_provider_command(
        provider,
        roaming_app_data=roaming_app_data,
        local_app_data=local_app_data,
    )

    if provider == "gemini":
        # Gemini nao suporta stdin — exige arquivo. Caller deve criar temp file se necessario.
        if not model:
            raise ValueError("provider=gemini requer --model")
        if not prompt_file:
            raise ValueError(
                "provider=gemini requer --prompt-file. "
                "Escreva o prompt em um arquivo temporario e passe o caminho."
            )
        provider_args = ["-m", model, "-p", f"@{prompt_file}"]
        return wrap_process_command(resolved_executable, provider_args), None

    if provider == "qwen":
        # Qwen le stdin nativamente sem flags
        if prompt_file:
            prompt = _read_text_file(prompt_file)
        provider_args = ["--yolo"] if yolo else []
        return wrap_process_command(resolved_executable, provider_args), prompt

    if provider == "claude":
        # Claude suporta stdin via --print
        if prompt_file:
            prompt = _read_text_file(prompt_file)
        provider_args = ["--print"]
        if model:
            provider_args.extend(["--model", model])
        return wrap_process_command(resolved_executable, provider_args), prompt

    if provider == "codex":
        # Codex le stdin via flag "-"
        if prompt_file:
            prompt = _read_text_file(prompt_file)
        provider_args = ["exec", "--skip-git-repo-check", "-"]
        return wrap_process_command(resolved_executable, provider_args), prompt

    raise ValueError(f"provider invalido: {provider}")


def run_command(
    cmd: list[str],
    *,
    stdin_text: str | None,
    timeout_s: int,
    env: dict[str, str],
    cwd: str | None = None,
) -> CallResult:
    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            env=env,
            cwd=cwd,
            creationflags=_CREATE_NEW_PROCESS_GROUP,
        )
        try:
            stdout, stderr = proc.communicate(input=stdin_text, timeout=timeout_s)
            return CallResult(
                ok=(proc.returncode == 0),
                returncode=proc.returncode,
                stdout=stdout or "",
                stderr=stderr or "",
                command=cmd,
            )
        except subprocess.TimeoutExpired:
            _kill_process_tree(proc)
            return CallResult(
                ok=False,
                returncode=124,
                stdout="",
                stderr="TIMEOUT",
                command=cmd,
            )
    except Exception as exc:
        return CallResult(
            ok=False,
            returncode=-1,
            stdout="",
            stderr=str(exc),
            command=cmd,
        )


def main() -> int:
    import tempfile

    parser = argparse.ArgumentParser(description="Chama uma IA via CLI e retorna um envelope JSON padronizado.")
    parser.add_argument("--provider", required=True, choices=["gemini", "qwen", "claude", "codex"])
    parser.add_argument("--model", default=None, help="Modelo quando aplicavel. Ex.: gemini-3-flash-preview")
    parser.add_argument("--prompt", default="", help="Prompt em string. Use --prompt-file para prompts longos.")
    parser.add_argument("--prompt-file", default=None, help="Arquivo UTF-8 com prompt.")
    parser.add_argument("--timeout-s", type=int, default=180, help="Timeout em segundos.")
    parser.add_argument("--yolo", action="store_true", help="Apenas para qwen: adiciona --yolo.")
    parser.add_argument("--expect-json", action="store_true", help="Tenta extrair o primeiro JSON embutido no stdout.")
    parser.add_argument("--max-bytes", type=int, default=200_000, help="Trunca stdout/stderr no envelope.")
    parser.add_argument("--cwd", default=None, help="Diretorio de trabalho para a chamada.")
    parser.add_argument("--executable", default=None, help="Executavel explicito para o provider selecionado.")
    args = parser.parse_args()

    prompt = args.prompt or ""
    if not prompt and not args.prompt_file:
        print("ERRO: forneca --prompt ou --prompt-file", file=sys.stderr)
        return 2

    # Gemini nao suporta stdin — cria arquivo temporario quando nao foi fornecido
    temp_file: str | None = None
    if args.provider == "gemini" and not args.prompt_file:
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".txt", delete=False, encoding="utf-8"
        ) as fh:
            fh.write(prompt)
            temp_file = fh.name
        args.prompt_file = temp_file

    try:
        cmd, stdin_text = build_provider_command(
            args.provider,
            args.model,
            prompt,
            args.prompt_file,
            args.yolo,
            executable=args.executable,
        )
    except Exception as exc:
        print(f"ERRO: {exc}", file=sys.stderr)
        if temp_file:
            try:
                os.unlink(temp_file)
            except Exception:
                pass
        return 2

    env = os.environ.copy()
    if args.provider == "codex":
        env.pop("OPENAI_BASE_URL", None)
        env.pop("OPENAI_API_KEY", None)

    result = run_command(
        cmd,
        stdin_text=stdin_text,
        timeout_s=args.timeout_s,
        env=env,
        cwd=args.cwd,
    )

    if temp_file:
        try:
            os.unlink(temp_file)
        except Exception:
            pass

    stdout = result.stdout[: args.max_bytes]
    stderr = result.stderr[: args.max_bytes]

    parsed = extract_first_json(stdout) if args.expect_json else None

    envelope = {
        "status": "OK" if result.ok else "ERRO",
        "ia": args.provider,
        "modelo": args.model or "",
        "timestamp": _now_iso(),
        "cmd": result.command,
        "returncode": result.returncode,
        "stdout": stdout,
        "stderr": stderr,
        "json_extraido": parsed,
    }
    sys.stdout.write(json.dumps(envelope, ensure_ascii=False))
    sys.stdout.write("\n")
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
