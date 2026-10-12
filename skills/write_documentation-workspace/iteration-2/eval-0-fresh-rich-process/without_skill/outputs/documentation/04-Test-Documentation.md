# Тестовая документация — ICS-00057 «Обновление справочника»

## 1. Стратегия тестирования

Тестирование на уровне Java-модуля (unit-тесты JUnit 5 + Mockito + AssertJ). Бот-рантайм, SAP GUI, SharePoint и Orchestrator имитируются моками; реальные внешние вызовы в unit-тестах отсутствуют. Тестовый класс `SapStepTest` проверяет утилиту `StorageNames` (формирование плоских имён Storage), а не сам SapStep — он покрыт косвенно через `FolderStructureTest` и интеграцию мок-SAP.

Цели покрытия:
- корректность ветвления sender-шагов по `workflow_status` и наличию новых/изменённых счетов;
- корректность разбора `initialData` MT-задачи в `processedAccounts` (включая alternate-имена полей `Account`);
- финализация MT-задачи в любой ветке (`SUCCESS` + `processed*`) — критично для предотвращения повторного auto-trigger;
- формирование унифицированной структуры папок и плоских Storage-имён;
- чтение/запись состояния в Orchestrator Storage (`ProcessStateService`);
- рендеринг email-шаблонов FreeMarker и совпадение подписей с ODF-шаблонами;
- маршрутизация логов Apache POI через мост `log4j-to-slf4j` в Logback.

## 2. Стек

| Компонент | Версия | Назначение |
|---|---|---|
| JUnit 5 (jupiter) | 5.10.0 (BOM) | test runner |
| Mockito | 5.7.0 | моки `EmailService`, `OrchestratorService`, `Transaction` |
| AssertJ | 3.27.4 | fluent assertions |
| FreeMarker | 2.3.34 (testImplementation) | рендер email-шаблонов в тестах |
| Lombok | 1.18.40 | compile-only, test-compile |

## 3. Тестовые ресурсы

- `src/test/resources/accounts/{prod,test}/ics00057_accounts.json` — эталонные справочники счетов
- `src/test/resources/comments/{prod,test}/ics00057_comments.json` — эталонные множества комментариев
- `src/main/resources/sap_mock/excel/` — мок-выгрузки SAP:
  - `without_new_accounts/ZACCOUNTS.xlsx`
  - `with_changed_accounts/ZACCOUNTS.xlsx`
  - `with_new_accounts/ZACCOUNTS.xlsx`
- `src/main/resources/sap_mock/mock_screen_*.png` — мок-скриншоты для `SapStep.exportMock`

## 4. Перечень тестов

Всего: **53 метода `@Test`** (по данным `grep -r "@Test" src/test/java/`).

### 4.1. Шаги (`src/test/java/.../steps/`)

