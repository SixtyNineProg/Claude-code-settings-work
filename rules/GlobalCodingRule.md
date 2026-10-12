1. Please don't violate DRY Principle — eliminate duplication; centralize shared logic to a single source of truth.
2. Keep in mind of SOLID Principle — apply SRP, OCP, LSP, ISP, and DIP to keep code modular, testable, and maintainable.
3. Do not add comments to code unnecessarily — prefer clear naming and structure; comment intent and non-obvious
   decisions only.
4. Try to limit docstrings when you can — document public APIs and edge cases; avoid repeating what the code already
   says.
5. Follow the KISS principle (Keep It Simple) — choose the simplest solution that meets requirements; avoid premature
   abstractions and cleverness.
6. Practice true TDD (RED-GREEN-REFACTOR): write a failing test first, write the minimal code to pass, then refactor. Do
   not keep or commit code written before a failing test exists. — always test-first and commit only after green.
7. YAGNI: implement only what is required by current tests and scope; avoid speculative features. — defer features and
   configuration until proven necessary.
8. Plan before coding: agree on a short design, then break work into tiny tasks (2–5 minutes) with exact file paths and
   clear verification steps. — small, verifiable tasks accelerate delivery and reduce rework.
9. Use isolated branches (e.g., git worktrees) per feature; start from a clean, green baseline and keep main stable. —
   isolate work, keep CI green, and clean up after merge.
10. Prefer systematic debugging: reproduce, form a hypothesis, change one thing, verify, and confirm the fix with
    tests (verification-before-completion). — process over guessing; add tests to prevent regressions.
11. Code review discipline: request reviews between tasks, check changes against the plan, block on critical issues, and
    address feedback promptly. — ensure alignment and quality continuously.
12. Finish branches cleanly: ensure all tests pass, then merge/PR/keep/discard as decided, and clean up worktrees. —
    maintain a tidy history and delete temporary branches.
13. Favor simplicity and evidence: reduce complexity; rely on tests and observable results over claims. — decide by data
    and working tests, not intuition.