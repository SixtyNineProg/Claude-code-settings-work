# ChargesGSM — Кейсы инцидентов

Семейство процессов: ChargesGSM (RPA/BCB v1.0.2)
Платформа: WorkFusion ODF
Пул-ключ: `INTAKE_CGM_MANUAL_POOL_KEY`
Шаги: Infrastructure → GetDataFromBSCS → ExcelUpload

---

## Кейс 1 — Secrets Vault недоступен (Connection refused)

**Дата:** 2026-06-22
**Сигнатура ошибки:** `ResourceAccessException: Connection refused` + `secrets-vault-get alias='Workspace_url'`
**Шаг:** ExcelUpload
**Статус:** ✅ Решено (самовосстановление)

### Описание

Шаг ExcelUpload падал с ошибкой `PluginException: Failed to execute object-pool body` на 3 Hit ID (16152319, 16152409, 16152438) в период 06:01–06:24 22.06.2026.

Корневая причина: агент не мог подключиться к локальному Secrets Vault сервису на `http://127.0.0.1:7081/workfusion/internal-api/v1/secrets-vault/entry` (Connection refused).

### Цепочка вызовов

```
ExcelUpload.xml → ChargesApp.init() → AppNotificationModule.getServiceEmail()
  → getNotificationServiceDirector() → getDefaultValues()
    → SVParamsWorkspaceUrl.getWorkspaceUrl()
      → SecretsVaultGetPlugin → POST http://127.0.0.1:7081/.../secrets-vault/entry
        → Connection refused!
```

### Категория

Инфраструктура — Secrets Vault сервис на агенте был недоступен.

### Почему процесс «завис»

Pool-конфигурация: `wait-timeout="86400000"` (24 часа), `polling-interval="300000"` (5 мин). Система повторяла попытки каждые 5 минут, создавая впечатление «зависшего» процесса.

### Восстановление

После ~06:24 Secrets Vault сервис восстановился, и последующие Hit ID (начиная с 16152705 в 07:40) завершились успешно.

### Repair note

- Repair упавшего шага **не поможет**, если Secrets Vault всё ещё недоступен.
- Если Secrets Vault восстановлен — repair упавшего шага **может сработать**, т.к. ошибка возникает на этапе инициализации (до обработки данных).
- Альтернатива: новый запуск процесса.

### Рекомендация

1. **Краткосрочно:** Проверить доступность Secrets Vault на агенте (порт 7081) перед запуском процесса.
2. **Долгосрочно:** Добавить resilient-обработку в `AppNotificationModule` — при недоступности Secrets Vault логировать warning и продолжать без email-уведомлений, а не падать.

### Затронутые процессы

Все процессы, использующие `BaseNotificationModule` → `SVParamsWorkspaceUrl` из a1lib, потенциально подвержены этой же проблеме при недоступности Secrets Vault.

---

## Кейс 2 — HTTP 400: некодированный `+` смещения часового пояса в query

**Дата:** 2026-10-06
**Процесс:** charges-gsm-flow (Sherpa-порт ChargesGSM)
**Jira:** RPA-18027
**Шаг:** GetDataFromBSCSStep
**Сигнатура ошибки:** `OpenApiException: OpenAPI request failed with status 400` + `customerBillManagement/v2/customerBill` + `startDate=…T23:59:00.000+0X:00` (сырой `+` в query вместо `%2B`)
**Категория причины:** Баг кода — некодированная подстановка значения в query-строку
**Статус:** ✅ Исправлено в коде + покрыто тестом (подтверждение на QA ожидается)

### Описание

На тестовом прогоне ветки `feat/ChargesGSM-RPA-18027` (QA: `srv-lb-qa:8084`) шаг
`GetDataFromBSCSStep` упал на первом же обращении к BSCS/VIX:

```
OpenAPI request failed with status 400: /A1TAG/customerBillManagement/v2/customerBill
  ?billingAccount.id=199&startDate=2026-06-02T23:59:00.000+03:00&endDate=2026-11-02T23:59:00.000+03:00
```

