# Confluence Auth Setup

## Endpoints (self-hosted A1)

| Resource | URL | Token env var |
|----------|-----|---------------|
| **Confluence** | `https://wiki.a1.by` | `CONFLUENCE_PERSONAL_TOKEN` |
| **Jira** | `https://jira.a1.by` | `JIRA_PERSONAL_TOKEN` |

User: `dzmitry_klim` (d.klimau@a1.by).

## Token storage

Файл: `C:\Users\dzmitry_klim\.claude\.env`

Переменные: `CONFLUENCE_PERSONAL_TOKEN`, `JIRA_PERSONAL_TOKEN`. Значения берутся оттуда при необходимости — **никогда не хардкодить токены в коде, скриптах или markdown-файлах**.

⚠️ **Это Personal Access Token для self-hosted**, НЕ работает с id.atlassian.com (Cloud).

## MCP server

Конфиг: `~/.claude/mcp.json` — `atlassian-selfhosted` (Jira + Confluence, source `~/.claude/mcp-servers/atlassian-selfhosted/`).

## Рекомендуемый паттерн: Python с прямым чтением токена из .env

```python
from pathlib import Path

env_path = Path.home() / '.claude' / '.env'
token = None
for line in env_path.read_text(encoding='utf-8').splitlines():
    if line.startswith('CONFLUENCE_PERSONAL_TOKEN='):
        token = line.split('=', 1)[1].strip()
        break
if not token:
    raise RuntimeError('CONFLUENCE_PERSONAL_TOKEN not found in ~/.claude/.env')

BASE_URL = 'https://wiki.a1.by'
AUTH_HEADER = {'Authorization': f'Bearer {token}'}
```

Почему не полагаться на `os.environ`: в shell-сессии Claude Code переменная может быть не подхвачена, особенно в PowerShell 5.1.

## Какие операции покрывает этот skill

- GET страницы по ID с любым `expand` (version, body.storage, history, ancestors, children, descendants)
- GET списка вложений страницы
- Скачивание вложений (PNG, JPG, PDF, etc.)
- PUT (update) страницы — storage format
- POST (create) страницы
- GET/POST дочерних страниц
- Поиск CQL

Jira-операции — отдельный набор (см. AtlassianMCP.md в глобальных правилах).
