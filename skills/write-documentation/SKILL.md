---
name: write-documentation
description: Генерирует полный комплект HTML-документации для RPA-процесса Sherpa (PDD, UG, TD, инструкция по развёртыванию, история изменений, обзорную страницу и по одному файлу на каждый Step) из шаблонов DemoBP на основе анализа Java-кода, process-config.json, init_params, email-templates и .process-файла. Используй этот skill всегда, когда пользователь просит создать/сгенерировать/обновить документацию для RPA-процесса, упоминает PDD, UG, TD, инструкцию по развёртыванию, историю изменений, «документацию Sherpa» или хочет описать/задокументировать ботопроцесс для модуля ics*/rps-*/ipe — даже если навык не назван явно. Также применяй, когда просят «описать процесс», «сделать PDD» или «подготовить документацию к релизу» для RPA-модуля. НЕ используй для написания README.md (есть отдельный навык write_readme) и не путай с обычной Java-Java-документацией.
---

# write_documentation

Генерирует полный комплект HTML-документации для RPA-процесса на платформе Sherpa, используя шаблоны DemoBP из `references/templates/` как основу и данные из исходного кода процесса.

## ⚠️ КРИТИЧЕСКИЕ ПРАВИЛА (читай первым делом)

1. **Все файлы DemoBP — HTML-фрагменты БЕЗ обёртки.** Не добавляй `<!DOCTYPE>`, `<html>`, `<head>`, `<body>`, `<style>`. Эти фрагменты встраиваются в большую систему документации, которая сама подставляет обёртку — любая обёртка сломает вёрстку.
2. **Копируй ТОЧНУЮ структуру шаблона** — таблицы, заголовки, списки, `rowspan`, количество колонок и порядок строк должны совпадать с DemoBP-шаблоном. Структура — это контракт; отступления недопустимы.
3. **Создавай только файлы из Template Mapping.** Никаких «Technical Design», «Architecture», диаграмм классов и т.п. — только перечисленные ниже.
4. **Читай шаблоны DemoBP как образцы.** Каждый файл из `references/templates/` читай перед заполнением — это твоя структура.
5. **Используй Sequential Thinking** для анализа кода и построения документации шаг за шагом — это многоэтапная задача, поспешное обобщение ведёт к ошибкам.

## Вход

- **processDir** (обязательно): путь к директории процесса (например, `rpa-suite/ics00057-accounts`). Если путь не указан явно, уточни у пользователя.

## Выход

Все файлы пишутся в `{processDir}/src/main/resources/documentation/`:

| Файл | Источник данных |
| ----------------------------------------------------- | ---------------------- |
| `{bpName}.html` | README.md (обзорная страница) |
| `{bpName} - История изменений.html` | Шаблон (placeholder-строка) |
| `{bpName} - Инструкция по развертыванию.html` | Шаблон + credentials/assets из Java |
| `{bpName}-PDD - Process Design Document.html` | Все источники |
| `{bpName}-Step-{NN}.html` | Один на каждый шаг сценария (Java `*Step.java` + самостоятельный MT/web-action) |
| `{bpName}-TD - Test Documentation.html` | Шаблон (placeholder) |
| `{bpName}-UG - User Guide.html` | PDD + Java Steps |

`{bpName}` берётся из `process-config.json` (поле `bpName`). Имена файлов следуют соглашению модуля ics60001: `{bpName}-Step-01.html`, `{bpName}-Step-02.html` и т.д. (без описательного суффикса в имени файла, описание идёт внутрь).

## Порядок работы

### 1. Собрать метаданные процесса

Прочитай и извлеки данные из (пути относительно `processDir`):

- `src/main/resources/process-config.json` → `bpName`, `bpNumber`, `bpDescription`, `controlName`, `processName`. Все четыре поля нужны — они используются в PDD и в шаблонах писем (`${bpName}`, `${bpNumber}`, `${bpDescription}`).
- `src/main/resources/init_params/prod/<module>_init_params.json` (и `test/` при наличии) → все ключи верхнего уровня. Это конфигурируемые параметры процесса. Путь содержит подпапки `prod/`/`test/`.
- `src/main/resources/<module>_email_templates.json` → ключи (имена шаблонов) + их `subjectTemplate`/`bodyTemplate` (FreeMarker `${...}`).
- `README.md` в корне процесса → описание, обзор, поток, внешние системы, credentials.

`bpName` используется как `{ProcessName}` во всех именах файлов и кросс-ссылках.

### 2. Проанализировать Java-исходники

Java-пакет: `by.a1.<module_with_underscores>` (дефисы модуля заменяются на подчёркивания, например `ics00057-accounts` → `by.a1.ics00057_accounts`).

Структура под `src/main/java/by/a1/<package>/`:

