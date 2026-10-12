#!/usr/bin/env python3
"""Programmatic grader for write_documentation skill eval runs.

Usage:
  python grade_run.py <run_dir> --bpname <BP> --steps <N> [--systems "A,B,C"]
  --  run_dir contains outputs/documentation/ with the generated HTML files.

Reads assertions from the sibling eval_metadata.json (assertions with auto=true
are checked programmatically; auto=false are left for inline grading).
Writes grading.json into <run_dir>/ with the schema the eval viewer expects:
  { "expectations": [ {"text": ..., "passed": bool, "evidence": str}, ... ] }
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path


def load_assertions(run_dir: Path):
    meta_path = run_dir.parent / "eval_metadata.json"
    if not meta_path.exists():
        # fallback: no metadata, use a default assertion set
        return None
    with open(meta_path, "r", encoding="utf-8") as f:
        return json.load(f)


def list_html(doc_dir: Path):
    if not doc_dir.exists():
        return []
    return sorted(doc_dir.glob("*.html"))


def read_all(doc_dir: Path):
    chunks = []
    for p in list_html(doc_dir):
        try:
            chunks.append((p.name, p.read_text(encoding="utf-8", errors="replace")))
        except Exception as e:
            chunks.append((p.name, f"<<read error: {e}>>"))
    return chunks


def check_all_expected_files(doc_dir: Path, bp: str, expected_steps: int):
    expected = [
        f"{bp}.html",
        f"{bp} - История изменений.html",
        f"{bp} - Инструкция по развертыванию.html",
        f"{bp}-PDD - Process Design Document.html",
        f"{bp}-TD - Test Documentation.html",
        f"{bp}-UG - User Guide.html",
    ]
    missing = [n for n in expected if not (doc_dir / n).exists()]
    step_files = sorted(doc_dir.glob(f"{bp}-Step-*.html"))
    evidence = f"found {len(list_html(doc_dir))} html files; {len(step_files)} step files; missing: {missing}"
    passed = not missing
    return passed, evidence


def check_no_wrapper(doc_dir: Path):
    bad = []
    pattern = re.compile(r"<!DOCTYPE|<html\b|<head\b|<body\b|<style\b", re.IGNORECASE)
    for name, txt in read_all(doc_dir):
        if pattern.search(txt):
            bad.append(name)
    return (not bad), f"files with wrapper tags: {bad}"


def check_step_count(doc_dir: Path, bp: str, expected: int):
    step_files = sorted(doc_dir.glob(f"{bp}-Step-*.html"))
    actual = len(step_files)
    names = [p.name for p in step_files]
    return (actual == expected), f"expected {expected} step files, found {actual}: {names}"


def check_cross_refs(doc_dir: Path, bp: str):
    # look for IDs not matching the bp prefix
    pat = re.compile(rf"\b(?!{re.escape(bp)}-)([A-Z]+-\d{{4,}})-(?:Step|EX|PDD|TD|UG)\b")
    bad = set()
    for name, txt in read_all(doc_dir):
        for m in pat.findall(txt):
            if m != bp:
                bad.add(m)
    return (not bad), f"non-{bp} cross-ref prefixes found: {sorted(bad)}"


def check_no_demobp(doc_dir: Path):
    bad = []
    for name, txt in read_all(doc_dir):
        if "DemoBP" in txt or "демобп" in txt.lower():
            bad.append(name)
    return (not bad), f"files still containing 'DemoBP': {bad}"


def check_no_placeholder(doc_dir: Path):
    bad = []
    # ${...} FreeMarker variables are LEGITIMATE documented content in the
    # Нотификации "Текущее значение" column (the email template bodies use them),
    # so we do NOT flag ${...}. We only flag clearly unfilled template scaffolding.
    pats = [
        re.compile(r"имя_ресурса_\d"),
        re.compile(r"\{\{\{"),
        re.compile(r"\bplaceholder\b", re.IGNORECASE),
        re.compile(r"Действие \d+[;.]?"),
    ]
    for name, txt in read_all(doc_dir):
        for pat in pats:
            m = pat.search(txt)
            if m:
                bad.append((name, pat.pattern, m.group(0)))
    return (not bad), f"placeholder hits: {bad[:10]}"


def check_bpname_consistent(doc_dir: Path, bp: str):
    # all html files should start with bp (except none)
    bad = [p.name for p in list_html(doc_dir) if not p.name.startswith(bp)]
    return (not bad), f"files not starting with {bp}: {bad}"


def check_pdd_systems(doc_dir: Path, bp: str, systems):
    pdd = doc_dir / f"{bp}-PDD - Process Design Document.html"
    if not pdd.exists():
        return False, f"PDD not found at {pdd.name}"
    txt = pdd.read_text(encoding="utf-8", errors="replace")
    if "Используемые системы" not in txt:
        return False, "PDD missing 'Используемые системы' section"
    found = []
    for s in systems:
        # case-insensitive substring on the systems table region
        region = txt[txt.index("Используемые системы"):]
        if s.lower() in region.lower():
            found.append(s)
    missing = [s for s in systems if s not in found]
    return (not missing), f"systems found={found}, missing={missing}"


CHECKS = {
    "all_expected_files_exist": check_all_expected_files,
    "no_html_wrapper": check_no_wrapper,
    "step_file_count_matches_java": check_step_count,
    "cross_ref_id_format": check_cross_refs,
    "no_leftover_demobp": check_no_demobp,
    "no_leftover_placeholder": check_no_placeholder,
    "bpName_consistent": check_bpname_consistent,
    "pdd_systems_present": check_pdd_systems,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir")
    ap.add_argument("--bpname", required=True)
    ap.add_argument("--steps", type=int, required=True)
    ap.add_argument("--systems", default="", help="comma-separated system names")
    args = ap.parse_args()

    run_dir = Path(args.run_dir)
    doc_dir = run_dir / "outputs" / "documentation"
    systems = [s.strip() for s in args.systems.split(",") if s.strip()]

    meta = load_assertions(run_dir)
    assertions = meta.get("assertions", []) if meta else []

    DISPATCH = {
        "all_expected_files_exist": lambda: check_all_expected_files(doc_dir, args.bpname, args.steps),
        "no_html_wrapper": lambda: check_no_wrapper(doc_dir),
        "step_file_count_matches_java": lambda: check_step_count(doc_dir, args.bpname, args.steps),
        "cross_ref_id_format": lambda: check_cross_refs(doc_dir, args.bpname),
        "no_leftover_demobp": lambda: check_no_demobp(doc_dir),
        "no_leftover_placeholder": lambda: check_no_placeholder(doc_dir),
        "bpName_consistent": lambda: check_bpname_consistent(doc_dir, args.bpname),
        "pdd_systems_present": lambda: check_pdd_systems(doc_dir, args.bpname, systems),
    }

    expectations = []
    for a in assertions:
        aid = a.get("id")
        text = a.get("text", aid)
        if a.get("auto") and aid in DISPATCH:
            passed, evidence = DISPATCH[aid]()
            expectations.append({"text": text, "passed": bool(passed), "evidence": evidence})
        else:
            # subjective / inline-graded — leave as not-yet-graded
            expectations.append({"text": text, "passed": None, "evidence": "awaiting inline grading"})

    out = {"expectations": expectations}
    out_path = run_dir / "grading.json"
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    passed_count = sum(1 for e in expectations if e["passed"] is True)
    total = len(expectations)
    print(f"{run_dir.name}: {passed_count}/{total} auto-passed -> {out_path}")


if __name__ == "__main__":
    main()