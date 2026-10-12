# Шаг 8 — SaveAllStep

| Поле | Значение |
|---|---|
| Класс | `by.a1.ics00057_accounts.steps.SaveAllStep` |
| `@StepName` | `SaveAllStep` |
| Стадия | Stage4 (receiver MT №3) |
| Зависимости | `EmailService`, `OrchestratorService` (Guice) |
| Источник | `src/main/java/by/a1/ics00057_accounts/steps/SaveAllStep.java` |

## Назначение

Receiver-шаг MT №3 «Внесение изменений по счетам». Запускается Orchestrator-триггером по тегу `reviewedAll`. Находит MT №3 (`name=processAll`, final-тег `reviewedAll`, статус `IN_PROGRESS`), разбирает `initialData` → `ProcessAllResult` → `processedAccounts`, обновляет `checklist_accounts` и `mt_comments`, финализирует задачу (`SUCCESS` + `processedAll`).

## Вход

- MT-задача №3 из очереди
- `checklist_accounts` и `mt_comments` из транзакции

## Выход (в `ProcessTransaction`)

- Обновлённые `checklist_accounts`, `mt_comments`
- `all_processed_accounts` (для справки)

## Логика

В отличие от `SaveNewStep`/`SaveChangedStep`, **не ветвится** по `workflow_status`: MT №3 безусловна, `processedAccounts` может быть пустым списком (контролёр не внёс ни одной правки).

```
submittedTask = findSubmittedTask()
processSubmittedAccounts(processTransaction, submittedTask, emailRecipients)

# Финализация
markTaskSuccess(submittedTask.guid)         # status = SUCCESS
markTaskProcessed(submittedTask.guid)       # tags = ["processedAll"]
```

### `processSubmittedAccounts`
1. `parseProcessedAccounts(submittedTask)` → `List<Account>` (возможно пустой).
2. `AccountChecklistHelper(checklistAccounts).updateWith(processedAccounts)`.
3. Обновить `checklist_accounts`.
4. Объединить комментарии (`comment` из каждого `processedAccounts`).
5. `sendMailTaskProcessed` (`task_processed`, `mtName = "Внесение изменений по счетам"`).

### `findSubmittedTask`
Фильтр: `name == "processAll"`, `tagList.contains("reviewedAll")`, `status == IN_PROGRESS`.

### `parseTaskIntoResult`
Разбирает `initialData` в `ProcessAllResult` (Map/String/raw JSON fallback). Отсутствие `initialData` → `BusinessException`.

### Финализация
- `markTaskSuccess`: `tasks().update(guid).status(SUCCESS)`
- `markTaskProcessed`: `tags(["processedAll"])` — заменяет список тегов.

> Финализация критична — иначе auto-trigger повторно запустит Stage4.

## Email

| Событие | Шаблон | Переменные |
|---|---|---|
| Задача обработана | `task_processed` | `mtName = "Внесение изменений по счетам"` |

## Обработка ошибок

- Нет задачи с final-тегом `reviewedAll` → `IllegalStateException("No MT №3 task ...")`.
- Ошибка разбора → `BusinessException("Failed to parse MT №3 task ...")`.
- Любое исключение оборачивается в `BusinessException("Process MT №3 results failed")`.

## Тесты (`SaveAllStepTest`)

- `readsProcessedAccountsFromQueue_mergesChecklistAndComments_persistsResult`
- `mergesEmptyProcessedAccounts_whenControllerSubmittedNothing` — пустой `processedAccounts` корректно обрабатывается
- `throws_whenNoTaskWithFinalTag`

## Связанные файлы

- `model/ProcessAllResult.java`
- `utils/AccountChecklistHelper.java`
- `service/AppNotificationService.java`
- `resources/actions/process_all.js`