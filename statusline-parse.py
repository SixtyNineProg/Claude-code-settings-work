#!/usr/bin/env python
"""Standalone parser for Claude Code statusLine JSON context.

Reads the statusLine JSON (passed as argv[1] — a path to a temp file containing
the JSON, or '-' for stdin) and prints FOUR tab-separated fields:
    <path>\t<model_name>\t<context_used>\t<context_total>

Where context_used/context_total are absolute token counts (ints) if available,
or empty strings otherwise. The bash script formats them as «used / total».

This parser is defensive: it tries many common field names that different
runtimes have used. When DEBUG=1 is set in the environment, the parser will
emit a short diagnostic line to stderr (not stdout) describing which fields
were selected. The stdout must remain exactly the four tab-separated fields.
"""
import json
import os
import sys


def g(d, *keys, default=''):
    cur = d
    for k in keys:
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return default
    return '' if cur is None else cur


def as_int(v):
    if v is None or v == '':
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        try:
            return int(float(v))
        except (TypeError, ValueError):
            return None


def try_many(d, candidates):
    """Try a list of candidate paths. Each candidate is either a string key
    or a tuple of keys to pass to g(...). Return first non-None as_int value.
    """
    for c in candidates:
        if isinstance(c, (list, tuple)):
            val = g(d, *c, default='')
        else:
            val = g(d, c, default='')
        v = as_int(val)
        if v is not None:
            return v, c
    return None, None


def main():
    try:
        if len(sys.argv) > 1 and sys.argv[1] != '-':
            with open(sys.argv[1], 'r', encoding='utf-8') as f:
                d = json.load(f)
        else:
            d = json.load(sys.stdin)
    except Exception:
        # Keep stdout exact shape expected by caller — four tab-separated fields.
        print('\t\t\t')
        return

    debug = os.environ.get('STATUSLINE_DEBUG', '') != ''

    # Path
    path = g(d, 'workspace', 'current_dir') or g(d, 'cwd') or g(d, 'dir')

    # Model
    model_name = g(d, 'model', 'display_name') or g(d, 'model') or g(d, 'model_name')

    # We'll search for counts in these places (ordered by priority).
    # Prefer absolute counts when present.
    cw = d.get('context_window') if isinstance(d.get('context_window'), dict) else {}

    # Candidate keys for used tokens (in descending priority):
    used_candidates = [
        ('context_window', 'used_tokens'),
        ('context_window', 'current_usage', 'input_tokens'),
        ('context_window', 'current_usage', 'used_tokens'),
        ('context_window', 'current_usage', 'total_tokens'),
        ('context_window', 'current_usage', 'input'),
        ('usage', 'input_tokens'),
        ('usage', 'input'),
        ('current_usage', 'input_tokens'),
        ('current_usage', 'used_tokens'),
        ('current_usage', 'input'),
        ('used_tokens',),
        ('used',),
        ('input_tokens',),
        # fallback: top-level percent fields handled later
    ]

    total_candidates = [
        ('context_window', 'total_tokens'),
        ('context_window', 'max_tokens'),
        ('context_window', 'context_window_size'),
        ('usage', 'max_tokens'),
        ('max_tokens',),
        ('total_tokens',),
        ('context_window', 'current_usage', 'total_tokens'),
    ]

    # Total: prefer explicit context_window_size (the model window),
    # fall back to other candidates only if it's missing.
    total, total_from = try_many(d, total_candidates)

    # Used priority:
    #   1) context_window.used_percentage * context_window_size
    #      This is the same number /context displays and reflects the actual
    #      contents of the current context window (post-compaction). Without
    #      this, the display drifts after /compact because current_usage still
    #      reports pre-compact tokens while the window itself has been trimmed.
    #   2) sum of current_usage.{input_tokens, cache_creation_input_tokens,
    #      cache_read_input_tokens} when no percentage is available.
    #   3) any other absolute candidate as a last resort.
    used = None
    used_from = None

    used_pct, up_from = try_many(d, [
        ('context_window', 'used_percentage'),
        ('used_percentage',),
    ])
    if used_pct is not None and total is not None:
        used = int(round(total * used_pct / 100.0))
        used_from = ('derived_from_used_percentage', used_pct, up_from)

    if used is None:
        cu = cw.get('current_usage') if isinstance(cw, dict) else None
        if isinstance(cu, dict):
            parts = []
            for k in ('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens'):
                v = as_int(cu.get(k))
                if v:
                    parts.append((k, v))
            if parts:
                used = sum(v for _, v in parts)
                used_from = ('current_usage_sum', parts)

    if used is None:
        used, used_from = try_many(d, used_candidates)

    remaining = None

    # remaining tokens candidates
    remaining_candidates = [
        ('context_window', 'remaining_tokens'),
        ('remaining_tokens',),
        ('remaining',),
    ]
    remaining, remaining_from = try_many(d, remaining_candidates)

    # If we don't have absolute counts, try deriving from percentages
    if (used is None or total is None):
        # percent candidates
        used_pct_candidates = [
            ('context_window', 'used_percentage'),
            ('used_percentage',),
            ('context_window', 'used_pct'),
            ('used_pct',),
        ]
        rem_pct_candidates = [
            ('context_window', 'remaining_percentage'),
            ('remaining_percentage',),
            ('context_window', 'remaining_pct'),
            ('remaining_pct',),
        ]
        used_pct, up_from = try_many(d, used_pct_candidates)
        rem_pct, rp_from = try_many(d, rem_pct_candidates)
        # If only rem_pct is present, convert to used_pct
        if used_pct is None and rem_pct is not None:
            used_pct = 100 - rem_pct
            up_from = ('derived_from_remaining_pct',)

        # Derive used from percent if total is known
        if used_pct is not None and total is not None and used is None:
            used = int(round(total * used_pct / 100.0))
            used_from = ('derived_from_pct', used_pct)
        # If we have remaining and total, derive used
        if used is None and remaining is not None and total is not None:
            used = int(total - remaining)
            used_from = ('derived_from_remaining', remaining)

    # Final safety: if still missing but there is a 'usage' block that sums tokens, try to infer
    if (used is None or total is None) and isinstance(d.get('usage'), dict):
        u = d.get('usage', {})
        # sometimes usage has input_tokens + output_tokens + cached tokens; we can't know total, but used=input_tokens
        if used is None:
            used = as_int(u.get('input_tokens') or u.get('input'))
            if used is not None:
                used_from = ('usage.input_tokens',)
        if total is None:
            # no reliable total here; leave as None
            pass

    used = None if used is None else int(used)
    total = None if total is None else int(total)

    used_str = '' if used is None else str(used)
    total_str = '' if total is None else str(total)

    # Emit four tab-separated fields (exact stdout contract)
    print(f"{path}\t{model_name}\t{used_str}\t{total_str}")

    # Diagnostic to stderr only when debug enabled
    if debug:
        info = {
            'used_from': used_from,
            'remaining_from': remaining_from if 'remaining_from' in locals() else None,
            'total_from': total_from,
            'used': used,
            'total': total,
        }
        print('STATUSLINE_DEBUG: ' + json.dumps(info), file=sys.stderr)


if __name__ == '__main__':
    main()
