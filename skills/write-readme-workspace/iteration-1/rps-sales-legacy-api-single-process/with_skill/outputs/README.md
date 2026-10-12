# RPS-Sales — Сверка продаж 1C и SAP с эскалацией расхождений в Jira

## Описание

Процесс получает выгрузку заказов из 1C по HTTP и отчёт SALES из SAP через SAP GUI
автоматизацию за отчётный период, затем сравнивает заказы по номеру и сумме. При
обнаружении расхождений формирует Excel-отчёт, создаёт issue в Jira Service Desk и
отправляет email-уведомления с вложением; при отсутствии расхождений отправляет
уведомление об успешной сверке.

## Шаги процесса

1. GetOnecReportData [`getOnecReportData`](src/main/java/by/a1/rps_sales/steps/GetOnecReportDataStep.java)
2. PrepareInitialParameters [`prepareInitialParameters`](src/main/java/by/a1/rps_sales/steps/PrepareInitialParametersStep.java)
3. DataProcessing [`dataProcessing`](src/main/java/by/a1/rps_sales/steps/DataProcessingStep.java)
4. GetSapReportData [`getSapReportData`](src/main/java/by/a1/rps_sales/steps/GetSapReportDataStep.java)

## Конфигурация

### Параметры инициализации

- [`rps_sales_init_params`](src/main/resources/rps_sales_init_params.json)

### Шаблоны email-уведомлений

- [`rps_sales_email_templates`](src/main/resources/rps_sales_email_templates.json)

## Сервисные переменные (Service Variables)

| Переменная | Тип | Описание |
|-----------|-----|----------|
| `1c_ct_credentials` | credentials | Учётные данные 1C для выгрузки заказов по HTTP |
| `sap_credentials` | credentials | Учётные данные SAP для входа в SAP GUI сессию |
| `jira_jsd_credentials` | credentials | Доступ к Jira Service Desk для создания issue по расхождениям |
| `sap_settings` | settings | Параметры SAP GUI сессии (systemName, client, language, sapLogonPath) |