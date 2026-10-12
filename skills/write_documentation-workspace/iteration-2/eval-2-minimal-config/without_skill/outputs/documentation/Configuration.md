# ICS-00012 — Конфигурация процесса

Документ описывает параметры инициализации `ics00012_init_params.json` (prod/test),
минимальный `process-config.json`, используемые внешние активы (учётные данные) и
плейсхолдеры шаблонов.

## 1. process-config.json

Расположение: `src/main/resources/process-config.json`.

```json
{
  "bpName": "ICS-00012"
}
```

Конфигурация намеренно минимальная — указано только имя бизнес-процесса. Все параметры
выполнения вынесены в `init_parameters`.

## 2. init_parameters/prod/ics00012_init_params.json

```json
{
  "emailRecipients": {
    "to": ["SOX_Workfusion_App_RPA_ICS-00012@a1.by"],
    "cc": ["sc_sg_workfusion@a1.by"]
  },
  "jiraUrl": "jira.a1.by",
  "issueProject": "SOX",
  "issueType": "Task",
  "issueComponent": "Mediation Service",
  "issueAssignee": "SC_SG_Mediation_Service",
  "issueSummary": "ICS-00012 %s",
  "issueDescription": "ALERT: %{count} files at %{directory} is over limit of %{count_limit}.",
  "serverName": "srv-roamtrns-03",
  "fileDirectory": "D:\\Inetpub\\ftproot\\NRTRDE\\NRTRDE_OUT",
  "countLimit": "100",
  "scriptBlock": "(Get-ChildItem '%{directory}' ).Count;"
}
```

## 3. Отличия test-окружения

Файл: `src/main/resources/init_parameters/test/ics00012_init_params.json`.

Отличается только поле `jiraUrl` = `jira-test.a1.by`. Остальные параметры идентичны prod.

## 4. Описание полей

| Поле | Тип | Обяз. | Назначение |
|------|-----|-------|------------|
| `emailRecipients` | объект (`to`: string[], `cc`: string[]) | да | Получатели email-уведомлений о старте/завершении |
| `jiraUrl` | string | да | Хост Jira (для REST API и для построения ссылки `https://<jiraUrl>/browse/<key>`) |
| `issueProject` | string | да | Ключ проекта Jira (`SOX`) |
| `issueType` | string | да | Тип задачи (`Task`) |
| `issueComponent` | string | да | Компонент Jira (`Mediation Service`) |
| `issueAssignee` | string | да | Имя исполнителя/группы для `assignIssue` |
| `issueSummary` | string (шаблон с `%s`) | да | Шаблон summary; `%s` заполняется значением `date.time` через `String.format` |
| `issueDescription` | string (шаблон) | да | Шаблон описания с плейсхолдерами `%{count}`, `%{directory}`, `%{count_limit}` |
| `serverName` | string | да | Имя/хост удалённого Windows-сервера для `Invoke-Command` (WinRM) |
| `fileDirectory` | string | да | Контролируемый каталог; подставляется в `scriptBlock` и в описание тикета |
| `countLimit` | string (десятичное число) | да | Порог количества файлов; сравнение `count >= countLimit` |
| `scriptBlock` | string (PowerShell-блок) | да | Тело `ScriptBlock`; подстановка `%{directory}` → `fileDirectory` |

## 5. Плейсхолдеры

| Плейсхолдер | Где используется | Чем заменяется |
|------------|-----------------|----------------|
| `%{directory}` | `scriptBlock`, `issueDescription` | `initParams.fileDirectory` |
| `%{count}` | `issueDescription` | `scriptResult` (число файлов из PowerShell) |
| `%{count_limit}` | `issueDescription` | `initParams.countLimit` |
| `%s` | `issueSummary` | `date.time` (формат `EEEE MM/dd/yyyy HH:mm`, часовой пояс `Europe/Minsk`) |

## 6. Внешние учётные данные (Orchestrator Storage → Secrets)

| Код актива | Назначение | Поля |
|------------|------------|------|
| `svc_wf_rm_credentials` | Подключение WinRM к `serverName` | `login`, `password` |
| `jira_jsd_credentials` | Доступ к Jira REST API | `login`, `password` |

Получение: `orchestratorService.assets().getCredentials("<код>").execute()`.

## 7. Часовой пояс и формат даты

Жёстко заданы в `ScriptExecutingStep`:
- Формат: `EEEE MM/dd/yyyy HH:mm` (например, `Monday 08/05/2026 14:30`).
- Зона: `Europe/Minsk`.
- Форматирование: `LocalDateTime.now(TimeZone.getTimeZone("Europe/Minsk").toZoneId())`.

## 8. Поведение при превышении порога

- `count >= countLimit` → `is.ticket.needed = true`, в транзакцию пишутся
  `script.result` и `date.time`, далее создаётся тикет.
- `count < countLimit` → `is.ticket.needed = false`, шаг `JiraTicketCreation` пропускается
  (через условие в `.process`), тикет не создаётся, в финальном письме ссылка на тикет
  отсутствует.