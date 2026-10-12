# Шаг 7 — PrepareAllStep

| Поле | Значение |
|---|---|
| Класс | `by.a1.ics00057_accounts.steps.PrepareAllStep` |
| `@StepName` | `PrepareAllStep` |
| Стадия | Stage3 (sender для MT №3) |
| Зависимости | `EmailService`, `OrchestratorService` (Guice) |
| Источник | `src/main/java/by/a1/ics00057_accounts/steps/PrepareAllStep.java` |

## Назначение

Создаёт MT №3 «Внесение изменений по счетам» с полным справочником `allAccounts` (для autocomplete по номеру счета), комментариями и `bearerToken`. MT №3 **безусловна** — задача создаётся всегда; контролёр сам добавляет счета для корректировки. Auto-trigger ветка отсутствует.

## Вход

- `checklist_accounts` — `List<Account>` (полный справочник после `SaveNewStep` и `SaveChangedStep`)
- `mt_comments` — `Set<String>`

## Выход

- MT-задача №3 в очереди Orchestrator
- Email «Новая задача»

## Логика

```
checklistAccounts = processTransaction.getChecklistAccounts()  # обязаны быть
comments = processTransaction.getMtComments().orElse(Set.of())

createManualTask(checklistAccounts, comments)
sendMailNewTask(emailRecipients, initParams.processAllActionLink)
```

### `createManualTask` (payload `initialData`)
```json
{
  "allAccounts":  [Account...],   # весь справочник (autocomplete по номеру)
  "comments":     [String...],
  "bearerToken":  "<sherpa_api_credentials.password>"
}
```
Параметры задачи:
- `queue` = `ICS-00057 Обновление справочника` (общая)
- `name` = `processAll`
- `tags` = `["pendingAll"]`
- `parameters` = `{ "initialData": payload, "transactionName": <...>, "processStage": 4 }`

`processStage=4` побуждает Orchestrator-триггер запустить Stage4 (`SaveAllStep` → `UploadEvidenceStep`).

### `resolveTransactionName`
Аналогично другим Prepare-шагам — из JVM-свойства `transaction.path`.

## Email

| Событие | Шаблон | Переменные |
|---|---|---|
| Новая задача | `new_tasks` | `mtName = "Внесение изменений по счетам"`, `actionUrl = processAllActionLink` |

> Письмо «нет новых задач» здесь не отправляется — MT №3 безусловна.

## Константы (`ProcessDataKeys`)

- `MT_03_QUEUE_NAME = MT_01_QUEUE_NAME` (общая очередь)
- `MT_03_TASK_NAME = "processAll"`
- `MT_03_PENDING_TAG = "pendingAll"`, `MT_03_FINAL_TAG = "reviewedAll"`, `MT_03_PROCESSED_TAG = "processedAll"`

## Обработка ошибок

- `checklist_accounts` отсутствуют → `IllegalStateException("Checklist accounts not found")`.
- `InitParameters` отсутствуют → `IllegalStateException("InitParameters not found")`.

## Тесты (`PrepareAllStepTest`)

- `createsMt03TaskWithFullChecklistAndSendsEmail`
- `throws_whenChecklistAccountsMissing`
- `throws_whenInitParametersMissing`

## Связанные файлы

- `service/AppNotificationService.java`
- `resources/actions/process_all.js`