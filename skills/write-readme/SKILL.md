---
name: write-readme
description: >
  Генерирует или обновляет README.md для RPA-процесса Sherpa на основе
  анализа .process-файлов, Java-кода (шагов) и конфигурации процесса.
  Используй этот скилл всегда, когда пользователь просит создать, обновить,
  перегенерировать или «сделать» README.md для RPA-процесса (модули ics*/rps-*/ipe),
  говорит «опиши процесс», «документируй бот», «сделай README для процесса»,
  «обнови README в каталоге процесса» или ссылается на каталог RPA-процесса —
  даже если не произносит слово «README». Use this skill whenever the user asks
  to generate, update, or regenerate a README.md for a Sherpa RPA process, even
  if they do not explicitly say "README". НЕ используй для полного комплекта
  HTML-документации (PDD/UG/TD) — для него есть отдельный навык
  write_documentation. Не путай с обычной Javadoc.
compatibility: "Python 3.10+ (stdlib only)"
---

# write-readme

Генерирует `README.md` для RPA-процесса на платформе Sherpa, опираясь на
детерминированный анализ кода, а не на догадки о структуре.

## Когда использовать

- Пользователь просит README/документацию для конкретного RPA-модуля.
- Пользователь говорит «опиши процесс» / «документируй бот» про каталог процесса.
- Нужно обновить устаревший README под текущую структуру шагов и ассетов.

## Когда НЕ использовать

- Полная HTML-документация (PDD, UG, TD, инструкция по развёртыванию) — это
  навык `write_documentation`.
- Документация произвольного Java-кода вне RPA-процесса.

## Входные и выходные данные

- **Вход**: `processDir` — путь к каталогу процесса (содержит `*.process`,
  `src/main/...`).
- **Выход**: `{processDir}/README.md`.

## Воркфлоу — 3 фазы, строгий порядок

### Фаза 1. Сбор данных (детерминированный)

Запусти анализатор, чтобы получить единый источник правды в виде JSON-отчёта:

```
python <skillDir>/scripts/analyze_process.py <processDir> --out <processDir>/.readme-report.json
```

`<skillDir>` — каталог этого навыка (`~/.claude/skills/write-readme`). Скрипт
извлекает `process-config.json`, шаги с разрешением `@StepName`/выводом из
имени класса, порядок шагов из `.process` (`StepName`-свойство Java-блоков),
`init_params`, `email_templates`, сервисные переменные (все три стиля вызова
`orchestratorService`: `.assets().getCredentials/.get`, legacy
`.getCredentials`, legacy `.getAsset`, с разрешением констант) **и Manual
Tasks (MT)**: формы `actions/*.js`, `*ActionLink`-поля в `InitParameters`,
пары `Prepare<…>Step`/`Save<…>Step`, DTO `model/<…>Result`, константы
`MT_<NN>_*` (с разрешением ссылок вида `MT_02_QUEUE_NAME = MT_01_QUEUE_NAME`),
`SHERPA_API_CREDENTIALS_ASSET`. Прочитай полученный отчёт.

Если в отчёте есть `warnings` — разбери их вручную: шаг без Java-класса,
неразрешённая константа-ассет или шаг в Java, не фигурирующий в `.process`
(часто отключённый шаг с префиксом `_`). Загляни в
`references/process_structure.md`, чтобы разобраться вручную, если скрипт
что-то пропустил.

### Фаза 2. Описание процесса

Из `executeSource` каждого шага в отчёте составь 2–3 предложения для секции
«Описание»: какие данные процесс получает, какая логика обработки, какой
результат. Пиши по-русски, без воды. Не копируй код дословно — суммируй
смысл.

### Фаза 3. Рендер README.md

Заполни шаблон ниже и запиши в `{processDir}/README.md`. Ссылки в шагах ведут
на реальные пути из отчёта (`javaPath`), имена шагов — из `stepName`,
человекочитаемые метки — из `displayName`. Порядок шагов — из отчёта
(соответствует порядку `StepName`-свойств в `.process`).

