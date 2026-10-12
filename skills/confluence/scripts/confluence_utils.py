"""
Confluence REST API helper for wiki.a1.by (self-hosted).

Reusable functions for page CRUD, attachments, search. No external deps
(uses stdlib urllib + json). Reads PAT from ~/.claude/.env — never hardcode.

Why Python (not PowerShell): PowerShell 5.1 has encoding bugs with Cyrillic
(see references/troubleshooting.md §1) and ConvertTo-Json hangs on large
payloads. Python's UTF-8 + json is the reliable path.

Usage:
    from confluence_utils import get_page, update_page_storage, list_attachments, download_attachment
    page = get_page('494305966', expand='body.storage,version')
"""

import difflib
import json
import re
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Optional


BASE_URL = 'https://wiki.a1.by'


def _load_token() -> str:
    """Read CONFLUENCE_PERSONAL_TOKEN from ~/.claude/.env. Fails loud if missing."""
    env_path = Path.home() / '.claude' / '.env'
    if not env_path.exists():
        raise RuntimeError(f'Env file not found: {env_path}')
    for line in env_path.read_text(encoding='utf-8').splitlines():
        if line.startswith('CONFLUENCE_PERSONAL_TOKEN='):
            token = line.split('=', 1)[1].strip()
            if token:
                return token
    raise RuntimeError('CONFLUENCE_PERSONAL_TOKEN not set in ~/.claude/.env')


_TOKEN: Optional[str] = None


def _auth_headers(accept: str = 'application/json; charset=utf-8') -> dict:
    """Build request headers with Bearer token. Token is cached after first read."""
    global _TOKEN
    if _TOKEN is None:
        _TOKEN = _load_token()
    return {
        'Authorization': f'Bearer {_TOKEN}',
        'Accept': accept,
        'Content-Type': 'application/json; charset=utf-8',
    }


