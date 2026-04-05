#!/usr/bin/env python3
"""Sync hot-layer police case notes into an authorized Obsidian vault."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
import textwrap
import zipfile
from collections import OrderedDict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence
from xml.etree import ElementTree


CASE_ID_ANY_RE = re.compile(r"\b(\d{1,8})[/_](\d{4})\b")
BO_ID_RE = re.compile(r"\b(\d{8})/(\d{4}(?:-[A-Z0-9]{2,4})?)\b")
BO_ID_UNDERSCORE_RE = re.compile(r"\b(\d{8})_(\d{4}(?:-[A-Z0-9]{2,4})?)\b")
EMAIL_RE = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
IP_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
CPF_RE = re.compile(r"\b\d{3}\.?\d{3}\.?\d{3}-?\d{2}\b")
CNPJ_RE = re.compile(r"\b\d{2}\.?\d{3}\.?\d{3}/?\d{4}-?\d{2}\b")
PHONE_RE = re.compile(r"(?<!\d)(?:\+?55\s*)?(?:\(?\d{2}\)?\s*)?(?:9?\d{4})[-\s]?\d{4}(?!\d)")
SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+")
FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n?", re.DOTALL)
HEADING_RE = re.compile(r"^##\s+(.+?)\s*$", re.MULTILINE)

DEFAULT_ALLOWED_VAULTS = {"DRCC_Obsidian_Vault"}
ALLOWED_PIECE_TYPES = {
    "relatorio-missao",
    "relatorio-diligencia",
    "oficio",
    "representacao",
    "analise-tecnica",
    "achado-probatorio",
}

CASE_DIR_ACTIVE = Path("DRCC Cerebro") / "Casos Ativos"
CASE_DIR_ARCHIVED = Path("DRCC Cerebro") / "Casos Arquivados"
OPERATIONS_DIR = Path("DRCC Cerebro") / "Operacional"
CASES_DASHBOARD = OPERATIONS_DIR / "00_Casos_Ativos.md"
INBOX_NOTE = OPERATIONS_DIR / "00_Inbox_Atualizacoes_Pendentes.md"


@dataclass
class Resolution:
    case_id: str | None
    confidence: str
    reason: str
    status: str


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso_date(value: datetime | None = None) -> str:
    return (value or now_utc()).date().isoformat()


def iso_timestamp(value: datetime | None = None) -> str:
    return (value or now_utc()).replace(microsecond=0).isoformat()


def normalize_case_id(raw: str | None) -> str | None:
    if not raw:
        return None
    match = CASE_ID_ANY_RE.search(str(raw))
    if not match:
        return None
    return f"{match.group(1).zfill(8)}_{match.group(2)}"


def normalize_bo_id(raw: str) -> str:
    cleaned = raw.strip()
    if "_" in cleaned:
        cleaned = cleaned.replace("_", "/", 1)
    parts = cleaned.split("/")
    if len(parts) != 2:
        return cleaned
    return f"{parts[0].zfill(8)}/{parts[1].upper()}"


def dedupe(values: Iterable[str]) -> list[str]:
    seen: OrderedDict[str, None] = OrderedDict()
    for value in values:
        text = str(value).strip()
        if text and text not in seen:
            seen[text] = None
    return list(seen.keys())


def ensure_allowed_vault(vault_path: Path, allowed_names: set[str]) -> None:
    if vault_path.name not in allowed_names:
        raise SystemExit(
            f"Vault '{vault_path.name}' nao autorizado. Permitidos: {', '.join(sorted(allowed_names))}"
        )


def read_docx_text(path: Path) -> str:
    with zipfile.ZipFile(path) as archive:
        xml_bytes = archive.read("word/document.xml")
    root = ElementTree.fromstring(xml_bytes)
    ns = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}
    chunks: list[str] = []
    for paragraph in root.findall(".//w:p", ns):
        runs = paragraph.findall(".//w:t", ns)
        text = "".join(run.text or "" for run in runs).strip()
        if text:
            chunks.append(text)
    return "\n".join(chunks)


def read_source_text(source_path: Path | None, inline_text: str | None) -> str:
    if inline_text:
        return inline_text
    if not source_path:
        return ""
    if source_path.suffix.lower() == ".docx":
        return read_docx_text(source_path)
    return source_path.read_text(encoding="utf-8", errors="ignore")


def compute_source_key(source_path: Path | None, inline_text: str | None) -> str:
    digest = hashlib.blake2b(digest_size=16)
    if source_path and source_path.exists():
        try:
            digest.update(source_path.read_bytes())
            return digest.hexdigest()
        except OSError:
            stat = source_path.stat()
            digest.update(str(source_path.resolve()).encode("utf-8", "ignore"))
            digest.update(str(stat.st_size).encode("ascii"))
            digest.update(str(int(stat.st_mtime)).encode("ascii"))
            return digest.hexdigest()
    digest.update((inline_text or "").encode("utf-8"))
    return digest.hexdigest()


def source_date(source_path: Path | None) -> str:
    if source_path and source_path.exists():
        return datetime.fromtimestamp(source_path.stat().st_mtime, tz=timezone.utc).date().isoformat()
    return iso_date()


def extract_case_ids(text: str) -> list[str]:
    return dedupe(normalize_case_id(match.group(0)) for match in CASE_ID_ANY_RE.finditer(text))


def extract_text_case_ids(text: str) -> list[str]:
    values = [normalize_case_id(match.group(0)) for match in re.finditer(r"\b\d{1,8}_\d{4}\b", text)]
    keyword_re = re.compile(
        r"\b(?:caso|ip|inquerito|inquérito|procedimento)\s*(?:n[ºo.]?\s*)?(\d{1,8})/(\d{4})\b",
        re.IGNORECASE,
    )
    values.extend(
        normalize_case_id(f"{match.group(1)}/{match.group(2)}")
        for match in keyword_re.finditer(text)
    )
    return dedupe(value for value in values if value)


def extract_bo_ids(text: str) -> list[str]:
    values = [f"{m.group(1)}/{m.group(2).upper()}" for m in BO_ID_RE.finditer(text)]
    values.extend(f"{m.group(1)}/{m.group(2).upper()}" for m in BO_ID_UNDERSCORE_RE.finditer(text))
    return dedupe(normalize_bo_id(value) for value in values)


def canonical_digits(value: str) -> str:
    return re.sub(r"\D", "", value)


def looks_like_ipv4(value: str) -> bool:
    parts = value.split(".")
    if len(parts) != 4:
        return False
    try:
        return all(0 <= int(part) <= 255 for part in parts)
    except ValueError:
        return False


def extract_entities(text: str) -> dict[str, list[str]]:
    emails = dedupe(match.group(0).lower() for match in EMAIL_RE.finditer(text))
    ips = dedupe(match.group(0) for match in IP_RE.finditer(text) if looks_like_ipv4(match.group(0)))
    cpfs = dedupe(canonical_digits(match.group(0)) for match in CPF_RE.finditer(text))
    cnpjs = dedupe(canonical_digits(match.group(0)) for match in CNPJ_RE.finditer(text))
    phones = []
    for match in PHONE_RE.finditer(text):
        digits = canonical_digits(match.group(0))
        if len(digits) == 13 and digits.startswith("55"):
            digits = digits[2:]
        if len(digits) in {10, 11}:
            phones.append(digits)
    return {
        "email": emails,
        "ip": ips,
        "cpf": cpfs,
        "cnpj": cnpjs,
        "telefone": dedupe(phones),
    }


def first_sentences(text: str, limit: int = 2) -> str:
    compact = " ".join(line.strip() for line in text.splitlines() if line.strip())
    if not compact:
        return "Sem resumo disponivel."
    sentences = [chunk.strip() for chunk in SENTENCE_SPLIT_RE.split(compact) if chunk.strip()]
    summary = " ".join(sentences[:limit]).strip()
    return textwrap.shorten(summary or compact, width=400, placeholder="...")


def collect_section_bullets(text: str, keywords: Sequence[str]) -> list[str]:
    lines = text.splitlines()
    collected: list[str] = []
    active = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#"):
            heading = stripped.lstrip("#").strip().lower()
            active = any(keyword in heading for keyword in keywords)
            continue
        if active and stripped.startswith(("- ", "* ", "• ")):
            collected.append(stripped[2:].strip())
        elif active and stripped and not stripped.startswith(">") and not stripped.startswith("["):
            if len(stripped) < 200:
                collected.append(stripped)
    return dedupe(collected)


def fallback_keyword_bullets(text: str, keywords: Sequence[str]) -> list[str]:
    bullets: list[str] = []
    for line in text.splitlines():
        stripped = line.strip(" -*•\t")
        lowered = stripped.lower()
        if stripped and any(keyword in lowered for keyword in keywords):
            bullets.append(textwrap.shorten(stripped, width=220, placeholder="..."))
    return dedupe(bullets)


def extract_findings_and_requests(text: str) -> tuple[list[str], list[str]]:
    findings = collect_section_bullets(text, ("achado", "conclus", "evidenc", "resultado"))
    requests = collect_section_bullets(text, ("pedido", "dilig", "providenc", "requisicao"))
    if not findings:
        findings = fallback_keyword_bullets(text, ("ip ", "cpf", "cnpj", "telefone", "email", "pix", "acesso", "fraude"))
    if not requests:
        requests = fallback_keyword_bullets(text, ("oficiar", "requisitar", "quebra", "dilig", "representa", "intimar"))
    return findings[:12], requests[:12]


def parse_frontmatter(text: str) -> tuple[dict[str, object], str]:
    match = FRONTMATTER_RE.match(text)
    if not match:
        return {}, text
    frontmatter: dict[str, object] = {}
    current_key: str | None = None
    for raw_line in match.group(1).splitlines():
        line = raw_line.rstrip()
        if not line:
            continue
        if line.startswith("  - ") and current_key:
            frontmatter.setdefault(current_key, [])
            frontmatter[current_key].append(strip_quotes(line[4:].strip()))
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        current_key = key
        if not value:
            frontmatter[key] = []
        else:
            frontmatter[key] = strip_quotes(value)
    return frontmatter, text[match.end():]


def strip_quotes(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


def dump_frontmatter(data: dict[str, object]) -> str:
    lines = ["---"]
    for key, value in data.items():
        if isinstance(value, list):
            lines.append(f"{key}:")
            if not value:
                lines.append("  -")
            else:
                for item in value:
                    lines.append(f'  - "{str(item).replace(chr(34), chr(39))}"')
        else:
            scalar = str(value).replace('"', "'")
            lines.append(f'{key}: "{scalar}"')
    lines.append("---")
    return "\n".join(lines)


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def read_note(path: Path) -> tuple[dict[str, object], str]:
    if not path.exists():
        return {}, ""
    return parse_frontmatter(path.read_text(encoding="utf-8"))


def extract_heading_section(text: str, heading: str) -> str:
    pattern = re.compile(rf"^##\s+{re.escape(heading)}\s*$", re.MULTILINE)
    match = pattern.search(text)
    if not match:
        return ""
    start = match.end()
    next_heading = HEADING_RE.search(text, start)
    end = next_heading.start() if next_heading else len(text)
    return text[start:end].strip()


def render_bullets(items: Sequence[str]) -> str:
    if not items:
        return "- Nenhum registro."
    return "\n".join(f"- {item}" for item in items)


def case_note_path(vault_root: Path, case_id: str, status: str = "ativo") -> Path:
    base = CASE_DIR_ACTIVE if status == "ativo" else CASE_DIR_ARCHIVED
    return vault_root / base / case_id / f"Caso {case_id}.md"


def case_pieces_dir(vault_root: Path, case_id: str, status: str = "ativo") -> Path:
    base = CASE_DIR_ACTIVE if status == "ativo" else CASE_DIR_ARCHIVED
    return vault_root / base / case_id / "Pecas"


def piece_note_path(vault_root: Path, case_id: str, piece_type: str, source_key: str, status: str = "ativo") -> Path:
    return case_pieces_dir(vault_root, case_id, status) / f"Peca {case_id} - {piece_type} - {source_key}.md"


def bo_note_link(vault_root: Path, bo_id: str) -> str:
    file_name = f"BO {bo_id.replace('/', '_')}.md"
    rel_path = Path("DRCC Cerebro") / "BOs" / file_name
    full_path = vault_root / rel_path
    if full_path.exists():
        return f"[[DRCC Cerebro/BOs/{file_name}|BO {bo_id}]]"
    return f"`BO {bo_id}`"


def entity_note_link(vault_root: Path, entity_type: str, value: str) -> str:
    file_name = f"Entidade {entity_type} {value}.md"
    rel_path = Path("DRCC Cerebro") / "Entidades" / file_name
    full_path = vault_root / rel_path
    if full_path.exists():
        return f"[[DRCC Cerebro/Entidades/{file_name}|{value}]]"
    return f"`{entity_type}: {value}`"


def infer_piece_type(source_path: Path | None, text: str, explicit_piece_type: str | None) -> str:
    if explicit_piece_type:
        if explicit_piece_type not in ALLOWED_PIECE_TYPES:
            raise SystemExit(f"peca_tipo invalido: {explicit_piece_type}")
        return explicit_piece_type
    haystack = f"{source_path or ''}\n{text}".lower()
    if "relatorio de missao" in haystack or "relatorio_missao" in haystack:
        return "relatorio-missao"
    if "relatorio de dilig" in haystack or "relatorio_dilig" in haystack:
        return "relatorio-diligencia"
    if "representa" in haystack:
        return "representacao"
    if "oficio" in haystack or "ofício" in haystack:
        return "oficio"
    if "achado probatorio" in haystack or "achado_probat" in haystack:
        return "achado-probatorio"
    return "analise-tecnica"


def list_case_notes(vault_root: Path) -> list[dict[str, object]]:
    notes: list[dict[str, object]] = []
    for root_name, status in ((CASE_DIR_ACTIVE, "ativo"), (CASE_DIR_ARCHIVED, "arquivado")):
        root = vault_root / root_name
        if not root.exists():
            continue
        for path in root.glob("*/Caso *.md"):
            frontmatter, body = read_note(path)
            notes.append(
                {
                    "path": path,
                    "status": status,
                    "case_id": str(frontmatter.get("caso_id", "")),
                    "bo_relacionados": [str(item) for item in frontmatter.get("bo_relacionados", [])],
                    "frontmatter": frontmatter,
                    "body": body,
                }
            )
    return notes


def active_case_map(vault_root: Path) -> dict[str, dict[str, object]]:
    mapping: dict[str, dict[str, object]] = {}
    for note in list_case_notes(vault_root):
        if note["status"] == "ativo" and note["case_id"]:
            mapping[str(note["case_id"])] = note
    return mapping


def read_focus_case(vault_root: Path) -> str | None:
    frontmatter, _body = read_note(vault_root / CASES_DASHBOARD)
    return normalize_case_id(str(frontmatter.get("caso_em_foco", "")))


def resolve_case_id(
    explicit_case_id: str | None,
    source_path: Path | None,
    source_text: str,
    active_cases: dict[str, dict[str, object]],
    focus_case: str | None,
) -> Resolution:
    if explicit_case_id:
        case_id = normalize_case_id(explicit_case_id)
        if not case_id:
            return Resolution(None, "low", "case_id explicito invalido", "inbox")
        return Resolution(case_id, "high", "case_id explicito", "resolved")

    path_candidates = extract_case_ids(str(source_path)) if source_path else []
    if len(path_candidates) == 1:
        return Resolution(path_candidates[0], "high", "identificador explicito no caminho ou nome do arquivo", "resolved")
    if len(path_candidates) > 1:
        return Resolution(None, "low", f"multiplos identificadores no caminho: {', '.join(path_candidates)}", "inbox")

    text_candidates = extract_text_case_ids(source_text)
    if len(text_candidates) == 1:
        return Resolution(text_candidates[0], "high", "identificador explicito no conteudo", "resolved")
    if len(text_candidates) > 1:
        return Resolution(None, "low", f"multiplos identificadores no conteudo: {', '.join(text_candidates)}", "inbox")

    bo_ids = dedupe(extract_bo_ids(str(source_path or "")) + extract_bo_ids(source_text))
    if bo_ids:
        for bo_id in bo_ids:
            matches = [
                case_id
                for case_id, case_note in active_cases.items()
                if bo_id in case_note.get("bo_relacionados", [])
            ]
            if len(matches) == 1:
                return Resolution(matches[0], "medium", f"BO {bo_id} ligado a caso ativo", "resolved")
            if len(matches) > 1:
                return Resolution(None, "low", f"BO {bo_id} ligado a multiplos casos ativos: {', '.join(matches)}", "inbox")

    if focus_case:
        return Resolution(focus_case, "medium", "caso_em_foco do painel operacional", "resolved")

    return Resolution(None, "low", "sem caso resolvido com seguranca", "inbox")


def find_case_status(vault_root: Path, case_id: str) -> str | None:
    active = case_note_path(vault_root, case_id, "ativo")
    if active.exists():
        return "ativo"
    archived = case_note_path(vault_root, case_id, "arquivado")
    if archived.exists():
        return "arquivado"
    return None


def ensure_case_folder(vault_root: Path, case_id: str, status: str = "ativo") -> None:
    case_note = case_note_path(vault_root, case_id, status)
    pieces_dir = case_pieces_dir(vault_root, case_id, status)
    pieces_dir.mkdir(parents=True, exist_ok=True)
    if not case_note.exists():
        frontmatter = OrderedDict(
            [
                ("type", "caso"),
                ("caso_id", case_id),
                ("status", status),
                ("titulo_curto", f"Caso {case_id}"),
                ("bo_principal", ""),
                ("bo_relacionados", []),
                ("entidades_chave", []),
                ("ultima_atualizacao", iso_date()),
                ("prioridade", "normal"),
            ]
        )
        content = (
            f"{dump_frontmatter(frontmatter)}\n\n"
            f"# Caso {case_id}\n\n"
            "## Síntese\n- Caso ativo sem peça materializada.\n\n"
            "## BOs relacionados\n- Nenhum registro.\n\n"
            "## Peças produzidas\n- Nenhum registro.\n\n"
            "## Achados principais\n- Nenhum registro.\n\n"
            "## Pedidos e diligências\n- Nenhum registro.\n\n"
            "## Vínculos relevantes\n- Nenhum registro.\n\n"
            "## Log de atualizações\n- Caso materializado sem peça em "
            f"{iso_timestamp()}.\n"
        )
        write_text(case_note, content)


def write_text(path: Path, content: str) -> None:
    ensure_parent(path)
    path.write_text(content.rstrip() + "\n", encoding="utf-8")


def load_piece_records(vault_root: Path, case_id: str, status: str) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    pieces_root = case_pieces_dir(vault_root, case_id, status)
    if not pieces_root.exists():
        return records
    for path in sorted(pieces_root.glob("Peca *.md")):
        frontmatter, body = read_note(path)
        records.append(
            {
                "path": path,
                "frontmatter": frontmatter,
                "body": body,
                "summary": extract_heading_section(body, "Resumo curto") or "Sem resumo disponivel.",
                "findings": dedupe(
                    line.lstrip("- ").strip()
                    for line in extract_heading_section(body, "Principais achados").splitlines()
                    if line.strip().startswith("- ")
                ),
                "requests": dedupe(
                    line.lstrip("- ").strip()
                    for line in extract_heading_section(body, "Pedidos e diligências").splitlines()
                    if line.strip().startswith("- ")
                ),
            }
        )
    return records


def infer_entity_type(value: str) -> str:
    if "@" in value:
        return "email"
    if re.fullmatch(r"(?:\d{1,3}\.){3}\d{1,3}", value):
        return "ip"
    if len(value) == 14 and value.isdigit():
        return "cnpj"
    if len(value) == 11 and value.isdigit():
        return "telefone" if value.startswith(("8", "9")) else "cpf"
    return "entidade"


def build_case_note(vault_root: Path, case_id: str, status: str, priority: str = "normal", title: str | None = None) -> str:
    pieces = load_piece_records(vault_root, case_id, status)
    existing_frontmatter, _existing_body = read_note(case_note_path(vault_root, case_id, status))

    bo_relacionados = dedupe(
        str(item)
        for piece in pieces
        for item in piece["frontmatter"].get("bo_relacionados", [])
    )
    if not bo_relacionados and existing_frontmatter.get("bo_relacionados"):
        bo_relacionados = [str(item) for item in existing_frontmatter.get("bo_relacionados", [])]

    entidades_chave = dedupe(
        str(item)
        for piece in pieces
        for item in piece["frontmatter"].get("entidades_chave", [])
    )[:12]
    if not entidades_chave and existing_frontmatter.get("entidades_chave"):
        entidades_chave = [str(item) for item in existing_frontmatter.get("entidades_chave", [])]

    latest_piece = None
    if pieces:
        latest_piece = max(
            pieces,
            key=lambda item: str(item["frontmatter"].get("data_peca", "")),
        )
    title = title or str(existing_frontmatter.get("titulo_curto", "") or f"Caso {case_id}")
    summary = latest_piece["summary"] if latest_piece else "Caso ativo sem peça materializada."

    piece_lines = []
    for piece in sorted(
        pieces,
        key=lambda item: (
            str(item["frontmatter"].get("data_peca", "")),
            str(item["frontmatter"].get("source_key", "")),
        ),
        reverse=True,
    ):
        rel_path = piece["path"].relative_to(vault_root).as_posix()
        piece_type = piece["frontmatter"].get("peca_tipo", "peca")
        piece_date = piece["frontmatter"].get("data_peca", "")
        piece_lines.append(f"[[{rel_path}|{piece_type}]] ({piece_date})")

    achados = dedupe(
        finding
        for piece in pieces
        for finding in piece["findings"]
    )[:12]
    pedidos = dedupe(
        request
        for piece in pieces
        for request in piece["requests"]
    )[:12]

    vinculos = [bo_note_link(vault_root, bo_id) for bo_id in bo_relacionados]
    vinculos.extend(
        entity_note_link(vault_root, infer_entity_type(value), value)
        for value in entidades_chave
    )
    vinculos = dedupe(vinculos)[:16]

    log_entries = []
    for piece in sorted(
        pieces,
        key=lambda item: (
            str(item["frontmatter"].get("data_peca", "")),
            str(item["frontmatter"].get("source_key", "")),
        ),
        reverse=True,
    ):
        piece_date = piece["frontmatter"].get("data_peca", "")
        source_path = piece["frontmatter"].get("source_path", "")
        confidence = piece["frontmatter"].get("confianca_vinculacao", "")
        source_key = piece["frontmatter"].get("source_key", "")
        log_entries.append(
            f"{piece_date} | {piece['frontmatter'].get('peca_tipo', 'peca')} | "
            f"{confidence} | `{source_key}` | `{source_path}`"
        )
    if not log_entries:
        log_entries = [f"Caso materializado sem peça em {iso_timestamp()}."]

    frontmatter = OrderedDict(
        [
            ("type", "caso"),
            ("caso_id", case_id),
            ("status", status),
            ("titulo_curto", title),
            ("bo_principal", bo_relacionados[0] if bo_relacionados else str(existing_frontmatter.get("bo_principal", ""))),
            ("bo_relacionados", bo_relacionados),
            ("entidades_chave", entidades_chave),
            ("ultima_atualizacao", latest_piece["frontmatter"].get("data_peca", iso_date()) if latest_piece else iso_date()),
            ("prioridade", str(existing_frontmatter.get("prioridade", priority or "normal"))),
        ]
    )
    return (
        f"{dump_frontmatter(frontmatter)}\n\n"
        f"# Caso {case_id}\n\n"
        f"## Síntese\n{summary}\n\n"
        f"## BOs relacionados\n{render_bullets([bo_note_link(vault_root, bo_id) for bo_id in bo_relacionados])}\n\n"
        f"## Peças produzidas\n{render_bullets(piece_lines)}\n\n"
        f"## Achados principais\n{render_bullets(achados)}\n\n"
        f"## Pedidos e diligências\n{render_bullets(pedidos)}\n\n"
        f"## Vínculos relevantes\n{render_bullets(vinculos)}\n\n"
        f"## Log de atualizações\n{render_bullets(log_entries)}\n"
    )


def write_piece_note(
    vault_root: Path,
    case_id: str,
    piece_type: str,
    source_key: str,
    source_path: Path | None,
    source_text: str,
    confidence: str,
    status: str = "ativo",
) -> Path:
    summary = first_sentences(source_text)
    bo_relacionados = extract_bo_ids(source_text)
    entities = extract_entities(source_text)
    entity_values = dedupe(
        value
        for key in ("ip", "email", "telefone", "cpf", "cnpj")
        for value in entities[key]
    )[:12]
    findings, requests = extract_findings_and_requests(source_text)
    piece_path = piece_note_path(vault_root, case_id, piece_type, source_key, status)
    frontmatter = OrderedDict(
        [
            ("type", "peca"),
            ("caso_id", case_id),
            ("peca_tipo", piece_type),
            ("source_key", source_key),
            ("source_path", str(source_path) if source_path else "inline"),
            ("data_peca", source_date(source_path)),
            ("bo_relacionados", bo_relacionados),
            ("entidades_chave", entity_values),
            ("confianca_vinculacao", confidence),
        ]
    )
    entity_links = [
        entity_note_link(vault_root, infer_entity_type(value), value) for value in entity_values
    ]
    content = (
        f"{dump_frontmatter(frontmatter)}\n\n"
        f"# Peça {case_id}: {piece_type}\n\n"
        f"- Fonte: `{source_path if source_path else 'inline'}`\n"
        f"- Vinculação: `{confidence}`\n\n"
        f"## Resumo curto\n{summary}\n\n"
        f"## Principais achados\n{render_bullets(findings)}\n\n"
        f"## Pedidos e diligências\n{render_bullets(requests)}\n\n"
        f"## Entidades-chave\n{render_bullets(entity_links)}\n\n"
        f"## BOs relacionados\n{render_bullets([bo_note_link(vault_root, bo_id) for bo_id in bo_relacionados])}\n"
    )
    write_text(piece_path, content)
    return piece_path


def load_inbox_items(vault_root: Path) -> list[dict[str, str]]:
    path = vault_root / INBOX_NOTE
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8")
    items: list[dict[str, str]] = []
    for line in text.splitlines():
        match = re.match(r"^- \[ \] `([^`]+)` \| `([^`]+)` \| `([^`]+)` \| (.+)$", line.strip())
        if match:
            items.append(
                {
                    "source_key": match.group(1),
                    "source_path": match.group(2),
                    "reason": match.group(3),
                    "hints": match.group(4),
                }
            )
    return items


def write_inbox(vault_root: Path, items: list[dict[str, str]]) -> None:
    lines = []
    for item in items:
        lines.append(
            f"- [ ] `{item['source_key']}` | `{item['source_path']}` | `{item['reason']}` | {item['hints']}"
        )
    frontmatter = OrderedDict(
        [
            ("type", "operacional"),
            ("painel", "inbox-atualizacoes"),
            ("ultima_atualizacao", iso_timestamp()),
        ]
    )
    body = "\n".join(lines) if lines else "- Nenhum item pendente."
    content = (
        f"{dump_frontmatter(frontmatter)}\n\n"
        "# Inbox de Atualizações Pendentes\n\n"
        "Itens com vinculacao insuficiente para escrita automatica no dossie.\n\n"
        f"{body}\n"
    )
    write_text(vault_root / INBOX_NOTE, content)


def add_inbox_item(vault_root: Path, source_key: str, source_path: str, reason: str, hints: str) -> Path:
    items = load_inbox_items(vault_root)
    remaining = [item for item in items if item["source_key"] != source_key]
    remaining.append(
        {
            "source_key": source_key,
            "source_path": source_path,
            "reason": reason,
            "hints": hints,
        }
    )
    write_inbox(vault_root, remaining)
    return vault_root / INBOX_NOTE


def remove_inbox_item(vault_root: Path, source_key: str) -> None:
    items = [item for item in load_inbox_items(vault_root) if item["source_key"] != source_key]
    write_inbox(vault_root, items)


def rebuild_dashboard(vault_root: Path) -> None:
    cases = []
    for case_id, note in sorted(active_case_map(vault_root).items()):
        frontmatter = note["frontmatter"]
        cases.append(
            {
                "case_id": case_id,
                "prioridade": str(frontmatter.get("prioridade", "normal")),
                "ultima_atualizacao": str(frontmatter.get("ultima_atualizacao", "")),
                "bo_principal": str(frontmatter.get("bo_principal", "")),
            }
        )

    old_frontmatter, _old_body = read_note(vault_root / CASES_DASHBOARD)
    caso_em_foco = normalize_case_id(str(old_frontmatter.get("caso_em_foco", "")))
    if caso_em_foco and caso_em_foco not in {case["case_id"] for case in cases}:
        caso_em_foco = ""

    frontmatter = OrderedDict(
        [
            ("type", "operacional"),
            ("painel", "casos-ativos"),
            ("caso_em_foco", caso_em_foco or ""),
            ("ultima_atualizacao", iso_timestamp()),
            ("total_casos_ativos", len(cases)),
        ]
    )

    lines = []
    for case in sorted(cases, key=lambda item: (item["prioridade"], item["ultima_atualizacao"], item["case_id"]), reverse=True):
        rel_path = (CASE_DIR_ACTIVE / case["case_id"] / f"Caso {case['case_id']}.md").as_posix()
        lines.append(
            f"[[{rel_path}|{case['case_id']}]] | prioridade `{case['prioridade']}` | "
            f"ultima_atualizacao `{case['ultima_atualizacao']}` | BO principal `{case['bo_principal'] or '-'}`"
        )

    content = (
        f"{dump_frontmatter(frontmatter)}\n\n"
        "# Casos Ativos\n\n"
        "## Painel\n"
        f"- Caso em foco: `{caso_em_foco or '-'}`\n"
        f"- Total de casos ativos: `{len(cases)}`\n\n"
        "## Lista operacional\n"
        f"{render_bullets(lines)}\n\n"
        "## Bases\n"
        "- ![[DRCC Cerebro/Indices/Casos Ativos.base]]\n"
        "- ![[DRCC Cerebro/Indices/Pecas Ativas.base]]\n"
    )
    write_text(vault_root / CASES_DASHBOARD, content)


def set_focus_case(vault_root: Path, case_id: str | None) -> None:
    frontmatter, body = read_note(vault_root / CASES_DASHBOARD)
    frontmatter["type"] = "operacional"
    frontmatter["painel"] = "casos-ativos"
    frontmatter["caso_em_foco"] = case_id or ""
    frontmatter["ultima_atualizacao"] = iso_timestamp()
    if not body.strip():
        body = "# Casos Ativos\n"
    write_text(vault_root / CASES_DASHBOARD, f"{dump_frontmatter(frontmatter)}\n\n{body.strip()}\n")
    rebuild_dashboard(vault_root)


def activate_case(vault_root: Path, case_id: str, bos: list[str], title: str | None, priority: str, focus: bool) -> dict[str, object]:
    case_id = normalize_case_id(case_id) or ""
    if not case_id:
        raise SystemExit("case_id invalido")

    archived_path = case_note_path(vault_root, case_id, "arquivado")
    active_path = case_note_path(vault_root, case_id, "ativo")
    if archived_path.exists() and not active_path.exists():
        target_dir = active_path.parent
        target_dir.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(archived_path.parent), str(target_dir))

    ensure_case_folder(vault_root, case_id, "ativo")
    frontmatter, _body = read_note(active_path)
    frontmatter["type"] = "caso"
    frontmatter["caso_id"] = case_id
    frontmatter["status"] = "ativo"
    frontmatter["titulo_curto"] = title or str(frontmatter.get("titulo_curto", f"Caso {case_id}"))
    bo_values = dedupe([normalize_bo_id(value) for value in bos] + [str(item) for item in frontmatter.get("bo_relacionados", [])])
    frontmatter["bo_principal"] = bo_values[0] if bo_values else str(frontmatter.get("bo_principal", ""))
    frontmatter["bo_relacionados"] = bo_values
    frontmatter["entidades_chave"] = [str(item) for item in frontmatter.get("entidades_chave", [])]
    frontmatter["ultima_atualizacao"] = iso_date()
    frontmatter["prioridade"] = priority
    content = (
        f"{dump_frontmatter(frontmatter)}\n\n"
        f"# Caso {case_id}\n\n"
        "## Síntese\n- Caso ativo materializado manualmente no painel operacional.\n\n"
        f"## BOs relacionados\n{render_bullets([bo_note_link(vault_root, bo) for bo in bo_values])}\n\n"
        "## Peças produzidas\n- Nenhum registro.\n\n"
        "## Achados principais\n- Nenhum registro.\n\n"
        "## Pedidos e diligências\n- Nenhum registro.\n\n"
        "## Vínculos relevantes\n- Nenhum registro.\n\n"
        f"## Log de atualizações\n- Caso ativado manualmente em {iso_timestamp()}.\n"
    )
    write_text(active_path, content)
    rebuild_dashboard(vault_root)
    if focus:
        set_focus_case(vault_root, case_id)
    return {"status": "activated", "case_id": case_id, "case_path": str(active_path)}


def archive_case(vault_root: Path, case_id: str) -> dict[str, object]:
    case_id = normalize_case_id(case_id) or ""
    if not case_id:
        raise SystemExit("case_id invalido")
    active_root = case_note_path(vault_root, case_id, "ativo").parent
    archived_root = case_note_path(vault_root, case_id, "arquivado").parent
    if not active_root.exists():
        raise SystemExit(f"Caso ativo nao encontrado: {case_id}")
    archived_root.parent.mkdir(parents=True, exist_ok=True)
    if archived_root.exists():
        shutil.rmtree(archived_root)
    shutil.move(str(active_root), str(archived_root))
    archived_note = case_note_path(vault_root, case_id, "arquivado")
    frontmatter, body = read_note(archived_note)
    frontmatter["status"] = "arquivado"
    frontmatter["ultima_atualizacao"] = iso_date()
    write_text(archived_note, f"{dump_frontmatter(frontmatter)}\n\n{body.strip()}\n")
    rebuild_dashboard(vault_root)
    if read_focus_case(vault_root) == case_id:
        set_focus_case(vault_root, None)
    return {"status": "archived", "case_id": case_id, "case_path": str(archived_note)}


def sync_piece(
    vault_root: Path,
    source_path: Path | None,
    inline_text: str | None,
    explicit_case_id: str | None,
    explicit_piece_type: str | None,
) -> dict[str, object]:
    source_text = read_source_text(source_path, inline_text)
    if not source_text.strip():
        raise SystemExit("Fonte vazia; nada para sincronizar.")
    source_key = compute_source_key(source_path, inline_text)
    active_cases = active_case_map(vault_root)
    resolution = resolve_case_id(
        explicit_case_id=explicit_case_id,
        source_path=source_path,
        source_text=source_text,
        active_cases=active_cases,
        focus_case=read_focus_case(vault_root),
    )
    if not resolution.case_id:
        inbox_path = add_inbox_item(
            vault_root,
            source_key=source_key,
            source_path=str(source_path) if source_path else "inline",
            reason=resolution.reason,
            hints=", ".join(extract_case_ids(source_text) or extract_bo_ids(source_text) or ["sem pistas fortes"]),
        )
        rebuild_dashboard(vault_root)
        return {
            "status": "inbox",
            "source_key": source_key,
            "reason": resolution.reason,
            "inbox_path": str(inbox_path),
        }

    case_id = resolution.case_id
    case_status = find_case_status(vault_root, case_id) or "ativo"
    if case_status == "arquivado":
        activate_case(vault_root, case_id, [], None, "normal", False)
    else:
        ensure_case_folder(vault_root, case_id, "ativo")

    piece_type = infer_piece_type(source_path, source_text, explicit_piece_type)
    piece_path = write_piece_note(
        vault_root=vault_root,
        case_id=case_id,
        piece_type=piece_type,
        source_key=source_key,
        source_path=source_path,
        source_text=source_text,
        confidence=resolution.confidence,
        status="ativo",
    )
    case_content = build_case_note(vault_root, case_id, "ativo")
    write_text(case_note_path(vault_root, case_id, "ativo"), case_content)
    remove_inbox_item(vault_root, source_key)
    rebuild_dashboard(vault_root)
    return {
        "status": "synced",
        "case_id": case_id,
        "piece_type": piece_type,
        "confidence": resolution.confidence,
        "reason": resolution.reason,
        "source_key": source_key,
        "case_path": str(case_note_path(vault_root, case_id, "ativo")),
        "piece_path": str(piece_path),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--allowed-vault-name",
        action="append",
        default=[],
        help="Additional authorized vault names.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    sync_parser = subparsers.add_parser("sync", help="Sync a piece into the hot layer.")
    sync_parser.add_argument("--vault-path", required=True)
    sync_parser.add_argument("--source-path")
    sync_parser.add_argument("--source-text")
    sync_parser.add_argument("--case-id")
    sync_parser.add_argument("--piece-type", choices=sorted(ALLOWED_PIECE_TYPES))

    activate_parser = subparsers.add_parser("activate-case", help="Create or reactivate an active case dossier.")
    activate_parser.add_argument("--vault-path", required=True)
    activate_parser.add_argument("--case-id", required=True)
    activate_parser.add_argument("--bo", action="append", default=[])
    activate_parser.add_argument("--title")
    activate_parser.add_argument("--priority", default="normal")
    activate_parser.add_argument("--focus", action="store_true")

    archive_parser = subparsers.add_parser("archive-case", help="Archive an active case dossier.")
    archive_parser.add_argument("--vault-path", required=True)
    archive_parser.add_argument("--case-id", required=True)

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    allowed_vaults = set(DEFAULT_ALLOWED_VAULTS)
    allowed_vaults.update(args.allowed_vault_name or [])

    vault_path = Path(args.vault_path).resolve()
    ensure_allowed_vault(vault_path, allowed_vaults)

    if args.command == "sync":
        source_path = Path(args.source_path).resolve() if args.source_path else None
        if source_path and not source_path.exists():
            raise SystemExit(f"Fonte nao encontrada: {source_path}")
        result = sync_piece(
            vault_root=vault_path,
            source_path=source_path,
            inline_text=args.source_text,
            explicit_case_id=args.case_id,
            explicit_piece_type=args.piece_type,
        )
    elif args.command == "activate-case":
        result = activate_case(
            vault_root=vault_path,
            case_id=args.case_id,
            bos=args.bo,
            title=args.title,
            priority=args.priority,
            focus=args.focus,
        )
    elif args.command == "archive-case":
        result = archive_case(vault_root=vault_path, case_id=args.case_id)
    else:
        raise SystemExit(f"Comando desconhecido: {args.command}")

    sys.stdout.write(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