## Шаблон README

```markdown
# {bpName} — {Краткое описание из кода}

## Описание

{2–3 предложения: какие данные, какая логика, какой результат}

## Шаги процесса

1. {displayName} [`{stepName}`]({javaPath})
2. ...

## Конфигурация

### Параметры инициализации

- [`{имя_файла}`](src/main/resources/{относительный_путь})  <!-- перечислить все найденные (prod/test) -->

### Шаблоны email-уведомлений

- [`{имя_файла}`](src/main/resources/{имя_файла})  <!-- только если есть; иначе секцию опустить -->

## Сервисные переменные (Service Variables)

| Переменная | Тип | Описание |
|-----------|-----|----------|
| `{имя}` | {credentials/settings/конфигурация} | {краткое описание по контексту вызова} |
```

Если в отчёте `hasMt == true`, **сразу после «Сервисные переменные»** добавь
секцию Manual Tasks (шаблон ниже). Если `hasMt == false` — секцию опускай.

```markdown
## Manual Tasks (MT)

{1 предложение: MT-архитектура процесса — общая очередь + final-tag, триггеры Orchestrator стреляют на статус NEW (не In Progress).}

| MT | Form | Action link | Sender | Receiver | Result DTO | Queue | Task name | Pending | Final | Processed |
|----|------|-------------|--------|----------|------------|-------|-----------|---------|-------|-----------|
| {mtNumber} | [`{name}`]({formPath}) | `InitParameters.{actionLinkField}` | [`{senderStep}`]({senderStepPath}) | [`{receiverStep}`]({receiverStepPath}) | [`{resultDto}`]({resultDtoPath}) | `{queueName}` | `{taskName}` | `{pendingTag}` | `{finalTag}` | `{processedTag}` |
| ...  <!-- по одной строке на каждый элемент manualTasks -->

### Orchestrator setup (out-of-repo)

1. Создать очередь(и) из столбца Queue (общая для MT_01; MT_02/03 алиасят её через `MT_<NN>_QUEUE_NAME = MT_01_QUEUE_NAME`).
2. Триггер на MT: Task Queue, условие по **final tag**, lastTask, status = **NEW** (НЕ In Progress).
3. Создать asset `{mtApiCredentialsAsset}` (login/password) — sender читает bearerToken для формы.
4. Designer Action на MT (swap pending → final tag); UUID → поле `<camelName>ActionLink` в `init_params`.
```

Для неканоничных процессов (в отчёте `manualTasks[*].mtNumber == null` и/или
`warnings` содержат «non-canonical») — рендери те же строки таблицы, но пустые
`senderStep`/`receiverStep`/`resultDto`/`queueName`/`taskName`/теги заменяй на
`—`, и оставь сноску: «*(sender/receiver/DTO/константы = `—` для неканоничного
процесса — см. `warnings` отчёта.)*». Подсекцию **Orchestrator setup** в этом
случае опускай.

### Пример (фрагмент для ics60001)

