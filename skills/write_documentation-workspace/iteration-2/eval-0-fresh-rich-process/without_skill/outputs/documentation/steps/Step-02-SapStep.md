# Шаг 2 — SapStep

| Поле | Значение |
|---|---|
| Класс | `by.a1.ics00057_accounts.steps.SapStep` |
| `@StepName` | `SapStep` |
| Стадия | Stage1 |
| Зависимости | `OrchestratorService` (Guice) |
| Источник | `src/main/java/by/a1/ics00057_accounts/steps/SapStep.java` |

## Назначение

Выгружает справочник счетов из SAP (Z-транзакция `ZACCOUNTS`, план счетов `IFRS`, БЕ `1320`), собирает 3 скриншота экранов в xlsx, парсит выгрузку в `List<Account>` и загружает файлы в Orchestrator Storage (плоское имя с суффиксом даты-времени). Также создаёт унифицированную структуру папок на SharePoint и удаляет папку `other evidence`.

## Константы

| Константа | Значение |
|---|---|
| `SAP_TRANSACTION` | `ZACCOUNTS` |
| `CHART_OF_ACCOUNTS` | `IFRS` |
| `COMPANY_CODE` | `1320` |
| `WAIT_S` | 5 (сек) |
| `EXPORT_TIMEOUT_S` | 1800 (таймаут ожидания ALV-экспорта) |
| `SAP_CREDENTIALS_ASSET` | `sap_credentials` |
| `SAP_SETTINGS_ASSET` | `sap_settings` |
| `MOCK_EXCEL` | `sap_mock/excel/without_new_accounts/ZACCOUNTS.xlsx` |

## Вход

- `InitParameters` (`spVactproBase`, `spVactproProject`, `spVactproPath`, `mockSap`, `storageFolderName`, `unloadingFileName`, `screenshotsFileName`)
- `ReportingPeriod` (из транзакции, установлен `InfrastructureStep`)

## Выход (в `ProcessTransaction`)

- `sap_accounts` — `List<Account>` (распарсенная выгрузка)
- `sap_screenshots_storage_name` — плоское имя `screenshots_<ts>.xlsx`
- `sap_unloading_storage_name` — плоское имя `ZACCOUNTS_<ts>.xlsx`

## Логика

### `createSharePointFolders`
1. Получить `sharepoint_credentials` из ассета.
2. Создать `SharePointService` через `SharePointModule.create(...)`.
3. `createUnifiedFolderStructure(spVactproPath, remoteFolderStructure)` — обходит `UnifiedFoldersUtil.getAllPaths()` и создаёт каждый путь рекурсивно.
4. Удалить папку `<spVactproPath>/<workOtherEvidenceFolderPath>` (не используется процессом).

### `exportAndStore`
1. `FileUtils.createTempDirectory("ICS-00057 SAP Accounts Unloading")` — локальная temp-папка.
2. `isMock = "true".equalsIgnoreCase(initParams.getMockSap())`.
   - `true` → `exportMock(unloadingPath)` — копирует `sap_mock/excel/without_new_accounts/ZACCOUNTS.xlsx` и 3 PNG-скриншота из ресурсов.
   - `false` → `exportFromSap(exportDir, unloadingFileName)` — реальная выгрузка через SAP GUI.
3. `ExcelScreenshotHelper.saveScreenshotsToExcel(screenshots, screenshotsPath, sheetName)` — оборачивает 3 `BufferedImage` в xlsx.
4. `ExcelSapUnloadingParser.processFile(unloadingPath)` → `List<Account>`.
5. `fileTimestamp = StorageNames.nowFileTimestamp()` (`yyyyMMdd_HHmmss`).
6. Загрузить оба файла в Storage с плоским именем `StorageNames.withTimestamp(name, ts)` в папку `storageFolderName`.
7. Сохранить `sapAccounts`, `screenshotsStorageName`, `unloadingStorageName` в транзакцию.
8. `FileUtils.deleteRecursively(tempDir)`.

### `exportFromSap` (реальный SAP)
1. `SapGuiConfig`: elementTimeout=60, connectTimeout=60, handleCopyrightDialog=true, autoMaximizeWindows=true, autoCloseSapLogon=FORCE.
2. Завершить процессы `saplogon.exe` и `saplgpad.exe` (10 попыток).
3. Получить `sap_credentials` и `sap_settings` (последний парсится в `SapGuiSettings`).
4. `SapGuiAutomation.connectViaShortcutDesc(systemName, client, language, login, password, 30, sapConfig)`.
5. `session.runTransaction("ZACCOUNTS")`.
6. `SHIFT+F7` (выбор параметров) → заполнить `SD_KTOPL-LOW = IFRS`, `SD_BUKRS-LOW = 1320` → скриншот №1 (параметры).
7. `F8` (запуск отчёта) → ждать кнопку `tbar[1]/btn[39]` (экспорт) до `EXPORT_TIMEOUT_S`.
8. Скриншот №2 (первая страница).
9. `clickNearCenterSequence()` (5 кликов около центра экрана через `Robot`) + `pressCtrlPageDownWithRobot()` → последняя страница → скриншот №3.
10. Экспорт: `CTRL+SHIFT+F10` → `CTRL+SHIFT+F7` → заполнить `DY_PATH`/`DY_FILENAME` → нажать `tbar[0]/btn[11]`.
11. Завершить `EXCEL.EXE` после экспорта.
12. `SessionException` → `BusinessException("SAP session failed")`.

## Storage-имена

`StorageNames.withTimestamp(name, ts)` вставляет `ts` перед расширением:
- `ZACCOUNTS.xlsx` + `20260716_143022` → `ZACCOUNTS_20260716_143022.xlsx`
- `screenshots.xlsx` + `...` → `screenshots_20260716_143022.xlsx`

## Замечания

- `sap_settings.language` должен быть `"RU"` — имена счетов зависят от языка.
- Локальная temp-папка удаляется в конце шага; `UploadEvidenceStep` позже скачивает файлы обратно из Storage (бот-сессия разрывается на MT-шагах).
- TODO в коде: проверить на живом SAP ключи триггера экспорта и id кнопки сохранения.

## Тесты

`SapStepTest` проверяет только утилиту `StorageNames.withTimestamp` (4 теста: вставка перед расширением, для screenshots, без расширения, dotfiles). Сам `SapStep` покрыт косвенно через `FolderStructureTest` и мок-SAP.

## Связанные файлы

- `excel/ExcelSapUnloadingParser.java`, `excel/ExcelScreenshotHelper.java`
- `utils/FileUtils.java`, `utils/ScreenshotUtils.java`, `utils/StorageNames.java`, `utils/FolderStructure.java`
- `module/SharePointModule.java`, `service/SharePointService.java`
- `resources/sap_mock/`