def _request(method: str, path: str, data: Optional[dict] = None,
             query: Optional[dict] = None, accept: str = 'application/json; charset=utf-8'):
    """Low-level Confluence REST call. Returns parsed JSON or raises HTTPError."""
    url = f'{BASE_URL}{path}'
    if query:
        url += '?' + urllib.parse.urlencode(query)
    body_bytes = None
    if data is not None:
        body_bytes = json.dumps(data, ensure_ascii=False).encode('utf-8')
    headers = _auth_headers(accept=accept)
    req = urllib.request.Request(url, data=body_bytes, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = resp.read()
        if not raw:
            return None
        return json.loads(raw.decode('utf-8'))


# ---------- Pages ----------

def get_page(page_id: str | int, expand: str = 'body.storage,version') -> dict:
    """Get a page by ID. `expand` is comma-separated (e.g. 'body.storage,version,history')."""
    return _request('GET', f'/rest/api/content/{page_id}', query={'expand': expand})


def get_page_by_title(space_key: str, title: str, expand: str = 'body.storage,version') -> dict:
    """Get a page by space+title."""
    return _request('GET', '/rest/api/content',
                    query={'spaceKey': space_key, 'title': title, 'expand': expand})


def update_page_storage(page_id: str | int, body_storage: str, title: Optional[str] = None,
                        version_number: Optional[int] = None,
                        minor_edit: bool = False) -> dict:
    """
    Update page body in storage format. Auto-fetches current version+title if not given.

    Returns the response (which contains the new version + body).
    Raises AssertionError if the body in response doesn't match (PUT silently failed).
    """
    page = get_page(page_id, expand='version')
    if version_number is None:
        version_number = page['version']['number'] + 1
    if title is None:
        title = page['title']

    payload = {
        'id': str(page_id),
        'type': 'page',
        'title': title,
        'version': {'number': version_number, 'minorEdit': minor_edit},
        'body': {'storage': {'value': body_storage, 'representation': 'storage'}},
    }
    resp = _request('PUT', f'/rest/api/content/{page_id}', data=payload)
    # Sanity check: PUT can return 200 with stale body if payload was malformed
    if 'body' in resp and 'storage' in resp['body']:
        actual = resp['body']['storage']['value']
        if body_storage[:200] not in actual:
            raise AssertionError(
                f'PUT returned 200 but body not updated. Sent starts with: {body_storage[:80]!r}; '
                f'Got starts with: {actual[:80]!r}')
    return resp


def create_page(space_key: str, title: str, body_storage: str,
                parent_id: Optional[str | int] = None) -> dict:
    """Create a new page."""
    payload = {
        'type': 'page',
        'title': title,
        'space': {'key': space_key},
        'body': {'storage': {'value': body_storage, 'representation': 'storage'}},
    }
    if parent_id is not None:
        payload['ancestors'] = [{'id': str(parent_id)}]
    return _request('POST', '/rest/api/content', data=payload)


def get_page_history(page_id: str | int, limit: int = 5) -> dict:
    """Get version history (most recent first)."""
    return _request('GET', f'/rest/api/content/{page_id}/history',
                    query={'limit': limit})


def get_children(page_id: str | int, limit: int = 50) -> list[dict]:
    """Get child pages."""
    resp = _request('GET', f'/rest/api/content/{page_id}/child/page',
                    query={'limit': limit})
    return resp.get('results', [])


# ---------- Attachments ----------

def list_attachments(page_id: str | int, limit: int = 200) -> list[dict]:
    """List all attachments on a page."""
    resp = _request('GET', f'/rest/api/content/{page_id}/child/attachment',
                    query={'limit': limit})
    return resp.get('results', [])


def download_attachment(att_id: str | int, dest: Path) -> Path:
    """Download a single attachment by its content ID. Returns the saved path."""
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    url = f'{BASE_URL}/rest/api/content/{att_id}/data'
    req = urllib.request.Request(url, headers=_auth_headers(accept='*/*'))
    with urllib.request.urlopen(req, timeout=60) as resp:
        dest.write_bytes(resp.read())
    return dest


def download_all_attachments(page_id: str | int, dest_dir: Path,
                              progress: bool = True) -> list[Path]:
    """Download all attachments of a page into dest_dir. Returns list of saved paths."""
    dest_dir = Path(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    attachments = list_attachments(page_id)
    saved = []
    for att in attachments:
        att_id = att['id']
        title = att['title']
        safe_name = f'{att_id}_{title}'.replace('/', '_').replace('\\', '_')
        out = dest_dir / safe_name
        try:
            download_attachment(att_id, out)
            if progress:
                print(f'OK: {safe_name}')
            saved.append(out)
        except Exception as e:
            if progress:
                print(f'FAIL: {safe_name} - {e}')
    return saved


# ---------- Search ----------

def search(cql: str, limit: int = 25) -> list[dict]:
    """
    Confluence Query Language search. Examples:
      "space = SRPA AND type = page"
      "type = page AND title ~ 'Change management'"
      "creator = dzmitry_klim AND created >= -30d"
    """
    resp = _request('GET', '/rest/api/content/search',
                    query={'cql': cql, 'limit': limit})
    return resp.get('results', [])


# ---------- Storage-format builders ----------
# Small builders for the most common Confluence storage elements. Use them to
# assemble a page body instead of hand-concatenating raw HTML — they keep tags
# balanced (no stale </li>) and handle the macro/CDATA plumbing for you.

def code_block(body: str, language: Optional[str] = None) -> str:
    """{code} macro. body is rendered verbatim via CDATA.
    Limitation: body must not contain the literal `]]>` (CDATA terminator)."""
    lang = ''
    if language:
        lang = f'<ac:parameter ac:name="language">{language}</ac:parameter>'
    return (
        '<ac:structured-macro ac:name="code" ac:schema-version="1" '
        f'ac:macro-id="{uuid.uuid4()}">{lang}'
        f'<ac:plain-text-body><![CDATA[{body}]]></ac:plain-text-body>'
        '</ac:structured-macro>'
    )


def table(headers: list[str], rows: list[list[str]]) -> str:
    """Wrapped table. cells may contain inline storage (e.g. <code>, <a>)."""
    head = '<thead><tr>' + ''.join(
        f'<th style="text-align: left;"><span>{h}</span></th>' for h in headers
    ) + '</tr></thead>'
    body_rows = ''.join(
        '<tr>' + ''.join(f'<td>{c}</td>' for c in row) + '</tr>' for row in rows
    )
    return f'<table class="wrapped">{head}<tbody>{body_rows}</tbody></table>'


def macro(name: str, body: str, params: Optional[dict] = None) -> str:
    """Rich-text macro: info / warning / note / tip. body is storage-format inner."""
    p = ''
    if params:
        p = ''.join(
            f'<ac:parameter ac:name="{k}">{v}</ac:parameter>' for k, v in params.items()
        )
    return (
        f'<ac:structured-macro ac:name="{name}" ac:schema-version="1" '
        f'ac:macro-id="{uuid.uuid4()}">{p}'
        f'<ac:rich-text-body>{body}</ac:rich-text-body>'
        '</ac:structured-macro>'
    )


def image_attachment(filename: str, height: Optional[int] = None) -> str:
    """<ac:image> referencing an attachment by filename."""
    h = f' ac:height="{height}"' if height else ''
    return f'<ac:image{h}><ri:attachment ri:filename="{filename}" /></ac:image>'


def heading(level: int, text: str) -> str:
    if not 1 <= level <= 6:
        raise ValueError(f'heading level must be 1..6, got {level}')
    return f'<h{level}><span>{text}</span></h{level}>'


def bullet(text: str) -> str:
    """Simple <li> with a ds-markdown-paragraph inside."""
    return f'<li><p class="ds-markdown-paragraph"><span>{text}</span></p></li>'


def li(item_uuid: str, inner: str) -> str:
    """<li data-uuid="..."> — use for case/numbered items with arbitrary inner."""
    return f'<li data-uuid="{item_uuid}">{inner}</li>'


# ---------- Preview / diff / safety ----------

def check_xhtml_balance(body: str) -> list[str]:
    """CDATA-aware stack checker. Reports mismatched tags WITH char offset +
    context so you can jump to the problem (not just a count). Empty list = OK.

    Handles code blocks correctly: tags inside <![CDATA[ ... ]]> are ignored,
    so HTML shown inside a {code} macro is not counted as real markup.
    """
    void = {'br', 'hr', 'img', 'meta', 'link'}
    warnings = []
    stack = []
    i, n = 0, len(body)
    while i < n:
        if body.startswith('<![CDATA[', i):
            end = body.find(']]>', i + 9)
            i = end + 3 if end != -1 else n
            continue
        if body[i] != '<':
            i += 1
            continue
        m = re.match(r'</?([a-zA-Z][\w:]*)', body[i:])
        if not m:
            i += 1
            continue
        tag = m.group(1)
        gt = body.find('>', i)
        if gt == -1:
            warnings.append(f'  malformed tag at char {i}: …{body[i:i + 40]}…')
            break
        tagtext = body[i:gt + 1]
        is_close = tagtext.startswith('</')
        is_self = tagtext.rstrip().endswith('/>') or tag in void
        if is_self:
            i = gt + 1
            continue
        if is_close:
            depth = next((k for k in range(len(stack) - 1, -1, -1)
                         if stack[k][0] == tag), None)
            if depth is None:
                ctx = body[max(0, i - 30):i]
                warnings.append(f'  extra close </{tag}> at char {i}: …{ctx}')
            else:
                for t, off in stack[depth + 1:]:
                    warnings.append(
                        f'  unclosed <{t}> at char {off} (closed by </{tag}> at {i}): '
                        f'…{body[off:off + 40]}…')
                stack = stack[:depth]
            i = gt + 1
            continue
        stack.append((tag, i))
        i = gt + 1
    for t, off in stack:
        warnings.append(f'  unclosed <{t}> at char {off}: …{body[off:off + 40]}…')
    return warnings


def storage_to_markdown(body: str) -> str:
    """Render Confluence storage XML to readable markdown — for showing the user
    a preview before publish. Best-effort (not a perfect renderer): handles
    {code} blocks (fenced, with language), info/warning/note/tip macros, headings,
    strong/em/code, links, images, hr, br, tables and bullet/numbered lists.
    """
    stash = []

    def _stash_code(m):
        pm = re.search(r'<ac:parameter ac:name="language">([^<]*)</ac:parameter>', m[0])
        lang = pm.group(1) if pm else ''
        inner = re.search(r'<!\[CDATA\[(.*?)\]\]>', m[0], re.DOTALL)
        text = inner.group(1) if inner else ''
        stash.append(f'```{lang}\n{text}\n```' if lang else f'```\n{text}\n```')
        return f'\x00S{len(stash) - 1}\x00'

    def _stash_macro(m):
        name = re.match(r'<ac:structured-macro ac:name="(\w+)"', m[0]).group(1)
        rb = re.search(r'<ac:rich-text-body>(.*?)</ac:rich-text-body>', m[0], re.DOTALL)
        inner = storage_to_markdown(rb.group(1)) if rb else ''
        stash.append(f'> **{name}:**\n{inner}'.rstrip())
        return f'\x00S{len(stash) - 1}\x00'

    body = re.sub(r'<ac:structured-macro ac:name="code"[^>]*>.*?</ac:structured-macro>',
                 _stash_code, body, flags=re.DOTALL)
    body = re.sub(r'<ac:structured-macro ac:name="(info|warning|note|tip)"[^>]*>.*?</ac:structured-macro>',
                 _stash_macro, body, flags=re.DOTALL)

    # tables → markdown table (one per <table>)
    def _table(m):
        cells = re.findall(r'<t[hd][^>]*>(.*?)</t[hd]>', m[0], re.DOTALL)
        cells = [storage_to_markdown(c).strip() for c in cells]
        # split into rows by <tr>
        rows = re.findall(r'<tr[^>]*>(.*?)</tr>', m[0], re.DOTALL)
        out = []
        for r in rows:
            out.append([storage_to_markdown(c).strip()
                        for c in re.findall(r'<t[hd][^>]*>(.*?)</t[hd]>', r, re.DOTALL)])
        if not out:
            return ''
        header = '| ' + ' | '.join(out[0]) + ' |'
        sep = '| ' + ' | '.join('---' for _ in out[0]) + ' |'
        rows_md = '\n'.join('| ' + ' | '.join(r) + ' |' for r in out[1:])
        return '\n'.join([header, sep, rows_md])

    body = re.sub(r'<table[^>]*>.*?</table>', _table, body, flags=re.DOTALL)

    # lists → bullet lines
    def _ul(m):
        items = re.findall(r'<li[^>]*>(.*?)</li>', m[0], re.DOTALL)
        return '\n' + '\n'.join('- ' + storage_to_markdown(it).strip() for it in items) + '\n'

    def _ol(m):
        items = re.findall(r'<li[^>]*>(.*?)</li>', m[0], re.DOTALL)
        return '\n' + '\n'.join(f'{i}. ' + storage_to_markdown(it).strip()
                                for i, it in enumerate(items, 1)) + '\n'

    body = re.sub(r'<ul[^>]*>.*?</ul>', _ul, body, flags=re.DOTALL)
    body = re.sub(r'<ol[^>]*>.*?</ol>', _ol, body, flags=re.DOTALL)

    body = re.sub(r'<h([1-6])[^>]*>(.*?)</h\1>',
                 lambda m: '\n' + '#' * int(m.group(1)) + ' ' + storage_to_markdown(m.group(2)).strip() + '\n',
                 body, flags=re.DOTALL)
    body = re.sub(r'<a href="([^"]*)"[^>]*>(.*?)</a>',
                 lambda m: f'[{storage_to_markdown(m.group(2)).strip()}]({m.group(1)})',
                 body, flags=re.DOTALL)
    body = re.sub(r'<strong[^>]*>', '**', body)
    body = re.sub(r'</strong>', '**', body)
    body = re.sub(r'<em[^>]*>', '*', body)
    body = re.sub(r'</em>', '*', body)
    body = re.sub(r'<code>', '`', body)
    body = re.sub(r'</code>', '`', body)
    body = re.sub(r'<ac:image[^>]*><ri:attachment ri:filename="([^"]*)"[^>]*/></ac:image>',
                 lambda m: f'![{m.group(1)}]', body)
    body = re.sub(r'<hr[^>]*/?>', '\n---\n', body)
    body = re.sub(r'<br[^>]*/?>', '\n', body)
    body = re.sub(r'</p>', '\n\n', body)
    body = re.sub(r'<[^>]+>', '', body)  # strip remaining tags
    from html import unescape
    body = unescape(body)
    # restore stashed blocks
    body = re.sub(r'\x00S(\d+)\x00', lambda m: stash[int(m.group(1))], body)
    body = re.sub(r'\n{3,}', '\n\n', body)
    return body.strip()


def diff_bodies(old: str, new: str) -> str:
    """Structural diff of two storage bodies (whitespace-normalised, tag-level).
    Returns a short human-readable summary of changed hunks, or 'no changes'."""
    def norm(b):
        b = re.sub(r'>\s*<', '>\n<', b)
        return [l.strip() for l in b.splitlines() if l.strip()]
    a, b = norm(old), norm(new)
    out = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b).get_opcodes():
        if tag == 'equal':
            continue
        out.append(f'--- {tag} ---')
        if tag in ('replace', 'delete'):
            out += ['- ' + l[:120] for l in a[i1:i2][:5]]
        if tag in ('replace', 'insert'):
            out += ['+ ' + l[:120] for l in b[j1:j2][:5]]
    return '\n'.join(out) if out else 'no changes'
