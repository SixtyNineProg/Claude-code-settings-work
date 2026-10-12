# Process Design Document (PDD) — ICS-00057 «Обновление справочника»

## 1. Описание процесса

Ботопроцесс актуализирует справочник счетов, релевантных для контроля ICS-00057. Источник — SAP-транзакция `ZACCOUNTS` (план счетов `IFRS`, БЕ `1320`). Бот выгружает счета, сравнивает со справочником из Orchestrator Asset, готовит три последовательные ручные задачи (MT №1–№3) для контролёра, разбирает результаты, обновляет справочник и публикует доказательства в SharePoint и Orchestrator Storage.

## 2. Границы процесса

### Внутри области (in scope)
- Выгрузка данных из SAP GUI (ZACCOUNTS) и скриншотов экранов
- Сравнение выгрузки с хранимым справочником счетов
- Создание MT-задач в Orchestrator Task Queue с payload для форм Shadow Core Engine
- Разбор результата MT-форм (`initialData` → `processedAccounts`)
- Формирование чек-листа `ICS-00057_01.xlsx` и технического zip-архива
- Загрузка доказательств в SharePoint и Orchestrator Storage
- Обновление ассетов состояния (`ics00057_accounts`, `ics00057_comments`)
- Email-уведомления (старт, новые задачи, нет задач, задача обработана, работа завершена, ошибка)

### Вне области (out of scope)
- Ввод данных контролёром внутри MT-форм (логика формы — `actions/process_*.js`)
- Маршрутизация писем через SMTP (делегировано `rpa-core EmailService`)
- Управление жизненным циклом Orchestrator (триггеры настраиваются администратором)
- Учётная политика плана счетов IFRS / БЕ 1320 (внешний мастер-данные SAP)

## 3. Роли

| Роль | Описание |
|---|---|
| Контролёр | Пользователь Shadow Core Engine, проверяет счета в MT №1–№3, ставит релевантность, комментарий, метки; кнопкой Submit отправляет результат |
| Администратор Orchestrator | Настраивает ассеты, очереди, триггеры Task Queue, Action-ссылки |
| Владелец процесса | Получает email-уведомления о старте/завершении/ошибках; контролирует корректность работы |

## 4. Поток процесса (последовательность шагов)

### Stage1 (бот, запуск по расписанию)
1. **InfrastructureStep** — расчёт отчётного периода, email «ботопроцесс запущен».
2. **SapStep** — вход в SAP GUI, `ZACCOUNTS`, экспорт ALV в Excel, 3 скриншота, загрузка `ZACCOUNTS.xlsx` + `screenshots.xlsx` в Orchestrator Storage (плоское имя с суффиксом даты-времени), создание унифицированной структуры папок на SharePoint, парсинг выгрузки в `List<Account>`.
3. **PrepareNewStep** — сравнение SAP-счетов со справочником из ассета `ics00057_accounts`; определение новых счетов; разбиение на «без меток»/«с метками»; создание MT №1 (тег `pending`, `processStage=2`) либо auto-trigger (тег `reviewed`); email «новая задача» / «новых задач нет».

### Stage2 (бот, запуск триггером по тегу `reviewed`)
4. **SaveNewStep** — поиск MT №1 с тегом `reviewed` и статусом `IN_PROGRESS`; разбор `initialData` → `ProcessNewResult` → `processedAccounts`; обновление `checklist_accounts` и `mt_comments`; финализация задачи (`SUCCESS` + тег `processed`); email «задача обработана».
5. **PrepareChangedStep** — определение счетов с изменившимися метками (`hasPostingBlockMark` / `hasDeletionMark`); разбиение на редактируемые «без меток» и неизменяемые «с метками» (через `AccountUpdated`); создание MT №2 (тег `pendingChanged`, `processStage=3`) либо auto-trigger (тег `reviewedChanged`); email.

### Stage3 (бот, запуск триггером по тегу `reviewedChanged`)
6. **SaveChangedStep** — разбор результата MT №2 (`ProcessChangedResult`), обновление справочника и комментариев, финализация задачи (`SUCCESS` + `processedChanged`), email.
7. **PrepareAllStep** — создание MT №3 с полным справочником `allAccounts` (тег `pendingAll`, `processStage=4`); auto-trigger отсутствует — задача безусловна; email «новая задача».

### Stage4 (бот, запуск триггером по тегу `reviewedAll`)
8. **SaveAllStep** — разбор результата MT №3 (`ProcessAllResult`), обновление справочника и комментариев, финализация задачи (`SUCCESS` + `processedAll`), email.
9. **UploadEvidenceStep** — скачивание `ZACCOUNTS.xlsx` и `screenshots.xlsx` обратно из Storage (локальный temp удалён, бот-сессия разорвана на MT-шагах); формирование `ICS-00057_01.xlsx` (из шаблона) и технического zip-архива; загрузка чек-листа и архива в Storage и SharePoint (по унифицированной структуре); обновление ассетов `ics00057_accounts`, `ics00057_comments`; email «работа завершена» со ссылкой на SharePoint.

