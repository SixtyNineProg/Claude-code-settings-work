# RPS-Sales — Автоматизированная сверка продаж между SAP и 1С

## Описание

Процесс RPS-Sales (бизнес-процесс `RPS-Sales`, см. [`process-config.json`](src/main/resources/process-config.json))
выполняет сверку данных о продажах между системами SAP и 1С за отчётный период, формирует Excel-отчёт с
расхождениями и, при наличии расхождений, автоматически создаёт тикет в Jira (JSD) с прикреплённым отчётом.

Отчётный период — предыдущий календарный месяц относительно даты, переданной в `endDateString`
(формат `ddMMyyyy`), либо относительно текущей даты, если параметр не задан.

## Шаги процесса

1. Подготовка начальных параметров [`PrepareInitialParametersStep`](src/main/java/by/a1/rps_sales/steps/PrepareInitialParametersStep.java)
   - Извлекает `InitParameters` из транзакции и отправляет email-уведомление о старте процесса
     (`EmailService.sendProcessStarted`).
   - Рассчитывает диапазон дат сверки: последний день предыдущего месяца — первый день предыдущего месяца
     относительно `endDateString` (либо `new Date()`, если параметр пустой). Парсинг выполняется строго
     (`setLenient(false)`) по формату `ddMMyyyy`; некорректная строка бросает `IllegalArgumentException`.
   - Сохраняет границы периода в транзакцию через `ProcessTransaction.storeSapStartDate` /
     `storeSapEndDate` (ключи `start.date.millis`, `end.date.millis`).

2. Выгрузка данных из SAP [`GetSapReportDataStep`](src/main/java/by/a1/rps_sales/steps/GetSapReportDataStep.java)
   - Подключается к SAP GUI через `SapGuiAutomation` с настройками из ассета `sap_settings`
     (`SapSettings`: `sapLogonPath`, `systemName`, `client`, `language`), `elementTimeout=60`,
     авто-закрытие copyright-диалога.
   - Авторизуется учётными данными из ассета `sap_credentials`, запускает транзакцию
     `sapTransactionName` (по умолчанию `ZOTCSD_PRCHECK_SUM`), выставляет layout
     `sapReportLayout` (`BF_SALES_1C`) и диапазон дат в формате `ddMMyyyy`, выполняет экспорт
     в Excel (`MB_EXPORT` → `XXL`) во временную директорию.
   - После экспорта завершает процесс `EXCEL.EXE`, парсит файл через Poiji в `SapOrder`
     (`preferNullOverDefault`, sheet 0), фильтрует `null`-записи и записи без `orderNumber`,
     сохраняет список в транзакцию (`sap.orders`) и удаляет временный файл.

3. Выгрузка данных из 1С [`GetOnecReportDataStep`](src/main/java/by/a1/rps_sales/steps/GetOnecReportDataStep.java)
   - Получает учётные данные из ассета `1c_ct_credentials`.
   - Формирует JSON-тело запроса `OnecRequest(dateBegin, dateEnd, dataType)` с датами в формате
     `yyyyMMdd` и отправляет POST-запрос на `onecUrlSpec` с `Authorization: Basic <base64>`.
   - Ответ `OnecReportResponse` содержит `status`, `errorMessage` и `fileBase64` (zip-архив).
     Содержимое архива распаковывается через Apache Commons Compress, JSON парсится в
     `OnecRoot` со списком `OnecOrder`.
   - Сохраняет заказы 1С в транзакцию (`onec.orders`).

4. Обработка и сверка [`DataProcessingStep`](src/main/java/by/a1/rps_sales/steps/DataProcessingStep.java)
   - Сравнивает заказы SAP и 1С (`getNotEqualPairs`): группирует по `orderNumber + materialNumber`,
     для каждой группы строит матрицу совпадений по 4 атрибутам (`quantity`, `finalAmount`,
     `warehouse`, `date`) и подбирает лучшие пары; пары с `originalOrderNumber`-несовпадением,
     `counter != 4` или `!uploaded` попадают в список расхождений.
   - Если расхождений нет — отправляет стандартное уведомление `process_completed`.
   - Если расхождения есть:
     - Формирует Excel-отчёт (`XSSFWorkbook`, лист `Report`, 25 колонок) с подсветкой
       расхождений (`IndexedColors.ROSE`); файл сохраняется во временную директорию с именем
       `<sapDataType>_rep_<dd_MM_yyyy>-<dd_MM_yyyy>.xlsx`.
     - Отправляет email по кастомному шаблону `discrepancies_found` с прикреплённым отчётом.
     - Создаёт тикет в Jira (JSD) с проектом `jsdIssueProject` (`ITSM`), типом `jsdIssueType`
       (`Проблема ПО`), summary/description по шаблонам из `InitParameters`. Если все расхождения
       типа «заказ 1С не выгружен в SAP» — заполняются customfields для 1C
       (`customfield_14007`, `14222`, `14201`), иначе — для SAP (`customfield_14007`, `14221`).
       К созданному тикету прикрепляется файл отчёта.
     - Отправляет `process_completed` со ссылкой `https://<jsdHost>/browse/<issueKey>` в
       параметре `controlResultsLink`.
     - Удаляет временный файл и временную директорию.

## Струкура проекта

