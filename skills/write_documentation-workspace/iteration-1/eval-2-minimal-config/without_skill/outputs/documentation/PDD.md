# PDD — ICS-00012. Мониторинг каталога и создание тикета в Jira

| Поле | Значение |
|------|----------|
| Идентификатор процесса | ICS-00012 |
| `bpName` (process-config.json) | `ICS-00012` |
| Версия PDD | 1.0 |
| Дата | 2026-08-05 |
| Платформа | Sherpa RPA Suite (`rpa-suite`, модуль `rpa-core`) |
| Язык реализации | Java 21 (Gradle, `application` + `shadow`) |
| Точка входа | `by.a1.rpa.core.StepRunnerMain` (из `rpa-core`) |
| Артефакт сборки | `ics00012-1.0.0.jar` (shadowJar) |
| Тип процесса | Плановый/разовый запуск, 4 шага, линейный поток |

---

## 1. Назначение и контекст

Процесс контролирует переполнение заданного сетевого каталога на удалённом Windows-сервере и
автоматически создаёт инцидент в Jira, если количество файлов в каталоге достигает порога.

**Бизнес-сценарий.** На сервере `srv-roamtrns-03` в каталоге `D:\Inetpub\ftproot\NRTRDE\NRTRDE_OUT`
накапливаются файлы NRTRDE. Превышение количества файлов сверх лимита (по умолчанию `100`)
сигнализирует о задержке обработки/переполнении исходящего каталога и требует вмешательства
группы поддержки Mediation Service. Процесс:

1. Уведомляет ответственных о старте контроля.
2. Подсчитывает файлы в каталоге через PowerShell (`Invoke-Command` через WinRM).
3. При `count >= countLimit` создаёт задачу в проекте Jira `SOX` и назначает исполнителя.
4. Уведомляет ответственных о завершении, прикладывая ссылку на созданный тикет.

**Владелец процесса:** SOX / Mediation Service.
**Получатели уведомлений:** `SOX_Workfusion_App_RPA_ICS-00012@a1.by` (To), `sc_sg_workfusion@a1.by` (CC).

---

## 2. Границы процесса

### Входы

| Вход | Источник | Способ получения |
|------|----------|-----------------|
| Параметры инициализации (`init_parameters/{env}/ics00012_init_params.json`) | Ресурсы процесса | Загружаются в `Transaction` на старте движком `rpa-core` |
| Учётные данные WinRM | Orchestrator Storage, актив `svc_wf_rm_credentials` | `orchestratorService.assets().getCredentials("svc_wf_rm_credentials")` |
| Учётные данные Jira/JSD | Orchestrator Storage, актив `jira_jsd_credentials` | `orchestratorService.assets().getCredentials("jira_jsd_credentials")` |

### Выходы

| Выход | Получатель | Канал |
|-------|------------|-------|
| Email «Процесс запущен» | `emailRecipients.to` / `.cc` | SMTP (`EmailService.sendProcessStarted`) |
| Задача в Jira (`SOX` / `Task` / `Mediation Service`) | Проект Jira, исполнитель `SC_SG_Mediation_Service` | Jira REST API (`JiraJsdUtils.createIssue` + `assignIssue`) |
| Email «Процесс завершён» (со ссылкой на тикет при наличии) | `emailRecipients.to` / `.cc` | SMTP (`EmailService.sendProcessCompleted`) |

### Вне границ процесса

- Физическая очистка/перемещение файлов в каталоге не выполняется.
- Закрытие, эскалация или повторное открытие созданного тикета не выполняются.
- Изменение порога `countLimit` и списка получателей — через конфигурацию, а не в коде.

---

## 3. Поток процесса (диаграмма)

```
        ┌──────────────────────┐
        │  StartNotification   │   email «процесс запущен»
        └──────────┬───────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │   ScriptExecuting     │   PowerShell: (Get-ChildItem '%{directory}').Count
        │  count >= countLimit? │
        └──────────┬───────────┘
                   │
        ┌──────────┴──────────┐
        │ yes                 │ no
        ▼                     ▼
┌────────────────────┐   (isTicketNeeded=false)
│ JiraTicketCreation │
│   create + assign  │
└─────────┬──────────┘
          │
          ▼
        ┌──────────────────────┐
        │   EndNotification    │   email «процесс завершён» (+ ссылка на тикет)
        └──────────────────────┘
```

Поток линейный, без ветвления на уровне оркестрации: шаг `JiraTicketCreation` выполняется
всегда, но внутри себя ничего не создаёт при `isTicketNeeded = false` (значение флага
сохраняется в транзакции шагом `ScriptExecuting`). См. раздел 6 про условие выполнения.

---

## 4. Описание шагов

