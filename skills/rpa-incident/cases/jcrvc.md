# Кейсы инцидентов — JCRVC

Семейство процессов: **JCRVC** (JSD comments registration as VIX contacts).
Компонент Jira: `B2B_BSD`. Процесс живёт в `ODF/jcrvc`.

## Поток данных

| Этап | Где | Что делает |
|------|-----|------------|
| Source | Jira Service Desk (проект `GPU`, JQL) | Бот ищет «Сервисные заявки», обновлённые за период, с заполненным `cf[10201]` (тип услуги) |
| Step 1 — `GetJsdDataProcessor` | JSD REST API | Тянет обновлённые issues + их комментарии, сериализует в `UPDATED_ISSUES_JSON` |
| Step 2 — `PrepareTickerDataProcessor` | `CommentProcessingServiceImpl` | Фильтрует комментарии по формату и периоду, проверяет обязательные поля, собирает `PreparedTicklerDTO` |
| Step 3 — `CreateTicklersProcessor` | VIX API (`getSubscriptionInfoByAcc`) | Создаёт tickler-контакты в VIX по `billingId` |
| Step 4 — `WorkEndProcessor` | DataStore `jcrvc_common` | Обновляет `last_check_date_time` = `startTime` (чекпойнт следующего запуска) + финишное письмо |

**Гранулярность транзакции:** `InfrastructureSupplier.get()` возвращает **одну транзакцию на весь запуск** (`Collections.singletonList`). Весь батч issues = одна транзакция → одна битая запись валит весь запуск.

**Чекпойнт:** `last_check_date_time` обновляется ТОЛЬКО на шаге 4 (WorkEnd). Упавший запуск не сдвигает чекпойнт → следующий запуск перепроверит тот же временной интервал.

**JQL окна:** `updated >= lastCheckDateTime AND updated < startTime`. Комментарии дополнительно фильтруются по `comment.updated` в том же окне (`isUpdatedDateRelevant`).

---

## Кейс 1 — obligatory fields null (billing account пустой в source JSD)

**Сигнатура ошибки:**
`AppProcessException: Some of the obligatory fields (account id or provided network type) are null. Fix the ticket and restart the process: JsdIssue(issueId=GPU-..., billingId=null, ...`

Класс: `by.a1.lib.error_handler.AppProcessException`.
Место: `CommentProcessingServiceImpl.checkObligatoryFieldsForNull` (CommentProcessingServiceImpl.java:88-94).
Шаг: `PrepareTickerDataProcessor.transform` (шаг 2).

**Причина (категория: качество данных + баг устойчивости кода):**
Source JSD-тикет (например GPU-101337, Internet_atl/B2B) заведён БЕЗ лицевого счёта — `customfield_10150` (billingAccount) = null и `customfield_10204` (subscriptionNumber) = null. JQL фильтрует только `cf[10201] IS NOT NULL` (тип услуги), но НЕ проверяет `cf[10150]`, поэтому тикет без счёта попадает в батч. На шаге 2 `checkObligatoryFieldsForNull` бросает `AppProcessException` — а т.к. весь батч это одна транзакция, исключение абортит ВЕСЬ запуск: 14 валидных тикетов тоже не получают tickler.

Проверка `getProvidedServiceType() == null` фактически мертва (JQL гарантирует `cf[10201] IS NOT NULL`) — реально триггерит только `getBillingId() == null`.

**Упавшие запуски:** RPA-17880 (2026-06-24 12:00), GPU-101337.

**Repair note:**
- Repair упавшего шага (PrepareTickerData) НЕ поможет — транзакция уже содержит сериализованный `UPDATED_ISSUES_JSON` с `billingId=null`, ремонт перезапустит с теми же данными и упадёт снова.
- Правильное восстановление: заполнить лицевой счёт на source-тикете в JSD, затем **новый запуск** (или repair с шага GetJsdData). Т.к. чекпойнт не сдвинулся, следующий плановый запуск перепроверит то же окно и подтянет исправленный тикет (issue `updated` и comment `updated` останутся в окне `>= lastCheckDateTime`).
- ⚠️ Важно: заполнение поля меняет `issue.updated`, но НЕ меняет `comment.updated`. Окно следующего запуска `[lastCheck, nextStart)` должно покрывать И обновлённый issue, И исходный комментарий — это выполняется, т.к. `lastCheck` не сдвинулся.

**Постоянное исправление (код):**
В `CommentProcessingServiceImpl.processNewComments` не бросать `AppProcessException` на одну битую запись, а логировать WARN + отправлять уведомление и `continue` (пропускать тикет), чтобы остальные 14 доходили до CreateTicklers. Дополнительно можно добавить в JQL `AND cf[10150] IS NOT NULL` (но тогда тикеты без счёта вообще молча выпадут — нужно решить, приемлемо ли это для бизнеса).

**Затронутые процессы:** только JCRVC (логика валидации в `by.a1.jcrvc.service.tickler.comment_processing`). Класс-исключение `AppProcessException` общий (a1lib), но триггер специфичен для jcrvc.