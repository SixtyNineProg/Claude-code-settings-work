# Шаг 1 — InfrastructureStep

| Поле | Значение |
|---|---|
| Класс | `by.a1.ics00057_accounts.steps.InfrastructureStep` |
| `@StepName` | `InfrastructureStep` |
| Стадия | Stage1 |
| Зависимости | `EmailService` (Guice) |
| Источник | `src/main/java/by/a1/ics00057_accounts/steps/InfrastructureStep.java` |

## Назначение

Подготовка инфраструктуры процесса: чтение `InitParameters`, расчёт отчётного периода, сохранение его в транзакцию (`run_date`, `period_start`, `period_end`), отправка email-уведомления «ботопроцесс запущен» (`process_started`).

## Вход

- `InitParameters` из транзакции (`emailRecipients`, `periodStart`, `periodEnd`)
- Текущее время в зоне `Europe/Minsk`

## Выход (в `ProcessTransaction`)

- `run_date` — `ZonedDateTime.now(Europe/Minsk)`
- `period_start`, `period_end` — начало/конец отчётного периода

## Логика расчёта периода

```
if (isDateParseable(periodStart) && isDateParseable(periodEnd)):
    pStart = LocalDate.parse(periodStart, dd.MM.yyyy)
    pEnd   = LocalDate.parse(periodEnd,   dd.MM.yyyy)
    runDate = now(Minsk)
    if (pStart < pEnd && pEnd < today): ReportingPeriod(runDate, pStart, pEnd)
    else: throw BusinessException("Invalid input reporting period: ...")
else:
    ReportingPeriod = getDefaultReportingPeriod()  # предыдущий квартал
```

`getDefaultReportingPeriod`:
```
runDate = now(Minsk)
prevQStart = runDate.minusMonths(3).with(IsoFields.DAY_OF_QUARTER = 1)
prevQEnd   = prevQStart.plusMonths(2).with(TemporalAdjusters.lastDayOfMonth())
```

## Email

`AppNotificationService.notificationWorkStart(emailRecipients)` → `emailService.sendProcessStarted(...)`. Шаблон `process_started` (см. `ics00057_accounts_email_templates.json`).

## Обработка ошибок

- `InitParameters` отсутствуют → `IllegalStateException("InitParameters not found")`.
- Парсинг удался, но `pStart >= pEnd` или `pEnd >= today` → `BusinessException("Invalid input reporting period")` — процесс остановлен (общий `HandleErrorStep` отправит `process_error`).

## Тесты

Unit-тестов на `InfrastructureStep` нет — логика расчёта периода тривиальна и покрыта косвенно через тесты sender-шагов, использующих `getReportingPeriod()`. При добавлении нетривиальных правил расчёта периода рекомендуется добавить тесты.

## Связанные файлы

- `src/main/java/by/a1/ics00057_accounts/entity/ReportingPeriod.java`
- `src/main/java/by/a1/ics00057_accounts/model/InitParameters.java`
- `src/main/java/by/a1/ics00057_accounts/service/AppNotificationService.java`