| # | Имя шага (`@StepName`) | Класс | Ответственность |
|---|------------------------|-------|----------------|
| 1 | `startNotification` | `StartNotificationStep` | Отправка email о старте процесса |
| 2 | `scriptExecuting` | `ScriptExecutingStep` | Подсчёт файлов, сравнение с порогом, фиксация даты/времени |
| 3 | `jiraTicketCreation` | `JiraTicketCreationStep` | Создание и назначение тикета Jira при превышении порога |
| 4 | `endNotification` | `EndNotificationStep` | Отправка email о завершении со ссылкой на тикет |

### 4.1. StartNotificationStep

- **Вход:** `InitParameters.emailRecipients` из транзакции.
- **Действие:** вызывает `EmailService.sendProcessStarted(emailRecipients)`.
- **Выход:** email-уведомление «процесс запущен».
- **Внешние зависимости:** `EmailService` (из `rpa-core`). `OrchestratorService` внедрён, но не используется.
- **Ошибки:** исключения из `EmailService` пробрасываются наверх (становятся ошибкой шага).

### 4.2. ScriptExecutingStep

- **Вход:** `InitParameters` (`serverName`, `fileDirectory`, `countLimit`, `scriptBlock`); актив `svc_wf_rm_credentials` (login/password).
- **Действие:**
  1. Получает учётные данные WinRM из Orchestrator Storage.
  2. Формирует тело скрипта: `scriptBlock.replace("%{directory}", fileDirectory)`.
  3. Создаёт `PowershellService`, который выполняет
     `Invoke-Command -ComputerName <serverName> -Credential <cred> -ScriptBlock { <scriptBlock> }`
     локально через `powershell.exe`.
  4. Ожидает ответ размером ровно `NORMAL_SCRIPT_RESPONSE_SIZE = 1` строка, без stderr.
  5. Парсит первую строку ответа как `int count`.
  6. Сравнивает `count` с `countLimit` (int, `>=`).
  7. При превышении: сохраняет в транзакцию `isTicketNeeded=true`, `scriptResult=count`,
     `date.time` = текущее время в зоне `Europe/Minsk`, формат `EEEE MM/dd/yyyy HH:mm`.
     Иначе: `isTicketNeeded=false`.
- **Выход:** ключи транзакции `IS_TICKET_NEEDED`, `SCRIPT_RESULT`, `DATE_TIME`.
- **Ошибки:** `BusinessException` при пустом ответе, неверном формате числа, ошибке выполнения
  PowerShell (exit code != 0) или нарушении ожидаемого размера ответа.

### 4.3. JiraTicketCreationStep

- **Условие выполнения:** шаг выполняется всегда, но при `isTicketNeeded=false` фактически
  ничего не создаёт — чтение `getScriptResult()` в этом случае не выполняется, потому что
  шаг на уровне оркестрации пропускается (см. раздел 6). При `isTicketNeeded=true`:
- **Вход:** `InitParameters` (`jiraUrl`, `issueProject`, `issueType`, `issueComponent`,
  `issueAssignee`, `issueSummary`, `issueDescription`, `fileDirectory`, `countLimit`);
  актив `jira_jsd_credentials`; `scriptResult` и `date.time` из транзакции.
- **Действие:**
  1. Получает учётные данные Jira из Orchestrator Storage.
  2. Строит `JiraJsdUtils(login, password, jiraUrl)`.
  3. Формирует описание подстановкой `%{count}`, `%{directory}`, `%{count_limit}` в шаблон
     `issueDescription`.
  4. Формирует summary как `String.format(issueSummary, dateTime)` (например,
     `ICS-00012 <EEEE MM/dd/yyyy HH:mm>`).
  5. Строит `Issue` с project, issueType, summary, description, одним компонентом
     `Mediation Service` и customfield_18311 = компонент с именем исполнителя.
  6. `createIssue(issue)` → `key`, затем `assignIssue(key, issueAssignee)`.
  7. Сохраняет `ticket.id` в транзакцию.
- **Выход:** `ticket.id` в транзакции; задача в Jira.
- **Ошибки:** `IllegalStateException`, если `issueId` пустой; исключения из `JiraJsdUtils`.

### 4.4. EndNotificationStep

- **Вход:** `InitParameters.emailRecipients`, `InitParameters.jiraUrl`, `ticket.id` из транзакции (опционально).
- **Действие:**
  - Если `ticketId != null` — формирует ссылку `https://<jiraUrl>/browse/<ticketId>` и
    вызывает `EmailService.sendProcessCompleted(Map.of("controlResultsLink", link), recipients)`.
  - Иначе — `sendProcessCompleted(recipients)` без доп. параметров.
- **Выход:** email-уведомление «процесс завершён».
- **Ошибки:** пробрасываются из `EmailService`.