```
rps-sales/
├── build.gradle                              # Конфигурация Gradle (shadowJar, application)
├── libs/
│   └── jacob-1.21-x64.dll                     # JNI-библиотека JACOB (COM/SAP GUI Scripting)
├── RPS-Sales.robot / RPS-Sales.sherpa        # Дескрипторы процесса для Sherpa RPA Suite
├── SAP Automation.process / Главная.process  # Диаграммы процессов (Sherpa)
└── src/main/
    ├── java/by/a1/rps_sales/
    │   ├── model/                             # InitParameters, SapOrder, OnecOrder, OnecRequest, OnecRoot,
    │   │                                      #   OnecReportResponse, SapSettings, jsd/* (модели тикета Jira)
    │   ├── steps/                             # Шаги процесса
    │   ├── transaction/                        # ProcessTransaction, ProcessDataKeys
    │   └── ...
    └── resources/
        ├── process-config.json                # bpName = "RPS-Sales"
        ├── rps_sales_init_params.json         # Значения InitParameters по умолчанию
        ├── rps_sales_email_templates.json     # Кастомные email-шаблоны
        ├── logback.xml                        # Конфигурация логирования (logs/rps-sales.log, 30 дней)
        └── ExportXLSX.vbs
```

## Параметры инициализации (`InitParameters`)

Источник значений по умолчанию — [`rps_sales_init_params.json`](src/main/resources/rps_sales_init_params.json).

| Поле | Описание | Значение по умолчанию |
|------|----------|-----------------------|
| `emailRecipients` | Получатели email-уведомлений (`to`, `cc`) | `admin@example.com`, `support@example.com` |
| `onecUrlSpec` | URL HTTP-сервиса 1C для выгрузки отчёта | `http://srv-preprod-01/preprod/hs/ReportService/RPA/SAPDataCheck?TextEncoding=UTF8` |
| `endDateString` | Опорная дата сверки в формате `ddMMyyyy` (пусто = текущая дата) | `""` |
| `sapDataType` | Тип данных сверки (формирует префикс имени файла отчёта) | `sales` |
| `sapTransactionName` | SAP-транзакция сверки | `ZOTCSD_PRCHECK_SUM` |
| `sapReportLayout` | Layout SAP-отчёта | `BF_SALES_1C` |
| `jsdHost` | Базовый URL Jira Service Desk | `https://jsd-test.a1.by` |
| `jsdIssueProject` | Проект JSD для создания тикета | `ITSM` |
| `jsdIssueType` | Тип задачи JSD | `Проблема ПО` |
| `jsdIssueSummary` | Шаблон summary (`%s` = дата сверки) | `Автоматическая сверка продаж %s` |
| `jsdIssueDescription` | Шаблон description (`%s %s` = даты начала и конца) | текст с подстановкой периода |
| `jsdIssueSystem1c` / `jsdIssueSystem1cSales` / `jsdIssueLog1c` | Значения customfields для сценария «1С» | `1с`, `1С Продажи`, `*` |
| `jsdIssueSystem` / `jsdIssueSystemSap` | Значения customfields для сценария «SAP» | `SAP`, `SAP SD (продажи)` |

## Email-шаблоны

[`rps_sales_email_templates.json`](src/main/resources/rps_sales_email_templates.json):

- `discrepancies_found` — письмо с темой и телом «При сверке продаж обнаружены расхождения», прикрепляется
  Excel-отчёт. Использует переменные `processName`/`bpName`, `bpNumber`/`bpDescription`, `currentDate`,
  `controlName`.

Стандартные шаблоны, отправляемые через `EmailService`:
- `sendProcessStarted` — уведомление о старте процесса (шаг 1).
- `sendProcessCompleted` — уведомление о завершении (шаг 4), опционально с параметром
  `controlResultsLink` (ссылка на созданный тикет JSD).

## Внешние учётные данные (Orchestrator Assets)

| Asset | Назначение |
|-------|-----------|
| `sap_settings` | JSON-настройки подключения к SAP GUI (`SapSettings`) |
| `sap_credentials` | Логин/пароль для входа в SAP |
| `1c_ct_credentials` | Логин/пароль для HTTP-сервиса 1C |
| `jira_jsd_credentials` | Логин/пароль для Jira Service Desk API |

## Ключи транзакции (`ProcessDataKeys`)

| Ключ | Тип | Описание |
|------|------|----------|
| `start.date.millis` | `Long` | Дата начала периода сверки (мс) |
| `end.date.millis` | `Long` | Дата окончания периода сверки (мс) |
| `sap.orders` | JSON `List<SapOrder>` | Заказы, выгруженные из SAP |
| `onec.orders` | JSON `List<OnecOrder>` | Заказы, выгруженные из 1С |

## Сборка и запуск

```bash
gradlew :rps-sales:build        # Собирает shadowJar rps-sales-1.0.0.jar
gradlew :rps-sales:run          # Запуск через application-плагин
```

JVM-аргументы по умолчанию: `-Xmx512m -XX:+UseG1GC`. Для запуска требуется
`-Djava.library.path=<projectDir>/libs` (см. `run { jvmArgs = ... }` в `build.gradle`),
чтобы JACOB мог загрузить `jacob-1.21-x64.dll`.

Запуск в Sherpa RPA Suite выполняется через `by.a1.rpa.core.StepRunnerMain`
(см. `application.mainClass`), дескрипторы процесса — `RPS-Sales.sherpa`,
`Главная.process` (главная диаграмма), `SAP Automation.process` (диаграмма SAP-автоматизации).

## Зависимости

- `rpa-core` — ядро RPA-фреймворка (`Step`, `Transaction`, `OrchestratorService`, `EmailService`,
  `Jira`, `SapGuiAutomation`).
- `jacob.jar` + `jacob-1.21-x64.dll` — COM-автоматизация SAP GUI Scripting.
- `com.github.ozlerhakan:poiji` — парсинг Excel в POJO.
- `com.profesorfalken:jPowerShell` — вспомогательные PowerShell-вызовы.
- `com.squareup.okhttp3:okhttp` / `logging-interceptor` — HTTP-клиент.
- Apache POI, Apache Commons Compress, Gson, Lombok.