```markdown
# ICS-60001 — Проверка корректности ручных бухгалтерских проводок

## Описание

Получает выгрузку SAP по бухгалтерским проводкам за отчётный период,
классифицирует документ-типы и формирует выборку для проверки. Результат
публикуется в SharePoint и отправляется multitask-уведомление контролёрам.

## Шаги процесса

1. ProcessSetup [`processSetup`](src/main/java/by/a1/ics60001/steps/ProcessSetupStep.java)
2. GetSapReportData [`getSapReportData`](src/main/java/by/a1/ics60001/steps/GetSapReportDataStep.java)
3. PrepareDocumentTypeLists [`prepareDocumentTypeLists`](src/main/java/by/a1/ics60001/steps/PrepareDocumentTypeListsStep.java)
4. PersistDocumentTypeLists [`persistDocumentTypeLists`](src/main/java/by/a1/ics60001/steps/PersistDocumentTypeListsStep.java)
5. SamplePreparation [`samplePreparation`](src/main/java/by/a1/ics60001/steps/SamplePreparationStep.java)
6. OwnersEnrichment [`ownersEnrichment`](src/main/java/by/a1/ics60001/steps/OwnersEnrichmentStep.java)
7. SendMultitaskNotification [`sendMultitaskNotification`](src/main/java/by/a1/ics60001/steps/SendMultitaskNotificationStep.java)
8. FinalizeAndPublishResults [`finalizeAndPublishResults`](src/main/java/by/a1/ics60001/steps/FinalizeAndPublishResultsStep.java)

## Конфигурация

### Параметры инициализации

- [`ics60001_init_params`](src/main/resources/initparams/test/ics60001_init_params.json)

### Шаблоны email-уведомлений

- [`ics60001_email_templates`](src/main/resources/ics60001_email_templates.json)

## Сервисные переменные (Service Variables)

| Переменная | Тип | Описание |
|-----------|-----|----------|
| `sap_credentials` | credentials | Учётные данные SAP для выгрузки отчёта |
| `proxy_credentials` | credentials | Прокси-учётные данные для исходящих запросов |
| `sharepoint_credentials` | credentials | Доступ к SharePoint для публикации результатов |
| `sherpa_api_credentials` | credentials | Доступ к API Orchestrator/Sherpa |
| `mim_credentials` | credentials | Подключение к MIM для обогащения владельцев |
| `sap_settings` | settings | Параметры SAP GUI сессии |
| `currency_rates_config` | конфигурация | Конфигурация курса валют |
| `document_type_classification` | конфигурация | Справочник классификации документ-типов |
| `document_type_comments` | конфигурация | Комментарии к классификации документ-типов |
```

### Пример MT-секции (фрагмент для ics00057-accounts — канонический)

```markdown
## Manual Tasks (MT)

MT-архитектура: общая очередь + final-tag, триггеры Orchestrator стреляют на статус NEW (не In Progress).

| MT | Form | Action link | Sender | Receiver | Result DTO | Queue | Task name | Pending | Final | Processed |
|----|------|-------------|--------|----------|------------|-------|-----------|---------|-------|-----------|
| MT_01 | [`process_new`](src/main/resources/actions/process_new.js) | `InitParameters.processNewActionLink` | [`PrepareNewStep`](src/main/java/by/a1/ics00057_accounts/steps/PrepareNewStep.java) | [`SaveNewStep`](src/main/java/by/a1/ics00057_accounts/steps/SaveNewStep.java) | [`ProcessNewResult`](src/main/java/by/a1/ics00057_accounts/model/ProcessNewResult.java) | `ICS-00057 Обновление справочника` | `processNew` | `pending` | `reviewed` | `processed` |
| MT_02 | [`process_changed`](src/main/resources/actions/process_changed.js) | `InitParameters.processChangedActionLink` | [`PrepareChangedStep`](src/main/java/by/a1/ics00057_accounts/steps/PrepareChangedStep.java) | [`SaveChangedStep`](src/main/java/by/a1/ics00057_accounts/steps/SaveChangedStep.java) | [`ProcessChangedResult`](src/main/java/by/a1/ics00057_accounts/model/ProcessChangedResult.java) | `ICS-00057 Обновление справочника` | `processChanged` | `pendingChanged` | `reviewedChanged` | `processedChanged` |
| MT_03 | [`process_all`](src/main/resources/actions/process_all.js) | `InitParameters.processAllActionLink` | [`PrepareAllStep`](src/main/java/by/a1/ics00057_accounts/steps/PrepareAllStep.java) | [`SaveAllStep`](src/main/java/by/a1/ics00057_accounts/steps/SaveAllStep.java) | [`ProcessAllResult`](src/main/java/by/a1/ics00057_accounts/model/ProcessAllResult.java) | `ICS-00057 Обновление справочника` | `processAll` | `pendingAll` | `reviewedAll` | `processedAll` |

### Orchestrator setup (out-of-repo)

1. Создать очередь(и) из столбца Queue (общая для MT_01; MT_02/03 алиасят её через `MT_<NN>_QUEUE_NAME = MT_01_QUEUE_NAME`).
2. Триггер на MT: Task Queue, условие по **final tag**, lastTask, status = **NEW** (НЕ In Progress).
3. Создать asset `sherpa_api_credentials` (login/password) — sender читает bearerToken для формы.
4. Designer Action на MT (swap pending → final tag); UUID → поле `<camelName>ActionLink` в `init_params`.
```

