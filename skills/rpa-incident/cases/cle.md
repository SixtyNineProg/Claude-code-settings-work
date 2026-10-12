# Кейсы по процессам CLE (CLE-Upload)

Семейство процессов: `CLE-Upload` (BCB `cle-upload-bcb`, бизнес-процесс `CLE-Upload v1.0.x`).
Компонент Jira: `B2B_BSD`. Назначение: получение приказов об увольнении из JSD (проект CSG), поиск телефонов сотрудников через OpenAPI (VIX/BSCS), рассылка SMS.

Поток данных: JSD (проект CSG) → `GetJsdDataProcessor` (парсинг комментариев + маппа компаний) → `GetPhoneNumberProcessor` (OpenAPI по customer_id) → `SendSmsProcessor`.
Init-параметры (включая JSON `companies` имя→customer_id) лежат в DataStore на сервере, в zip бизнес-процесса не входят.

---

## Кейс 1 — Company "А1" Сербия not founded

**Jira:** RPA-18128
**Дата:** 2026-08-02 19:30 (плановый запуск)
**Шаг:** `CLE-Upload Get JSD Data` (cle-upload RPA/BCB v1.0.0)
**Hit ID:** 16604022
**Обрабатываемый JSD-тикет:** CSG-44063

### Сигнатура ошибки
`AppProcessException: Company "А1" Сербия not founded`
в `by.a1.cle_upload.processor.GetJsdDataProcessor.getCompanyId` (строка 177).

### Причина
`getCompanyId` (`GetJsdDataProcessor.java:170-178`) ищет точное совпадение (`company::equals`) имени компании, извлечённого regex-группой 3 из комментария JSD-тикета, среди ключей маппы `companies` из init-параметра DataStore. Маппа сопоставляет отображаемое имя компании → customer_id в биллинговом OpenAPI.

В приказе впервые появился сотрудник сербского филиала: `Кирдей Роман Игоревич (таб.номер 1200006 /"А1" Сербия/...)`. Ключа `"А1" Сербия` в JSON `companies` на проде нет → `orElseThrow` роняет весь шаг.

Категория: **конфигурация** (отсутствует маппинг новой компании) + **баг-робастности кода** (одна неизвестная компания валит весь батч).

### Механика
- Шаг `Get JSD Data` при каждом запуске заново читает JSD-тикет через JQL — repair упавшего шага перечитывает CSG-44063 и парсит заново → та же ошибка. Два repair-запуска воспроизвели ошибку (подтверждено events: 2 ERROR-события).
- Crash происходит на этапе парсинга (`getEmployeesFromIssues` → `getEmployeesInfoFromComment` → `getCompanyId`), ДО `removeProcessedEmployees` — фильтр уже-обработанных не спасает, т.к. падение идёт в `map` до `removeIf`.

### Нюанс кода
- `getCompanyId` сравнивает сырую строку из JSD без `StringUtils.normalizeCyrillic` (в отличие от ФИО). Ключ должен совпадать буквально, включая кавычки `"А1"`. Если в JSD когда-то придут look-alike символы (неразрывный пробел, латинская 'A') — маппинг промахнётся даже для существующей компании.

### Решение
- **Быстро (данные):** убрать строку сотрудника Сербии из комментария CSG-44063 (Сербия вне зоны BY-биллинга) → repair с шага `Get JSD Data`. Не перманентно — следующий приказ по Сербии снова упадёт.
- **Перманентно (код):** в `getEmployeesInfoFromComment`/`getCompanyId` не падать при отсутствии компании, а пропускать/логировать такого сотрудника. Требует сборки + деплоя.
- **Доп. вариант:** добавить `"А1" Сербия` → customer_id в JSON `companies`, НО только если у Сербии есть реальный customer_id в BY OpenAPI; иначе упадёт следующий шаг `GetPhoneNumberProcessor.getCustomerInfo`.

### Repair note
Repair упавшего шага `Get JSD Data` **воспроизводит ошибку** (данные JSD те же). Поможет только после изменения источника (JSD-комментарий) ИЛИ кода ИЛИ маппы companies.

### Затронутые процессы
CLE-Upload (единственный процесс семейства). Общая библиотека `a1lib` не затронута — баг локален в `cle-upload-bcb`.