---

## 5. Модель данных транзакции

Ключи определены в `by.a1.ics00012.transaction.ProcessDataKeys`.

| Ключ | Тип | Кто пишет | Кто читает | Назначение |
|------|-----|-----------|------------|------------|
| `is.ticket.needed` | `Boolean` | `ScriptExecutingStep` | Логика пропуска `JiraTicketCreationStep` | Флаг «превышен порог» |
| `script.result` | `Integer` | `ScriptExecutingStep` | `JiraTicketCreationStep` | Количество файлов в каталоге |
| `date.time` | `String` (`EEEE MM/dd/yyyy HH:mm`, Европа/Минск) | `ScriptExecutingStep` | `JiraTicketCreationStep` | Метка времени для summary тикета |
| `ticket.id` | `String` | `JiraTicketCreationStep` | `EndNotificationStep` | Ключ созданного тикета Jira |

Обёртка `ProcessTransaction` делегирует чтение/запись в `Transaction` (из `rpa-core`) и
выбрасывает `IllegalStateException`, если обязательный ключ отсутствует.

### 5.1. InitParameters

`by.a1.ics00012.model.InitParameters` — DTO, заполняется из JSON-параметров инициализации.
Поля: `emailRecipients` (`EmailRecipients` из `rpa-core`), `jiraUrl`, `issueProject`,
`issueType`, `issueComponent`, `issueAssignee`, `issueSummary`, `issueDescription`,
`serverName`, `fileDirectory`, `countLimit`, `scriptBlock`.

---

## 6. Оркестрация и конфигурация

### 6.1. process-config.json

```json
{
  "bpName": "ICS-00012"
}
```

Минимальная конфигурация: указано только имя бизнес-процесса (`bpName`). Все параметры
выполнения вынесены в `init_parameters/{env}/ics00012_init_params.json`. Последовательность
шагов и их идентификаторы задаются в файле `.process` (Sherpa) — `Главная.process` и
`ICS00012.sherpa`/`.sherpax` в корне модуля.

### 6.2. Идентификаторы шагов в коде

| Имя в `.process` | `@StepName` | Класс |
|------------------|------------|-------|
| StartNotification | `startNotification` | `StartNotificationStep` |
| ScriptExecuting | `scriptExecuting` | `ScriptExecutingStep` |
| JiraTicketCreation | `jiraTicketCreation` | `JiraTicketCreationStep` |
| EndNotification | `endNotification` | `EndNotificationStep` |

### 6.3. Условие выполнения JiraTicketCreation

Решение о создании тикета принимается внутри `ScriptExecutingStep` и сохраняется в
`IS_TICKET_NEEDED`. Шаг `JiraTicketCreationStep` должен быть сконфигурирован в `.process`
с условием выполнения по флагу `is.ticket.needed = true` (стандартный механизм условий
`rpa-core`). При `false` шаг пропускается, и `ticket.id` не записывается; `EndNotification`
корректно обрабатывает отсутствие тикета.

---

## 7. Внешние учётные данные (Orchestrator Storage)

| Актив (Secrets) | Назначение | Используется в |
|------------------|------------|----------------|
| `svc_wf_rm_credentials` | Логин/пароль для WinRM на `srv-roamtrns-03` | `ScriptExecutingStep` |
| `jira_jsd_credentials` | Логин/пароль для Jira/JSD API | `JiraTicketCreationStep` |

---

## 8. Параметры инициализации

Файлы: `src/main/resources/init_parameters/{prod,test}/ics00012_init_params.json`.

| Поле | Пример (prod) | Описание |
|------|---------------|----------|
| `emailRecipients.to` | `SOX_Workfusion_App_RPA_ICS-00012@a1.by` | Получатели «To» |
| `emailRecipients.cc` | `sc_sg_workfusion@a1.by` | Получатели «CC» |
| `jiraUrl` | `jira.a1.by` (prod) / `jira-test.a1.by` (test) | Хост Jira для API и ссылки |
| `issueProject` | `SOX` | Ключ проекта Jira |
| `issueType` | `Task` | Тип задачи |
| `issueComponent` | `Mediation Service` | Компонент Jira |
| `issueAssignee` | `SC_SG_Mediation_Service` | Исполнитель (assignee) |
| `issueSummary` | `ICS-00012 %s` | Шаблон summary (`%s` — дата/время) |
| `issueDescription` | `ALERT: %{count} files at %{directory} is over limit of %{count_limit}.` | Шаблон описания |
| `serverName` | `srv-roamtrns-03` | Целевой Windows-сервер (WinRM) |
| `fileDirectory` | `D:\Inetpub\ftproot\NRTRDE\NRTRDE_OUT` | Контролируемый каталог |
| `countLimit` | `100` | Порог количества файлов |
| `scriptBlock` | `(Get-ChildItem '%{directory}' ).Count;` | PowerShell-блок; `%{directory}` заменяется на `fileDirectory` |

