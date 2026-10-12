# Шаг 9 — UploadEvidenceStep

| Поле | Значение |
|---|---|
| Класс | `by.a1.ics00057_accounts.steps.UploadEvidenceStep` |
| `@StepName` | `UploadEvidenceStep` |
| Стадия | Stage4 (финальный) |
| Зависимости | `OrchestratorService`, `EmailService` (Guice) |
| Источник | `src/main/java/by/a1/ics00057_accounts/steps/UploadEvidenceStep.java` |

## Назначение

Финальный шаг: формирует чек-лист `ICS-00057_01.xlsx` и технический zip-архив, загружает их в Orchestrator Storage (плоское имя) и SharePoint (унифицированная структура), обновляет ассеты состояния (`ics00057_accounts`, `ics00057_comments`), отправляет финальное письмо «Работа завершена» со ссылкой на SharePoint.

## Вход

- `ReportingPeriod` (для `FolderStructure.from(...)`)
- `sap_screenshots_storage_name`, `sap_unloading_storage_name` (из `SapStep`)
- `checklist_accounts` (отсортированы по `accountNumber`)
- `mt_comments`
- `InitParameters` (`storageFolderName`, `spVactproBase`, `spVactproProject`, `spVactproPath`, `unloadingFileName`, `screenshotsFileName`)

## Выход (в `ProcessTransaction`)

- `checksum` — MD5 zip-архива

## Побочные эффекты (внешние)

- Storage: `ICS-00057_01_<ts>.xlsx`, `<runDate> archive ICS-00057_01_<ts>.zip`
- SharePoint: 4 файла по унифицированной структуре
- Asset-файлы `ics00057_accounts.json`, `ics00057_comments.json` обновлены
- Email `work_end`

## Логика

```
reportingPeriod = processTransaction.getReportingPeriod()
remoteFolderStructure = FolderStructure.from(reportingPeriod)
storageFolderName = initParams.storageFolderName
fileTimestamp = StorageNames.nowFileTimestamp()

credentials = orchestratorService.assets().getCredentials("sharepoint_credentials")
sharePoint = SharePointModule.create(spVactproBase, spVactproProject, credentials)

tempDir = FileUtils.createTempDirectory("ICS-00057-")

# 1. Скачать SAP-выгрузку и скриншоты обратно из Storage (бот-сессия разрывалась на MT)
screenDir = tempDir/screenshots
inputDir  = tempDir/input data
screenFile = downloadFromStorage(sapScreenshotsStorageName, screenDir/screenshots.xlsx)
inputFile  = downloadFromStorage(sapUnloadingStorageName,   inputDir/ZACCOUNTS.xlsx)

# 2. Сформировать чек-лист из шаблона
checklistFilename = remoteFolderStructure.getCheckListFilename()  # ICS-00057_01.xlsx
checklist.sort(Comparator.comparing(Account::getAccountNumber))
checklistFile = ExcelChecklistHelper(checklistPath).fillChecklistFile(checklist)

# 3. Сформировать zip-архив
zipFilename = remoteFolderStructure.getTechnicalArchiveFilename()  # <runDate> archive ICS-00057_01.zip
zip = FileUtils.zipDirectory([screenDir, inputDir, checklistPath], zipPath)
processTransaction.setMd5Checksum(FileUtils.getFileMd5Checksum(zip))

# 4. Загрузить чек-лист и архив в Storage (плоское имя с суффиксом)
uploadToStorage(checklistFile, storageFolderName, fileTimestamp)
uploadToStorage(zip,            storageFolderName, fileTimestamp)

# 5. Загрузить 4 файла в SharePoint по унифицированной структуре
uploadToSharePoint(sharePoint, screenFile,   spRootPath, workScreenshotsFolder/screenshots.xlsx)
uploadToSharePoint(sharePoint, inputFile,    spRootPath, workInputDataFolder/ZACCOUNTS.xlsx)
uploadToSharePoint(sharePoint, checklistFile,spRootPath, workingFolder/checklistFilename)
uploadToSharePoint(sharePoint, zip,          spRootPath, workingFolder/zipFilename)

# 6. Обновить ассеты состояния
stateService.updateAccounts(checklist)
stateService.updateComments(comments)

# 7. Финал
FileUtils.deleteRecursively(tempDir)
linkPath = spVactproBase + "/" + spRootPath + "/" + workingFolder
sendMailBotFinish(emailRecipients, linkPath)
```

## Структура zip-архива

Внутри архива (воспроизводит структуру ODF-источника):
```
screenshots/screenshots.xlsx
input data/ZACCOUNTS.xlsx
ICS-00057_01.xlsx           # в корне архива
```

## Чек-лист (`ExcelChecklistHelper`)

- Шаблон: `src/main/resources/excel_template/ICS-00057_01_template.xlsx`
- Колонки: номер счета, наименование, релевантность («Включить»/«Исключить»), комментарий, «блокировка проводки» (X/пусто), «пометка удаления» (X/пусто)
- Авторазмер колонок, автофильтр, заморозка первой строки

## Storage-имена

- `ICS-00057_01_<ts>.xlsx`
- `<runDate> archive ICS-00057_01_<ts>.zip`

## SharePoint-пути (по `UnifiedFoldersUtil`)

- `<spVactproPath>/<workingFolder>/ICS-00057_01.xlsx`
- `<spVactproPath>/<workingFolder>/<runDate> archive ICS-00057_01.zip`
- `<spVactproPath>/<workInputDataFolder>/ZACCOUNTS.xlsx`
- `<spVactproPath>/<workScreenshotsFolder>/screenshots.xlsx`

Конфликт при загрузке — `OVERWRITE` (`SharePointService.uploadFile`).

## Email

| Событие | Шаблон | Переменные |
|---|---|---|
| Работа завершена | `work_end` | `controlResultsLink = <spVactproBase>/<spRootPath>/<workingFolder>` |

## Обработка ошибок

- `sap_screenshots_storage_name` / `sap_unloading_storage_name` отсутствуют → `IllegalStateException`.
- `checklist_accounts` отсутствуют → `IllegalStateException`.
- `InitParameters` отсутствуют → `IllegalStateException`.

## Тесты

`UploadEvidenceStep` прямо не покрыт unit-тестами — логика сборки архива/чек-листа и загрузки в SharePoint интегрируется с внешними системами. Косвенно покрыт:
- `FolderStructureTest` (структура папок и Storage-имена)
- `SharePointServiceTest` (стратегия OVERWRITE)
- `ExcelChecklistHelper` покрыт косвенно через тестовые данные справочника.

## Связанные файлы

- `excel/ExcelChecklistHelper.java`
- `utils/FolderStructure.java`, `utils/FileUtils.java`, `utils/StorageNames.java`
- `service/SharePointService.java`, `module/SharePointModule.java`
- `service/ProcessStateService.java`, `service/AppNotificationService.java`
- `resources/excel_template/ICS-00057_01_template.xlsx`