# Task Scope and Change Discipline

These rules apply to every project and override any default tendency to broaden the task.

## Execute Only the Requested Scope

- Implement exactly what the user explicitly asks for.
- Do not add unrelated improvements, architecture changes, cleanup, modernization, or style-only edits.
- Do not start code review, refactoring cycles, or optimization work unless the user explicitly requests it.
- Treat suggestions for possible improvements as informational unless the user asks to implement them.

## Protect Existing Work

- Preserve existing behavior and the user's current WIP.
- Before editing, inspect the working tree and avoid modifying unrelated changed files.
- Never discard, reset, overwrite, or reformat existing changes without explicit permission.
- Prefer the smallest change that satisfies the request.

## Verification

- Run only checks necessary to validate the requested change, unless the user asks for broader validation.
- Do not use test failures or review findings as a reason to begin unrelated refactoring.
- Report unrelated issues separately and ask before fixing them.

## Communication

- If the request is ambiguous or completion requires changes outside the stated scope, ask for clarification first.
- Clearly distinguish requested implementation from optional recommendations.
