---
name: confluence
description: >
  Work with Confluence at wiki.a1.by (self-hosted) — read/update pages, manage
  attachments, search. Use this skill when the user asks to edit a Confluence
  page, modify storage format, list or download attachments, add placeholders
  to test cases, or anything that touches wiki.a1.by / Confluence REST API.
  Triggers on: "обнови страницу в confluence", "добавь кейс", "вложения
  со страницы", "обнови wiki", "confluence rest api", "wiki.a1.by", and any
  mention of editing page content in Confluence.
compatibility: "Python 3.10+ (stdlib only)"
---

# Confluence (wiki.a1.by) Skill

Self-hosted Confluence at `https://wiki.a1.by`. Personal Access Token is read
from `~/.claude/.env` (variable `CONFLUENCE_PERSONAL_TOKEN`) — never hardcode
it. See `references/auth-setup.md`.

This skill prefers **Python** (stdlib urllib + json) over PowerShell because
PowerShell 5.1 has encoding bugs with Cyrillic and `ConvertTo-Json` hangs on
large payloads. See `references/troubleshooting.md` for the full list of
landmines.

## When to trigger

- User wants to edit / update a page on `wiki.a1.by` or `SRPA` space
- User wants to read page content (body, history, version, attachments)
- User wants to download page attachments (screenshots, PDFs, etc.)
- User wants to add a block, placeholder, or template to specific case rows
- User mentions "конфлюенс", "wiki.a1.by", "Confluence REST API",
  "storage format", "Draft: Changes", "Change management", "SOX"
- User wants to bulk-update a draft / test-results page

## When NOT to trigger

- Jira-only operations → see `AtlassianMCP.md` global rules + Jira tools. If
  a Confluence task also needs to read a Jira issue (e.g. mirror a ticket
  format) and no Jira MCP tool is connected, call the Jira REST API directly
  with `JIRA_PERSONAL_TOKEN` from `~/.claude/.env` (urllib + Bearer auth),
  the same pattern this module uses for Confluence.
- Read-only research → use the `atlassian-selfhosted` MCP server if it has the
  tool you need (`mcp__atlassian__confluence_get_page`, etc.)

## Quick reference: the bundled utility

`scripts/confluence_utils.py` — stdlib-only Python module. Drop into your
session's Python environment and call:

```python
import sys
sys.path.insert(0, r'C:\Users\dzmitry_klim\.claude\skills\confluence\scripts')
from confluence_utils import (
    get_page, get_page_by_title, update_page_storage, create_page,
    get_children, get_page_history, list_attachments, download_attachment,
    download_all_attachments, search, check_xhtml_balance,
    storage_to_markdown, diff_bodies,
    code_block, table, macro, image_attachment, heading, bullet, li,
)

# Read
page = get_page('494305966', expand='body.storage,version')
print(page['title'], 'v' + str(page['version']['number']))
body = page['body']['storage']['value']

# Update
update_page_storage('494305966', body_storage=body.replace(
    '</h2>', '</h2><p>Updated.</p>', 1))

# Preview the body as readable markdown before asking the user to confirm
print(storage_to_markdown(body)[:2000])

# Structural diff of two bodies (e.g. original vs new)
print(diff_bodies(original_body, new_body))

# Attachments
for att in list_attachments('494305966'):
    print(att['id'], att['title'])
download_all_attachments('494305966', Path('./attachments'))
```

**Important:** the function `update_page_storage` does an automatic sanity
check — if the PUT returned 200 but the body in the response doesn't contain
the changes you sent, it raises `AssertionError`. This catches the silent
failure mode described in `references/troubleshooting.md` §3.

## Building a page body: storage-format builders

When you assemble a page (especially a large one) from scratch, use the
builders instead of hand-concatenating raw HTML. They keep tags balanced (no
stale `</li>` from a helper that already closed the tag) and handle the
macro/CDATA plumbing:

