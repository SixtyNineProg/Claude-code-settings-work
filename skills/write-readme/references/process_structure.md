# Структура RPA-процесса Sherpa — справочник

Этот справочник содержит реальные факты о структуре процесса, которые
`analyze_process.py` использует автоматически. Обращайся к нему, если скрипт
что-то пропустил или встретился нестандартный layout — тогда нужно читать
файлы вручную по правилам ниже.

> Важно: исходный черновик `write_readme.md` содержал несколько неточностей
> об устройстве репозитория. Приведённые ниже правила — то, как устроено на
> самом деле (проверено на `ics60001`, `ics00057-accounts`, `rps-sales`).

## 1. process-config.json

Путь: `{processDir}/src/main/resources/process-config.json`.

Обязательное поле — только `bpName`. Остальные опциональны:

| Поле | Пример |
|------|--------|
| `bpName` | `ICS-60001` |
| `processName` | `ICS-00057` |
| `bpNumber` | `01` |
| `bpDescription` | `Обновление справочника` |
| `controlName` | `Correctness of manual journal entries` |

## 2. .process файлы — блоки и шаги

Файлы лежат в корне процесса: `Главная.process` (главная диаграмма) и
опционально `Stage1.process` … `StageN.process` (поддиаграммы, выбираются
через `SwitchCase` по `$Parameters.processStage`). У `rps-sales` есть
английское имя `SAP Automation.process`.

Каждый `<Content>` внутри `<DesignerItem>` — это XML-escaped
`<ToolboxItemSettings ...>` (сущности `&amp;` `&quot;` `&#xA;` `&lt;`
`&gt;`). У блока есть атрибуты `DisplayName` (человекочитаемая метка) и
`InternalName` (тип блок-набора: `Start`, `SwitchCase`, `ReturnOrStop` либо
сгенерированный GUID `MyBlock…`). **`InternalName` — это НЕ имя шага**.

Имя Java-шага лежит в отдельном элементе внутри блока:

```xml
<Property Name="StepName" ...
          Value="&quot;processSetup&quot;" .../>
```

После unescape значение имеет вид `Value=""processSetup""` (двойные кавычки).
Реальное имя шага — `processSetup` (без внутренних кавычек).

Блоки без `StepName` (Старт, Switch/Case, Конец, Try/Catch, HandleError) —
не Java-шаги, в README не попадают.

## 3. Разрешение имени шага (StepRegistry)

Имя шага = значение `StepName` в `.process`. Оно должно совпадать с тем, что
возвращает `StepRegistry.getStepName` для Java-класса:

1. Если на классе есть `@StepName("X")` — имя = `X`. Пример `ics00057`:
   `@StepName("SapStep")` на классе `SapStep`.
2. Иначе имя выводится из simple name класса: отбросить суффикс `Step` и
   сделать первую букву строчной. `ProcessSetupStep` → `processSetup`.

Сопоставление в README: берём `StepName` из `.process` и ищем Java-класс,
чей resolved step name ему равен. Ссылка в README указывает на реальный
путь файла (например
`src/main/java/by/a1/ics60001/steps/ProcessSetupStep.java`), а не на
угадываемый.

## 4. Java-шаги

Путь: `{processDir}/src/main/java/by/a1/{pkg}/steps/*Step.java`, где `pkg` —
имя каталога процесса с заменой `-` на `_` (`ics00057-accounts` →
`ics00057_accounts`). Каждый класс `implements by.a1.rpa.core.Step` с методом
`public void execute(Transaction transaction, List<String> args)`.

Описание шага для README составляется из тела `execute()`: какие данные
получаются, какая обработка, какой результат (2–3 предложения).

Классы-помощники без суффикса `Step` и без `@StepName` (например
`TemplateResultsWorkbookBuilder`) — не шаги. Если класс не фигурирует ни в
одном `.process`, он попадает в `warnings` (см. `rps-sales/_GetSapReportDataStep` —
отключённый шаг с префиксом `_`).

## 5. init_params

Глоб: `{processDir}/src/main/resources/**/*init_params*.json`. Файл НЕ всегда
в корне ресурсов — возможны подпапки `init_parameters/`, `init_params/`,
`initparams/`, `prod/`, `test/` или корень. Имя файла
`{code_with_underscores}_init_params.json`. Бывают варианты `prod` и `test` —
перечислять все найденные с реальными относительными путями.

## 6. email-templates

Путь: `{processDir}/src/main/resources/{code_with_underscores}_email_templates.json`
(корень ресурсов, один файл). Шаблоны — FreeMarker, top-level ключи = имена
шаблонов. Если файла нет — секция `### Шаблоны email-уведомлений` опускается.

## 7. Сервисные переменные (orchestratorService.assets())

Три стиля вызова сосуществуют в репозитории:

- Канонический: `orchestratorService.assets().getCredentials("sap_credentials")` и
  `orchestratorService.assets().get("sap_settings")`.
- Legacy getCredentials: `orchestratorService.getCredentials("sap_credentials")`
  (без `.assets()`, встречается в `rps-sales`, `ics60187`).
