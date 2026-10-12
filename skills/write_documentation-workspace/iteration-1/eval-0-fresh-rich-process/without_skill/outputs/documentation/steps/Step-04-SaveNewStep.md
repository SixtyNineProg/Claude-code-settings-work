# Шаг 4 — SaveNewStep

| Поле | Значение |
|---|---|
| Класс | `by.a1.ics00057_accounts.steps.SaveNewStep` |
| `@StepName` | `SaveNewStep` |
| Стадия | Stage2 (receiver MT №1) |
| Зависимости | `EmailService`, `OrchestratorService` (Guice) |
| Источник | `src/main/java/by/a1/ics00057_accounts/steps/SaveNewStep.java` |

## Назначение

Receiver-шаг MT №1 «Проверка новых счетов». Запускается Orchestrator-триггером по тегу `reviewed`. Находит в очереди MT №1 с `name=processNew`, final-тегом `reviewed`, статусом `IN_PROGRESS`, разбирает `initialData` → `ProcessNewResult` → `processedAccounts`, обновляет `checklist_accounts` и `mt_comments`, финализирует задачу (`SUCCESS` + `processed`) в любой ветке.

## Вход

- MT-задача №1 из очереди (по тегу `reviewed`)
- `workflow_status` из транзакции (определяет ветку)
- `checklist_accounts` и `mt_comments` из транзакции

## Выход (в `ProcessTransaction`)

- Обновлённые `checklist_accounts`, `mt_comments`
- `new_processed_accounts` (для справки)

## Логика

```
submittedTask = findSubmittedTask()
workflowStatus = processTransaction.getWorkflowStatus()

if (workflowStatus == "new_accounts_exist"):
    processSubmittedAccounts(...)
elif (workflowStatus == "no_new_accounts"):
    log.info("No new accounts; skipping MT №1 account processing")
else:
    log.warn("Unknown workflow_status; skipping (safe default)")

# Финализация в ЛЮБОЙ ветке
markTaskSuccess(submittedTask.guid)         # status = SUCCESS
markTaskProcessed(submittedTask.guid)       # tags = ["processed"]
```

### `processSubmittedAccounts`
1. `parseProcessedAccounts(submittedTask)` — `ProcessNewResult` → `userInput.processedAccounts`.
2. `AccountChecklistHelper(checklistAccounts).updateWith(newProcessedAccounts)` — обновляет существующие записи, добавляет новые.
3. Обновить `checklist_accounts` в транзакции.
4. Объединить комментарии: добавить `comment` из каждого `processedAccounts` в `mt_comments`.
5. Сохранить `new_processed_accounts` в транзакцию.
6. `sendMailTaskProcessed` (шаблон `task_processed`, `mtName = "Проверка новых счетов"`).

### `findSubmittedTask`
Фильтрует `tasks().listFromQueue(MT_01_QUEUE_NAME)`:
- `name == "processNew"`
- `tagList.contains("reviewed")`
- `status == IN_PROGRESS`

Если не найдена — `IllegalStateException("No MT №1 task with name ... final tag 'reviewed' and status IN_PROGRESS in queue ...")`.

### `parseTaskIntoResult`
Разбирает `initialData` из задачи в `ProcessNewResult`. Поддерживает:
- `Map` (после `tasks().create()` с параметрами)
- `String` (после `ShadowCore.submit`)
- Fallback: raw JSON `{ "text": { "initialData": "..." } }`

Если `initialData` отсутствует — `IllegalStateException("MT №1 task has no initialData parameter")`, обёрнуто в `BusinessException`.

### Финализация
- `markTaskSuccess`: `tasks().update(guid).status(SUCCESS).execute()`
- `markTaskProcessed`: `tasks().update(guid).tags(["processed"]).execute()` — `tags(...)` полностью заменяет список тегов. Сервер игнорирует пустое значение, поэтому тег `processed` (а не пустой список) снимает `pending`/`reviewed` с триггера.

> Критично: финализация обязательна в любой ветке, иначе auto-trigger пере-сработает и Stage2 запустится повторно.

## Email

| Событие | Шаблон | Переменные |
|---|---|---|
| Задача обработана | `task_processed` | `mtName = "Проверка новых счетов"` |

## Обработка ошибок

- Нет задачи с final-тегом → `IllegalStateException` (оборачивается в `BusinessException("Process MT №1 results failed")`).
- Ошибка разбора `initialData` → `BusinessException("Failed to parse MT №1 task ...")`.

## Тесты (`SaveNewStepTest`)

- `readsProcessedAccountsFromQueue_mergesChecklistAndComments_persistsResult` — happy path
- `skipsAccountProcessingAndFinalizesTask_whenNoNewAccounts` — auto-trigger путь
- `skipsAndFinalizesTask_whenWorkflowStatusUnknown` — safe default
- `throws_whenNoTaskWithFinalTag`

## Связанные файлы

- `model/ProcessNewResult.java`
- `utils/AccountChecklistHelper.java`
- `service/AppNotificationService.java`
- `resources/actions/process_new.js`