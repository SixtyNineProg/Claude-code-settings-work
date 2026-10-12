# Confluence Troubleshooting

Конкретные грабли, пойманные при работе с `wiki.a1.by` (self-hosted Confluence 8.x). Применять как чеклист при первом признаке проблемы.

## 1. Mojibake: PowerShell искажает кириллицу при сохранении в файл

**Симптом:** `Get-Content` или `Invoke-RestMethod` возвращают нормальную UTF-8 кириллицу, но после `Out-File -Encoding utf8` файл содержит `Ð` `Ñ` (двойное перекодирование), а после чтения обратно в Python — `Кейс` не находится.

**Причина:** PowerShell 5.1 в Windows-консоли по умолчанию читает в кодировке системной консоли (часто cp1251/Windows-1251), а пишет как UTF-8-BOM. Кириллица из REST API (UTF-8) перекодируется дважды.

**Решение:** Никогда не сохраняйте body страницы через `Out-File` / `Set-Content` в PowerShell. Используйте **Python** для всей работы с Confluence — он работает в UTF-8 по умолчанию.

```python
# ✅ Правильно
import json, urllib.request
req = urllib.request.Request('https://wiki.a1.by/rest/api/content/494305966?expand=body.storage',
    headers={'Authorization': 'Bearer <token>', 'Accept': 'application/json; charset=utf-8'})
data = json.loads(urllib.request.urlopen(req).read().decode('utf-8'))
body = data['body']['storage']['value']  # нормальная кириллица
```

```powershell
# ❌ Неправильно
$body = (Invoke-RestMethod ...).body.storage.value
$body | Out-File -Encoding utf8 "page.html"   # ← здесь теряется кириллица
```

**Диагностика:** если `len(body)` > 7000 для простой страницы, проверьте на mojibake:

```python
with open('file.html', 'rb') as f:
    raw = f.read()
if b'\xc3\x90' in raw or b'\xc3\x91' in raw:
    print('MOJIBAKE detected - re-fetch via Python')
```

## 2. ConvertTo-Json зависает на больших payload

**Симптом:** `ConvertTo-Json -Depth 10` на 12+ KB JSON-объекте с кириллицей **подвисает** (timeout), хотя должен быть мгновенным.

**Причина:** PowerShell 5.1 `ConvertTo-Json` имеет проблемы с экранированием спецсимволов в строках с двойными кавычками или эмодзи при больших объёмах.

**Решение:** не использовать `ConvertTo-Json` для body > 5 KB. Строить JSON руками или через Python:

```python
import json
payload = {'id': '494305966', 'type': 'page', 'version': {'number': 32},
           'body': {'storage': {'value': body, 'representation': 'storage'}}}
data = json.dumps(payload, ensure_ascii=False).encode('utf-8')
```

## 3. Confluence возвращает 200, но не обновляет body

**Симптом:** `PUT /rest/api/content/{id}` возвращает `200 OK`, `version.number` инкрементируется, но `body.storage.value` в ответе содержит **старое** содержимое.

**Причина:** POST/PUT с невалидным JSON (например, битый из-за двойного кодирования, см. п.1) — Confluence молча принимает пустой/обрезанный body как новую "версию".

**Диагностика:** после каждого PUT **обязательно** проверять `response.body.storage.value` на наличие ожидаемого изменения:

```python
resp = urllib.request.urlopen(req)
resp_json = json.loads(resp.read())
assert 'Ожидаемое событие' in resp_json['body']['storage']['value'], \
    'PUT вернул 200, но body не изменился — был невалидный JSON'
```

Если не сходится — перепослать через Python с `json.dumps(..., ensure_ascii=False)`.

## 4. XHTML ошибка "Unexpected close tag </p>; expected </ul>"

**Симптом:** `HTTP 400 Bad Request` с телом:
```
{"statusCode":400,"message":"Error parsing xhtml: Unexpected close tag </p>; expected </ul>."}
```

**Причина:** в storage format Confluence требует **строгую** вложенность XHTML-тегов. Типовые баги:
- `<p>` открыт внутри `<li>`, но закрыт после `</li>` — `</p>` оказывается "снаружи"
- `<strong>` открыт в одной `<li>`, закрыт в другой
- `<br />` внутри `<p>` без открывающего `<p>`
- Удаление блока кода через substring-replace задевает соседние теги