- `steps/*Step.java` — шаги процесса.
- `model/*.java` — модели данных (включая `InitParameters`).
- `transaction/ProcessTransaction.java` + `ProcessDataKeys.java` — хранение данных между шагами.

**Для каждого Step-класса извлеки:**
- `@StepName("...")` → имя шага.
- Поля и `@Inject`-зависимости конструктора → используемые сервисы.
- Тело `execute(Transaction transaction, List<String> args)` → действия Бота (основной путь).
- `orchestratorService.assets().getCredentials(ASSET).execute()` → credentials (конфиденциальные значения).
- `orchestratorService.assets().get(ASSET).execute().parseJson(Class.class)` → assets (прочие ресурсы).
- `emailService.send*(...)` **и** вызовы через сервис-обёртки (например `AppNotificationService`, `sendByTemplateName`) → отправляемые нотификации. Не ограничивайся прямыми вызовами `emailService` — email часто инкапсулирован в отдельном сервисе.
- `throw new BusinessException(...)` → возможные исключения (для таблицы Exceptions).

**Для model-классов:** поля `InitParameters` → конфигурируемые параметры; поля других моделей → структура данных.

**Для ProcessTransaction:** методы `get*()`/`set*()` → данные, передаваемые между шагами. Ключи лежат в `ProcessDataKeys.java` (строковые константы) — это паттерн «ключи отдельно, типизированные аксессоры отдельно».

### 3. Определить шаги сценария и их порядок

Шаги документации (`Step-NN` файлы) соответствуют **шагам сценария выполнения процесса**, а не только Java-классам. Шаг сценария — это либо:

- **Java Step** — класс `*Step.java` с `@StepName` (выполняется Ботом); или
- **Manual Task / web-action** — пользовательское действие Исполнителя (форма Shadow Core Engine, `actions/*.js`), которое README или `.process` **явно перечисляют как отдельный шаг** сценария (например «контролёр проверяет и заполняет форму»). Такие шаги получают свой `Step-NN` файл с `Пользователь` = `Исполнитель`.

⚠️ **Не выделяй отдельный `Step-NN` для MT, который срабатывает внутри Java-шага** (например Java-шаг создаёт задачу в очереди и тот же шаг/приёмник её обрабатывает). Внутренние MT описываются внутри файла соответствующего Java-шага (в «Основной путь»/«Альтернативные пути»), а самостоятельные пользовательские действия Исполнителя, имеющие собственную форму и явно входящие в сценарий, — отдельным `Step-NN`.

Признак отдельного MT-шага: README описывает его как самостоятельный этап с действиями Исполнителя (не Бота), или `.process`/`actions/` содержат отдельную web-форму (`process_*.js`), которую Исполнитель заполняет между Java-шагами. Пример: ics60001 — 8 Java-шагов + 2 web-action (document-type-policy-editor, document-review) = 10 `Step-NN` файлов.

Прочитай `.process`-файлы в корне процесса: `Главная.process` (основная диаграмма) и `Stage{N}.process` (по стадиям), а также `README.md` (раздел про поток/MT) и `src/main/resources/actions/*.js` (список web-форм).

⚠️ **Важно:** `.process`-файлы — это XML в формате Sherpa Designer. `$StepName` встречается только как placeholder `$StepName={{{StepName}}}` (Mustache) внутри `<Content>`-блоков designer-блоков. **Не ищи** литералы вида `$StepName="prepareInitialParameters"` — их там нет.

Алгоритм определения порядка:
1. Собери множество шагов сценария: все Java `*Step.java` + все самостоятельные MT/web-action из README/`actions/`.
2. Найди последовательность designer-блоков в `Главная.process` / `Stage{N}.process` и сопоставь с шагами по имени.
3. MT/web-action располагаются в порядке между Java-шагами согласно потоку в README (кто чьи выходные данные обрабатывает).
4. **Если порядок неоднозначен** — восстанови по потоку данных `execute()`: какой Step вычисляет выходные данные, потребляемые следующим (через `ProcessTransaction.get*()`). Это надёжная эвристика, потому что шаги образуют конвейер данных.

Порядок определяет нумерацию `Step-NN`, записи в PDD «Сценарий использования» и таблицу шагов в UG.

### 4. Определить используемые системы

Анализируй импорты в Java-файлах. Полная таблица — в `references/source-mapping.md`. Краткая сводка:

| Импорт | Система |
| ------------------------------------- | ---------------------- |
| `by.a1.rpa.core.*` | RPA core / framework |
| `by.a1.rpa.orchestrator.*` | Sherpa Orchestrator (assets, files, tasks, storage) |
| `by.a1.rpa.sapgui.*` | SAP GUI automation |
| `by.a1.rpa.jira.*` | Jira / JSD |
| `by.a1.rpa.email.*` | Email (SMTP) |
| `by.a1.rpa.folders.*` | Unified storage folders |
| `org.apache.poi.*` | Excel (Apache POI) — обычно в `excel/`-хелперах, не в Steps |
| `com.google.gson.*` | JSON-сериализация |
| `HttpURLConnection`, `java.net.URL` | Внешний HTTP API |