> Обработка ошибок: `rpa-core HandleErrorStep` (общий обработчик) отправляет email `process_error` с опциональной ссылкой «Порядок действий при возникновении ошибок» (init_param `errorHandling.errorOccursUrl`, если задан).

## 5. Схема переходов состояний MT-задачи

```
[pending]      ── контролёр открыл форму, заполнил, Submit ──▶ [reviewed]
   ↑                                                        (checkAndMarkLastTask
   │                                                         заменяет pending→reviewed)
   │
   └── create (PrepareNewStep)             SaveNewStep: SUCCESS + tags=[processed]
                                                        (снимает задачу с триггера)
```

Аналогично для MT №2 (`pendingChanged` → `reviewedChanged` → `processedChanged`) и MT №3 (`pendingAll` → `reviewedAll` → `processedAll`).

`SaveNewStep/SaveChangedStep` дополнительно ветвятся по `workflow_status`:
- `new_accounts_exist` / `changed_accounts_exist` — разбирают `processedAccounts`
- `no_new_accounts` / `no_changed_accounts` — пропускают разбор (auto-trigger путь)
- неизвестное/пустое — safe default, но задача ОБЯЗАТЕЛЬНО финализируется (иначе auto-trigger пере-сработает)

`SaveAllStep` не ветвится — MT №3 безусловна, `processedAccounts` может быть пустым.

## 6. Логика расчёта отчётного периода (`InfrastructureStep`)

```
periodStart, periodEnd из InitParameters
│
├── оба парсятся как dd.MM.yyyy?
│   ├── да → start < end && end < today(Minsk)?
│   │       ├── да → ReportingPeriod(run=now, start, end)
│   │       └── нет → BusinessException("Invalid input reporting period")
│   └── нет → ReportingPeriod = предыдущий квартал от run
│            prevQStart = run.minusMonths(3).with(DAY_OF_QUARTER=1)
│            prevQEnd   = prevQStart.plusMonths(2).with(lastDayOfMonth())
```

## 7. Структура данных MT-задачи

Все MT-задачи создаются в очереди `ICS-00057 Обновление справочника` с параметрами:
- `initialData` — payload для формы (см. ниже)
- `transactionName` — имя файла транзакции (из JVM-свойства `transaction.path`, без расширения)
- `processStage` — 2/3/4, определяет стартовую стадию receiver

### `initialData` по MT

**MT №1 (PrepareNewStep)**
```json
{
  "newAccountsWithoutMarks": [Account...],   // редактируемые (без меток)
  "newAccountsWithMarks":    [Account...],   // неизменяемые (с метками)
  "comments":               ["...", ...],    // autocomplete комментариев
  "bearerToken":            "<sherpa_api_credentials.password>"
}
```

**MT №2 (PrepareChangedStep)**
```json
{
  "changedAccounts":         [AccountUpdated...], // без меток (редактируемые)
  "changedAccountsImmutable": [AccountUpdated...], // с метками (неизменяемые)
  "comments":                ["...", ...],
  "bearerToken":             "<...>"
}
```

**MT №3 (PrepareAllStep)**
```json
{
  "allAccounts":  [Account...],  // весь справочник (autocomplete по номеру)
  "comments":     ["...", ...],
  "bearerToken":  "<...>"
}
```

### Результат формы (отправка `ShadowCore.submit`)
```json
{ "userInput": { "processedAccounts": [Account...] } }
```
Сериализуется в скрытый параметр задачи `initialData`. Receiver-шаги разбирают его через `ProcessNewResult` / `ProcessChangedResult` / `ProcessAllResult` (`getUserInput().getProcessedAccounts()`).

## 8. Ключи транзакции (`ProcessDataKeys`)

| Ключ | Тип | Кто пишет | Кто читает |
|---|---|---|---|
| `init_params` | InitParameters | Orchestrator (старт) | Все шаги |
| `run_date`, `period_start`, `period_end` | ZonedDateTime (string) | InfrastructureStep | SapStep, UploadEvidenceStep |
| `sap_accounts` | `List<Account>` (JSON) | SapStep | PrepareNewStep, PrepareChangedStep |
| `sap_screenshots_storage_name` | String | SapStep | UploadEvidenceStep |
| `sap_unloading_storage_name` | String | SapStep | UploadEvidenceStep |
| `checklist_accounts` | `List<Account>` | PrepareNewStep (init), Save* (обновление) | Следующие шаги, UploadEvidence |
| `mt_comments` | `Set<String>` | PrepareNewStep (init), Save* (обновление) | Следующие шаги, UploadEvidence |
| `new_accounts_with_marks`, `new_accounts_without_marks` | `List<Account>` | PrepareNewStep | (справочно) |
| `changed_accounts_with_marks`, `changed_accounts_without_marks` | `List<AccountUpdated>` | PrepareChangedStep | (справочно) |
| `workflow_status` | String | PrepareNewStep, PrepareChangedStep | Save*Step (ветвление) |
| `new_processed_accounts`, `changed_processed_accounts`, `all_processed_accounts` | `List<Account>` | Save*Step | (справочно) |
| `checksum` | String (MD5) | UploadEvidenceStep | (справочно) |

