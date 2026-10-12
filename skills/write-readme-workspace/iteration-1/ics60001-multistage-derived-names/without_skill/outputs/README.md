# ICS-60001 — Контроль корректности ручных бухгалтерских проводок

## Описание

Процесс ICS-60001 автоматизирует контроль корректности ручных бухгалтерских проводок в SAP. Робот извлекает параметры инициализации, получает данные отчёта SAP-транзакции `ZFI_FCRP1`, рассчитывает порог существенности по курсу валюты, формирует структуру папок в SharePoint, подготавливает и рассылает задания исполнителям, обеспечивает пользовательский ввод (редактирование справочника типов документов и проверка отдельных документов), после чего финализирует и публикует результаты контроля.

Процесс реализован на платформе Sherpa RPA Suite и построен из 10 последовательных шагов, описанных в `Stage1.process`–`Stage3.process` и orchestрируемых главной схемой `Главная.process`.

## Архитектура

- **Платформа:** Sherpa RPA Suite (`by.a1.rpa.core`).
- **Язык:** Java (Gradle, `application` + `shadowJar`), главный класс запуска — `by.a1.rpa.core.StepRunnerMain`.
- **Сборка:** `./gradlew :ics60001:shadowJar` формирует fat-jar `ics-60001-1.0.0.jar`; задача `build` зависит от `shadowJar`.
- **Зависимости:**
  - `:rpa-core` — ядро RPA (Step, Transaction, OrchestratorService, EmailService, SharePoint, folders).
  - `poiji` / `apache-poi` — чтение Excel-отчётов SAP.
  - `commons-io` — файловые утилиты.
  - `jPowerShell` — вызов PowerShell-команд (в т.ч. для MIM).
  - `lombok` — boilerplate-генерация.
- **Структура пакетов (`by.a1.ics60001`):**
  - `model` — DTO: `InitParameters`, `ExchangeRate`, `AccountingDocumentGroup`, `AccountingDocumentPosition`, `DocumentReviewResult`, `DocumentTypeEntry`, `DocumentTypeClassification`, `OwnerContact`.
  - `steps` — реализации `Step` (по одному классу на шаг процесса).
  - `transaction` — `ProcessTransaction` (обёртка над `Transaction` для типизированного доступа к данным шагов) и `ProcessDataKeys` (константы ключей разделяемого состояния).

## Шаги процесса

| № | Шаг | Реализация | Описание |
|---|-----|------------|----------|
| 1 | Инициализация параметров и создание структуры папок | [`ProcessSetupStep`](src/main/java/by/a1/ics60001/steps/ProcessSetupStep.java) | Извлекает `InitParameters`, разрешает дату окончания отчётного периода, получает курс валюты и рассчитывает порог существенности, создаёт унифицированную структуру папок в SharePoint, отправляет email о старте процесса. |
| 2 | Получение данных отчёта из SAP | [`GetSapReportDataStep`](src/main/java/by/a1/ics60001/steps/GetSapReportDataStep.java) | Выгружает данные транзакции `ZFI_FCRP1` (или тестовый Excel при `sapMocked=true`) и разбирает позиции проводок. |
| 3 | Подготовка списков типов документов | [`PrepareDocumentTypeListsStep`](src/main/java/by/a1/ics60001/steps/PrepareDocumentTypeListsStep.java) | Формирует allowed/denied/unclassified списки типов документов по справочникам классификации и комментариев. |
| 4 | Редактирование списков типов документов | [`document-type-policy-editor.js`](src/main/resources/actions/document-type-policy-editor.js) | Пользовательская форма (Shadow Core Engine): просмотр и редактирование allowed/denied списков, ввод комментариев, включение/отключение типов для проверки. |
| 5 | Сохранение списков типов документов | [`PersistDocumentTypeListsStep`](src/main/java/by/a1/ics60001/steps/PersistDocumentTypeListsStep.java) | Сохраняет отредактированные списки в транзакцию и справочники. |
| 6 | Подготовка выборки для проверки | [`SamplePreparationStep`](src/main/java/by/a1/ics60001/steps/SamplePreparationStep.java) | Фильтрует позиции по порогу существенности и формирует выборку документов для проверки. |
| 7 | Обогащение выборки владельцами | [`OwnersEnrichmentStep`](src/main/java/by/a1/ics60001/steps/OwnersEnrichmentStep.java) | Сопоставляет проводки с владельцами (через MIM) и их контактами. |
| 8 | Рассылка заданий исполнителям | [`SendMultitaskNotificationStep`](src/main/java/by/a1/ics60001/steps/SendMultitaskNotificationStep.java) | Формирует email по шаблону `multitask_new` и рассылает задания исполнителям. |
| 9 | Обработка документа | [`document-review.js`](src/main/resources/actions/document-review.js) | Пользовательская форма (Shadow Core Engine): просмотр документа и его позиций, загрузка подтверждающего файла, выбор статуса (`OK`/`NOT OK`), ввод комментария, сохранение результата проверки. |
| 10 | Финализация и публикация результатов | [`FinalizeAndPublishResultsStep`](src/main/java/by/a1/ics60001/steps/FinalizeAndPublishResultsStep.java) | Агрегирует результаты проверки, формирует отчёт (Workbook) и публикует доказательства в SharePoint. |

Вспомогательный класс [`TemplateResultsWorkbookBuilder`](src/main/java/by/a1/ics60001/steps/TemplateResultsWorkbookBuilder.java) строит Excel-отчёт по результатам.

## Схема процесса