### Цепочка вызовов

```
GetDataFromBSCSStep.execute(:99) → writeContractFile(:155) → fillSheet(:172)
  → ChargesOpenApi.getBillsByPeriod(:109)
    → executeQuery(:339) → executeGet(:365)  ← статус 400
```

### Корневая причина

`ChargesOpenApi.getBillsByPeriod` собирал query через `formatZoned` **без кодирования**.
`formatZonedDate` форматирует зону `Europe/Minsk` шаблоном `yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ`; пять
букв `Z` дают смещение со знаком «плюс»: `2026-06-02T23:59:00.000+03:00`.

`+` легален в query по RFC 3986, поэтому `new HttpGet(...)` собирался без ошибки и `+` уходил по
проводу как есть. Но сервер разбирает query по правилам `application/x-www-form-urlencoded`, где `+`
означает **пробел**: до него доезжало `2026-06-02T23:59:00.000 03:00` → разбор даты падал → 400.

В том же файле три точки сборки query, кодирование было только в двух:

| Эндпоинт | Дата с `+` | Кодирование (до правки) |
|---|---|---|
| `CUSTOMER_BILL_ENDPOINT` | да | ❌ отсутствовало |
| `APPLIED_BILLING_RATE_BY_BILL_ENDPOINT` | нет (`billNo`) | ⚠️ `.replace("\\+", "%2B")` — no-op: `String.replace` искал литерал `\+` |
| `INSTANT_BILL_ENDPOINT` | да | ✅ `.replaceAll("\\+", "%2B")` |

Все три написаны одним коммитом переноса из WorkFusion (`2ac40ba4`); `getBillsByPeriod` пропустили.

### Исправление

Кодирование перенесено в единственную точку подстановки значений — `ChargesOpenApi.formatZoned`:

```java
static String formatZoned(String pattern, Object... arguments) {
  return String.format(pattern, arguments).replace("+", "%2B");
}
```

Обе ручные замены на точках вызова удалены (DRY). Разместить кодирование в `executeGet` нельзя: он
получает путь *вместе* с query, и сплошное кодирование уничтожило бы `/`, `?`, `=`, `&`.

Тест `formatZonedShouldEncodeTheTimezoneOffsetOfTheCustomerBillQuery` воспроизводил продовую строку
байт-в-байт до правки и проходит после. Проводная форма `getQuickCharge` не изменилась (там был
`%2B`) — регресс на проверенном пути исключён.

### Repair note

- Repair/перезапуск шага к правке отношения не имеют: дефект в **коде**, нужна пересборка
  `charges-gsm-flow-1.0.0.jar` и деплой шага.
- Данные корректны, перечитывать входные файлы не требуется.

### Затронутые процессы

Дефект уникален для `charges-gsm-flow`. Проверено по `rpa-suite`: `cle-processing`, `cle-upload`,
`aci`, `aalc`, `fsd-flow` кодируют параметры через `URLEncoder.encode`; `stb-bills` идёт через
`rpa-core`'s `OpenApiClient.customClient().withQueryParam(...)` и форматирует даты литералом `'Z'`;
`charges-gsm-manual` OpenAPI не вызывает.

### Рекомендация (долгосрочно)

Перевести `ChargesOpenApi` на типизированный клиент `rpa-core` —
`OpenApiClient.customerBillManagement()` (TMF678): он связывает параметры через OkHttp и шлёт даты в
UTC-`Z` (`Instant.toString()`), где `+` не возникает вовсе. Это устранит класс ошибки целиком, но
требует перепрошивки заголовков через `OpenApiConfig` и переработки семантики ошибок — отдельная
задача.

### Диагностируемость (сопутствующее)

`ChargesOpenApi.executeGet` выбрасывает тело ответа при не-2xx. Тело 400 почти наверняка называло
проблемный параметр, и диагноз занял бы минуты. Политика репозитория запрещает класть тело в
`OpenApiException`, поэтому правильная форма — `log.warn` с усечённым телом.

---

## Кейс 3 — IllegalAccessError: Spire.XLS обращается к внутреннему API JDK

