#!/usr/bin/env python3
"""Grade README.md outputs against assertions + ground-truth analyzer report.

For each eval, reads with_skill/outputs/README.md and without_skill/outputs/README.md,
runs analyze_process.py against the real process dir to get ground truth, and
checks the assertions. Writes grading.json into each run directory with fields
text / passed / evidence (the format the benchmark viewer expects).

Usage:
    python grade.py <iteration-dir>
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
from pathlib import Path
from typing import Optional

ANALYZER_PATH = Path(
    "C:/Users/dzmitry_klim/.claude/skills/write-readme/scripts/analyze_process.py"
)

# Process dir per eval name.
PROCESS_DIRS = {
    "ics60001-multistage-derived-names": Path(
        "C:/Users/dzmitry_klim/IdeaProjects/sherpa/rpa-suite/ics60001"
    ),
    "ics00057-accounts-annotation-names-constants": Path(
        "C:/Users/dzmitry_klim/IdeaProjects/sherpa/rpa-suite/ics00057-accounts"
    ),
    "rps-sales-legacy-api-single-process": Path(
        "C:/Users/dzmitry_klim/IdeaProjects/sherpa/rpa-suite/rps-sales"
    ),
}

EXPECTED_FIRST_LINE = {
    "ics60001-multistage-derived-names": "# ICS-60001",
    "ics00057-accounts-annotation-names-constants": "# ICS-00057",
    "rps-sales-legacy-api-single-process": "# RPS-Sales",
}

EXPECTED_STEPS = {
    "ics60001-multistage-derived-names": [
        "processSetup",
        "getSapReportData",
        "prepareDocumentTypeLists",
        "persistDocumentTypeLists",
        "samplePreparation",
        "ownersEnrichment",
        "sendMultitaskNotification",
        "finalizeAndPublishResults",
    ],
    "ics00057-accounts-annotation-names-constants": [
        "InfrastructureStep",
        "SapStep",
        "PrepareNewStep",
        "SaveNewStep",
        "PrepareChangedStep",
        "SaveChangedStep",
        "PrepareAllStep",
        "SaveAllStep",
        "UploadEvidenceStep",
    ],
    "rps-sales-legacy-api-single-process": [
        "getOnecReportData",
        "prepareInitialParameters",
        "dataProcessing",
        "getSapReportData",
    ],
}

REQUIRED_ASSETS = {
    "ics60001-multistage-derived-names": [
        "sap_credentials",
        "proxy_credentials",
        "sharepoint_credentials",
        "sherpa_api_credentials",
        "mim_credentials",
        "sap_settings",
        "currency_rates_config",
    ],
    "ics00057-accounts-annotation-names-constants": [
        "sap_credentials",
        "sap_settings",
        "sharepoint_credentials",
        "sherpa_api_credentials",
    ],
    "rps-sales-legacy-api-single-process": [
        "1c_ct_credentials",
        "jira_jsd_credentials",
        "sap_credentials",
    ],
}

EXPECTED_INIT_SUBSTR = {
    "ics60001-multistage-derived-names": "ics60001_init_params.json",
    "ics00057-accounts-annotation-names-constants": "ics00057_accounts_init_params.json",
    "rps-sales-legacy-api-single-process": "rps_sales_init_params.json",
}

EXPECTED_EMAIL = {
    "ics60001-multistage-derived-names": "ics60001_email_templates.json",
    "ics00057-accounts-annotation-names-constants": "ics00057_accounts_email_templates.json",
    "rps-sales-legacy-api-single-process": "rps_sales_email_templates.json",
}


def _load_analyzer():
    spec = importlib.util.spec_from_file_location("analyze_process", ANALYZER_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


_NUM_STEP_RE = re.compile(r"^\s*\d+\.\s+(.+)", re.MULTILINE)
_LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
_BACKTICK_RE = re.compile(r"`([^`]+)`")


def _extract_numbered_steps(readme: str) -> list[str]:
    """Return the backticked step names from the numbered 'Шаги процесса' list."""
    # Restrict to the 'Шаги процесса' section.
    section = re.search(
        r"##\s*Шаги процесса(.*?)(?=\n##\s|\Z)", readme, re.DOTALL
    )
    if not section:
        return []
    body = section.group(1)
    steps: list[str] = []
    for line in body.splitlines():
        m = re.match(r"\s*\d+\.\s+(.*)", line)
        if not m:
            continue
        item = m.group(1)
        # Prefer the first backticked token (the resolved step name).
        bt = _BACKTICK_RE.search(item)
        steps.append(bt.group(1) if bt else item.strip())
    return steps


def _extract_step_links(readme: str) -> list[tuple[str, str]]:
    section = re.search(
        r"##\s*Шаги процесса(.*?)(?=\n##\s|\Z)", readme, re.DOTALL
    )
    if not section:
        return []
    links: list[tuple[str, str]] = []
    for line in section.group(1).splitlines():
        if not re.match(r"\s*\d+\.\s+", line):
            continue
        for link in _LINK_RE.finditer(line):
            label, target = link.group(1), link.group(2)
            # The step-name link target is the .java path; label is the class.
            if target.endswith(".java"):
                links.append((label, target))
            elif target.endswith(".json"):
                continue
    return links


def _asset_names_in_table(readme: str) -> list[str]:
    section = re.search(
        r"##\s*Сервисные переменные.*?\|.*?\|.*?\|(.*?)(?=\n##\s|\Z)",
        readme,
        re.DOTALL,
    )
    if not section:
        return []
    names: list[str] = []
    for line in section.group(1).splitlines():
        m = _BACKTICK_RE.search(line)
        if m:
            names.append(m.group(1))
    return names


def grade_one(readme: Optional[str], report: dict, eval_name: str, process_dir: Path) -> list[dict]:
    """Return a list of {text, passed, evidence} for each assertion."""
    results: list[dict] = []

    def check(text: str, passed: bool, evidence: str) -> None:
        results.append({"text": text, "passed": bool(passed), "evidence": evidence})

    # README exists.
    if readme is None:
        check("README.md существует", False, "README.md not found in outputs")
        return results

    # First line.
    first = readme.lstrip("\ufeff").splitlines()[0] if readme.strip() else ""
    check(
        f"Первая строка начинается с '{EXPECTED_FIRST_LINE[eval_name]}'",
        first.startswith(EXPECTED_FIRST_LINE[eval_name]),
        f"first line: {first!r}",
    )

    # Step count + names + order.
    actual_steps = _extract_numbered_steps(readme)
    expected = EXPECTED_STEPS[eval_name]
    check(
        f"Список шагов содержит {len(expected)} пунктов в ожидаемом порядке",
        actual_steps == expected,
        f"got {actual_steps}",
    )

    # Step link targets resolve to real files.
    links = _extract_step_links(readme)
    broken = [
        target
        for _, target in links
        if not (process_dir / target).is_file()
    ]
    check(
        "Каждая ссылка на шаг ведёт на существующий .java файл",
        len(links) > 0 and not broken,
        f"{len(links)} links; broken: {broken[:3]}",
    )

    # Step names match resolved stepName (not InternalName / not DisplayName).
    report_step_names = [s["stepName"] for s in report["steps"]]
    check(
        "Имена шагов совпадают с resolved stepName из отчёта",
        actual_steps == report_step_names,
        f"report: {report_step_names}; readme: {actual_steps}",
    )

    # init params references real path substring.
    expected_init = EXPECTED_INIT_SUBSTR[eval_name]
    init_section = re.search(
        r"###\s*Параметры инициализации(.*?)(?=\n###|\n##\s|\Z)",
        readme,
        re.DOTALL,
    )
    init_ok = bool(init_section) and expected_init in init_section.group(1)
    check(
        f"Секция параметров инициализации ссылается на {expected_init}",
        init_ok,
        "init section present and references expected file" if init_ok else "missing or wrong reference",
    )

    # Email section.
    email_section = re.search(
        r"###\s*Шаблоны email-уведомлений(.*?)(?=\n###|\n##\s|\Z)",
        readme,
        re.DOTALL,
    )
    email_file = report.get("emailTemplatesFile")
    if email_file:
        email_ok = bool(email_section) and EXPECTED_EMAIL[eval_name] in (
            email_section.group(1) if email_section else ""
        )
        check(
            "Секция email-шаблонов присутствует и ссылается на реальный файл",
            email_ok,
            f"emailTemplatesFile in report: {email_file}",
        )
    else:
        check(
            "Секция email-шаблонов опущена (файла нет)",
            email_section is None,
            "no email templates file in process",
        )

    # Service variables table contains required assets.
    asset_names = set(_asset_names_in_table(readme))
    required = REQUIRED_ASSETS[eval_name]
    missing = [a for a in required if a not in asset_names]
    check(
        f"Таблица сервисных переменных содержит: {', '.join(required)}",
        not missing,
        f"missing: {missing}; present: {sorted(asset_names)}",
    )

    # No unresolved constant identifiers in the service-variables table.
    unresolved = [n for n in asset_names if re.fullmatch(r"[A-Z_][A-Z0-9_]*", n or "") and not n.endswith("_credentials") and not n.endswith("_settings")]
    check(
        "В таблице нет неразрешённых идентификаторов-констант",
        not unresolved,
        f"unresolved identifiers: {unresolved}",
    )

    # rps-sales: orphan not in numbered steps.
    if eval_name == "rps-sales-legacy-api-single-process":
        orphan_present = "_GetSapReportData" in " ".join(actual_steps)
        check(
            "Отключённый шаг _GetSapReportData не включён в нумерованный список",
            not orphan_present,
            f"steps: {actual_steps}",
        )

    return results


def main(argv=None) -> int:
    iteration_dir = Path(argv[0] if argv else sys.argv[1])
    analyzer = _load_analyzer()

    for eval_name, process_dir in PROCESS_DIRS.items():
        eval_dir = iteration_dir / eval_name
        report = analyzer.analyze(process_dir)
        for run in ("with_skill", "without_skill"):
            readme_path = eval_dir / run / "outputs" / "README.md"
            readme = None
            if readme_path.is_file():
                readme = readme_path.read_text(encoding="utf-8")
            results = grade_one(readme, report, eval_name, process_dir)
            grading = {
                "eval_name": eval_name,
                "run": run,
                "expectations": results,
            }
            out_path = eval_dir / run / "grading.json"
            out_path.write_text(
                json.dumps(grading, indent=2, ensure_ascii=False), encoding="utf-8"
            )
            passed = sum(1 for r in results if r["passed"])
            total = len(results)
            print(f"{eval_name} / {run}: {passed}/{total} passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())