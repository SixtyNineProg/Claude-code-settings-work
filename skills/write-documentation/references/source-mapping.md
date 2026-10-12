# Source Mapping

Полная карта источников данных для заполнения placeholder-ов шаблонов DemoBP. Используй вместе с `template-anatomy.md` (структура файлов) — здесь описано, **откуда** брать данные.

## Содержание

1. [Карта placeholder → источник](#карта-placeholder--источник)
2. [Полная таблица import → system](#полная-таблица-import--system)
3. [Паттерн ProcessDataKeys / ProcessTransaction](#паттерн-processdatakeys--processtransaction)
4. [Чтение .process-файлов](#чтение-process-файлов)
5. [process-config.json — поля](#process-configjson--поля)
6. [init_params и email_templates — расположение](#init_params-и-email_templates--расположение)

---

## Карта placeholder → источник

| Placeholder в шаблоне | Откуда брать данные |
| -------------------------------------------- | -------------------------------------------- |
| `DemoBP` / `Демонстрационный бизнес-процесс` | `bpName` / `bpDescription` из `process-config.json` |
| Описание / назначение процесса | `README.md` → Обзор |
| Используемые системы | Анализ Java-импортов (таблица ниже) |
| Конфигурируемые параметры | `init_params/prod/<module>_init_params.json` — все ключи верхнего уровня |
| Нотификации | `<module>_email_templates.json` — все ключи + `subjectTemplate`/`bodyTemplate` |
| Конфиденциальные значения (credentials) | `orchestratorService.assets().getCredentials(ASSET).execute()` в Java |
| Прочие ресурсы (text assets) | `orchestratorService.assets().get(ASSET).execute().parseJson(...)` в Java |
| Описание шагов | Java Step-классы: `@StepName`, `@Inject`-зависимости, `execute()` |
| Порядок шагов | `.process` XML (см. [Чтение .process-файлов](#чтение-process-файлов)) |
| Исключения | `throw new BusinessException(...)` в Java |
| Хранилище / папки | `by.a1.rpa.folders.UnifiedFoldersUtil` в Java + README |
| Папки доступа / Actions | `README.md` (раздел про Actions/папки) |

---

## Полная таблица import → system

| Импорт | Система | Примечание |
| ------------------------------------- | ---------------------- | ---------- |
| `by.a1.rpa.core.*` | RPA core / framework | `Step`, `StepName`, `BusinessException`, `Transaction` |
| `by.a1.rpa.orchestrator.*` | Sherpa Orchestrator | assets, files, tasks, storage (`OrchestratorService`, `model.Asset`, `model.StorageFile`, `model.Task`, `model.TaskStatus`) |
| `by.a1.rpa.sapgui.*` | SAP GUI automation | `SapGuiAutomation`, `config.SapGuiConfig`, `config.SapGuiSettings`, `session.SapGuiSession`, `exception.SessionException` |
| `by.a1.rpa.jira.*` | Jira / JSD | (встречается в других модулях, не в accounts) |
| `by.a1.rpa.email.*` | Email (SMTP) | `EmailService`, `model.EmailRecipients` |
| `by.a1.rpa.folders.*` | Unified storage folders | `UnifiedFoldersUtil` |
| `org.apache.poi.*` | Excel (Apache POI) | Обычно в `excel/`-хелперах (`ExcelSapUnloadingParser`, `ExcelScreenshotHelper`, `ExcelChecklistHelper`), **не** в Step-классах |
| `com.google.gson.*` | JSON-сериализация | `Gson`, `TypeToken` — в `ProcessTransaction` |
| `com.google.inject.Inject` | DI (Guice) | Конструкторная инъекция |
| `lombok.extern.slf4j.Slf4j` | Логирование | `@Slf4j` на каждом Step |
| `HttpURLConnection`, `java.net.URL` | Внешний HTTP API | Прямые HTTP-вызовы |
| `java.nio.*`, `java.io.*` | Файловая система | Локальные файлы |

Алгоритм: собери все `import` из всех `*Step.java`; для каждого сопоставь систему по таблице; внеси уникальные системы в PDD «Используемые системы». Минимум — Sherpa Orchestrator (всегда есть) + Почтовый сервер (если есть `by.a1.rpa.email`).

---

## Паттерн ProcessDataKeys / ProcessTransaction

Состояние между шагами хранится по паттерну «ключи отдельно, типизированные аксессоры отдельно»:

- **`ProcessDataKeys.java`** — строковые константы-ключи (например `static final String SAP_QUEUE_ID = "sapQueueId";`).
- **`ProcessTransaction.java`** — обёртка над `by.a1.rpa.core.transaction.Transaction`; типизированные `get*()`/`set*()` методы, внутри вызывающие `transaction.put(key, value)` / `transaction.get(key, Class)`. Сложные типы сериализуются в JSON через Gson (`getSapAccountsJson()` ↔ `setSapAccounts(List<Account>)`).

Для Step-документации:
- **Выходные данные шага** = `set*()`-вызовы в `execute()` этого Step.
- **Входные данные шага** = `get*()`-вызовы в `execute()` этого Step (или `Не заданы`, если их нет).

---

## Чтение .process-файлов

`.process`-файлы лежат в **корне** процесса: `Главная.process` (основная диаграмма) + `Stage{N}.process` (по стадиям). Это XML в формате Sherpa Designer.

⚠️ **Типичная ошибка:** искать литералы `$StepName="prepareInitialParameters"`. Таких строк **нет**. В XML встречается только placeholder `$StepName={{{StepName}}}` (Mustache) внутри `<Content>`-блоков designer-блоков.

Алгоритм определения порядка шагов:
1. Открой `Главная.process`. Найди последовательность designer-блоков (или ссылок на Step-классы).
2. Сопоставь каждый блок с Java Step-классом по имени (`@StepName("...")`).
3. Если в `Главная.process` только ссылки на `Stage{N}.process` — открывай соответствующие Stage-файлы и собирай порядок оттуда.
4. **Если порядок неоднозначен** — восстанови по потоку данных:
   - Шаг A предшествует шагу B, если A вызывает `setX(...)`, а B вызывает `getX(...)` для того же ключа из `ProcessDataKeys`.
   - Строй граф зависимостей по `get*`/`set*`-парам в `ProcessTransaction`.
   - Топологическая сортировка даёт порядок.
5. Первый шаг — тот, у которого нет `get*()`-входов (или входы только из init_params). Последний — тот, чьи выходы никто не читает.

Эта эвристика надёжна, потому что шаги образуют конвейер данных через `ProcessTransaction`.

---

## process-config.json — поля

Файл: `src/main/resources/process-config.json`. Поля (по реальному модулю ics00057-accounts):

```json
{
  "processName": "ICS-00057",
  "bpName": "ICS-00057",
  "bpNumber": "01",
  "bpDescription": "Обновление справочника",
  "controlName": "Document Verification Accounting"
}
```

| Поле | Использование |
|------|---------------|
| `bpName` | `{ProcessName}` во всех именах файлов и кросс-ссылках |
| `bpNumber` | PDD, шаблоны писем (`${bpNumber}`) |
| `bpDescription` | PDD «Общая информация», обзорная страница, шаблоны писем (`${bpDescription}`) |
| `controlName` | PDD «Общая информация» (Управление), если применимо |
| `processName` | То же что bpName обычно; используй `bpName` как основной |

---

## init_params и email_templates — расположение

**init_params:** `src/main/resources/init_params/{prod,test}/<module>_init_params.json`
- Подпапки `prod/` и `test/` — разные наборы для сред.
- Для документации используй `prod/` (основной), но упомянай обе, если различаются ключи.
- Все ключи верхнего уровня → в PDD «Конфигурируемые параметры».
- Структура: `emailRecipients` — объект с `to`/`cc`/`bcc`-массивами (в PDD разворачивается в 3 строки с `rowspan`); прочие ключи — скаляры/объекты.

**email_templates:** `src/main/resources/<module>_email_templates.json`
- Один файл, ключи — имена шаблонов.
- Каждый объект: `{"subjectTemplate": "...", "bodyTemplate": "..."}` с FreeMarker `${...}` интерполяцией.
- Все ключи → в PDD «Нотификации» (наименование = ключ, текущее значение = subject/body, тип = Email/SMS).
- Стандартные шаблоны (`process_started`, `process_error`) могут ссылаться на [стандартное значение](https://wiki.a1.by/pages/viewpage.action?pageId=474058264) (ссылка постоянная) вместо разворота тела.