#!/usr/bin/env python3
"""Deterministic analyzer for a Sherpa RPA process directory.

Scans a process directory and emits a structured JSON report that the
write-readme skill renders into a README.md. The analyzer does only
extraction and formatting -- no prose, no LLM -- so the same input always
yields the same report.

Usage:
    python analyze_process.py <processDir> [--out report.json]

The report schema (printed to stdout unless --out is given):

    {
      "processDir": "...",
      "config": {"bpName": "...", "processName": "...?", ...},
      "steps": [
        {"order": 1, "displayName": "...", "stepName": "...",
         "className": "...", "javaPath": "src/main/java/...",
         "processFile": "Stage1.process", "executeSource": "..."}
      ],
      "initParamsFiles": ["src/main/resources/..."],
      "emailTemplatesFile": "src/main/resources/..." | null,
      "serviceVariables": [
        {"name": "sap_credentials", "kind": "credentials|settings|config",
         "callStyle": "assets.getCredentials|assets.get|legacy.getCredentials",
         "definedIn": "SapStep.java" | null}
      ],
      "hasMt": true | false,
      "manualTasks": [
        {"name": "process_new", "formPath": "src/main/resources/actions/process_new.js",
         "actionLinkField": "processNewActionLink" | null,
         "senderStep": "PrepareNewStep" | null, "senderStepPath": "..." | null,
         "receiverStep": "SaveNewStep" | null, "receiverStepPath": "..." | null,
         "resultDto": "ProcessNewResult" | null, "resultDtoPath": "..." | null,
         "mtNumber": "MT_01" | null, "queueName": "..." | null,
         "taskName": "processNew" | null, "pendingTag": "..." | null,
         "finalTag": "..." | null, "processedTag": "..." | null}
      ],
      "mtApiCredentialsAsset": "sherpa_api_credentials" | null,
      "warnings": ["..."]
    }

Step-name resolution mirrors rpa-core's StepRegistry: read @StepName("...")
on the class first; otherwise strip the "Step" suffix and lowercase the
first character of the class simple name.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


# --- .process XML helpers -------------------------------------------------

_PROCESS_ENTITIES = {
    "&amp;": "&",
    "&quot;": '"',
    "&#xA;": "\n",
    "&#xD;": "\r",
    "&lt;": "<",
    "&gt;": ">",
}


def _unescape(text: str) -> str:
    """Undo the XML entity escaping used inside .process <Content> payloads."""
    # &amp; first so we don't double-decode entities it produced.
    for entity, char in _PROCESS_ENTITIES.items():
        text = text.replace(entity, char)
    return text


def _read_process_file(path: Path) -> str:
    """Read a .process file, tolerating the UTF-8 BOM the designer writes."""
    return path.read_text(encoding="utf-8-sig")


_STEPNAME_PROP_RE = re.compile(
    r'<Property\s+Name="StepName"[^>]*?Value="(.*?)"(?=\s)', re.DOTALL
)
_DISPLAYNAME_RE = re.compile(r'DisplayName="([^"]*)"')


def _ordered_process_files(process_dir: Path) -> list[Path]:
    """Order .process files so the README follows the real flow.

    Order: Главная.process (main diagram) first, then Stage1..N in numeric
    order, then any remaining .process files alphabetically.
    """
    all_process = sorted(process_dir.glob("*.process"))

    def sort_key(p: Path) -> tuple[int, int, str]:
        name = p.name
        if name == "Главная.process":
            return (0, 0, name)
        stage_match = re.match(r"Stage(\d+)\.process$", name)
        if stage_match:
            return (1, int(stage_match.group(1)), name)
        return (2, 0, name)

    return sorted(all_process, key=sort_key)


def extract_step_blocks(process_dir: Path) -> list[dict]:
    """Extract the ordered (displayName, stepName) pairs from .process files.

    Each Java-invoking block carries a <Property Name="StepName" Value="...">.
    We pair its Value with the nearest preceding DisplayName in the same
    ToolboxItemSettings block. The block's InternalName is a toolbox type
    identifier (Start, SwitchCase, or a per-process MyBlock GUID) and is NOT
    a step name -- only the StepName property value is.
    """
    steps: list[dict] = []
    seen: set[str] = set()
    for proc_file in _ordered_process_files(process_dir):
        text = _unescape(_read_process_file(proc_file))
        for match in _STEPNAME_PROP_RE.finditer(text):
            raw_value = match.group(1).strip().strip('"')
            if not raw_value:
                continue
            preceding = text[: match.start()]
            display_names = _DISPLAYNAME_RE.findall(preceding)
            display_name = display_names[-1] if display_names else raw_value
            if raw_value in seen:
                continue
            seen.add(raw_value)
            steps.append(
                {
                    "displayName": display_name,
                    "stepName": raw_value,
                    "processFile": proc_file.name,
                }
            )
    return steps


# --- Java step resolution -------------------------------------------------

_STEPNAME_ANN_RE = re.compile(r'@StepName\s*\(\s*"([^"]+)"\s*\)')
_CLASS_DECL_RE = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)")
_IMPLEMENT_STEP_RE = re.compile(r"\bimplements\s+[^{]*\bStep\b")
_EXECUTE_RE = re.compile(
    r"public\s+void\s+execute\s*\([^)]*\)\s*\{", re.DOTALL
)


def _resolve_step_name(class_name: str, annotation_value: Optional[str]) -> str:
    """Mirror rpa-core StepRegistry.getStepName: annotation wins, else derive.

    Derivation: strip a trailing "Step" suffix and lowercase the first char.
    """
    if annotation_value and annotation_value.strip():
        return annotation_value.strip()
    name = class_name
    if name.endswith("Step"):
        name = name[: -len("Step")]
    if not name:
        return class_name
    return name[0].lower() + name[1:]


def _extract_method_body(source: str, start: int, max_chars: int = 1200) -> str:
    """Extract a balanced method body starting at the brace after `start`."""
    brace_start = source.find("{", start)
    if brace_start == -1:
        return ""
    depth = 0
    i = brace_start
    while i < len(source):
        ch = source[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[brace_start : i + 1][:max_chars]
        i += 1
    return source[brace_start:brace_start + max_chars]


@dataclass
class JavaStep:
    class_name: str
    step_name: str
    rel_path: str
    execute_source: str
    file_name: str


def _java_files(process_dir: Path) -> list[Path]:
    java_root = process_dir / "src" / "main" / "java"
    if not java_root.is_dir():
        return []
    # Only classes under a .../steps/ package are real steps; helpers live
    # alongside but we still include them and let the .process ordering filter.
    return sorted(java_root.rglob("*.java"))


def collect_java_steps(process_dir: Path) -> dict[str, JavaStep]:
    """Map resolved step name -> JavaStep for every step-like class.

    A class is "step-like" if it has an @StepName annotation OR its simple
    name ends with "Step". Builders and helpers without either are skipped.
    """
    steps: dict[str, JavaStep] = {}
    for java_file in _java_files(process_dir):
        try:
            source = java_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        class_match = _CLASS_DECL_RE.search(source)
        if not class_match:
            continue
        class_name = class_match.group(1)
        annotation = _STEPNAME_ANN_RE.search(source)
        annotation_value = annotation.group(1) if annotation else None
        is_step_by_name = class_name.endswith("Step")
        if annotation_value is None and not is_step_by_name:
            continue
        step_name = _resolve_step_name(class_name, annotation_value)
        execute_match = _EXECUTE_RE.search(source)
        execute_source = ""
        if execute_match:
            execute_source = _extract_method_body(source, execute_match.end() - 1)
        rel_path = str(java_file.relative_to(process_dir)).replace(os.sep, "/")
        steps[step_name] = JavaStep(
            class_name=class_name,
            step_name=step_name,
            rel_path=rel_path,
            execute_source=execute_source,
            file_name=java_file.name,
        )
    return steps


# --- Asset (service variable) extraction ----------------------------------

# Matches the asset argument: either a string literal or an identifier
# (optionually qualified as Class.IDENT).
_ASSET_CALL_RE = re.compile(
    r"orchestratorService\s*(?:\.\s*assets\s*\(\s*\)\s*)?\s*\.\s*"
    r"(getCredentials|getAsset|get)\s*\(\s*"
    r"(?:\"([^\"]+)\"|([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?))"
    r"\s*\)",
)
_CONST_DEF_RE = re.compile(
    r'\bString\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]+)"'
)


def _build_constant_maps(java_files: list[Path]) -> tuple[dict[str, str], dict[str, dict[str, str]]]:
    """Build a global and per-class constant map for resolving asset names.

    Some processes reference assets via constants, e.g.
    `getCredentials(SAP_CREDENTIALS_ASSET)` where
    `String SAP_CREDENTIALS_ASSET = "sap_credentials"`. We resolve those so
    the README lists real asset names, not identifiers.
    """
    global_map: dict[str, str] = {}
    per_class: dict[str, dict[str, str]] = {}
    for java_file in java_files:
        try:
            source = java_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        class_match = _CLASS_DECL_RE.search(source)
        class_name = class_match.group(1) if class_match else java_file.stem
        for const_match in _CONST_DEF_RE.finditer(source):
            ident, value = const_match.group(1), const_match.group(2)
            global_map.setdefault(ident, value)
            per_class.setdefault(class_name, {})[ident] = value
    return global_map, per_class


def _classify_asset(name: str) -> str:
    if name.endswith("_credentials"):
        return "credentials"
    if name.endswith("_settings"):
        return "settings"
    return "config"


def _call_style(match: re.Match) -> str:
    method = match.group(1)
    # The regex optionally consumed ".assets()" -- detect by inspecting text.
    text = match.group(0)
    if ".assets()" in text:
        return f"assets.{method}"
    return f"legacy.{method}"


def extract_service_variables(
    process_dir: Path,
    java_files: list[Path],
    global_map: dict[str, str],
    per_class: dict[str, dict[str, str]],
) -> tuple[list[dict], list[str]]:
    """Extract deduplicated asset references from all step Java files."""

    # Map class simple name -> file stem for resolving Class.IDENT refs.
    stem_to_class: dict[str, str] = {}
    for jf in java_files:
        stem_to_class[jf.stem] = jf.stem

    seen: dict[str, dict] = {}
    warnings: list[str] = []
    for java_file in java_files:
        try:
            source = java_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        file_class = _CLASS_DECL_RE.search(source)
        file_class_name = file_class.group(1) if file_class else java_file.stem
        for match in _ASSET_CALL_RE.finditer(source):
            literal = match.group(2)
            ident_ref = match.group(3)
            if literal is not None:
                name = literal
            elif ident_ref is not None:
                name = _resolve_constant(
                    ident_ref, file_class_name, global_map, per_class
                )
                if name is None:
                    warnings.append(
                        f"Unresolved asset reference {ident_ref} in "
                        f"{java_file.name}; listed by identifier."
                    )
                    name = ident_ref
            else:
                continue
            if name in seen:
                # Keep first occurrence; merge call styles for traceability.
                seen[name]["callStyles"].add(_call_style(match))
                continue
            seen[name] = {
                "name": name,
                "kind": _classify_asset(name),
                "callStyles": {_call_style(match)},
                "definedIn": java_file.name,
            }

    result = []
    for name in sorted(seen):
        entry = seen[name]
        entry["callStyles"] = sorted(entry["callStyles"])
        result.append(entry)
    if warnings:
        # Surfaced via the top-level warnings list instead.
        pass
    return result, warnings


def _resolve_constant(
    ref: str,
    current_class: str,
    global_map: dict[str, str],
    per_class: dict[str, dict[str, str]],
) -> Optional[str]:
    """Resolve a constant reference (bare IDENT or Class.IDENT) to its value."""
    if "." in ref:
        cls, ident = ref.split(".", 1)
        return per_class.get(cls, {}).get(ident)
    # Bare identifier: prefer the constant defined in the same class, then
    # fall back to the global map.
    same_class = per_class.get(current_class, {})
    if ref in same_class:
        return same_class[ref]
    return global_map.get(ref)


# --- Manual Task (MT) extraction -----------------------------------------

_SHARED_FORM_BASENAMES = {"core", "template", "style"}

# MT_<NN>_<SUFFIX> = "literal"  |  MT_<NN>_<SUFFIX> = IDENT  (e.g. MT_02_QUEUE_NAME = MT_01_QUEUE_NAME)
_MT_CONST_RE = re.compile(
    r"\bString\s+MT_(\d+)_(QUEUE_NAME|NAME|TASK_NAME|PENDING_TAG|FINAL_TAG|PROCESSED_TAG)"
    r"\s*=\s*(?:\"([^\"]+)\"|([A-Za-z_][A-Za-z0-9_]*))\s*;",
)
_ACTIONLINK_FIELD_RE = re.compile(
    r"(?:private|public|protected)\s+(?:final\s+)?String\s+([A-Za-z_]\w*ActionLink)\s*[;=]"
)
_SHERPA_API_CRED_RE = re.compile(
    r'\bString\s+SHERPA_API_CREDENTIALS_ASSET\s*=\s*"([^"]+)"'
)
_MT_CONST_FIELDS = (
    ("QUEUE_NAME", "queueName"),
    ("NAME", "name"),
    ("TASK_NAME", "taskName"),
    ("PENDING_TAG", "pendingTag"),
    ("FINAL_TAG", "finalTag"),
    ("PROCESSED_TAG", "processedTag"),
)


def _words(name: str) -> list[str]:
    """Split a kebab/snake form name into lowercase words."""
    return [w for w in re.split(r"[-_]+", name) if w]


def _to_camel(name: str) -> str:
    """kebab/snake -> lowerCamelCase: process_new -> processNew."""
    words = _words(name)
    if not words:
        return name
    return words[0].lower() + "".join(w.capitalize() for w in words[1:])


def _to_pascal(name: str) -> str:
    """kebab/snake -> UpperCamelCase: process_new -> ProcessNew."""
    return "".join(w.capitalize() for w in _words(name)) or name


def _step_suffix(name: str) -> str:
    """PascalCase of the form name with a leading 'process_'/'process' stripped.

    Mirrors wf-migrate: process_new -> New -> PrepareNewStep / SaveNewStep.
    """
    stripped = re.sub(r"^process[_-]?", "", name)
    return _to_pascal(stripped)


def extract_manual_tasks(
    process_dir: Path,
    java_files: list[Path],
    java_steps: dict,
    global_map: dict[str, str],
    per_class: dict[str, dict[str, str]],
) -> tuple[list[dict], Optional[str], list[str]]:
    """Detect MT forms and link each to its MT_<NN>_* constants + step pair + DTO.

    Returns (manualTasks, mtApiCredentialsAsset, warnings). Non-canonical
    processes (no MT_<NN>_* constants, non-matching step names) yield partial
    records with None fields and warnings -- never guesses.
    """
    warnings: list[str] = []

    # 1. MT forms: src/main/resources/actions/*.js, excluding shared files.
    actions_dir = process_dir / "src" / "main" / "resources" / "actions"
    forms: list[Path] = []
    if actions_dir.is_dir():
        forms = sorted(
            p for p in actions_dir.glob("*.js")
            if p.stem not in _SHARED_FORM_BASENAMES
        )

    # 2. ActionLink field names across Java (typically InitParameters).
    action_link_fields: set[str] = set()
    for jf in java_files:
        try:
            src = jf.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        action_link_fields.update(_ACTIONLINK_FIELD_RE.findall(src))

    # 3. MT_<NN>_* constants (literal or identifier reference, resolved).
    mt_constants: dict[str, dict[str, Optional[str]]] = {}
    api_credentials: Optional[str] = None
    for jf in java_files:
        try:
            src = jf.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        class_match = _CLASS_DECL_RE.search(src)
        class_name = class_match.group(1) if class_match else jf.stem
        for m in _MT_CONST_RE.finditer(src):
            number, suffix, literal, ident = (
                m.group(1), m.group(2), m.group(3), m.group(4),
            )
            if literal is not None:
                value: Optional[str] = literal
            else:
                value = _resolve_constant(ident, class_name, global_map, per_class)
                if value is None:
                    warnings.append(
                        f"Unresolved MT constant MT_{number}_{suffix} = {ident} "
                        f"in {jf.name}; listed by identifier."
                    )
                    value = ident
            key = f"MT_{number}"
            entry = mt_constants.setdefault(
                key, {field: None for _, field in _MT_CONST_FIELDS}
            )
            for suf, field in _MT_CONST_FIELDS:
                if suf == suffix:
                    entry[field] = value
        if api_credentials is None:
            cred = _SHERPA_API_CRED_RE.search(src)
            if cred:
                api_credentials = cred.group(1)

    # Index Java steps by class simple name for sender/receiver lookup.
    by_class = {js.class_name: js for js in java_steps.values()}

    # 4. Build per-form records, linking to MT_<NN>_* by name/taskName.
    matched_mt: set[str] = set()
    manual_tasks: list[dict] = []
    for form in forms:
        name = form.stem
        camel = _to_camel(name)
        pascal = _to_pascal(name)
        suffix = _step_suffix(name)
        form_path = str(form.relative_to(process_dir)).replace(os.sep, "/")

        action_link = f"{camel}ActionLink"
        action_link_field = action_link if action_link in action_link_fields else None

        sender = by_class.get(f"Prepare{suffix}Step")
        receiver = by_class.get(f"Save{suffix}Step")

        dto_rel: Optional[str] = None
        dto_name: Optional[str] = None
        for jf in java_files:
            rel = str(jf.relative_to(process_dir)).replace(os.sep, "/")
            if rel.endswith(f"/model/{pascal}Result.java"):
                dto_rel = rel
                dto_name = jf.stem
                break

        # Link to MT_<NN>_* by MT_<NN>_NAME == form name or TASK_NAME == camel.
        linked: dict[str, Optional[str]] = {
            field: None for _, field in _MT_CONST_FIELDS
        }
        mt_number: Optional[str] = None
        for key, entry in mt_constants.items():
            if entry.get("name") == name or entry.get("taskName") == camel:
                linked = entry
                mt_number = key
                matched_mt.add(key)
                break

        if sender is None or receiver is None or dto_name is None:
            warnings.append(
                f"MT '{name}': sender/receiver/DTO not found by canonical name "
                f"(non-canonical process?)"
            )

        manual_tasks.append(
            {
                "name": name,
                "formPath": form_path,
                "actionLinkField": action_link_field,
                "senderStep": sender.class_name if sender else None,
                "senderStepPath": sender.rel_path if sender else None,
                "receiverStep": receiver.class_name if receiver else None,
                "receiverStepPath": receiver.rel_path if receiver else None,
                "resultDto": dto_name,
                "resultDtoPath": dto_rel,
                "mtNumber": mt_number,
                "queueName": linked.get("queueName"),
                "taskName": linked.get("taskName"),
                "pendingTag": linked.get("pendingTag"),
                "finalTag": linked.get("finalTag"),
                "processedTag": linked.get("processedTag"),
            }
        )

    if forms and not mt_constants:
        warnings.append(
            "MT forms detected but no MT_<NN>_* constants found "
            "(non-canonical process)."
        )
    for key in set(mt_constants) - matched_mt:
        warnings.append(
            f"MT constants {key} present but not linked to any actions/*.js form."
        )

    return manual_tasks, api_credentials, warnings


# --- Top-level orchestration ---------------------------------------------


def _read_process_config(process_dir: Path) -> dict:
    config_path = process_dir / "src" / "main" / "resources" / "process-config.json"
    if not config_path.is_file():
        return {}
    try:
        return json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _find_init_params(process_dir: Path) -> list[str]:
    resources = process_dir / "src" / "main" / "resources"
    if not resources.is_dir():
        return []
    matches = sorted(resources.rglob("*init_params*.json"))
    return [str(m.relative_to(process_dir)).replace(os.sep, "/") for m in matches]


def _find_email_templates(process_dir: Path) -> Optional[str]:
    resources = process_dir / "src" / "main" / "resources"
    if not resources.is_dir():
        return None
    matches = sorted(resources.glob("*_email_templates.json"))
    if not matches:
        return None
    return str(matches[0].relative_to(process_dir)).replace(os.sep, "/")


def analyze(process_dir: Path) -> dict:
    config = _read_process_config(process_dir)
    java_steps = collect_java_steps(process_dir)
    process_blocks = extract_step_blocks(process_dir)

    java_files = _java_files(process_dir)
    global_map, per_class = _build_constant_maps(java_files)
    service_variables, asset_warnings = extract_service_variables(
        process_dir, java_files, global_map, per_class
    )
    manual_tasks, mt_api_credentials, mt_warnings = extract_manual_tasks(
        process_dir, java_files, java_steps, global_map, per_class
    )

    warnings: list[str] = []
    steps: list[dict] = []
    for index, block in enumerate(process_blocks, start=1):
        step_name = block["stepName"]
        java = java_steps.get(step_name)
        if java is None:
            warnings.append(
                f"Step '{step_name}' (display '{block['displayName']}', "
                f"file {block['processFile']}) has no matching *Step.java class."
            )
            steps.append(
                {
                    "order": index,
                    "displayName": block["displayName"],
                    "stepName": step_name,
                    "className": None,
                    "javaPath": None,
                    "processFile": block["processFile"],
                    "executeSource": "",
                }
            )
            continue
        steps.append(
            {
                "order": index,
                "displayName": block["displayName"],
                "stepName": step_name,
                "className": java.class_name,
                "javaPath": java.rel_path,
                "processFile": block["processFile"],
                "executeSource": java.execute_source,
            }
        )

    # Steps declared in Java but never referenced from any .process file.
    referenced = {b["stepName"] for b in process_blocks}
    orphan_java = sorted(set(java_steps) - referenced)
    for name in orphan_java:
        warnings.append(
            f"Java step '{name}' ({java_steps[name].file_name}) is not "
            f"referenced by any .process file."
        )

    warnings.extend(asset_warnings)
    warnings.extend(mt_warnings)

    return {
        "processDir": str(process_dir),
        "config": config,
        "steps": steps,
        "initParamsFiles": _find_init_params(process_dir),
        "emailTemplatesFile": _find_email_templates(process_dir),
        "serviceVariables": service_variables,
        "hasMt": bool(manual_tasks),
        "manualTasks": manual_tasks,
        "mtApiCredentialsAsset": mt_api_credentials,
        "warnings": warnings,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Analyze a Sherpa RPA process directory into a JSON report."
    )
    parser.add_argument("processDir", help="Path to the process directory")
    parser.add_argument(
        "--out", help="Write the report to this file instead of stdout"
    )
    args = parser.parse_args(argv)

    process_dir = Path(args.processDir).resolve()
    if not process_dir.is_dir():
        print(f"error: not a directory: {process_dir}", file=sys.stderr)
        return 2

    report = analyze(process_dir)
    rendered = json.dumps(report, indent=2, ensure_ascii=False)
    if args.out:
        Path(args.out).write_text(rendered, encoding="utf-8")
    else:
        print(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())