# Развёртывание — ICS-00057 «Обновление справочника»

Инструкция по сборке, конфигурации ассетов/триггеров и развёртыванию процесса в средах Orchestrator.

## 1. Сборка

### Требования к среде сборки
- JDK 8+ (процесс использует Lombok 1.18.40, Guice, Apache POI, poiji 5.2.0, zip4j 2.11.5)
- Gradle (wrapper родительского проекта `rpa-suite`)
- Доступ к `mavenCentral()`

### Команды
```bash
cd rpa-suite
./gradlew :rpa-suite:ics00057-accounts:build
```

Артефакт: `build/libs/ics00057-accounts-1.0.0.jar` (shadowJar, fat-jar со всеми зависимостями, кроме `rpa-core` — он подключается как `project(':rpa-core')`).

> `tasks.jar` отключён (`enabled = false`), `distZip` / `distTar` / `shadowDistZip` / `shadowDistTar` отключены — единственный артефакт это shadowJar.

### Спецзависимости
- `libs/jacob.jar` — локальная библиотека SAP GUI automation (Java-COM bridge). Должна лежать в `ics00057-accounts/libs/`. JVM-флаг запуска: `-Djava.library.path=${projectDir}/libs`.
- `org.apache.logging.log4j:log4j-to-slf4j:2.24.3` — мост логирования POI в Logback.

### Запуск из IDE
```bash
./gradlew :rpa-suite:ics00057-accounts:run
```
Main class: `by.a1.rpa.core.StepRunnerMain` (из `rpa-core`). JVM-args: `-Xmx512m -XX:+UseG1GC`.

## 2. Конфигурация процесса

### 2.1. `process-config.json`
```json
{
  "processName": "ICS-00057",
  "bpName": "ICS-00057",
  "bpNumber": "01",
  "bpDescription": "Обновление справочника",
  "controlName": "Document Verification Accounting"
}
```

### 2.2. `init_params` (по средам)

| Параметр | prod | test |
|---|---|---|
| `emailRecipients.to` | `[SOX_Workfusion_App_RPA_ICS-00057@a1.by]` | то же |
| `emailRecipients.cc` | `[SC_SG_WorkFusion@A1.by]` | то же |
| `storageFolderName` | `ICS-00057` | `ICS-00057` |
| `unloadingFileName` | `ZACCOUNTS.xlsx` | `ZACCOUNTS.xlsx` |
| `screenshotsFileName` | `screenshots.xlsx` | `screenshots.xlsx` |
| `spVactproBase` | `https://vactpro.main.velcom.by` | то же |
| `spVactproProject` | `Project_928` | `Project_1776` |
| `spVactproPath` | `Lists/documents` | `Lists/documents/Бот/ICS-00057` |
| `mockSap` | `"false"` | `"true"` |
| `periodStart` / `periodEnd` | `"-"` / `"-"` | `"-"` / `"-"` |
| `processNewActionLink` | `https://sherpa-prod.a1.by/main/my-actions/...` | `https://sherpa-test.a1.by/main/my-actions/db705eda-...` |
| `processChangedActionLink` | `https://sherpa-prod.a1.by/main/my-actions/...` | `https://sherpa-test.a1.by/main/my-actions/10a99034-...` |
| `processAllActionLink` | `https://sherpa-prod.a1.by/main/my-actions/...` | `https://sherpa-test.a1.by/main/my-actions/6a8a4771-...` |

Опционально: `errorHandling.errorOccursUrl` — ссылка «Порядок действий при возникновении ошибок» в письме `process_error`.

### 2.3. `periodStart` / `periodEnd` (формат `dd.MM.yyyy`)
- Оба параметра должны быть установлены.
- `periodStart < periodEnd`.
- `periodEnd < дата запуска`.
- При невозможности парсинга — используется предыдущий квартал от даты запуска.
- При нарушении порядка — `BusinessException`, процесс останавливается.

## 3. Ассеты Orchestrator

| Имя ассета | Тип | Содержимое |
|---|---|---|
| `sap_credentials` | Credentials | логин/пароль для SAP |
| `sap_settings` | JSON (`SapGuiSettings`) | `systemName`, `client`, `language = "RU"` |
| `sharepoint_credentials` | Credentials | логин/пароль для SharePoint |
| `sherpa_api_credentials` | Credentials | Bearer-токен (password) для JS-вызовов `/api/task/*` |
| `ics00057_accounts` | JSON-файл в Storage | `List<Account>` — справочник счетов (заменяет DataStore) |
| `ics00057_comments` | JSON-файл в Storage | `Set<String>` — комментарии MT (заменяет DataStore) |