**Дата:** 2026-10-06
**Процесс:** charges-gsm-flow (Sherpa-порт ChargesGSM)
**Jira:** RPA-18027
**Шаг:** ExcelStep
**Сигнатура ошибки:** `IllegalAccessError` + `class com.spire.xls.packages.sprRFA (in unnamed module …) cannot access class sun.security.action.GetPropertyAction (in module java.base)`
**Категория причины:** Зависимость — несовместимость библиотеки с рантаймом (JDK 21, система модулей)
**Статус:** ✅ Исправлено (бамп версии зависимости), подтверждено тестом

### Описание

Шаг `ExcelStep` падал на рендере PNG-скриншотов Excel, которые прикрепляются к тикету JSD: на
`new Workbook()` бросался `IllegalAccessError`. Ошибка не зависела от входных данных — рендер не
работал ни разу с момента переноса процесса на Sherpa.

### Цепочка вызовов

```
ExcelStep.execute(:107) → processFile(:171) → renderScreenshots(:242)
  → makeScreenshot(:275) → Screenshots.makeScreenshot(:32)
    → ExcelConverter.convert(:33)   ← new Workbook()
      → XlsWorkbook.<init> → sprHTa → sprksa → sprRFA.<init> → sprRFA.spr   ← IllegalAccessError
```

### Корневая причина

Класс `com.spire.xls.packages.sprRFA` из `e-iceblue:spire.xls.free:5.1.0` напрямую инстанцирует
`sun.security.action.GetPropertyAction`. В JDK 21 `java.base` отдаёт пакет `sun.security.action`
только модулям `jdk.crypto.ec`, `java.desktop`, `java.security.jgss` — в unnamed-модуль экспорта
нет. Шаг собирается под Java 21 и запускается лаунчером Sherpa как `java -jar <jar>`, поэтому весь
код, включая Spire внутри shadow-jar, лежит в unnamed-модуле → доступ запрещён всегда.

Проверено инструментально: `javap` по `sprRFA` из 5.1.0 даёт `new sun/security/action/GetPropertyAction`,
а `java --describe-module java.base` подтверждает квалифицированный экспорт без unnamed.

### Исправление

`charges-gsm-flow/build.gradle`: `e-iceblue:spire.xls.free` **5.1.0 → 5.3.0**. В 5.3.0 обращений к
`sun/…` и `com/sun/…` нет вообще (обзорный скан всех классов jar — пусто), поэтому атрибут
манифеста `Add-Exports` не понадобился.

Тест `ExcelConverterTest` воспроизводил продовое падение до правки (RED: `IllegalAccessError`,
кадр `sprRFA.spr (Unknown Source)` — как в проде) и проходит после (GREEN).

### Repair note

- Repair/перезапуск шага сами по себе не помогают: меняется **артефакт** шага (jar), нужна
  пересборка `charges-gsm-flow-1.0.0.jar` и деплой шага.
- Данные корректны, перечитывать входные файлы не требуется.

### Затронутые процессы

Дефект уникален для `charges-gsm-flow`: Spire объявлен только в этом модуле, других рендереров
XLSX → PNG в `rpa-suite` нет (проверено по всем `build.gradle`). Остальные «скриншоты» в репозитории
(`ics00074`, `ics00080`, `ics60018`, `ics60185`, `ics60207`, `ics60210`, `ics60230-*`) снимают
экран через `java.awt.Robot` и к Excel отношения не имеют.

### Остаточный риск (не снят бампом)

Лимиты бесплатной редакции Spire (порядка 5 листов / 200 строк на лист) версией не снимаются, а
усечение может быть **молчаливым** — тогда в тикете заказчика окажется неполное доказательство.
Тест с блоком 250 строк проверяет, что картинка выше, чем для блока в 1 строку, но точную границу
не ловит: нужен визуальный контроль на реальном файле. Если усечение подтвердится, правильный
ответ — отказ от Spire в пользу рендера через Apache POI + Java2D (POI в модуле уже есть).