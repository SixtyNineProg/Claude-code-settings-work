# ICS-00057 Обновление справочника

Первый шаг контроля ICS-00057, в рамках которого осуществляется обновление справочника релевантных для контроля счетов.

## Внешние системы и сетевые папки

- SAP — транзакция ZACCOUNTS (для получения списка счетов)
- SharePoint — vactpro.main.velcom.by (для сохранения результатов выполнения процесса)

## Ресурсы

- Orchestrator Assets
    - `sap_credentials` — логин и пароль для доступа Робота к серверу SAP
    - `sap_settings` — путь к SAP Logon (настройки подключения)
    - `sharepoint_credentials` — логин и пароль для доступа Робота к каталогам SharePoint
    - `sherpa_api_credentials` — Bearer-токен для JS-вызовов Manual Task (`/api/task/*`), передаётся в `initialData` как `bearerToken`
    - `ics00057_accounts` — JSON-состояние справочника счетов (заменяет DataStore)
    - `ics00057_comments` — JSON-состояние комментариев MT (заменяет DataStore)
- Manual Task (MT №1 «Проверка новых счетов») — Shadow Core Engine
    - Очередь Orchestrator: `ICS-00057 Обновление справочника`
    - Теги: pending `pending` → final `reviewed` → processed `processed` (после обработки `SaveNewStep` заменяет все теги задачи на `processed`)
    - Action-ссылка: `processNewActionLink` в [InitParams](src/main/resources/init_params/test/ics00057_accounts_init_params.json)
    - Триггер Orchestrator: Task Queue, очередь `ICS-00057 Обновление справочника`, условие по тегу `reviewed`, статус задачи → `In Progress`, запуск receiver-стадии (`SaveNewStep`)
    - Подпись задачи: `… | ICS-00057 Document Verification Accounting` (выравнено с ODF)
    - Скрипт формы: [actions/process_new.js](src/main/resources/actions/process_new.js) (загружается в файловое хранилище; `core.js` и `style.css` — общие из `rpa-core/src/test/resources/manualtask/`)
- Manual Task (MT №2 «Проверка изменения меток счетов») — Shadow Core Engine
    - Очередь Orchestrator: общая с MT №1 `ICS-00057 Обновление справочника` (собственные теги MT №2 не конфликтуют с тегами MT №1)
    - Теги: pending `pendingChanged` → final `reviewedChanged` → processed `processedChanged` (после обработки `SaveChangedStep` заменяет все теги задачи на `processedChanged`)
    - Action-ссылка: `processChangedActionLink` в [InitParams](src/main/resources/init_params/test/ics00057_accounts_init_params.json)
    - Триггер Orchestrator: Task Queue, очередь `ICS-00057 Обновление справочника`, условие по тегу `reviewedChanged`, статус задачи → `In Progress`, запуск receiver-шага `SaveChangedStep` (Stage3, начиная с блока `SaveChangedStep`)
    - Подпись задачи: `… | ICS-00057 Document Verification Accounting` (выравнено с ODF)
    - Скрипт формы: [actions/process_changed.js](src/main/resources/actions/process_changed.js) (загружается в файловое хранилище; `core.js` и `style.css` — общие из `rpa-core/src/test/resources/manualtask/`)
- Manual Task (MT №3 «Внесение изменений по счетам») — Shadow Core Engine
    - Очередь Orchestrator: общая с MT №1/№2 `ICS-00057 Обновление справочника` (собственные теги MT №3 не конфликтуют с тегами остальных MT)
    - Теги: pending `pendingAll` → final `reviewedAll` → processed `processedAll` (после обработки `SaveAllStep` заменяет все теги задачи на `processedAll`)
    - Action-ссылка: `processAllActionLink` в [InitParams](src/main/resources/init_params/test/ics00057_accounts_init_params.json)
    - Триггер Orchestrator: Task Queue, очередь `ICS-00057 Обновление справочника`, условие по тегу `reviewedAll`, статус задачи → `In Progress`, запуск receiver-шага `SaveAllStep` (Stage4, начиная с блока `SaveAllStep`)
    - Подпись задачи: `Прочие изменения | ICS-00057 Document Verification Accounting` (выравнено с ODF); кнопка добавления строки «Добавить строку», заголовок удаления «Удалить строку»
    - Скрипт формы: [actions/process_all.js](src/main/resources/actions/process_all.js) (загружается в файловое хранилище; `core.js` и `style.css` — общие из `rpa-core/src/test/resources/manualtask/`)
