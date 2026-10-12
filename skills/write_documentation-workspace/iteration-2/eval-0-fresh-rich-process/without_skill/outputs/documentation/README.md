# ICS-00057 «Обновление справочника» — документация

Документация RPA-процесса **ICS-00057 «Обновление справочника»** (BP `01`, контроль «Document Verification Accounting»).
Процесс является первым шагом контроля ICS-00057 и обеспечивает актуализацию справочника счетов, релевантных для контроля, с использованием SAP GUI, SharePoint, Email и Orchestrator.

## Состав документации

| Документ | Назначение |
|---|---|
| [01-Overview.md](01-Overview.md) | Краткий обзор процесса, архитектура, окружение, ключевые сущности |
| [02-PDD.md](02-PDD.md) | Process Design Document — детальное описание логики, потоков, шагов, данных |
| [03-User-Guide.md](03-User-Guide.md) | Руководство пользователя: роли, запуск, ручные задачи (MT), работа с письмами |
| [04-Test-Documentation.md](04-Test-Documentation.md) | Тестовая документация: стратегия, сценарии, тестовые данные, coverage |
| [05-Deployment.md](05-Deployment.md) | Инструкция по развёртыванию: сборка, ассеты, триггеры, конфигурация сред |
| [06-Change-History.md](06-Change-History.md) | История изменений процесса по коммитам |
| [steps/](steps/) | Постраничное описание каждого из 9 шагов процесса |

## Шаги процесса (9 шагов, 4 стадии)

| № | Шаг | Стадия | Назначение |
|---|---|---|---|
| 1 | [InfrastructureStep](steps/Step-01-InfrastructureStep.md) | Stage1 | Подготовка инфраструктуры, расчёт отчётного периода, email о старте |
| 2 | [SapStep](steps/Step-02-SapStep.md) | Stage1 | Выгрузка счетов из SAP (ZACCOUNTS), скриншоты, загрузка в Orchestrator Storage |
| 3 | [PrepareNewStep](steps/Step-03-PrepareNewStep.md) | Stage1 | Определение новых счетов, создание MT №1 «Проверка новых счетов» |
| 4 | [SaveNewStep](steps/Step-04-SaveNewStep.md) | Stage2 | Receiver MT №1, сохранение результата, обновление справочника |
| 5 | [PrepareChangedStep](steps/Step-05-PrepareChangedStep.md) | Stage2 | Определение счетов с изменившимися метками, создание MT №2 |
| 6 | [SaveChangedStep](steps/Step-06-SaveChangedStep.md) | Stage3 | Receiver MT №2, сохранение результата, обновление справочника |
| 7 | [PrepareAllStep](steps/Step-07-PrepareAllStep.md) | Stage3 | Подготовка полного справочника, создание MT №3 «Внесение изменений по счетам» |
| 8 | [SaveAllStep](steps/Step-08-SaveAllStep.md) | Stage4 | Receiver MT №3, сохранение корректировок |
| 9 | [UploadEvidenceStep](steps/Step-09-UploadEvidenceStep.md) | Stage4 | Чек-лист, технический архив, выгрузка в SharePoint и Storage, финальное письмо |

## Внешние системы

- **SAP GUI** — транзакция `ZACCOUNTS` (план счетов `IFRS`, БЕ `1320`), выгрузка ALV-отчёта в Excel + скриншоты.
- **SharePoint** — `vactpro.main.velcom.by`, проект `Project_928` (prod) / `Project_1776` (test), хранение доказательств по унифицированной структуре папок.
- **Email** — SMTP через `rpa-core EmailService`, FreeMarker-шаблоны в `ics00057_accounts_email_templates.json`.
- **Orchestrator** — очередь `ICS-00057 Обновление справочника`, ассеты, Storage, Task Queue-триггеры по тегам.

## Связанные ресурсы репозитория

- Исходники: `src/main/java/by/a1/ics00057_accounts/`
- Конфигурация: `src/main/resources/process-config.json`, `init_params/{prod,test}/`
- Email-шаблоны: `src/main/resources/ics00057_accounts_email_templates.json`
- MT-формы (Shadow Core Engine): `src/main/resources/actions/process_{new,changed,all}.js`
- SAP-мок: `src/main/resources/sap_mock/`
- Чек-лист-шаблон: `src/main/resources/excel_template/ICS-00057_01_template.xlsx`
- Sherpa-проект: `ICS-00057 Обновление справочника.sherpa`, `Stage{1..4}.process`, `Главная.process`

> Замечание. Документация сгенерирована на основе исходного кода, конфигураций и истории коммитов репозитория `rpa-suite/ics00057-accounts`. Источник истины — код; при расхождениях актуальным считается именно он.