> `ics00057_accounts` / `ics00057_comments` — это файлы в Orchestrator Storage (не assets-credentials). `ProcessStateService` читает/пишет их через `orchestratorService.files()`.

## 4. Очередь и триггеры Orchestrator

### Очередь
- Имя: `ICS-00057 Обновление справочника`
- Используется тремя MT (MT №1/№2/№3) с непересекающимися тегами.

### Триггеры Task Queue
Для каждой MT настраивается отдельный триггер:
| Триггер | Условие (final-тег) | Статус задачи → | Запускает |
|---|---|---|---|
| Stage2 | `reviewed` | `IN_PROGRESS` | `SaveNewStep` (Stage2, начиная с `SaveNewStep`) |
| Stage3 | `reviewedChanged` | `IN_PROGRESS` | `SaveChangedStep` (Stage3, начиная с `SaveChangedStep`) |
| Stage4 | `reviewedAll` | `IN_PROGRESS` | `SaveAllStep` (Stage4, начиная с `SaveAllStep`) |

Параметр `processStage` в MT-задаче (2/3/4) определяет стартовую стадию receiver.

### Расписание запуска
Stage1 запускается по расписанию Orchestrator (настраивается администратором). Расписание не входит в код процесса.

## 5. Развёртывание MT-форм Shadow Core Engine

Для каждой MT в Shadow Core Engine создаётся Action с привязкой скрипта формы:
| MT | Скрипт | Action-ссылка (init_param) |
|---|---|---|
| MT №1 | `src/main/resources/actions/process_new.js` | `processNewActionLink` |
| MT №2 | `src/main/resources/actions/process_changed.js` | `processChangedActionLink` |
| MT №3 | `src/main/resources/actions/process_all.js` | `processAllActionLink` |

Общие зависимости формы: `core.js` и `style.css` — берутся из `rpa-core/src/test/resources/manualtask/` и загружаются в файловое хранилище Shadow Core Engine.

Форма отправляет результат через `ShadowCore.submit({ userInput: { processedAccounts: [...] } })` и предварительно вызывает `ShadowCore.checkAndMarkLastTask(token, "ICS-00057 Обновление справочника", "<pendingTag>", "<finalTag>")` — это заменяет pending-тег на final-тег, что запускает Orchestrator-триггер.

## 6. Файлы ресурсов (включены в сборку)

- `src/main/resources/excel_template/ICS-00057_01_template.xlsx` — шаблон чек-листа
- `src/main/resources/ics00057_accounts_email_templates.json` — 6 email-шаблонов
- `src/main/resources/logback.xml` — конфигурация логирования
- `src/main/resources/sap_mock/` — мок-SAP для test-среды (`mockSap="true"`)
- `src/main/resources/init_params/{prod,test}/ics00057_accounts_init_params.json`

## 7. Требования к серверу бота (runtime)

- SAP GUI 750+ установлен, `saplogon.exe` доступен в PATH (для prod, `mockSap="false"`).
- `jacob.dll` доступен через `-Djava.library.path` (для SAP GUI automation).
- JVM: `-Xmx512m -XX:+UseG1GC`.
- Сетевой доступ:
  - к SAP-серверу (systemName из `sap_settings`)
  - к `vactpro.main.velcom.by` (SharePoint)
  - к Orchestrator API
  - к SMTP-серверу для email
  - к `sherpa-prod.a1.by` / `sherpa-test.a1.by` (из браузера контролёра, не из бота)

## 8. Проверка после развёртывания

1. **Чек-лист ассетов**: убедиться, что все 6 ассетов выше существуют и валидны.
2. **Чек-лист триггеров**: убедиться, что 3 триггера Task Queue настроены на очередь `ICS-00057 Обновление справочника` с правильными final-тегами.
3. **Чек-лист MT-форм**: открыть Action-ссылки test-среды — должны открываться формы с тестовыми данными.
4. **Тестовый прогон**: запустить процесс в test-среде (`mockSap="true"`) — пройти все 9 шагов без участия SAP/SharePoint (Storage и очередь — реальные test-окружения).
5. **Приёмочный прогон в prod**: запустить процесс в prod с `mockSap="false"` на тестовом периоде — проверить выгрузку из SAP, загрузку в SharePoint, отправку писем.

## 9. Откат

- Переключить `mockSap="true"` в init_params — бот перестанет ходить в SAP (только test-мок).
- Отключить расписание Stage1 — бот не стартует.
- При критической ошибке в MT-форме — отключить соответствующий триггер Task Queue, чтобы Stage не запускалась по auto-trigger.
- Откат ассетов `ics00057_accounts` / `ics00057_comments` — восстановить предыдущую версию файла из истории Storage.