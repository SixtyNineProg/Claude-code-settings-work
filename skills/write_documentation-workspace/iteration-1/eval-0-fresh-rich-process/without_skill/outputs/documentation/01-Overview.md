# Обзор процесса ICS-00057 «Обновление справочника»

## 1. Идентификация

| Поле | Значение |
|---|---|
| Код процесса | `ICS-00057` |
| BP Name | `ICS-00057` |
| BP Number | `01` |
| BP Description | Обновление справочника |
| Control Name | Document Verification Accounting |
| Версия сборки | `1.0.0` (`build.gradle`) |
| Jira-задача | `RPA-16567` (по истории коммитов) |
| Очередь Orchestrator | `ICS-00057 Обновление справочника` |
| Главная папка Storage | `ICS-00057` |

## 2. Назначение

Первый шаг контроля ICS-00057: ботопроцесс актуализирует справочник счетов, релевантных для контроля. Источник данных — SAP-транзакция `ZACCOUNTS` (план счетов `IFRS`, балансовая единица `1320`). Корректировки выполняются контролёром через три последовательные ручные задачи (Manual Task, MT №1–№3) на Shadow Core Engine; бот отвечает за выгрузку, подготовку данных, разбор результата и публикацию доказательств.

## 3. Высокоуровневая архитектура

```
                  ┌────────────┐    ┌────────────────────┐    ┌──────────────┐
   Schedule ───▶  │ Orchestrator│──▶│ Stage1 (бот)        │──▶│ Orchestrator │
                  │  Start     │   │ InfrastructureStep  │   │  Task Queue   │
                  └────────────┘   │ SapStep            │   │  (MT №1)      │
                                   │ PrepareNewStep     │   └──────┬───────┘
                                   └────────────────────┘          │
                                          ▲                        ▼
                                          │   SharePoint ──────  Trigger
                                          │   Storage         по тегу
                                          │   Email            "reviewed"
                                          │                          │
                                                          ┌─────────▼─────────┐
                                                          │ Stage2 (бот)      │
                                                          │ SaveNewStep       │
                                                          │ PrepareChangedStep│
                                                          └─────────┬─────────┘
                                                                    │
                                  ┌─────────────────────────────────┘
                                  ▼  Trigger по тегу "reviewedChanged"
                          ┌─────────▼─────────┐
                          │ Stage3 (бот)     │
                          │ SaveChangedStep   │
                          │ PrepareAllStep    │
                          └─────────┬─────────┘
                                    │ Trigger по тегу "reviewedAll"
                                    ▼
                          ┌─────────▼─────────┐
                          │ Stage4 (бот)     │
                          │ SaveAllStep      │
                          │ UploadEvidenceStep│
                          └───────────────────┘
```

Шаги разделены на 4 стадии (`Stage{1..4}.process`). Бот-сессия разрывается между стадиями: каждая стадия стартует из Task Queue-триггера Orchestrator по final-тегу соответствующей MT.

## 4. Окружение и внешние системы

### SAP GUI
- Транзакция: `ZACCOUNTS`
- План счетов: `IFRS`
- Балансовая единица (БЕ): `1320`
- Язык: из ассета `sap_settings` (требуется `language = "RU"` — имена счетов зависят от языка)
- Учётные данные: ассет `sap_credentials`
- Подключение: через SAP Logon Shortcut (предварительно завершаются процессы `saplogon.exe` / `saplgpad.exe`)
- Экспорт: ALV → Excel, имя файла `ZACCOUNTS.xlsx`, каталог — временный temp-dir бота
- Скриншоты: 3 экрана (параметры, первая страница, последняя страница) → `screenshots.xlsx`

### SharePoint
- Хост: `https://vactpro.main.velcom.by`
- Проект: `Project_928` (prod) / `Project_1776` (test)
- Базовый путь (prod): `Lists/documents`
- Базовый путь (test): `Lists/documents/Бот/ICS-00057`
- Структура папок: унифицированная (`UnifiedFoldersUtil`) — `Бот/<год>/<период start-end>/<01_Обновление справочника>/<runDate per период>/`
- Учётные данные: ассет `sharepoint_credentials`
- Стратегия конфликтов при загрузке: `OVERWRITE`

### Email
- Провайдер: `rpa-core EmailService` (SMTP)
- Шаблонизатор: FreeMarker, файл `ics00057_accounts_email_templates.json`
- Получатели (prod/test): `to = [SOX_Workfusion_App_RPA_ICS-00057@a1.by]`, `cc = [SC_SG_WorkFusion@A1.by]`
- Шаблоны: `process_started`, `process_error`, `new_tasks`, `no_new_tasks`, `task_processed`, `work_end`

### Orchestrator
- Очередь MT: `ICS-00057 Обновление справочника` (общая для MT №1/№2/№3 — теги не конфликтуют)
- Ассеты:
  - `sap_credentials` — учётные данные SAP
  - `sap_settings` — JSON `SapGuiSettings` (systemName, client, language)
  - `sharepoint_credentials` — учётные данные SharePoint
  - `sherpa_api_credentials` — Bearer-токен для JS-вызовов MT к `/api/task/*`
  - `ics00057_accounts` — JSON-состояние справочника счетов (заменяет DataStore)
  - `ics00057_comments` — JSON-состояние комментариев MT (заменяет DataStore)
- Storage: плоское пространство имён; уникальность файла — суффикс `yyyyMMdd_HHmmss` перед расширением (`StorageNames`)
- Триггеры: Task Queue, очередь `ICS-00057 Обновление справочника`, условия по final-тегам `reviewed` / `reviewedChanged` / `reviewedAll`, переводят задачу в `IN_PROGRESS` и запускают соответствующую стадию

## 5. Ключевые сущности

