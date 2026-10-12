#!/usr/bin/env python3
"""Build benchmark.json (viewer schema) from grading.json + timing.json files."""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

ITER = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
SKILL = "write-readme"
MODEL = "glm-5.2:cloud"

EVALS = [
    (1, "ics60001-multistage-derived-names", "ics60001"),
    (2, "ics00057-accounts-annotation-names-constants", "ics00057-accounts"),
    (3, "rps-sales-legacy-api-single-process", "rps-sales"),
]
CONFIGS = ["with_skill", "without_skill"]


def _stats(values: list[float]) -> dict:
    if not values:
        return {"mean": 0.0, "stddev": 0.0, "min": 0.0, "max": 0.0}
    n = len(values)
    mean = sum(values) / n
    sd = math.sqrt(sum((x - mean) ** 2 for x in values) / (n - 1)) if n > 1 else 0.0
    return {
        "mean": round(mean, 4),
        "stddev": round(sd, 4),
        "min": round(min(values), 4),
        "max": round(max(values), 4),
    }


def _fmt_delta(skill_vals, base_vals):
    sm = sum(skill_vals) / len(skill_vals) if skill_vals else 0
    bm = sum(base_vals) / len(base_vals) if base_vals else 0
    d = sm - bm
    return ("+" if d >= 0 else "") + f"{d:.2f}"


def main() -> int:
    runs = []
    pass_by_config = {"with_skill": [], "without_skill": []}
    time_by_config = {"with_skill": [], "without_skill": []}
    token_by_config = {"with_skill": [], "without_skill": []}

    for eval_id, eval_name, _ in EVALS:
        eval_dir = ITER / eval_name
        for config in CONFIGS:
            run_dir = eval_dir / config
            grading_path = run_dir / "grading.json"
            timing_path = run_dir / "timing.json"
            grading = json.loads(grading_path.read_text(encoding="utf-8"))
            timing = json.loads(timing_path.read_text(encoding="utf-8")) if timing_path.is_file() else {}

            exps = grading.get("expectations", [])
            passed = sum(1 for e in exps if e.get("passed"))
            total = len(exps)
            pass_rate = (passed / total) if total else 0.0
            time_s = timing.get("total_duration_seconds", 0.0)
            tokens = timing.get("total_tokens", 0)

            pass_by_config[config].append(pass_rate)
            time_by_config[config].append(time_s)
            token_by_config[config].append(tokens)

            runs.append(
                {
                    "eval_id": eval_id,
                    "eval_name": eval_name,
                    "configuration": config,
                    "run_number": 1,
                    "result": {
                        "pass_rate": round(pass_rate, 4),
                        "passed": passed,
                        "failed": total - passed,
                        "total": total,
                        "time_seconds": round(time_s, 2),
                        "tokens": tokens,
                        "errors": 0,
                    },
                    "expectations": [
                        {"text": e["text"], "passed": e["passed"], "evidence": e["evidence"]}
                        for e in exps
                    ],
                    "notes": [],
                }
            )

    # Order: each with_skill before its without_skill counterpart.
    ordered = []
    for eval_id, eval_name, _ in EVALS:
        for config in CONFIGS:
            for r in runs:
                if r["eval_id"] == eval_id and r["configuration"] == config:
                    ordered.append(r)

    delta = {
        "pass_rate": _fmt_delta(pass_by_config["with_skill"], pass_by_config["without_skill"]),
        "time_seconds": _fmt_delta(time_by_config["with_skill"], time_by_config["without_skill"]),
        "tokens": _fmt_delta(token_by_config["with_skill"], token_by_config["without_skill"]),
    }

    benchmark = {
        "metadata": {
            "skill_name": SKILL,
            "skill_path": str(Path("C:/Users/dzmitry_klim/.claude/skills/write-readme")),
            "executor_model": MODEL,
            "analyzer_model": MODEL,
            "timestamp": "2026-08-05T00:00:00Z",
            "evals_run": [e[0] for e in EVALS],
            "runs_per_configuration": 1,
        },
        "runs": ordered,
        "run_summary": {
            "with_skill": {
                "pass_rate": _stats(pass_by_config["with_skill"]),
                "time_seconds": _stats(time_by_config["with_skill"]),
                "tokens": _stats(token_by_config["with_skill"]),
            },
            "without_skill": {
                "pass_rate": _stats(pass_by_config["without_skill"]),
                "time_seconds": _stats(time_by_config["without_skill"]),
                "tokens": _stats(token_by_config["without_skill"]),
            },
            "delta": delta,
        },
        "notes": [
            "with_skill pass rate is 100% across all 3 evals (25/25 assertions); without_skill averages ~37%.",
            "without_skill consistently fails step-name resolution, ordered step list, and service-variable coverage — the core value the analyzer provides.",
            "Run once per configuration (runs_per_configuration=1); stddev is 0 for single runs.",
            "rps-sales with_skill timing not captured (subagent completed via blocking retrieval) — tokens/time approximated as 0; pass-rate assertions unaffected.",
        ],
    }

    out = ITER / "benchmark.json"
    out.write_text(json.dumps(benchmark, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"wrote {out}")
    print(
        f"with_skill pass_rate mean: {sum(pass_by_config['with_skill'])/3:.2f}; "
        f"without_skill: {sum(pass_by_config['without_skill'])/3:.2f}; delta {delta['pass_rate']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())