Для **ics60001** (неканоничный: формы и `*ActionLink` есть, но `MT_0X_*`
отсутствуют, receiver — `SaveDialogJnaFinal`) таблица рендерится с `—` в
столбцах sender/receiver/DTO/Queue/Task name/тегов и сноской про
`warnings`; подсекция Orchestrator setup опускается.

## Жёсткие правила

- Ссылки на шаги используй только реальные `javaPath` из отчёта, не угадывай
  `by/a1/.../`. Имя класса — в обратных кавычках после `displayName`.
- Имя шага в README — это resolved `stepName` из отчёта (совпадает со
  значением `StepName`-свойства в `.process`), не `InternalName` блока и
  не `DisplayName`.
- Порядок шагов — из отчёта (по `StepName`-свойствам в `.process`), не
  алфавитный и не по файлам Java.
- `init_params`: перечисляй **все** найденные файлы с реальными
  относительными путями (могут быть `prod`/`test`), не один угаданный.
- Секцию email-шаблонов включай только если файл существует.
- Таблицу сервисных переменных формируй из отчёта; тип — `credentials` /
  `settings` / `конфигурация`. Если в `warnings` есть неразрешённая
  константа-ассет — разберись вручную и добавь реальное имя.
- Не выдумывай ассеты, которых нет в отчёте. Не пропускай ассеты, которые
  есть.
- Не включай отключённые шаги (префикс `_`, попадают в `warnings` как
  orphan) в основной список «Шаги процесса» — упомяни отдельной строкой
  под списком, если сочтёшь нужным.
- Пиши на русском; заголовок таблицы сервисных переменных оставь
  bilingual (`## Сервисные переменные (Service Variables)`).
- **MT-секция рендерится только при `hasMt == true`** в отчёте. Все имена
  форм, пути, `*ActionLink`-поля, пары Prepare/Save, DTO, `mtNumber`,
  `queueName`, `taskName`, теги и `mtApiCredentialsAsset` берутся **только** из
  `manualTasks`/`mtApiCredentialsAsset` отчёта — не угадывай и не выдумывай
  константы MT.
- Пустые sender/receiver/DTO/`mtNumber`/`queueName`/`taskName`/теги (неканоничный
  процесс) рендери как `—` и опирайся на `warnings` отчёта; подсекцию
  Orchestrator setup в этом случае опускай. Для каноничного процесса
  (нет MT-`warnings`) — подсекция обязательна.
- Не ссылайся в README на другой процесс по имени (например «как в
  ics00057») — только на артефакты текущего процесса.

## Файлы в этом навыке

- `SKILL.md` — этот файл.
- `scripts/analyze_process.py` — детерминированный анализатор процесса в
  JSON-отчёт (шаги, `init_params`, `email_templates`, сервисные переменные,
  Manual Tasks). CLI: `python analyze_process.py <processDir> [--out report.json]`.
- `scripts/tests/test_analyze_process.py` — проверки анализатора на реальных
  процессах: `ics60001` (неканоничный MT — детекция + деградация) и
  `ics00057-accounts` (канонический MT — 3 MT, разрешённые `QUEUE_NAME`,
  пары Prepare/Save, DTO). Запуск: `python scripts/tests/test_analyze_process.py`
  (из корня rpa-suite); опционально `--ics00057 <path>` для канонического MT
  (получить: `git worktree add <tmp>/00057 origin/feat/00057-accounts`).
- `references/process_structure.md` — реальные факты о структуре процесса
  (`.process`, `@StepName`/StepRegistry, `init_params`, стили вызова ассетов,
  Manual Tasks) для ручного разбора, если скрипт что-то пропустил.