| Класс | Методы (кратко) | Что проверяют |
|---|---|---|
| `PrepareNewStepTest` | `splitsNewAccountsByMarksAndNotifiesNewTasks_whenNewAccountsExist`; `createsAutoTriggerTaskAndSetsNoNewAccountsStatus_whenNoNewAccounts`; `throws_whenSapAccountsMissing`; `throws_whenInitParametersMissing` | Разбиение новых счетов на «без меток»/«с метками», создание MT №1 или auto-trigger, ошибки при отсутствии входных данных |
| `PrepareChangedStepTest` | `splitsChangedAccountsByMarksAndCreatesMt02Task_whenChangedAccountsExist`; `createsAutoTriggerTaskAndSetsNoChangedAccountsStatus_whenNoChangedAccounts`; `throws_whenSapAccountsMissing`; `throws_whenChecklistAccountsMissing`; `throws_whenInitParametersMissing`; `changedAccountsExcelMock_containsExpectedChangedAccounts` | Аналогично для MT №2; дополнительно — корректность тестового мока `with_changed_accounts` |
| `PrepareAllStepTest` | `createsMt03TaskWithFullChecklistAndSendsEmail`; `throws_whenChecklistAccountsMissing`; `throws_whenInitParametersMissing` | Создание MT №3 с полным справочником, ошибки при отсутствии данных |
| `SaveNewStepTest` | `readsProcessedAccountsFromQueue_mergesChecklistAndComments_persistsResult`; `skipsAccountProcessingAndFinalizesTask_whenNoNewAccounts`; `skipsAndFinalizesTask_whenWorkflowStatusUnknown`; `throws_whenNoTaskWithFinalTag` | Разбор `initialData` → `processedAccounts`; ветвление по `workflow_status`; обязательная финализация задачи |
| `SaveChangedStepTest` | `readsProcessedAccountsFromQueue_mergesChecklistAndComments_persistsResult`; `skipsAccountProcessingAndFinalizesTask_whenNoChangedAccounts`; `skipsAndFinalizesTask_whenWorkflowStatusUnknown`; `throws_whenNoTaskWithFinalTag` | Аналогично для MT №2 |
| `SaveAllStepTest` | `readsProcessedAccountsFromQueue_mergesChecklistAndComments_persistsResult`; `mergesEmptyProcessedAccounts_whenControllerSubmittedNothing`; `throws_whenNoTaskWithFinalTag` | Разбор результата MT №3, обработка пустого `processedAccounts`, поиск задачи по final-тегу |
| `SapStepTest` | `insertsTimestampBeforeExtension`; `insertsTimestampForScreenshotsFile`; `appendsTimestampWhenNoExtension`; `preservesDotfilesWithoutTreatingDotAsExtension` | Утилита `StorageNames.withTimestamp` — корректная вставка суффикса перед расширением, обработка файлов без расширения и dotfiles |

### 4.2. Утилиты и сервисы

| Класс | Методы | Что проверяют |
|---|---|---|
| `FolderStructureTest` | `buildsWorkingFolderPathMatchingOriginalS3Structure`; `buildsInputDataAndScreenshotsSubfolders`; `buildsChecklistAndArchiveFilenames`; `composesStorageNamesForSapStepUploads`; `composesStorageNamesForUploadEvidenceStepUploads` | Единая структура папок и Storage-имён между `SapStep` и `UploadEvidenceStep` |
| `ProcessStateServiceTest` | `selectAccounts_returnsAccounts_whenStorageFileExists` / `_returnsEmpty_whenStorageFileMissing`; аналогично для `selectComments`; `updateAccounts_*` / `updateComments_*` (update vs upload-new); `selectAccounts_wrapsStorageFailure_intoBusinessException` | Чтение/запись JSON-состояния в Orchestrator Storage |
| `ProcessNewResultTest` | `parsesUserInputProcessedAccounts_withAlternateSerializedNameAliases`; `roundTripPreservesProcessedAccountsShape`; `parsesRawProcessedAccountsJsonList_intoAccountList` | Разбор результата MT №1, alternate-имена полей `Account` (`accountText`/`accountName`, `accountRelevance`/`isRelevant` и т.д.) |
| `SharePointServiceTest` | `uploadsWithOverwriteConflictStrategy` | Стратегия `OVERWRITE` при загрузке в SharePoint |

### 4.3. Email и логирование

| Класс | Методы | Что проверяют |
|---|---|---|
| `EmailTemplatesTest` | `containsAllExpectedTemplateKeys`; `processStartedMatchesOdfWorkStart`; `processErrorMatchesOdfError`; `rendersProcessStartedWithProcessConfigContext`; `rendersProcessErrorWithoutLinkWhenErrorOccursUrlAbsent`; `rendersProcessErrorWithLinkWhenErrorOccursUrlPresent` | Наличие всех 6 шаблонов, совпадение подписей `process_started`/`process_error` с ODF-эталоном, рендер с/без `errorOccursUrl` |
| `Log4jSlf4jBridgeTest` | `log4j2RoutesToSlf4jBridgeWhenPoiInitializesLog4j` | Маршрут логов POI через `log4j-to-slf4j` в Logback (отсутствие предупреждения «Log4j API could not find a logging provider») |

## 5. Ключевые сценарии