- Legacy getAsset: `orchestratorService.getAsset("sap_settings")` (без
  `.assets()`, возвращает объект с `.parseJson(...)`, встречается в
  `rps-sales/GetSapReportDataStep`).

Имя ассета может быть строковым литералом (`"sap_credentials"`) **или
константой** (`SAP_CREDENTIALS_ASSET`, `SharePointModule.CREDENTIALS_ASSET`).
`analyze_process.py` разрешает константы по определениям
`String IDENTIFIER = "value"` в Java-файлах процесса. Если константа не
разрешена — имя попадёт в `warnings` как неразрешённая ссылка.

Классификация:

| Суффикс | Тип | Замечание |
|---------|-----|-----------|
| `_credentials` | credentials | строгое соглашение |
| `_settings` | settings | слабое соглашение, не универсально |
| прочее | config | например `currency_rates_config` |

## 8. Что НЕ является сервисной переменной для README

`orchestratorService.tasks()`, `.queues()`, `.files()` — это задачи, очереди
и Orchestrator Storage, не ассеты. В таблицу сервисных переменных идут только
ассеты (учётные данные, настройки, конфиги) через `getCredentials`/`get`.

## 9. Manual Tasks (MT)

Micro-transaction архитектура: процесс выставляет MT-задачу в очередь,
Orchestrator показывает форму оператору, оператор завершает задачу — процесс
принимает результат и идёт дальше. Анализатор `analyze_process.py` детерминированно
извлекает MT-блок (`hasMt`/`manualTasks`/`mtApiCredentialsAsset`).

**Формы:** `src/main/resources/actions/<mtName>.js`. Shared-файлы `core.js`,
`template.js`, `style.css` — **не формы**, анализатор их исключает.

**Канонический нейминг** (так генерирует `wf-migrate`; верифицировано по
`ics00057-accounts`):

- Имя формы `<mtName>` (kebab/snake). `camelName = lowerCamelCase(<mtName>)`,
  `pascalName = UpperCamelCase(<mtName>)`, `stepSuffix = pascalName` со срезом
  лидирующего `process_`/`process` (→ `process_new` даёт `New`).
- Поле в `InitParameters`: `<camelName>ActionLink` (хранит UUID Designer Action).
- Пара шагов: `Prepare<stepSuffix>Step` (sender — готовит задачу в очередь) /
  `Save<stepSuffix>Step` (receiver — забирает результат оператора).
- DTO результата: `model/<pascalName>Result.java`.
- 6 констант на MT: `MT_<NN>_{QUEUE_NAME,NAME,TASK_NAME,PENDING_TAG,FINAL_TAG,PROCESSED_TAG}`.
- **Связь form ↔ MT-номер:** `MT_<NN>_NAME = "<mtName>"` (имя формы) и
  `MT_<NN>_TASK_NAME = "<camelName>"` — анализатор сопоставляет форму с
  константами по любому из этих двух значений.
- `MT_<NN>_QUEUE_NAME` для MT_02+ — **ссылка на константу**
  `MT_01_QUEUE_NAME` (не литерал): `MT_02_QUEUE_NAME = MT_01_QUEUE_NAME;`.
  Анализатор разрешает её тем же механизмом, что и asset-константы
  (`_resolve_constant`), и в отчёт попадает уже литеральное значение очереди.
- `SHERPA_API_CREDENTIALS_ASSET = "sherpa_api_credentials"` — ассет, из которого
  sender читает `bearerToken` для формы; попадает в `mtApiCredentialsAsset`.

**Неканоничные процессы.** Формы и `*ActionLink`-поля могут быть, но без
`MT_<NN>_*` и/или с другим receiver-шагом. Пример: `ics60001` — формы
`document-review.js`, `document-type-policy-editor.js`, поля
`documentReviewActionLink`/`documentTypePolicyEditorActionLink`, но receiver
`SaveDialogJnaFinal`, констант `MT_0X_*` нет. Анализатор фиксирует такие MT с
`mtNumber`/`queueName`/`taskName`/тегами = `null` и добавляет `warnings`
(«non-canonical process»). В README они рендерятся как `—` со ссылкой на
`warnings`; подсекция Orchestrator setup опускается.

**Out-of-repo (в README — подсекция Orchestrator setup):** очередь(и) из
`QUEUE_NAME` (общая для MT_01, алиас для MT_02/03); триггер на Task Queue по
**final tag**, lastTask, status = **NEW** (не In Progress); asset
`sherpa_api_credentials` (login/password); Designer Action (swap pending →
final tag), UUID → `<camelName>ActionLink` в `init_params`. Это не ассеты —
см. §8 (`tasks()`/`queues()`).

**Канонический пример для сверки:** `ics00057-accounts` на ветке
`origin/feat/00057-accounts` (3 формы `process_new/changed/all.js`, 3 пары
`Prepare/Save{New,Changed,All}Step`, 3 DTO `Process{New,Changed,All}Result`,
полные `MT_01/02/03_*`). Тест `_test_ics00057_mt` в
`scripts/tests/test_analyze_process.py` фиксирует этот контракт.