```python
from confluence_utils import (
    code_block, table, macro, image_attachment, heading, bullet, li,
)

parts = []
parts.append(heading(3, 'MariaDB → Zabbix → Trigger → Webhook → Jira'))
parts.append('<ul>' + bullet('Item one') + bullet('Item two') + '</ul>')
parts.append(code_block('SELECT 1', 'sql'))         # {code} macro, fenced in preview
parts.append(macro('warning', '<p>Limitation: …</p>'))  # info/warning/note/tip
parts.append(table(['Param', 'Value'], [['k', 'v'], ['a', '1']]))
parts.append(image_attachment('screenshot.png', height=250))
new_body = ''.join(parts)
```

Notes:
- `code_block` wraps `body` in `<![CDATA[…]]>`. The body must **not** contain
  the literal `]]>` (CDATA terminator) — rare in SQL/JS; if needed, split it.
- `macro(name, body)` is for rich-text macros (`info`/`warning`/`note`/`tip`),
  which take `ac:rich-text-body`. `code` uses `ac:plain-text-body` + CDATA, so
  it has its own `code_block()`.
- `ac:macro-id` is optional; the builders generate a UUID automatically.
- Always finish with `check_xhtml_balance(new_body)` (CDATA-aware — tags inside
  a code block are ignored) and `print(storage_to_markdown(new_body)[:2000])`
  to eyeball the result before publishing.

## Workflow: mirror a page as template

When the task is "make a new page по образцу/подобию of an existing one":
read the reference page, mirror its structure, substitute the content, keep
anything that must survive (screenshots, existing sections), then publish.

```python
from pathlib import Path
from confluence_utils import (
    get_page, get_children, update_page_storage, check_xhtml_balance,
    storage_to_markdown, diff_bodies,
)

# 1. Read the reference page (template) + the target page (existing content)
ref = get_page('<ref_id>', expand='body.storage,version')
tgt = get_page('<target_id>', expand='body.storage,version')
Path('original_target.html').write_text(tgt['body']['storage']['value'], encoding='utf-8')

# 2. Build the new body mirroring ref's structure, reusing builders.
#    Preserve what must survive (e.g. existing flat SQL + screenshots).
new_body = ''.join(parts)   # assembled with code_block / table / macro / ...

# 3. Verify + preview
assert check_xhtml_balance(new_body) == [], check_xhtml_balance(new_body)
print(storage_to_markdown(new_body)[:3000])        # readable preview for the user
print(diff_bodies(tgt['body']['storage']['value'], new_body))  # what changed

# 4. Confirm with the user, then publish
resp = update_page_storage('<target_id>', body_storage=new_body)
print('Published v' + str(resp['version']['number']))
```

`storage_to_markdown` is the right thing to show the user for confirmation —
it renders `{code}` blocks as fenced ``` blocks (so SQL/JS stay intact and
readable), headings as `#`, tables as markdown tables, and `info`/`warning`/
`note` macros as blockquotes. Don't hand-roll a tag-stripper regex for this —
it mangles code blocks.

## Workflow for "edit a page with cases" tasks

The pattern that came up in the Draft: Changes task — repeated per-case
insertions (placeholders, expected values, screenshots) — is:

### Phase 1: Read the current state

```python
from confluence_utils import get_page
page = get_page('<page_id>', expand='body.storage,version')
body = page['body']['storage']['value']
print('v' + str(page['version']['number']), 'len=' + str(len(body)))
```

Always save the original to a file for diff purposes:

```python
Path('original.html').write_text(body, encoding='utf-8')
```

### Phase 2: Identify insertion points

Cases are usually inside `<li data-uuid="...">Кейс N: ...</li>`. Use regex:

```python
import re
li_pattern = re.compile(r'(<li data-uuid="[^"]+">)(.*?)(</li>)', re.DOTALL)
cases = []
for m in li_pattern.finditer(body):
    content = m.group(2)
    if 'Кейс' in content:    # skip category labels
        cases.append((m.group(1), m.start(2), m.end(2)))
        print(m.group(1)[:40], '...', content[:60])
```

### Phase 3: Build the new body

Apply the modification. Common patterns:
- Insert placeholder before first image: `idx = content.find('<ac:image')` or `<br />`
- Insert new bullet/list item in a specific `<ul>` block
- Wrap a case in a status marker

**Always** verify before publishing — `check_xhtml_balance` now reports the
**char offset + context** of each imbalance so you can jump straight to it:

