---
name: no-co-authored-by
description: Never add Co-Authored-By lines to git commit messages.
metadata:
  type: feedback
---

Do **not** include `Co-Authored-By:` trailers in git commit messages. Always omit the `Co-Authored-By` line entirely, regardless of what the commit command or template suggests.

**Why:** The user prefers commits without Anthropic/Claude attribution in the message trailer.

**How to apply:** When constructing a `git commit` command or message, simply do not append the `Co-Authored-By` line. If a template or tool auto-inserts it, strip it before finalizing the commit.