### S1. Полный «счастливый» путь (mock-SAP, новые счета есть)
- Подготовка: `mockSap="true"`, тестовая выгрузка `with_new_accounts/ZACCOUNTS.xlsx`.
- Шаги: InfrastructureStep → SapStep (mock) → PrepareNewStep → SaveNewStep → PrepareChangedStep → SaveChangedStep → PrepareAllStep → SaveAllStep → UploadEvidenceStep.
- Ожидания:
  - `PrepareNewStep` создаёт MT №1 с тегом `pending`, `workflow_status = new_accounts_exist`, отправляет `new_tasks`.
  - `SaveNewStep` разбирает `processedAccounts`, обновляет `checklist_accounts` и `mt_comments`, переводит задачу в `SUCCESS` + `processed`.
  - Аналогично для MT №2/№3.

### S2. Нет новых счетов (auto-trigger)
- Подготовка: `without_new_accounts/ZACCOUNTS.xlsx`.
- Ожидания:
  - `PrepareNewStep` создаёт MT №1 с тегом `pending`, затем переводит в `IN_PROGRESS` + `reviewed`.
  - `SaveNewStep` видит `workflow_status = no_new_accounts`, пропускает разбор, но ОБЯЗАТЕЛЬНО финализирует задачу (`SUCCESS` + `processed`).
  - `PrepareChangedStep` аналогично обрабатывает absence изменений.

### S3. Ошибка разбора MT-задачи
- Подготовка: MT-задача без `initialData`.
- Ожидания: `Save*Step` бросает `BusinessException("Failed to parse MT task ...")`.

### S4. Повторный auto-trigger (защита)
- Подготовка: `workflow_status` пуст/неизвестен.
- Ожидания: `SaveNewStep/SaveChangedStep` логируют warn, пропускают разбор, но финализируют задачу — иначе триггер пере-сработает.

### S5. Отчётный период
- Введение `periodStart="01.01.2026"`, `periodEnd="31.03.2026"` → `InfrastructureStep` использует введённый период.
- Введение `"-"` → используется предыдущий квартал.
- Введение `start >= end` → `BusinessException("Invalid input reporting period")`.

## 6. Запуск тестов

```bash
cd rpa-suite
./gradlew :rpa-suite:ics00057-accounts:test
```

JVM-свойство `transaction.path` задаётся в `build.gradle` (`systemProperty 'transaction.path', "${buildDir}/test/transaction_ics00057.json"`) — чтобы sender-шаги не падали на `Missing system property 'transaction.path'`.

## 7. Coverage-ориентиры (по поведению, а не строкам)

| Поведение | Покрытие |
|---|---|
| Разбор `initialData` MT №1/№2/№3 | `ProcessNewResultTest`, `Save*StepTest` |
| Ветвление `workflow_status` | `SaveNewStepTest`, `SaveChangedStepTest` |
| Auto-trigger path | `PrepareNewStepTest`, `PrepareChangedStepTest` |
| Финализация задачи в любой ветке | `Save*StepTest` (`verify(...).status(SUCCESS)`, `tags(processed*)`) |
| Унифицированная структура папок | `FolderStructureTest` |
| Плоские Storage-имена | `SapStepTest`, `FolderStructureTest` |
| Чтение/запись состояния Storage | `ProcessStateServiceTest` |
| SharePoint OVERWRITE | `SharePointServiceTest` |
| Email-шаблоны | `EmailTemplatesTest` |
| Логирование POI | `Log4jSlf4jBridgeTest` |

## 8. Не покрыто unit-тестами (требует приёмочных тестов)

- Реальная выгрузка из SAP GUI (требует SAP Logon + живую систему).
- Загрузка в реальный SharePoint (требует доступ к `vactpro.main.velcom.by`).
- Срабатывание Orchestrator Task Queue-триггеров (требует Orchestrator-окружения).
- Рендер MT-форм `actions/process_*.js` в браузере Shadow Core Engine.

Эти сценарии проверяются в test-среде с `mockSap="true"` (для бот-логики) и вручную (для MT-форм и триггеров).