Плейсхолдеры:
- `%{directory}`, `%{count}`, `%{count_limit}` — в `issueDescription`.
- `%s` — в `issueSummary` (через `String.format`, аргумент — `date.time`).
- `%{directory}` — в `scriptBlock` (заменяется на `fileDirectory`).

---

## 9. Сборка и запуск

Сборка: `gradle :ics00012:build` → `ics00012-1.0.0.jar` (shadowJar, без классификатора).
JVM: Java 21, `-Xmx512m -XX:+UseG1GC`.
Точка входа (`application.mainClass`): `by.a1.rpa.core.StepRunnerMain`.

Логирование: `src/main/resources/logback.xml` (из модуля).

---

## 10. Обработка ошибок и исключения

| Ситуация | Реакция |
|----------|---------|
| Нет `InitParameters` в транзакции | `IllegalStateException` (из `ProcessTransaction.getInitParameters`) |
| PowerShell: exit code != 0 | `BusinessException("Execution error; exitValue = ...")` |
| PowerShell: stderr не пуст или размер ответа != 1 | `PowershellService.exec()` возвращает `false` → `BusinessException("Execution error")` |
| Ответ PowerShell не парсится как `int` | `BusinessException("Incorrect response format: ...")` |
| `createIssue` вернул пустой ключ | `IllegalStateException("Issue id is null or empty")` |
| Нет `script.result`/`date.time` при создании тикета | `IllegalStateException` (из `ProcessTransaction`) |

Все бизнес-исключения — `by.a1.rpa.core.exception.BusinessException`. Проброс до движка
`rpa-core` приводит к падению процесса; повторные попытки и компенсация не реализованы
(процесс однопроходный).

---

## 11. Риски и допущения

- PowerShell-скрипт выполняется локально (на RPA-воркере) через `powershell.exe`; удалённое
  подключение к `srv-roamtrns-03` выполняет сам `Invoke-Command`. Требуется сетевая
  доступность WinRM (5985/5986) и права учётной записи `svc_wf_rm_credentials`.
- Сравнение `count >= countLimit` — нестрогое; точное равенство порога уже создаёт тикет.
- Часовой пояс формирования `date.time` захардкожен — `Europe/Minsk`.
- `customfield_18311` используется как компонент-исполнитель; семантика поля должна
  поддерживаться целевым проектом Jira `SOX`.
- Процесс не выполняет очистку каталога и не закрывает тикет — только оповещение.

---

## 12. Ссылки на исходные файлы

- `C:/Users/dzmitry_klim/IdeaProjects/sherpa/rpa-suite/ics00012/README.md`
- `C:/Users/dzmitry_klim/IdeaProjects/sherpa/rpa-suite/ics00012/build.gradle`
- `C:/Users/dzmitry_klim/IdeaProjects/sherpa/rpa-suite/ics00012/src/main/resources/process-config.json`
- `C:/Users/dzmitry_klim/IdeaProjects/sherpa/rpa-suite/ics00012/src/main/resources/init_parameters/prod/ics00012_init_params.json`
- `C:/Users/dzmitry_klim/IdeaProjects/sherpa/rpa-suite/ics00012/src/main/java/by/a1/ics00012/model/InitParameters.java`
- `C:/Users/dzmitry_klim/IdeaProjects/sherpa/rpa-suite/ics00012/src/main/java/by/a1/ics00012/service/PowershellService.java`
- `C:/Users/dzmitry_klim/IdeaProjects/sherpa/rpa-suite/ics00012/src/main/java/by/a1/ics00012/transaction/ProcessDataKeys.java`
- `C:/Users/dzmitry_klim/IdeaProjects/sherpa/rpa-suite/ics00012/src/main/java/by/a1/ics00012/transaction/ProcessTransaction.java`
- `C:/Users/dzmitry_klim/IdeaProjects/sherpa/rpa-suite/ics00012/src/main/java/by/a1/ics00012/steps/StartNotificationStep.java`
- `C:/Users/dzmitry_klim/IdeaProjects/sherpa/rpa-suite/ics00012/src/main/java/by/a1/ics00012/steps/ScriptExecutingStep.java`
- `C:/Users/dzmitry_klim/IdeaProjects/sherpa/rpa-suite/ics00012/src/main/java/by/a1/ics00012/steps/JiraTicketCreationStep.java`
- `C:/Users/dzmitry_klim/IdeaProjects/sherpa/rpa-suite/ics00012/src/main/java/by/a1/ics00012/steps/EndNotificationStep.java`