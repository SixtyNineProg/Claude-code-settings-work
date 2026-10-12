# ICS-60001 — Проверка корректности ручных бухгалтерских проводок

## Описание

Процесс получает выгрузку SAP по бухгалтерским проводкам за отчётный период,
классифицирует документ-типы через справочник классификации и формирует выборку
документов для проверки. Результаты проверки публикуются в SharePoint, а
контролёрам отправляется multitask-уведомление с задачами на ревью.

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
| `currency_rates_config` | конфигурация | Конфигурация курсов валют для расчётов |
| `document_type_classification` | конфигурация | Справочник классификации документ-типов |
| `document_type_comments` | конфигурация | Комментарии к классификации документ-типов |
| `mim_credentials` | credentials | Учётные данные для подключения к MIM при обогащении владельцев |
| `proxy_credentials` | credentials | Прокси-учётные данные для исходящих запросов |
| `sap_credentials` | credentials | Учётные данные SAP для выгрузки отчёта |
| `sap_settings` | settings | Параметры SAP GUI сессии |
| `sharepoint_credentials` | credentials | Доступ к SharePoint для публикации результатов |
| `sherpa_api_credentials` | credentials | Доступ к API Orchestrator/Sherpa для multitask-уведомлений |