- Orchestrator Storage
    - Унифицированная структура папок (`UnifiedFoldersUtil`): `Бот/<год>/<период start-end>/<01_Обновление справочника>/<runDate per период>/` для хранения файлов выгрузки, скриншотов, чек-листов и архивов
        - `…/input data/ZACCOUNTS.xlsx` — выгрузка SAP (загружает `SapStep`)
        - `…/screenshots/screenshots.xlsx` — скриншоты экранов SAP (загружает `SapStep`)
        - `…/ICS-00057_01.xlsx` — чек-лист (загружает `UploadEvidenceStep`)
        - `…/<runDate> archive ICS-00057_01.zip` — технический архив (загружает `UploadEvidenceStep`)
    - Имена файлов в Storage плоские (Storage не поддерживает вложенность); уникальность имён обеспечивается суффиксом даты-времени `yyyyMMdd_HHmmss` через [StorageNames](src/main/java/by/a1/ics00057_accounts/utils/StorageNames.java) — единый источник имён для `SapStep` и `UploadEvidenceStep`
- [EmailTemplates](src/main/resources/ics00057_accounts_email_templates.json)
    - `process_started` — Уведомление о запуске ботопроцесса (отправляется `InfrastructureStep` через `sendProcessStarted`); мигрировано из ODF-шаблона `work_start`
    - `process_error` — Уведомление об ошибке ботопроцесса (отправляется rpa-core `HandleErrorStep`); мигрировано из ODF-шаблона `error`; ссылка «Порядок действий при возникновении ошибок» добавляется, если в init_params задан `errorHandling.errorOccursUrl`
    - `new_tasks` — Уведомление о новой задаче
    - `no_new_tasks` — Уведомление об отсутствии задач
    - `task_processed` — Уведомление об обработке задачи
    - `work_end` — Уведомление о завершении работы
- [InitParams](src/main/resources/init_params/) — параметры запуска, отдельные файлы для сред:
    - [prod](src/main/resources/init_params/prod/ics00057_accounts_init_params.json)
    - [test](src/main/resources/init_params/test/ics00057_accounts_init_params.json)
    - В случае необходимости тестирования частей процесса, не связанных с SAP, можно использовать параметр:
        - `mockSap`:
            - `true` — при установке данного значения процесс получает необходимые файлы из ресурсов
            - `false` — значение по умолчанию; осуществляется выгрузка счетов из системы SAP
    - В случае необходимости установки отчетного периода процесса, отличного от значения по умолчанию, можно воспользоваться параметрами `periodStart`, `periodEnd`. Требования:
        1. Оба параметра должны быть установлены (формат: `dd.MM.yyyy`)
        2. `periodStart` < `periodEnd`
        3. `periodEnd` < дата запуска процесса
        4. При невозможности парсинга параметров `periodStart`, `periodEnd` значение периода устанавливается по умолчанию (прошлый квартал относительно дня запуска процесса)
        5. При успешном парсинге, но невыполнении пунктов 2, 3 — процесс завершается с ошибкой
- [ProcessConfig](src/main/resources/process-config.json) — базовые параметры процесса (BP Number, BP Name, Description)

Прочее:

- Параметры запуска: [InitParameters.java](src/main/java/by/a1/ics00057_accounts/model/InitParameters.java)
- Письма: [AppNotificationService.java](src/main/java/by/a1/ics00057_accounts/service/AppNotificationService.java)
- MT №1 «Проверка новых счетов»: [actions/process_new.js](src/main/resources/actions/process_new.js)
- MT №2 «Проверка изменения меток счетов»: [actions/process_changed.js](src/main/resources/actions/process_changed.js)
- MT №3 «Внесение изменений по счетам»: [actions/process_all.js](src/main/resources/actions/process_all.js)

## Шаги (Java)

Процесс разбит на стадии (Stage1–Stage4); каждая MT-задача несёт параметр `processStage`, по которому Orchestrator-триггер запускает следующую стадию после ручной проверки контролёром.

### Stage1 — подготовка данных и MT №1

