# Шаг 5 — PrepareChangedStep

| Поле | Значение |
|---|---|
| Класс | `by.a1.ics00057_accounts.steps.PrepareChangedStep` |
| `@StepName` | `PrepareChangedStep` |
| Стадия | Stage2 (sender для MT №2) |
| Зависимости | `EmailService`, `OrchestratorService` (Guice) |
| Источник | `src/main/java/by/a1/ics00057_accounts/steps/PrepareChangedStep.java` |

## Назначение

Определяет счета с изменившимися метками (`hasPostingBlockMark` / `hasDeletionMark`), сравнивая SAP-выгрузку с обновлённым `SaveNewStep`-ом справочником из транзакции. Разбивает изменения на редактируемые «без меток» и неизменяемые «с метками» (`AccountUpdated`), создаёт MT №2 «Проверка изменения меток счетов» либо auto-trigger, отправляет email.

## Вход

- `sap_accounts` — `List<Account>` (из `SapStep`)
- `checklist_accounts` — `List<Account>` (обновлён `SaveNewStep`)
- `mt_comments` — `Set<String>`

## Выход (в `ProcessTransaction`)

- `changed_accounts_with_marks`, `changed_accounts_without_marks` — `List<AccountUpdated>`
- `workflow_status`:
  - `changed_accounts_exist` — есть изменения, создана MT №2
  - `no_changed_accounts` — нет изменений, создан auto-trigger

## Логика

```
checklist = AccountChecklistHelper(checklistAccounts)
existingAccounts   = checklist.getExistingAccounts(sapAccounts)         # счета уже в справочнике
withChangedMarks   = checklist.getAccountsWithChangedMarks(existingAccounts)
accountsWithMarks    = checklist.getAccountsWithMarks(withChangedMarks)    # у которых уже есть метки (неизменяемые)
accountsWithoutMarks = checklist.getAccountsWithoutMarks(withChangedMarks) # без меток (редактируемые)

changedWithMarks    = checklist.mapToUpdatedAccounts(accountsWithMarks)     # AccountUpdated
changedWithoutMarks = checklist.mapToUpdatedAccounts(accountsWithoutMarks)

if (withChangedMarks.isEmpty()):
    sendMailNoNewTask()
    workflow_status = "no_changed_accounts"
    createAutoTriggerTask()
else:
    workflow_status = "changed_accounts_exist"
    createManualTask(changedWithoutMarks, changedWithMarks, comments)
    sendMailNewTask(emailRecipients, initParams.processChangedActionLink)
```

### `getAccountsWithChangedMarks`
Для счета из SAP, который уже есть в справочнике: возвращает `true`, если `hasPostingBlockMark` или `hasDeletionMark` отличается от предыдущего значения в справочнике.

### `mapToUpdatedAccounts`
Оборачивает каждый счет в `AccountUpdated`:
- `accountPrev` — текущая запись из справочника (`checklist.getOrDefault(accountNumber, account)`)
- `hasPostingBlockMarkUpdated` — новое значение из SAP
- `hasDeletionMarkUpdated` — новое значение из SAP

### `createManualTask` (payload `initialData`)
```json
{
  "changedAccounts":          [AccountUpdated...],  # без меток (редактируемые)
  "changedAccountsImmutable": [AccountUpdated...],  # с метками (неизменяемые)
  "comments":                 [String...],
  "bearerToken":              "<sherpa_api_credentials.password>"
}
```
Параметры задачи:
- `queue` = `ICS-00057 Обновление справочника` (общая с MT №1)
- `name` = `processChanged`
- `tags` = `["pendingChanged"]`
- `parameters` = `{ "initialData": payload, "transactionName": <...>, "processStage": 3 }`

### `createAutoTriggerTask`
1. Создать с `pendingChanged`, `processStage=3`.
2. Обновить: `status = IN_PROGRESS`, `tags = ["reviewedChanged"]`.
`SaveChangedStep` по `workflow_status="no_changed_accounts"` пропускает разбор.

## Email

| Событие | Шаблон | Переменные |
|---|---|---|
| Новая задача | `new_tasks` | `mtName = "Проверка изменения меток счетов"`, `actionUrl = processChangedActionLink` |
| Нет задач | `no_new_tasks` | `mtName = "Проверка изменения меток счетов"` |

## Константы (`ProcessDataKeys`)

- `MT_02_QUEUE_NAME = MT_01_QUEUE_NAME` (общая очередь, теги не конфликтуют)
- `MT_02_TASK_NAME = "processChanged"`
- `MT_02_PENDING_TAG = "pendingChanged"`, `MT_02_FINAL_TAG = "reviewedChanged"`, `MT_02_PROCESSED_TAG = "processedChanged"`
- `STATUS_CHANGED_ACCOUNTS_EXIST`, `STATUS_NO_CHANGED_ACCOUNTS`

## Тесты (`PrepareChangedStepTest`)

- `splitsChangedAccountsByMarksAndCreatesMt02Task_whenChangedAccountsExist`
- `createsAutoTriggerTaskAndSetsNoChangedAccountsStatus_whenNoChangedAccounts`
- `throws_whenSapAccountsMissing`
- `throws_whenChecklistAccountsMissing`
- `throws_whenInitParametersMissing`
- `changedAccountsExcelMock_containsExpectedChangedAccounts` — проверка тестового мока `with_changed_accounts/ZACCOUNTS.xlsx`

## Связанные файлы

- `entity/AccountUpdated.java`
- `utils/AccountChecklistHelper.java`
- `service/AppNotificationService.java`
- `resources/actions/process_changed.js`