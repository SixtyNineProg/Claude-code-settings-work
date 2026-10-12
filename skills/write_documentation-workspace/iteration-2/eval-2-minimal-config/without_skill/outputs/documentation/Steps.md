# ICS-00012 — Спецификация шагов и поток данных

Детальное описание каждого шага, его контракта (вход/выход) и передачи данных через
транзакцию. Имена шагов соответствуют аннотации `@StepName` и файлу `.process`.

## Общая последовательность

```
StartNotification -> ScriptExecuting -> [JiraTicketCreation] -> EndNotification
```

`JiraTicketCreation` выполняется только при `is.ticket.needed = true` (условие в `.process`).

## 1. StartNotificationStep

- `@StepName("startNotification")`
- Класс: `by.a1.ics00012.steps.StartNotificationStep`
- Внедряемые зависимости: `EmailService`, `OrchestratorService` (не используется).

### Контракт

| Направление | Данные | Источник/Приёмник |
|-------------|--------|-------------------|
| Читает | `InitParameters.emailRecipients` | `Transaction` |
| Действие | `EmailService.sendProcessStarted(emailRecipients)` | SMTP |
| Пишет | — | — |

### Исключения
Пробрасываются исключения из `EmailService` (становятся ошибкой шага).

## 2. ScriptExecutingStep

- `@StepName("scriptExecuting")`
- Класс: `by.a1.ics00012.steps.ScriptExecutingStep`
- Внедряемые зависимости: `OrchestratorService`.
- Константы: `DATE_TIME_FORMAT = "EEEE MM/dd/yyyy HH:mm"`,
  `NORMAL_SCRIPT_RESPONSE_SIZE = 1`.

### Контракт

| Направление | Данные | Источник/Приёмник |
|-------------|--------|-------------------|
| Читает | `InitParameters` (`serverName`, `fileDirectory`, `countLimit`, `scriptBlock`) | `Transaction` |
| Читает | Учётные данные `svc_wf_rm_credentials` | Orchestrator Storage |
| Пишет | `is.ticket.needed` (Boolean) | `Transaction` |
| Пишет (при `isTicketNeeded=true`) | `script.result` (Integer), `date.time` (String) | `Transaction` |

### Алгоритм

1. `wfRmCreds = orchestratorService.assets().getCredentials("svc_wf_rm_credentials").execute()`.
2. `scriptBody = scriptBlock.replace("%{directory}", fileDirectory)`.
3. `PowershellService.exec()` формирует команду:
   ```powershell
   [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
   $pwd = ConvertTo-SecureString '<password>' -asplaintext -force
   $cred = New-Object System.Management.Automation.PSCredential ('<login>', $pwd)
   Invoke-Command -ComputerName '<serverName>' -Credential $cred -ScriptBlock {
     (Get-ChildItem '<fileDirectory>' ).Count;
   }
   ```
4. Успех = exit code 0 AND stderr пуст AND `response.size() == 1`.
5. `count = Integer.parseInt(response.get(0))`.
6. `count >= Integer.parseInt(countLimit)` → флаг `true` + запись `script.result` и `date.time`.

### Исключения
- `BusinessException("Response is empty")` — пустой ответ.
- `BusinessException("Incorrect response format: ...")` — нечисловой ответ.
- `BusinessException("Execution error")` — `PowershellService.exec()` вернул `false`.
- `BusinessException("Execution error; exitValue = ...")` — ненулевой exit code процесса.
- `BusinessException("Error during script executing", e)` — обёртка любых прочих ошибок.

## 3. JiraTicketCreationStep

- `@StepName("jiraTicketCreation")`
- Класс: `by.a1.ics00012.steps.JiraTicketCreationStep`
- Внедряемые зависимости: `OrchestratorService`.
- Условие выполнения: `is.ticket.needed = true` (в `.process`).

### Контракт