1. [InfrastructureStep](src/main/java/by/a1/ics00057_accounts/steps/InfrastructureStep.java) — подготовка инфраструктуры процесса (отчётный период, состояние справочника и комментариев из Orchestrator Assets).
2. Получение счетов из SAP. [SapStep](src/main/java/by/a1/ics00057_accounts/steps/SapStep.java)
    - Вход в SAP GUI
    - Запуск транзакции ZACCOUNTS
    - Экспорт данных в Excel
    - Создание скриншотов
    - Загрузка выгрузки и скриншотов в Orchestrator Storage (унифицированная структура папок; плоские имена через `StorageNames`)
3. Подготовка новых счетов для МТ №1. [PrepareNewStep](src/main/java/by/a1/ics00057_accounts/steps/PrepareNewStep.java)
    - Сравнение SAP данных со справочником (Orchestrator Asset)
    - Определение новых счетов
    - Создание задачи MT №1 в очереди `ICS-00057 Обновление справочника` (тег `pending`, `processStage=2`, `initialData`: счета «без меток»/«с метками», комментарии, `bearerToken`)
    - Отправка уведомления о Manual Task со ссылкой на Action
    - При отсутствии новых счетов — auto-trigger задача (тег `reviewed`, `processStage=2`) запускает Stage2 без ручной проверки

### Stage2 — обработка MT №1 и подготовка MT №2

4. Обработка результатов MT №1. [SaveNewStep](src/main/java/by/a1/ics00057_accounts/steps/SaveNewStep.java)
    - Receiver-шаг, запускается Orchestrator-триггером по тегу `reviewed`
    - Чтение результата формы из очереди (`initialData` → `processedAccounts`)
    - Сохранение результатов обработки новых счетов, обновление справочника и комментариев
5. Подготовка изм. счетов для МТ №2. [PrepareChangedStep](src/main/java/by/a1/ics00057_accounts/steps/PrepareChangedStep.java)
    - Сравнение SAP данных со справочником (из транзакции, обновлённым `SaveNewStep`)
    - Определение счетов с измененными метками (редактируемые «без меток» / неизменяемые «с метками»)
    - Создание задачи MT №2 в очереди `ICS-00057 Обновление справочника` (тег `pendingChanged`, `processStage=3`, `initialData`: счета «без меток»/«с метками», комментарии, `bearerToken`)
    - Отправка уведомления о Manual Task со ссылкой на Action
    - При отсутствии изменений — auto-trigger задача (тег `reviewedChanged`, `processStage=3`) запускает Stage3 без ручной проверки

### Stage3 — обработка MT №2 и подготовка MT №3

6. Обработка результатов MT №2. [SaveChangedStep](src/main/java/by/a1/ics00057_accounts/steps/SaveChangedStep.java)
    - Receiver-шаг, запускается Orchestrator-триггером по тегу `reviewedChanged`
    - Чтение результата формы из очереди (`initialData` → `processedAccounts`)
    - Сохранение результатов обработки измененных счетов, обновление справочника и комментариев
7. Подготовка МТ №3. [PrepareAllStep](src/main/java/by/a1/ics00057_accounts/steps/PrepareAllStep.java)
    - Чтение полного справочника из транзакции
    - Создание задачи MT №3 в очереди `ICS-00057 Обновление справочника` (тег `pendingAll`, `processStage=4`, `initialData`: весь справочник `allAccounts` для autocomplete, комментарии, `bearerToken`)
    - Отправка уведомления о Manual Task со ссылкой на Action
    - Задача безусловна (контролёр сам определяет счета для корректировки) — auto-trigger ветка отсутствует

### Stage4 — обработка MT №3 и выгрузка результатов

8. Обработка результатов MT №3. [SaveAllStep](src/main/java/by/a1/ics00057_accounts/steps/SaveAllStep.java)
    - Receiver-шаг, запускается Orchestrator-триггером по тегу `reviewedAll`
    - Чтение результата формы из очереди (`initialData` → `processedAccounts`)
    - Сохранение результатов корректировок, обновление справочника и комментариев
    - Финализация задачи (SUCCESS + тег `processedAll`) и запуск `UploadEvidenceStep`
9. Загрузка результатов на SharePoint и Orchestrator Storage. [UploadEvidenceStep](src/main/java/by/a1/ics00057_accounts/steps/UploadEvidenceStep.java)
    - Скачивание выгрузки и скриншотов из Orchestrator Storage
    - Формирование чек-листа
    - Создание ZIP архива
    - Загрузка чек-листа и архива в Orchestrator Storage
    - Загрузка на SharePoint
    - Обновление Orchestrator Assets (состояние счетов и комментариев)