BPMN-схема процесса с пулами «Bot» и «Исполнитель» и потоками сообщений (уведомление о старте, задание на редактирование, задание на проверку документа, уведомление об ошибке) находится в [`documentation/ICS-60001.bpmn`](src/main/resources/documentation/ICS-60001.bpmn).

## Конфигурация

### Параметры инициализации

JSON-файл с параметрами запуска процесса (получатели email, email контролёра, дата конца отчёта, уровень существенности, код валюты, параметры SharePoint, код SAP-транзакции, флаг mock-режима, ссылки на экшены, параметры MIM):

- тестовый: [`initparams/test/ics60001_init_params.json`](src/main/resources/initparams/test/ics60001_init_params.json)
- продуктивный: `initparams/prod/` (заполняется при развёртывании)

Ключевые поля (`InitParameters`):
- `reportEndDate` — дата конца отчётного периода. Пусто = последний день прошлого месяца; `yyyy-MM-dd` = дата; целое = смещение в месяцах от текущего (например, `-12`).
- `materialityLevel` + `currencyCode` — уровень существенности и код валюты для расчёта порога по курсу.
- `sapTransactionCode` / `sapMocked` / `testExcelPath` — параметры выгрузки SAP.
- `documentTypePolicyEditorActionLink`, `documentReviewActionLink` — ссылки на пользовательские экшены Sherpa.
- `mim*` — параметры подключения к Microsoft Identity Manager (URL, фильтры XPath, атрибуты, команда PowerShell, таймаут).
- `sharepointBaseUrl` / `sharepointProject` / `sharepointBasePath` — параметры подключения к SharePoint.

### Конфигурация процесса

[`process-config.json`](src/main/resources/process-config.json) задаёт `bpName = "ICS-60001"` и `controlName = "Correctness of manual journal entries"`.

### Шаблоны email-уведомлений

[`ics60001_email_templates.json`](src/main/resources/ics60001_email_templates.json) — FreeMarker-шаблон `multitask_new` (тема и тело письма рассылки заданий исполнителям; поддерживает переменные `processName`, `controlName`, `controllerEmail`, `expireDate`, `expireTime`, `inactiveEmailUsers`, `controllerName`, `mainTable`).

### Справочники типов документов

- [`document_type_classification.json`](src/main/resources/document_type_classification.json) — классификатор типов документов (allowed/denied).
- [`document_type_comments.json`](src/main/resources/document_type_comments.json) — справочник комментариев к типам документов.

## Сервисные переменные (Orchestrator Assets)

| Переменная | Описание |
|---|---|
| `sharepoint_credentials` | Учётные данные для доступа к SharePoint |
| `sap_credentials` | Учётные данные для доступа к SAP |
| `proxy_credentials` | Прокси для внешних соединений |
| `currency_rates_config` | Конфигурация получения курсов валют |
| `mim_credentials` | Учётные данные для MIM (если требуется) |
| `document_type_comments` | Справочник комментариев к типам документов |
| `document_type_classification` | Классификатор типов документов |
| `sherpa_api_credentials` | Ключи доступа к API Sherpa |

## Пользовательские действия (Sherpa Actions)

Реализованы на Shadow Core Engine (`.js`-модули с `ShadowCore.render({...})`):

### Редактор списков типов документов — `actions/document-type-policy-editor.js`
- Просмотр и редактирование allowed/denied списков типов документов;
- Ввод комментариев к каждому типу;
- Включение/отключение типов документов для проверки;
- Сохранение изменений.

### Обработка документа — `actions/document-review.js`
- Просмотр информации о документе и его позициях;
- Загрузка файла подтверждающего документа;
- Выбор статуса (`OK`/`NOT OK`) и ввод комментария;
- Сохранение результата проверки.

## Разделяемое состояние шагов (`ProcessDataKeys`)

`ProcessTransaction` типизирует доступ к данным, хранимым между шагами под ключами `ProcessDataKeys`:
- Расчётные: `exchange.rate`, `resolved.report.end.date`.
- Пути SharePoint: `work.screenshots.folder.path`, `work.input.data.folder.path`, `work.working.folder.path`, `work.other.evidence.folder.path`, `work.technical.archive.filename`.
- Данные проводок: `accounting.document.positions`, `sample.documents`, `sample.owners`, `documents.filtered`, `owners.enriched`.
- Справочники типов документов: `doc.types.white.list`, `doc.types.black.list`, `doc.types.unclassified.list`, `dictionary.list`.
- Связи экшенов: `document.type.lists.editor.action.link`.
- Данные контролёра: `controller.name`, `controller.position`.

## Документация

Дополнительная проектная документация в [`documentation/`](src/main/resources/documentation/):
- `ICS-60001.bpmn` — BPMN-схема процесса;
- `ICS-60001-PDD - Process Design Document.html` — описание процесса (PDD);
- `ICS-60001-UG - User Guide.html` — руководство пользователя;
- `ICS-60001-TD - Test Documentation.html` — тестовая документация;
- `ICS-60001-Step-01..10.html` — описание отдельных шагов;
- `ICS-60001 - Инструкция по развертыванию.html` — инструкция по развёртыванию;
- `ICS-60001 - История изменений.html` — история изменений.

## Сборка и запуск

```bash
# Из корня rpa-suite
./gradlew :ics60001:clean :ics60001:shadowJar
```

Артефакт: `ics60001/build/libs/ics-60001-1.0.0.jar` (fat-jar со всеми зависимостями). Запуск через стандартный entrypoint `by.a1.rpa.core.StepRunnerMain` с JVM-аргументами `-Xmx512m -XX:+UseG1GC`.

Логирование настраивается в [`logback.xml`](src/main/resources/logback.xml).