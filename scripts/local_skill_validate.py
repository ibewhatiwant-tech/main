#!/usr/bin/env python3
"""
Local skill validator with no external dependencies.

Checks:
- SKILL.md exists and includes valid frontmatter delimiters.
- Frontmatter includes required keys and naming constraints.
- Optional agents/openai.yaml interface fields follow basic constraints.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple

MAX_SKILL_NAME_LENGTH = 64
MAX_DESCRIPTION_LENGTH = 1024
ALLOWED_FRONTMATTER_KEYS = {"name", "description", "license", "allowed-tools", "metadata"}
RE_NAME = re.compile(r"^[a-z0-9-]+$")


def _err(message: str) -> Tuple[bool, str]:
    return False, message


def extract_frontmatter(content: str) -> Tuple[bool, str]:
    if not content.startswith("---"):
        return _err("No YAML frontmatter found")

    lines = content.splitlines()
    if not lines or lines[0].strip() != "---":
        return _err("Invalid frontmatter start delimiter")

    end_index = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end_index = i
            break

    if end_index is None:
        return _err("Invalid frontmatter format: missing end delimiter")

    return True, "\n".join(lines[1:end_index])


def parse_simple_yaml_mapping(text: str) -> Dict[str, str]:
    """
    Parse a conservative subset of YAML:
    - top-level keys: `key: value`
    - supports quoted or unquoted scalar values
    - captures nested section headers as keys with empty string values
    This is enough for skill frontmatter and openai interface checks.
    """
    data: Dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if ":" not in line:
            continue
        key_part, val_part = line.split(":", 1)
        key = key_part.strip()
        value = val_part.strip()
        if key:
            data[key] = value
    return data


def unquote(value: str) -> str:
    if len(value) >= 2 and ((value[0] == value[-1] == '"') or (value[0] == value[-1] == "'")):
        return value[1:-1]
    return value


def validate_frontmatter(frontmatter_text: str) -> Tuple[bool, str]:
    frontmatter = parse_simple_yaml_mapping(frontmatter_text)
    if not frontmatter:
        return _err("Frontmatter must be a YAML dictionary")

    unexpected_keys = set(frontmatter.keys()) - ALLOWED_FRONTMATTER_KEYS
    if unexpected_keys:
        allowed = ", ".join(sorted(ALLOWED_FRONTMATTER_KEYS))
        unexpected = ", ".join(sorted(unexpected_keys))
        return _err(
            f"Unexpected key(s) in SKILL.md frontmatter: {unexpected}. "
            f"Allowed properties are: {allowed}"
        )

    if "name" not in frontmatter:
        return _err("Missing 'name' in frontmatter")
    if "description" not in frontmatter:
        return _err("Missing 'description' in frontmatter")

    name = unquote(frontmatter.get("name", "")).strip()
    if name:
        if not RE_NAME.match(name):
            return _err(
                f"Name '{name}' should be hyphen-case (lowercase letters, digits, and hyphens only)"
            )
        if name.startswith("-") or name.endswith("-") or "--" in name:
            return _err(
                f"Name '{name}' cannot start/end with hyphen or contain consecutive hyphens"
            )
        if len(name) > MAX_SKILL_NAME_LENGTH:
            return _err(
                f"Name is too long ({len(name)} characters). "
                f"Maximum is {MAX_SKILL_NAME_LENGTH} characters."
            )

    description = unquote(frontmatter.get("description", "")).strip()
    if description:
        if "<" in description or ">" in description:
            return _err("Description cannot contain angle brackets (< or >)")
        if len(description) > MAX_DESCRIPTION_LENGTH:
            return _err(
                f"Description is too long ({len(description)} characters). "
                f"Maximum is {MAX_DESCRIPTION_LENGTH} characters."
            )

    return True, "SKILL.md frontmatter is valid"


def _collect_openai_interface(yaml_text: str) -> Dict[str, str]:
    interface: Dict[str, str] = {}
    in_interface = False
    for raw in yaml_text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if re.match(r"^\s*interface\s*:\s*$", raw):
            in_interface = True
            continue
        if in_interface:
            if re.match(r"^[^\s].*:\s*$", raw):
                break
            m = re.match(r"^\s+([A-Za-z0-9_]+)\s*:\s*(.*)\s*$", raw)
            if m:
                interface[m.group(1)] = m.group(2)
    return interface


def _is_quoted(value: str) -> bool:
    value = value.strip()
    return len(value) >= 2 and ((value[0] == value[-1] == '"') or (value[0] == value[-1] == "'"))


def validate_openai_yaml(skill_path: Path, skill_name: str) -> Tuple[bool, List[str]]:
    issues: List[str] = []
    openai_yaml = skill_path / "agents" / "openai.yaml"
    if not openai_yaml.exists():
        return True, issues

    text = openai_yaml.read_text(encoding="utf-8")
    interface = _collect_openai_interface(text)
    if not interface:
        issues.append("agents/openai.yaml: missing 'interface' section")
        return False, issues

    for k in ("display_name", "short_description", "default_prompt"):
        if k in interface and not _is_quoted(interface[k]):
            issues.append(f"agents/openai.yaml: interface.{k} should be quoted")

    short_description = unquote(interface.get("short_description", "")).strip()
    if short_description:
        if not (25 <= len(short_description) <= 64):
            issues.append(
                "agents/openai.yaml: interface.short_description must be 25-64 characters"
            )

    default_prompt = unquote(interface.get("default_prompt", "")).strip()
    if default_prompt and f"${skill_name}" not in default_prompt:
        issues.append(
            f"agents/openai.yaml: interface.default_prompt must mention ${skill_name}"
        )

    return (len(issues) == 0), issues


def validate_skill(skill_path: Path) -> Tuple[bool, str]:
    skill_md = skill_path / "SKILL.md"
    if not skill_md.exists():
        return _err("SKILL.md not found")

    content = skill_md.read_text(encoding="utf-8")
    ok, frontmatter_or_error = extract_frontmatter(content)
    if not ok:
        return _err(frontmatter_or_error)

    ok, message = validate_frontmatter(frontmatter_or_error)
    if not ok:
        return _err(message)

    frontmatter = parse_simple_yaml_mapping(frontmatter_or_error)
    skill_name = unquote(frontmatter["name"]).strip()

    openai_ok, openai_issues = validate_openai_yaml(skill_path, skill_name)
    if not openai_ok:
        return _err("\n".join(openai_issues))

    return True, "Skill is valid!"


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python scripts/local_skill_validate.py <skill_directory>")
        return 1

    skill_path = Path(sys.argv[1]).resolve()
    valid, message = validate_skill(skill_path)
    print(message)
    return 0 if valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
