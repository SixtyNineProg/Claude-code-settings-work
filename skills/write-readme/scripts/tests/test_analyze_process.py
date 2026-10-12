#!/usr/bin/env python3
"""Smoke tests for analyze_process.py against a real Sherpa process.

Runs the analyzer against the ics60001 process (the canonical multi-stage
example) and asserts the report shape and key resolved values. Run from the
repo root that contains ics60001, or pass the process dir via --ics60001.

    python scripts/tests/test_analyze_process.py
    python scripts/tests/test_analyze_process.py --ics60001 /path/to/ics60001

Optional canonical MT coverage against ics00057-accounts (branch
origin/feat/00057-accounts). Obtain it via a worktree, then point --ics00057:

    git worktree add /tmp/00057-accounts origin/feat/00057-accounts
    python scripts/tests/test_analyze_process.py --ics00057 /tmp/00057-accounts/ics00057-accounts
"""

from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ANALYZER_PATH = SCRIPT_DIR.parent / "analyze_process.py"

# Default location when run from the rpa-suite repo root.
DEFAULT_ICS60001 = Path("ics60001")


def _load_analyzer():
    spec = importlib.util.spec_from_file_location("analyze_process", ANALYZER_PATH)
    module = importlib.util.module_from_spec(spec)
    # Register before exec so dataclass can resolve cls.__module__ in sys.modules.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _assert(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def _test_ics60001(process_dir: Path) -> None:
    analyzer = _load_analyzer()
    report = analyzer.analyze(process_dir)

    # --- process-config ---------------------------------------------------
    config = report["config"]
    _assert(config.get("bpName") == "ICS-60001", "bpName must be ICS-60001")
    _assert(
        config.get("controlName") == "Correctness of manual journal entries",
        "controlName must be parsed from process-config.json",
    )

    # --- steps: count, order, resolution ---------------------------------
    steps = report["steps"]
    _assert(len(steps) == 8, f"expected 8 ordered steps, got {len(steps)}")

    expected_order = [
        ("processSetup", "ProcessSetupStep", "Stage1.process"),
        ("getSapReportData", "GetSapReportDataStep", "Stage1.process"),
        ("prepareDocumentTypeLists", "PrepareDocumentTypeListsStep", "Stage1.process"),
        ("persistDocumentTypeLists", "PersistDocumentTypeListsStep", "Stage2.process"),
        ("samplePreparation", "SamplePreparationStep", "Stage2.process"),
        ("ownersEnrichment", "OwnersEnrichmentStep", "Stage2.process"),
        ("sendMultitaskNotification", "SendMultitaskNotificationStep", "Stage2.process"),
        ("finalizeAndPublishResults", "FinalizeAndPublishResultsStep", "Stage3.process"),
    ]
    for index, (step_name, class_name, proc_file) in enumerate(expected_order):
        step = steps[index]
        _assert(
            step["stepName"] == step_name,
            f"step {index + 1} stepName: expected {step_name}, got {step['stepName']}",
        )
        _assert(
            step["className"] == class_name,
            f"step {index + 1} className: expected {class_name}, got {step['className']}",
        )
        _assert(
            step["processFile"] == proc_file,
            f"step {index + 1} processFile: expected {proc_file}, got {step['processFile']}",
        )
        _assert(
            step["javaPath"] is not None
            and step["javaPath"].endswith(f"/steps/{class_name}.java"),
            f"step {index + 1} javaPath must end with /steps/{class_name}.java",
        )
        _assert(
            bool(step["executeSource"]),
            f"step {index + 1} executeSource must not be empty",
        )

    # --- init params / email templates ------------------------------------
    _assert(
        any("ics60001_init_params.json" in p for p in report["initParamsFiles"]),
        "init params file must be discovered under resources/**/*init_params*.json",
    )
    _assert(
        report["emailTemplatesFile"] == "src/main/resources/ics60001_email_templates.json",
        f"email templates file mismatch: {report['emailTemplatesFile']}",
    )

    # --- service variables: literals, assets.* style ---------------------
    variables = {v["name"]: v for v in report["serviceVariables"]}
    for required in (
        "sap_credentials",
        "proxy_credentials",
        "sharepoint_credentials",
        "sap_settings",
    ):
        _assert(required in variables, f"service variable {required} must be present")
    _assert(
        variables["sap_credentials"]["kind"] == "credentials",
        "sap_credentials classified as credentials",
    )
    _assert(
        variables["sap_settings"]["kind"] == "settings",
        "sap_settings classified as settings",
    )
    _assert(
        "assets.getCredentials" in variables["sap_credentials"]["callStyles"],
        "sap_credentials uses the assets.getCredentials call style",
    )

    # --- MT: non-canonical (forms + ActionLinks, no MT_<NN>_* constants) --
    _assert(report["hasMt"] is True, "ics60001 must be detected as an MT process")
    mts = {m["name"]: m for m in report["manualTasks"]}
    _assert(
        set(mts) == {"document-review", "document-type-policy-editor"},
        f"expected 2 MT forms, got {set(mts)}",
    )
    _assert(
        mts["document-review"]["formPath"].endswith("actions/document-review.js"),
        f"document-review formPath: {mts['document-review']['formPath']}",
    )
    _assert(
        mts["document-review"]["actionLinkField"] == "documentReviewActionLink",
        f"document-review actionLinkField: {mts['document-review']['actionLinkField']}",
    )
    _assert(
        mts["document-type-policy-editor"]["actionLinkField"]
        == "documentTypePolicyEditorActionLink",
        "document-type-policy-editor actionLinkField mismatch",
    )
    for m in report["manualTasks"]:
        _assert(
            m["mtNumber"] is None and m["queueName"] is None and m["taskName"] is None,
            f"non-canonical MT must have no resolved constants: {m}",
        )

    # --- warnings: MT-related only (no step/asset regressions) -----------
    mt_warns = [
        w for w in report["warnings"] if "MT" in w or "non-canonical" in w
    ]
    non_mt_warns = [w for w in report["warnings"] if w not in mt_warns]
    _assert(
        bool(mt_warns),
        "expected an MT non-canonical warning (no MT_<NN>_* constants)",
    )
    _assert(
        non_mt_warns == [],
        f"unexpected non-MT warnings (step/asset regression?): {non_mt_warns}",
    )