| Направление | Данные | Источник/Приёмник |
|-------------|--------|-------------------|
| Читает | `InitParameters` (`jiraUrl`, `issueProject`, `issueType`, `issueComponent`, `issueAssignee`, `issueSummary`, `issueDescription`, `fileDirectory`, `countLimit`) | `Transaction` |
| Читает | `script.result` (Integer), `date.time` (String) | `Transaction` |
| Читает | Учётные данные `jira_jsd_credentials` | Orchestrator Storage |
| Пишет | `ticket.id` (String) | `Transaction` |
| Внешнее действие | `JiraJsdUtils.createIssue(issue)` + `assignIssue(key, assignee)` | Jira REST API |

### Формирование Issue

- `description = issueDescription`
  `.replace("%{count}", scriptResult.toString())`
  `.replace("%{directory}", fileDirectory)`
  `.replace("%{count_limit}", countLimit)`.
- `summary = String.format(issueSummary, dateTime)` → например `ICS-00012 Monday 08/05/2026 14:30`.
- `components = [Component{name = "Mediation Service"}]`.
- `customField("customfield_18311", Component{name = issueAssignee})`.
- `Issue.builder().project(issueProject).issueType(issueType).summary(summary)
   .description(description).components(...).customField(...).build()`.

### Исключения
- `IllegalStateException("Issue id is null or empty")` — пустой ключ созданного тикета.
- Пробрасываются ошибки `JiraJsdUtils` (аутентификация, сеть, REST API).
- `IllegalStateException` из `ProcessTransaction`, если отсутствуют `script.result`/`date.time`.

## 4. EndNotificationStep

- `@StepName("endNotification")`
- Класс: `by.a1.ics00012.steps.EndNotificationStep`
- Внедряемые зависимости: `EmailService`, `OrchestratorService` (не используется).

### Контракт

| Направление | Данные | Источник/Приёмник |
|-------------|--------|-------------------|
| Читает | `InitParameters.emailRecipients`, `InitParameters.jiraUrl` | `Transaction` |
| Читает | `ticket.id` (String, опционально) | `Transaction` |
| Действие | `EmailService.sendProcessCompleted(...)` | SMTP |

### Поведение
- Если `ticketId != null`:
  `link = https://<jiraUrl>/browse/<ticketId>`,
  `sendProcessCompleted(Map.of("controlResultsLink", link), recipients)`.
- Иначе:
  `sendProcessCompleted(recipients)` без параметров.

### Исключения
Пробрасываются исключения из `EmailService`.

## 5. Ключи транзакции (`ProcessDataKeys`)

| Константа | Значение | Тип значения |
|-----------|----------|--------------|
| `TICKET_ID` | `ticket.id` | `String` (опц.) |
| `SCRIPT_RESULT` | `script.result` | `Integer` (обяз. при `isTicketNeeded=true`) |
| `IS_TICKET_NEEDED` | `is.ticket.needed` | `Boolean` |
| `DATE_TIME` | `date.time` | `String` (обяз. при `isTicketNeeded=true`) |

## 6. Сводный поток данных

```
InitParameters (JSON) ───────────────► Transaction
                                          │
                       ┌──────────────────┼──────────────────┐
                       ▼                  ▼                  ▼
              StartNotification  ScriptExecuting   JiraTicketCreation
                       │                  │                  │
                       │           writes IS_TICKET_NEEDED    │ reads script.result, date.time
                       │           writes SCRIPT_RESULT       │ writes ticket.id
                       │           writes DATE_TIME           │
                       │                  │                  │
                       └──────────────────┴──────────────────┘
                                          │
                                          ▼
                                  EndNotification
                                   reads ticket.id
```

## 7. Уровень логирования

- `StartNotificationStep`: `@Slf4j`, без явных log-вызовов в коде.
- `ScriptExecutingStep`: `log.info` — получение скрипта, тело скрипта, `currentDateTime`;
  `log.debug` — `count`, `countLimit`, размер ответа.
- `JiraTicketCreationStep`: `log.info` — «Creating ticket...», `Created issue id = ...`.
- `PowershellService`: `log.info` — error/response списки; `log.debug` — «Try to execute script».
- `ProcessTransaction`: `log.error` — при отсутствии обязательных ключей в транзакции.

Конфигурация логирования: `src/main/resources/logback.xml`.