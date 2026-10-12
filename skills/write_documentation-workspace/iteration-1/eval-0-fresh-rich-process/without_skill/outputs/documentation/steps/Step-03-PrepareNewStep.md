# Шаг 3 — PrepareNewStep

| Поле | Значение |
|---|---|
| Класс | `by.a1.ics00057_accounts.steps.PrepareNewStep` |
| `@StepName` | `PrepareNewStep` |
| Стадия | Stage1 (sender для MT №1) |
| Зависимости | `EmailService`, `OrchestratorService` (Guice) |
| Источник | `src/main/java/by/a1/ics00057_accounts/steps/PrepareNewStep.java` |

## Назначение

Сравнивает SAP-выгрузку со справочником из Orchestrator Asset `ics00057_accounts`, определяет новые счета, разбивает их на «без меток» (редактируемые) и «с метками» (неизменяемые), создаёт MT №1 «Проверка новых счетов» в очереди Orchestrator с тегом `pending` либо auto-trigger задачу (тег `reviewed`), отправляет email.

## Вход

- `sap_accounts` — `List<Account>` (из `SapStep`)
- `ProcessStateService.selectAccounts()` — справочник из Storage `ics00057_accounts.json`
- `ProcessStateService.selectComments()` — комментарии из Storage `ics00057_comments.json`

## Выход (в `ProcessTransaction`)

- `new_accounts_with_marks`, `new_accounts_without_marks` — разбиение новых счетов
- `checklist_accounts` — справочник (для последующих шагов)
- `mt_comments` — множество комментариев
- `workflow_status`:
  - `new_accounts_exist` — есть новые счета, создана MT №1
  - `no_new_accounts` — нет новых счетов, создан auto-trigger

## Логика

```
checklist = AccountChecklistHelper(checklistAccounts)   # Map<accountNumber, Account>
newAccounts = checklist.getNewAccounts(sapAccounts)     # счета не из справочника
newAccountsWithMarks    = checklist.getAccountsWithMarks(newAccounts)
newAccountsWithoutMarks = checklist.getAccountsWithoutMarks(newAccounts)

if (newAccounts.isEmpty()):
    sendMailNoNewTask()
    workflow_status = "no_new_accounts"
    createAutoTriggerTask()
else:
    workflow_status = "new_accounts_exist"
    createManualTask(newAccountsWithoutMarks, newAccountsWithMarks, comments)
    sendMailNewTask(emailRecipients, initParams.processNewActionLink)
```

### `createManualTask`
Payload `initialData` (LinkedHashMap для порядка ключей):
```json
{
  "newAccountsWithoutMarks": [Account...],
  "newAccountsWithMarks":    [Account...],
  "comments":               [String...],
  "bearerToken":            "<sherpa_api_credentials.password>"
}
```
Параметры задачи:
- `queue` = `ICS-00057 Обновление справочника`
- `name` = `processNew`
- `tags` = `["pending"]`
- `parameters` = `{ "initialData": payload, "transactionName": <resolveTransactionName()>, "processStage": 2 }`

`sherpa_api_credentials` — ассет Credentials; в payload идёт `password()` как Bearer-токен для JS-вызовов MT.

### `createAutoTriggerTask`
1. Создать задачу с тегом `pending`, `processStage=2`, пустым `initialData`.
2. Обновить задачу: `status = IN_PROGRESS`, `tags = ["reviewed"]`.
Это реальный переход статуса/тега, надёжно заводящий Orchestrator-триггер Stage2 без ручной проверки. `SaveNewStep` по `workflow_status="no_new_accounts"` пропускает разбор и финализирует задачу.

### `resolveTransactionName`
Читает JVM-свойство `transaction.path`, берёт имя файла без расширения. Используется для связи MT-задачи с файлом транзакции в Storage. Если свойство пусто — `IllegalStateException("Missing system property 'transaction.path'")`.

## Email

| Событие | Шаблон | Переменные |
|---|---|---|
| Новая задача | `new_tasks` | `mtName = "Проверка новых счетов"`, `actionUrl = processNewActionLink` |
| Нет новых задач | `no_new_tasks` | `mtName = "Проверка новых счетов"` |

## Константы (`ProcessDataKeys`)

- `MT_01_QUEUE_NAME = "ICS-00057 Обновление справочника"`
- `MT_01_TASK_NAME = "processNew"`
- `MT_01_PENDING_TAG = "pending"`, `MT_01_FINAL_TAG = "reviewed"`, `MT_01_PROCESSED_TAG = "processed"`
- `STATUS_NEW_ACCOUNTS_EXIST`, `STATUS_NO_NEW_ACCOUNTS`

## Тесты (`PrepareNewStepTest`)

- `splitsNewAccountsByMarksAndNotifiesNewTasks_whenNewAccountsExist` — happy path
- `createsAutoTriggerTaskAndSetsNoNewAccountsStatus_whenNoNewAccounts`
- `throws_whenSapAccountsMissing`
- `throws_whenInitParametersMissing`

## Связанные файлы

- `utils/AccountChecklistHelper.java`
- `service/ProcessStateService.java`
- `service/AppNotificationService.java`
- `resources/actions/process_new.js`