def _test_ics00057_mt(process_dir: Path) -> None:
    """Canonical MT process: 3 MTs fully linked to MT_<NN>_* constants."""
    analyzer = _load_analyzer()
    report = analyzer.analyze(process_dir)

    _assert(report["hasMt"] is True, "ics00057-accounts must be detected as MT")
    mts = {m["name"]: m for m in report["manualTasks"]}
    _assert(
        set(mts) == {"process_new", "process_changed", "process_all"},
        f"expected 3 MT forms, got {set(mts)}",
    )

    expected = {
        "process_new": {
            "mtNumber": "MT_01",
            "actionLinkField": "processNewActionLink",
            "senderStep": "PrepareNewStep",
            "receiverStep": "SaveNewStep",
            "resultDto": "ProcessNewResult",
            "queueName": "ICS-00057 Обновление справочника",
            "taskName": "processNew",
            "pendingTag": "pending",
            "finalTag": "reviewed",
            "processedTag": "processed",
        },
        "process_changed": {
            "mtNumber": "MT_02",
            "actionLinkField": "processChangedActionLink",
            "senderStep": "PrepareChangedStep",
            "receiverStep": "SaveChangedStep",
            "resultDto": "ProcessChangedResult",
            "queueName": "ICS-00057 Обновление справочника",
            "taskName": "processChanged",
            "pendingTag": "pendingChanged",
            "finalTag": "reviewedChanged",
            "processedTag": "processedChanged",
        },
        "process_all": {
            "mtNumber": "MT_03",
            "actionLinkField": "processAllActionLink",
            "senderStep": "PrepareAllStep",
            "receiverStep": "SaveAllStep",
            "resultDto": "ProcessAllResult",
            "queueName": "ICS-00057 Обновление справочника",
            "taskName": "processAll",
            "pendingTag": "pendingAll",
            "finalTag": "reviewedAll",
            "processedTag": "processedAll",
        },
    }

    for name, exp in expected.items():
        m = mts[name]
        _assert(
            m["formPath"].endswith(f"actions/{name}.js"),
            f"{name} formPath: {m['formPath']}",
        )
        for key, value in exp.items():
            _assert(
                m[key] == value,
                f"{name}.{key}: expected {value!r}, got {m[key]!r}",
            )
        _assert(
            bool(m["senderStepPath"]) and m["senderStepPath"].endswith(
                f"/steps/{exp['senderStep']}.java"
            ),
            f"{name} senderStepPath must end with /steps/{exp['senderStep']}.java",
        )
        _assert(
            bool(m["receiverStepPath"]) and m["receiverStepPath"].endswith(
                f"/steps/{exp['receiverStep']}.java"
            ),
            f"{name} receiverStepPath must end with /steps/{exp['receiverStep']}.java",
        )
        _assert(
            bool(m["resultDtoPath"]) and m["resultDtoPath"].endswith(
                f"/model/{exp['resultDto']}.java"
            ),
            f"{name} resultDtoPath must end with /model/{exp['resultDto']}.java",
        )

    _assert(
        report["mtApiCredentialsAsset"] == "sherpa_api_credentials",
        f"mtApiCredentialsAsset: {report['mtApiCredentialsAsset']}",
    )
    mt_warns = [w for w in report["warnings"] if "MT" in w or "non-canonical" in w]
    _assert(
        mt_warns == [],
        f"canonical MT process must have no MT warnings, got: {mt_warns}",
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Test analyze_process.py")
    parser.add_argument(
        "--ics60001",
        type=Path,
        default=DEFAULT_ICS60001,
        help="Path to the ics60001 process directory",
    )
    parser.add_argument(
        "--ics00057",
        type=Path,
        default=None,
        help="Path to ics00057-accounts (canonical MT fixture); skip if unset",
    )
    args = parser.parse_args(argv)

    process_dir = args.ics60001.resolve()
    if not process_dir.is_dir():
        print(
            f"error: ics60001 not found at {process_dir}. "
            "Run from the rpa-suite repo root or pass --ics60001.",
            file=sys.stderr,
        )
        return 2

    _test_ics60001(process_dir)
    print("ok: analyze_process.py passed all assertions against ics60001")

    if args.ics00057 is not None:
        ics00057_dir = args.ics00057.resolve()
        if not ics00057_dir.is_dir():
            print(
                f"error: ics00057-accounts not found at {ics00057_dir}; skipping canonical MT test.",
                file=sys.stderr,
            )
        else:
            _test_ics00057_mt(ics00057_dir)
            print("ok: analyze_process.py passed all assertions against ics00057-accounts (MT)")
    else:
        print("skip: --ics00057 not provided; skipping canonical MT test")

    return 0


if __name__ == "__main__":
    sys.exit(main())