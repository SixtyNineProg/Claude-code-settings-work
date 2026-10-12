# UCG — Кейсы инцидентов

Решённые инциденты для семейства процессов UCG (UCG, UCG-v2, UCG-processor).

---

## Кейс 1: UCG-Flow — OpenAPI 401 «Ошибка проверки ключа доступа» на subscription/customer

**Дата:** 2026-09-28
**Jira:** RPA-18051
**Процесс:** UCG-Flow (Sherpa, порт UCG-processor/UCG-v2)
**Шаг:** DataProcessorStep (чтение данных BSCS через BscsReportService)
**Сигнатура ошибки:** `OpenApiException: OpenApi response status: code: '401'; message: 'Unauthorized'; body: '{"code":40,"message":"Ошибка проверки ключа доступа"}'`
**Категория причины:** Баг кода (потеря заголовка при переносе с WF) + Конфигурация (набор заголовков)
**Причина:** `BscsReportService.HEADERS` шлёт `X-Client-AuthType: USERNAME` без `X-Client-Login`; при AuthType=USERNAME шлюз A1TAG считает незаполненный login отсутствующим ключом доступа и отдаёт 401 code 40.
**Данные-триггер:** любой запуск — падают ровно те два вызова, которые rpa-core выполняет без msisdn: `partyManagement().getSubscriptionInfoById` (BscsReportService:188) и `customerManagement().getCustomerInfoById` (:150). Остальные три вызова (`federatedId().getUserInfo`, `customerBillManagement().getCallDetailsByMsisdn`, `...getBillDetailsBySubId`) login подставляют сами (`withXClientLogin(msisdn)`) и проходят.
**Исправление (код):** добавить `X-Client-Login` в константу `HEADERS` (`BscsReportService`) либо вызывать `withXClientLogin(...)` в двух местах. Значение не влияет на состав данных (сверено: ответы байт-в-байт одинаковы при login = `0`, real msisdn, WF-номере) — проверено `0`, `375296513255`, `375293101988`, msisdn подписки: все 200.
**Исправление (данные):** не требуется.
**Repair:** шаг DataProcessorStep идемпотентен по входам (данные читаются из транзакции/файла); после деплоя фикса — repair упавшего шага, заново передавать форму не нужно. До деплоя repair бессмысленен — тот же 401.
**Общая папка:** не затрагивается (обмена файлами нет, вход — задача Orchestrator + Orchestrator Storage).
**Исторический прецедент:** WF-процесс UCG-processor (`by.a1.lib.open_api.UserUtils`, строки DataStore `subscription_info` / `customer_info`) — там `X-Client-Login` был в заголовках каждой строки. Экспорт: `~/Downloads/open_api_credentials.{csv,json}`, исходники: `~/IdeaProjects/wf_odf/ODF/ucg-v2/UCG-processor`.
**Затронутые процессы:** потенциально любой процесс Sherpa, который зовёт типизированные методы rpa-core без msisdn (`getSubscriptionInfoById`, `getSubscriptionInfoByBillingAccount`, `getCustomerInfoById`) и при этом сам задаёт заголовки вместо ассета `openapi_default_headers`: проверены `ucg-flow`, `stb-bills`, `stb-terminate`, `opi-flow` — у них заголовки из ассета, где `X-Client-Login: 0` присутствует, поэтому они не падают.

---

## Шаблон нового кейса

```
## Кейс N: [Краткое название]

**Дата:** ГГГГ-ММ-ДД
**Jira:** RPA-XXXXX
**Процесс:** [Название процесса]
**Шаг:** [Название шага]
**Сигнатура ошибки:** [Класс исключения + отличительная часть сообщения]
**Категория причины:** Качество данных / Баг кода / Инфраструктура / Конфигурация
**Причина:** [Одно предложение]
**Данные-триггер:** [Какие входные данные вызвали сбой]
**Исправление (код):** [Изменение кода, если есть]
**Исправление (данные):** [Изменение данных, если есть]
**Repair:** [Работает ли repair упавшего шага? С какого шага нужно repair?]
**Общая папка:** [Оценка риска конфликта при возврате файлов]
**Исторический прецедент:** [Связанные Jira-тикеты]
**Затронутые процессы:** [Другие процессы с тем же багом]
```