**Решение:**
1. Перед PUT прогнать body через `lxml` или `xml.etree` чтобы поймать ошибку локально
2. При модификации существующего HTML — **дифф** с оригиналом по `difflib` или вручную
3. После PUT — проверить `response.body.storage.value` (см. п.3)

**Минимальный локальный парсер:**

```python
from xml.etree import ElementTree as ET
# Storage format uses HTML/XHTML, not pure XML - some tags self-close differently
# Better: just check tag balance manually
import re
opens = re.findall(r'<(\w+)(?:\s[^>]*)?(?<!/)>', body)  # non-self-closing
closes = re.findall(r'</(\w+)>', body)
from collections import Counter
o, c = Counter(opens), Counter(closes)
# Self-closing tags: br, hr, img, ac:image, etc.
self_closing = {'br', 'hr', 'img', 'meta', 'link', 'ac:image', 'ac:link'}
for tag in (o - c):
    if tag not in self_closing:
        print(f'Unclosed: {tag} (×{o[tag] - c[tag]})')
for tag in (c - o):
    print(f'Extra close: {tag} (×{c[tag] - o[tag]})')
```

## 5. Optimistic locking: version.number должен быть строго текущий + 1

**Симптом:** `HTTP 409 Conflict` "Version is incorrect" или "Page version mismatch".

**Причина:** Confluence использует optimistic concurrency control. Каждый PUT должен указывать `version.number` = (текущая версия) + 1.

**Решение:** всегда запрашивать текущую версию перед обновлением:

```python
import json, urllib.request
def get_current_version(page_id, token):
    req = urllib.request.Request(
        f'https://wiki.a1.by/rest/api/content/{page_id}?expand=version',
        headers={'Authorization': f'Bearer {token}', 'Accept': 'application/json'})
    return json.loads(urllib.request.urlopen(req).read())['version']['number']
```

Если правки делаются параллельно двумя сессиями — используйте `If-Match: <version.etag>` header.

## 6. Auth: токены не подхватываются из .env

**Симптом:** `401 Client must be authenticated`.

**Причина:** `CONFLUENCE_PERSONAL_TOKEN` — это PAT для self-hosted, **не** работает с id.atlassian.com. И конфиг MCP `~/.claude/mcp.json` использует `${env:CONFLUENCE_PERSONAL_TOKEN}` — если переменная не в env сессии, токен не подставится.

**Решение:**
- Файл токенов: `C:\Users\dzmitry_klim\.claude\.env` (см. `references/auth-setup.md`)
- В Python/PowerShell скриптах — читать токен напрямую из этого файла, не полагаться на env shell-сессии
- Self-hosted URL всегда `https://wiki.a1.by`, **не** `*.atlassian.net`

## 7. PNG-скриншоты: невозможно прочитать содержимое

**Симптом:** нужно извлечь данные из скриншотов, прикреплённых к кейсам.

**Ограничение в этой среде:**
- `Read` tool возвращает пустой результат для PNG/JPG
- `Playwright` блокирует `file://` URLs, localhost — загружает, но скриншот не виден
- `WebFetch` не имеет доступа к `127.0.0.1`
- Публичные хостинги (0x0.st, imgur) заблокированы — internal data exfiltration

**Workaround:** просить пользователя описать содержимое текстом или **сделать плейсхолдеры** в странице с последующим ручным заполнением.

## 8. Body длиной > 10 KB: используйте POST/PUT в бинарном UTF-8

**Симптом:** при больших страницах (>10 KB body) PowerShell `Invoke-RestMethod` молча обрезает body или подвисает.

**Решение:** всегда используйте `urllib.request` в Python с явным `data = json.dumps(...).encode('utf-8')`:

```python
req = urllib.request.Request(url, data=data, method='PUT',
    headers={'Authorization': f'Bearer {token}',
             'Content-Type': 'application/json; charset=utf-8'})
```

## Чеклист перед публикацией

- [ ] Тело получено напрямую через Python (не через PowerShell промежуточный файл)
- [ ] Текущая версия страницы получена через GET
- [ ] `version.number` в payload = текущая + 1
- [ ] `Content-Type: application/json; charset=utf-8`
- [ ] `json.dumps(payload, ensure_ascii=False).encode('utf-8')` — не `str`, а `bytes`
- [ ] Diff с оригиналом не имеет XHTML ошибок (парсинг тегов)
- [ ] После PUT — проверка `response.body.storage.value` на наличие ожидаемого изменения