## 9. Унифицированная структура папок (`FolderStructure`)

Единый источник истины — `FolderStructure.from(reportingPeriod)`, используется `SapStep` (создание папок, загрузка) и `UploadEvidenceStep` (загрузка по структуре).

```
Бот/<год>/<start - end>/<01_Обновление справочника>/<runDate per период>/
├── input data/ZACCOUNTS.xlsx
├── screenshots/screenshots.xlsx
├── ICS-00057_01.xlsx                              # чек-лист
└── <runDate> archive ICS-00057_01.zip             # технический архив
```

Папка `other evidence` (если создаётся структурой) удаляется в `SapStep` (`sharePoint.deleteFolder(...)`).

## 10. Именование файлов в Orchestrator Storage

Storage плоский (без папок). Уникальность — суффикс `yyyyMMdd_HHmmss` перед расширением (`StorageNames.withTimestamp`):
- `ZACCOUNTS_<ts>.xlsx`
- `screenshots_<ts>.xlsx`
- `ICS-00057_01_<ts>.xlsx`
- `<runDate> archive ICS-00057_01_<ts>.zip`

Папка Storage указана в `InitParameters.storageFolderName` (`ICS-00057`).

## 11. Email-уведомления

| Шаг/событие | Шаблон | Тема (шаблон FreeMarker) |
|---|---|---|
| InfrastructureStep (старт) | `process_started` | `${bpName} ${bpNumber}_${bpDescription}: ботопроцесс запущен ${currentDate}` |
| HandleErrorStep (ошибка) | `process_error` | `${bpName} ${bpNumber}_${bpDescription}: ошибка во время исполнения ботопроцесса ${currentDate}` |
| PrepareNew/Changed/AllStep (есть задача) | `new_tasks` | `${bpNumber} ${bpDescription}: Новая задача — ${mtName}` |
| PrepareNew/ChangedStep (нет задач) | `no_new_tasks` | `${bpNumber} ${bpDescription}: Новых задач нет — ${mtName}` |
| Save*Step (обработано) | `task_processed` | `${bpNumber} ${bpDescription}: Задача обработана — ${mtName}` |
| UploadEvidenceStep (завершение) | `work_end` | `${bpNumber} ${bpDescription}: Работа завершена` |

## 12. Допущения и ограничения

- Требуется установленная SAP GUI на сервере бота (SAP Logon 750+) и библиотека `jacob.jar` (в `libs/`).
- Язык SAP из `sap_settings.language` должен быть `RU` (имена счетов зависят от языка).
- Orchestrator Storage не поддерживает структуру папок — все имена плоские с суффиксом.
- Бот-сессия разрывается между стадиями (Orchestrator завершает бот после каждой стадии) — поэтому локальные файлы `SapStep` не переживают запуск `UploadEvidenceStep`; они скачиваются обратно из Storage.
- `transaction.path` (JVM-свойство) обязательно для sender-шагов (Prepare*); в тестах подменяется путём в `buildDir` (см. `build.gradle`).

## 13. Нефункциональные требования

- **Производительность**: таймаут экспорта ALV — 1800 с (`EXPORT_TIMEOUT_S`); ожидание элементов SAP — 60 с.
- **Надёжность**: финализация MT-задачи (`SUCCESS` + `processed*`) выполняется в любой ветке, чтобы предотвратить повторный запуск триггера.
- **Безопасность**: Bearer-токен `sherpa_api_credentials` передаётся в `initialData` MT-формы для вызовов `ShadowCore.checkAndMarkLastTask` из браузера.
- **Совместимость**: процесс зависит от модуля `rpa-core` (общий фреймворк), `jacob.jar` (SAP GUI automation), `poiji` + Apache POI (Excel), `zip4j` (архивация), `guice` (DI).
- **Журналирование**: SLF4J + Logback; мост `log4j-to-slf4j` для Apache POI.

## 14. Метрики и наблюдаемость

- Логи SLF4J на каждый шаг (`Start <Step>`, `Finish <Step>`, ключевые размеры: `Sap accounts {}`, `New accounts size: {}` и т. п.).
- MD5-контрольная сумма архива (`checksum` в транзакции).
- Email-уведомления на каждую бизнес-точку (старт, новые/нет задач, обработано, завершено, ошибка).
- Orchestrator Storage хранит датированные копии всех evidences-файлов (история по датам).