```python
# Sanity check (CDATA-aware; reports location, not just a count)
warnings = check_xhtml_balance(new_body)
if warnings:
    print('XHTML issues:'); [print(w) for w in warnings]

# Readable markdown preview of the whole new body — show this to the user
print(storage_to_markdown(new_body)[:2000])

# Structural diff vs the original you saved in Phase 1
print(diff_bodies(Path('original.html').read_text(encoding='utf-8'), new_body))

# Spot-check 3 cases
for uuid_prefix in ['622ead29', 'a46f0f72', '88811bc0']:
    # ...
    pass
```

### Phase 4: Publish with confirmation

The user-rule says **"Публикация в Jira/Confluence только с подтверждением"**.
Show a preview of the change (or a clear before/after diff for one
representative case) and ask. Only after explicit OK call `update_page_storage`.

```python
from confluence_utils import update_page_storage
new_resp = update_page_storage('<page_id>', body_storage=new_body)
print('Published v' + str(new_resp['version']['number']))
```

If the function raises `AssertionError` — do NOT retry blindly. See
`references/troubleshooting.md` §3 (silent PUT failure).

## Working with attachments

Screenshots on test-case pages are common (e.g., `Draft: Changes` page has
~80 PNGs showing Audit-table rows). Workflow:

```python
from pathlib import Path
from confluence_utils import download_all_attachments, list_attachments

# Quick list
for att in list_attachments('<page_id>'):
    print(att['id'], '|', att['title'])

# Bulk download
download_all_attachments('<page_id>', Path('./attachments'))
```

**Reading the image contents** is not possible in this environment (see
`references/troubleshooting.md` §7). For tasks like "extract values from
Audit table screenshots" — the realistic options are:

1. **Placeholders** — add a template line to each case, user fills in manually
2. **Ask for text** — user reads the screenshot and pastes the values
3. **Infer from context** — generate plausible values from the action type
   (e.g., "Package / Created / {package_name} / {date} / {user}") but flag
   that exact values are unverified

## Common patterns reference

### Find a page by space + title

```python
page = get_page_by_title('SRPA', 'Draft: Changes')
print(page['id'], page['version']['number'])
```

### Get all child pages of a parent

```python
for child in get_children('<parent_id>', limit=100):
    print(child['id'], '|', child['title'])
```

### Find recently modified pages by user

```python
results = search("contributor = dzmitry_klim AND lastModified >= -7d", limit=20)
for r in results:
    print(r['id'], r['title'], r['version']['when'])
```

### Add a child page

```python
create_page('SRPA', 'New Sub-page', '<p>Body in storage format</p>', parent_id='<parent>')
```

## Hard rules

1. **Never hardcode the PAT token** in scripts, code, or markdown. Read it
   from `~/.claude/.env` at runtime.
2. **Always use Python**, not PowerShell, for body > 5 KB or any Cyrillic
   content. Reasons: see `references/troubleshooting.md` §1, §2.
3. **Always get current version** before PUT, or pass `version_number`
   explicitly. PUT with stale `version.number` → HTTP 409.
4. **Always verify PUT response** — `update_page_storage()` does this
   automatically and raises on silent failure.
5. **Always confirm with user** before publishing to Jira/Confluence
   (project rule).
6. **XHTML is strict** — use `check_xhtml_balance()` before publishing.
   Confluence's parser rejects unbalanced `<p>`, `<strong>`, `<ul>`, etc.

## Quick command-line usage

```bash
python -c "
import sys; sys.path.insert(0, r'C:\Users\dzmitry_klim\.claude\skills\confluence\scripts')
from confluence_utils import get_page
p = get_page('494305966', expand='version')
print('v' + str(p['version']['number']), '|', p['title'])
"
```

## Files in this skill

- `SKILL.md` — this file
- `scripts/confluence_utils.py` — reusable Python utility (CRUD, builders, preview, diff)
- `scripts/tests/test_confluence_utils.py` — tests for the builders / preview / diff helpers (`python test_confluence_utils.py`)
- `references/auth-setup.md` — token storage, MCP config
- `references/troubleshooting.md` — concrete landmines with fixes