### `Account`
- `accountNumber` — номер счета
- `accountName` (alt: `accountText`) — наименование
- `comment` (alt: `accountComment`) — комментарий контролёра
- `isRelevant` (alt: `accountRelevance`) — признак релевантности (включить/исключить)
- `hasPostingBlockMark` (alt: `firstLabel`) — признак «блокировка проводки»
- `hasDeletionMark` (alt: `secondLabel`) — признак «пометка удаления»

### `AccountUpdated`
- `accountPrev` (alt: `account`) — предыдущее состояние счета
- `hasPostingBlockMarkUpdated` (alt: `newFirstLabel`) — новое значение «блокировка проводки»
- `hasDeletionMarkUpdated` (alt: `newSecondLabel`) — новое значение «пометка удаления»

### `ReportingPeriod`
- `run` — дата запуска (ZonedDateTime, Europe/Minsk)
- `start` — начало отчётного периода
- `end` — конец отчётного периода

### `InitParameters`
- `emailRecipients` (to/cc)
- `storageFolderName` — папка Orchestrator Storage (`ICS-00057`)
- `unloadingFileName` (`ZACCOUNTS.xlsx`)
- `screenshotsFileName` (`screenshots.xlsx`)
- `spVactproBase`, `spVactproProject`, `spVactproPath`
- `mockSap` (`"true"`/`"false"` строкой)
- `periodStart`, `periodEnd` (`dd.MM.yyyy` или `"-"`)
- `processNewActionLink`, `processChangedActionLink`, `processAllActionLink` — Action-ссылки MT

## 6. Состояние процесса

Хранится в Orchestrator Assets (заменили DataStore и S3 — см. коммиты `3214dff`, `88c2cdf`, `0fff4e8`):
- `ics00057_accounts.json` — `List<Account>`, полный справочник счетов с релевантностью, метками и комментариями
- `ics00057_comments.json` — `Set<String>`, накопленный справочник комментариев (для autocomplete в MT-формах)

Дополнительно между шагами в одной стадии состояние передаётся через `ProcessTransaction` (ключи `ProcessDataKeys`): `sap_accounts`, `checklist_accounts`, `mt_comments`, `new_accounts_*`, `changed_accounts_*`, `*_processed_accounts`, `workflow_status`, `sap_*_storage_name`, `checksum`.

## 7. Режимы работы

- **Real SAP** (`mockSap = "false"`) — боевой режим выгрузки из SAP GUI.
- **Mock SAP** (`mockSap = "true"`) — берёт выгрузку и скриншоты из ресурсов `sap_mock/`. Используется в test-окружении и в unit-тестах, не требует SAP Logon.

## 8. Отчётный период

- Если `periodStart`/`periodEnd` парсятся как `dd.MM.yyyy` и `start < end < сегодня` — используется введённый период.
- Если не парсятся (например, `"-"`) — предыдущий квартал от даты запуска (`Europe/Minsk`).
- Если парсятся, но нарушение порядка — `BusinessException`, ботопроцесс остановлен (см. `InfrastructureStep`).

## 9. Ручные задачи (Manual Task, Shadow Core Engine)

| MT | Имя | Pending → Final → Processed | Action-ссылка (init param) | Форма |
|---|---|---|---|---|
| №1 | Проверка новых счетов | `pending` → `reviewed` → `processed` | `processNewActionLink` | `actions/process_new.js` |
| №2 | Проверка изменения меток счетов | `pendingChanged` → `reviewedChanged` → `processedChanged` | `processChangedActionLink` | `actions/process_changed.js` |
| №3 | Внесение изменений по счетам | `pendingAll` → `reviewedAll` → `processedAll` | `processAllActionLink` | `actions/process_all.js` |

Все три MT используют общую очередь `ICS-00057 Обновление справочника` с непересекающимися тегами. Каждая MT-задача несёт параметр `processStage` (2/3/4), по которому Orchestrator-триггер выбирает стартовую стадию receiver-шага.

При отсутствии новых/изменённых счетов (`PrepareNewStep`, `PrepareChangedStep`) создаётся **auto-trigger задача** в финальном состоянии (`reviewed`/`reviewedChanged`), что запускает следующую стадию без ручной проверки. MT №3 безусловна — задача создаётся всегда.

## 10. Доказательства (evidences)

Локальная структура временной папки `UploadEvidenceStep`:
```
<temp>/
├── ICS-00057_01.xlsx                 # чек-лист (из шаблона excel_template/ICS-00057_01_template.xlsx)
├── <runDate> archive ICS-00057_01.zip # технический архив
├── screenshots/
│   └── screenshots.xlsx               # скриншоты SAP (скачаны из Storage)
└── input data/
    └── ZACCOUNTS.xlsx                 # выгрузка SAP (скачана из Storage)
```

Загрузка доказательств:
- Orchestrator Storage (плоское имя с суффиксом `yyyyMMdd_HHmmss`): `ZACCOUNTS_<ts>.xlsx`, `screenshots_<ts>.xlsx`, `ICS-00057_01_<ts>.xlsx`, `<runDate> archive ICS-00057_01_<ts>.zip`
- SharePoint (унифицированная структура): `…/input data/ZACCOUNTS.xlsx`, `…/screenshots/screenshots.xlsx`, `…/ICS-00057_01.xlsx`, `…/<runDate> archive ICS-00057_01.zip`

MD5-контрольная сумма архива сохраняется в транзакцию (`checksum`).

## 11. Журналирование

- Бэкенд логирования — SLF4J + Logback (`src/main/resources/logback.xml`)
- Мост `log4j-to-slf4j` маршрутизирует логи Apache POI (Log4j2) в Logback (коммит `8fbec5b`)
- Тест `Log4jSlf4jBridgeTest` подтверждает отсутствие предупреждения «Log4j API could not find a logging provider»