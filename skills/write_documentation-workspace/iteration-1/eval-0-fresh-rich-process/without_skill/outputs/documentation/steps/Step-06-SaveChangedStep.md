# Шаг 6 — SaveChangedStep

| Поле | Значение |
|---|---|
| Класс | `by.a1.ics00057_accounts.steps.SaveChangedStep` |
| `@StepName` | `SaveChangedStep` |
| Стадия | Stage3 (receiver MT №2) |
| Зависимости | `EmailService`, `OrchestratorService` (Guice) |
| Источник | `src/main/java/by/a1/ics00057_accounts/steps/SaveChangedStep.java` |

## Назначение

Receiver-шаг MT №2 «Проверка изменения меток счетов». Запускается Orchestrator-триггером по тегу `reviewedChanged`. Находит в очереди MT №2 (`name=processChanged`, final-тег `reviewedChanged`, статус `IN_PROGRESS`), разбирает `initialData` → `ProcessChangedResult` → `processedAccounts`, обновляет `checklist_accounts` и `mt_comments`, финализирует задачу (`SUCCESS` + `processedChanged`) в любой ветке.

## Вход

- MT-задача №2 из очереди
- `workflow_status` из транзакции
- `checklist_accounts` и `mt_comments` из транзакции

## Выход (в `ProcessTransaction`)

- Обновлённые `checklist_accounts`, `mt_comments`
- `changed_processed_accounts` (для справки)

## Логика

```
submittedTask = findSubmittedTask()
workflowStatus = processTransaction.getWorkflowStatus()

if (workflowStatus == "changed_accounts_exist"):
    processSubmittedAccounts(...)
elif (workflowStatus == "no_changed_accounts"):
    log.info("No changed accounts; skipping MT №2 account processing")
else:
    log.warn("Unknown workflow_status; skipping (safe default)")

# Финализация в ЛЮБОЙ ветке
markTaskSuccess(submittedTask.guid)         # status = SUCCESS
markTaskProcessed(submittedTask.guid)       # tags = ["processedChanged"]
```

Зеркало `SaveNewStep` для MT №2 — логика идентична, отличаются только константы (`MT_02_*`) и класс результата (`ProcessChangedResult`).

### `processSubmittedAccounts`
1. `parseProcessedAccounts(submittedTask)` → `List<Account>`.
2. `AccountChecklistHelper(checklistAccounts).updateWith(changedProcessedAccounts)`.
3. Обновить `checklist_accounts`.
4. Объединить комментарии.
5. `sendMailTaskProcessed` (`task_processed`, `mtName = "Проверка изменения меток счетов"`).

### `findSubmittedTask`
Фильтр: `name == "processChanged"`, `tagList.contains("reviewedChanged")`, `status == IN_PROGRESS`.

### `parseTaskIntoResult`
Разбирает `initialData` в `ProcessChangedResult` (Map/String/raw JSON fallback). Отсутствие `initialData` → `BusinessException`.

### Финализация
- `markTaskSuccess`: `tasks().update(guid).status(SUCCESS)`
- `markTaskProcessed`: `tags(["processedChanged"])` — заменяет список тегов, снимая `pendingChanged`/`reviewedChanged` с триггера.

> Обязательная финализация в любой ветке предотвращает повторный auto-trigger Stage3.

## Email

| Событие | Шаблон | Переменные |
|---|---|---|
| Задача обработана | `task_processed` | `mtName = "Проверка изменения меток счетов"` |

## Тесты (`SaveChangedStepTest`)

- `readsProcessedAccountsFromQueue_mergesChecklistAndComments_persistsResult`
- `skipsAccountProcessingAndFinalizesTask_whenNoChangedAccounts`
- `skipsAndFinalizesTask_whenWorkflowStatusUnknown`
- `throws_whenNoTaskWithFinalTag`

## Связанные файлы

- `model/ProcessChangedResult.java`
- `utils/AccountChecklistHelper.java`
- `service/AppNotificationService.java`
- `resources/actions/process_changed.js`