### 5. Сгенерировать README.md (если отсутствует)

Если в корне процесса нет `README.md`, сгенерируй его по шаблону:

```markdown
# Процесс {bpName}

Автоматизированный процесс RPA для выполнения бизнес-логики.

## Обзор

**Бизнес-процесс**: "{bpDescription из process-config.json или описание из кода}"

Этот процесс автоматизирует:
- {Действие шага 1}
- {Действие шага 2}

## Поток процесса

### 1. {StepName1}
{Описание из Java-кода}

### 2. {StepName2}
{Описание из Java-кода}

## Email шаблоны
- `{template_name}` - {Описание из email_templates.json}

## Внешние учетные данные
- `{credential_name}`: {Описание из кода}
```

### 6. Сгенерировать HTML-файлы документации

Для каждого файла из Template Mapping:
1. Прочитай соответствующий шаблон из `references/templates/`.
2. Замени `DemoBP` → `{bpName}` во всём файле (включая кросс-ссылки и ID).
3. Заполни placeholder-ы реальными данными из шагов 1–4.
4. Сохрани в `{processDir}/src/main/resources/documentation/`.

Точная структура каждого файла (какие таблицы, сколько колонок, какие строки) описана в `references/template-anatomy.md` — открой её при заполнении каждого файла, чтобы не отклониться от структуры.

**Где брать данные для placeholder-ов:**

| Placeholder в шаблоне | Источник |
| --------------------------------------------------- | -------------------------------------------- |
| `DemoBP` / `Демонстрационный бизнес-процесс` | `bpName` / `bpDescription` из process-config.json |
| Описание процесса | README.md → Обзор |
| Используемые системы | Анализ Java-импортов (шаг 4) |
| Конфигурируемые параметры | init_params.json (все ключи верхнего уровня) |
| Нотификации | email_templates.json (все ключи + subject/body) |
| Конфиденциальные значения | `getCredentials()` вызовы в Java |
| Прочие ресурсы | `assets().get()` вызовы в Java |
| Описание шагов | Java Step-классы (шаг 2) |
| Порядок шагов | `.process` файл (шаг 3) |
| Исключения | `throw new BusinessException` в Java |

### 7. Проверить результат

Убедись, что:
- Все файлы созданы в `{processDir}/src/main/resources/documentation/`.
- Количество `Step-NN` файлов = количеству шагов сценария (Java `*Step.java` + самостоятельные MT/web-action, явно перечисленные в README/`actions/`). Внутренние MT не учитываются отдельно.
- Кросс-ссылки используют единый формат ID: `{bpName}-Step-0N`, `{bpName}-EX-NN`, `{bpName}-PDD/TD/UG`.
- Нет пустых placeholder-ов (кроме явно помеченных TBD).
- Ни один файл не содержит `<!DOCTYPE`, `<html`, `<head`, `<body`.
- В тексте не осталось литерала `DemoBP` (кроме случаев, где это действительно уместно).

## Template Mapping (DemoBP → Процесс)

```
DemoBP файл                                           →  {bpName} файл
────────────────────────────────────────────────────────────────────────────────────
DemoBP - Демонстрационный бизнес-процесс.html         →  {bpName}.html
DemoBP - История изменений.html                       →  {bpName} - История изменений.html
DemoBP - Инструкция по развертыванию.html             →  {bpName} - Инструкция по развертыванию.html
DemoBP-PDD - Process Design Document...html           →  {bpName}-PDD - Process Design Document.html
DemoBP-Step-01. Начало работы.html                    →  {bpName}-Step-01.html
DemoBP-Step-02. ...html                               →  {bpName}-Step-02.html
DemoBP-TD - Test Documentation...html                 →  {bpName}-TD - Test Documentation.html
DemoBP-UG - User Guide...html                        →  {bpName}-UG - User Guide.html
```

## Style Guidelines

- Активный залог: «Бот проверяет» вместо «Проверяется».
- Предложения до 20 слов.
- Конкретные формулировки: «orderId — числовой, > 0» вместо «проверяет корректность».
- Единый термин: «бот» (с маленькой буквы), «процесс», «Исполнитель».
- ID исключений: формат `{bpName}-EX-01`.

## Ссылки на ресурсы

- `references/template-anatomy.md` — точная структура каждого DemoBP-шаблона (колонки, строки, ID). Открывай при заполнении соответствующего файла.
- `references/source-mapping.md` — полная таблица import→system, паттерн ProcessDataKeys/ProcessTransaction, подробности чтения `.process` XML.
- `references/templates/` — 10 исходных DemoBP HTML-шаблонов (читай как образцы структуры).