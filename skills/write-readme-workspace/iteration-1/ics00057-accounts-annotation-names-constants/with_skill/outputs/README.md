# ICS-00057 — Обновление справочника счетов

## Описание

Процесс получает выгрузку счетов из SAP за отчётный период, сравнивает её с
сохранённым чек-листом и формирует наборы новых и изменённых счетов для
ручной проверки через multitask-задачи Orchestrator. Результаты проверки
финализируются, а доказательства (чек-лист и архив) публикуются в SharePoint
и хранилище Orchestrator Storage с плоскими уникальными именами.

## Шаги процесса

1. InfrastructureStep [`InfrastructureStep`](src/main/java/by/a1/ics00057_accounts/steps/InfrastructureStep.java)
2. SapStep [`SapStep`](src/main/java/by/a1/ics00057_accounts/steps/SapStep.java)
3. PrepareNewStep [`PrepareNewStep`](src/main/java/by/a1/ics00057_accounts/steps/PrepareNewStep.java)
4. SaveNewStep [`SaveNewStep`](src/main/java/by/a1/ics00057_accounts/steps/SaveNewStep.java)
5. PrepareChangedStep [`PrepareChangedStep`](src/main/java/by/a1/ics00057_accounts/steps/PrepareChangedStep.java)
6. SaveChangedStep [`SaveChangedStep`](src/main/java/by/a1/ics00057_accounts/steps/SaveChangedStep.java)
7. PrepareAllStep [`PrepareAllStep`](src/main/java/by/a1/ics00057_accounts/steps/PrepareAllStep.java)
8. SaveAllStep [`SaveAllStep`](src/main/java/by/a1/ics00057_accounts/steps/SaveAllStep.java)
9. UploadEvidenceStep [`UploadEvidenceStep`](src/main/java/by/a1/ics00057_accounts/steps/UploadEvidenceStep.java)

## Конфигурация

### Параметры инициализации

- [`ics00057_accounts_init_params` (prod)](src/main/resources/init_params/prod/ics00057_accounts_init_params.json)
- [`ics00057_accounts_init_params` (test)](src/main/resources/init_params/test/ics00057_accounts_init_params.json)

### Шаблоны email-уведомлений

- [`ics00057_accounts_email_templates`](src/main/resources/ics00057_accounts_email_templates.json)

## Сервисные переменные (Service Variables)

| Переменная | Тип | Описание |
|-----------|-----|----------|
| `sap_credentials` | credentials | Учётные данные SAP для выгрузки счетов за отчётный период |
| `sap_settings` | settings | Параметры SAP-сессии (GUI/экспорт), используемые при выгрузке |
| `sharepoint_credentials` | credentials | Доступ к SharePoint для публикации доказательств и чек-листа |
| `sherpa_api_credentials` | credentials | Доступ к API Orchestrator/Sherpa для создания multitask-задач |