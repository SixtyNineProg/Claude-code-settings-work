#!/usr/bin/env python3
"""Разбор и проверка cron-выражений платформы Sherpa RPA.

Зачем нужен: ближайшие даты запуска по cron модель считает ненадёжно, а ошибка
на 12 часов («8 утра» против «8 вечера») в расписании процесса стоит дорого.
Скрипт разбирает выражение и считает срабатывания детерминированно, поэтому
любое утверждение о времени следующего запуска нужно брать отсюда, а не из головы.

Выражение — стандартный POSIX cron из пяти полей
(минута час день_месяца месяц день_недели), день недели 0 = воскресенье.
Время трактуется как локальное время Sherpa (по умолчанию Europe/Minsk, UTC+3).

Использование:
    python cron_next.py "0 9 * * 1-5"
    python cron_next.py "2,32 * * * *" -n 8
    python cron_next.py "29 11,13,15,17 25 12 *" --from 2026-10-01T00:00
    python cron_next.py "0 9 30 2 *" --json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from datetime import datetime, time, timedelta, timezone
from typing import Dict, FrozenSet, List, Optional, Sequence, Tuple

MINUTE_RANGE = (0, 59)
HOUR_RANGE = (0, 23)
DAY_OF_MONTH_RANGE = (1, 31)
MONTH_RANGE = (1, 12)
DAY_OF_WEEK_RANGE = (0, 7)  # 7 принимается как воскресенье, но в проде не встречается

MONTH_NAMES = {
    "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
    "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12,
}
DAY_NAMES = {
    "SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6,
}
WEEKDAY_SHORT = ("Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс")

# Базы данных часовых поясов на Windows нет, пакет tzdata не всегда установлен.
# Для этих зон держим постоянное смещение: Беларусь и Россия летнее время не переводят.
FIXED_OFFSETS = {
    "Europe/Minsk": 3,
    "Europe/Moscow": 3,
    "Europe/Kaliningrad": 2,
    "Europe/Kyiv": 2,
    "UTC": 0,
}

HORIZON_DAYS = 1831  # пять лет: иначе 0 0 29 2 * ложно покажет «не срабатывает никогда»
MAX_COUNT = 20


class CronParseError(Exception):
    """Выражение не разобрано: синтаксис или значение вне диапазона."""


def _token_to_int(token: str, names: Dict[str, int], label: str) -> int:
    text = token.strip().upper()
    if text in names:
        return names[text]
    try:
        return int(text, 10)
    except ValueError:
        raise CronParseError(f"{label}: не разобрано значение «{token}»") from None


def _parse_field(
    raw: str,
    bounds: Tuple[int, int],
    names: Dict[str, int],
    label: str,
) -> Optional[FrozenSet[int]]:
    """Разбирает одно поле. Возвращает None для «*» (ограничения нет)."""
    low, high = bounds
    text = raw.strip()
    if not text:
        raise CronParseError(f"{label}: пустое поле")
    if text == "*":
        return None
    if text == "?":
        raise CronParseError(f"{label}: «?» Sherpa не поддерживает — используйте «*»")

    values = set()
    for chunk in text.split(","):
        chunk = chunk.strip()
        if not chunk:
            raise CronParseError(f"{label}: пустой элемент в списке «{raw}»")

        step = 1
        base = chunk
        has_step = "/" in chunk
        if has_step:
            base, _, step_text = chunk.partition("/")
            try:
                step = int(step_text, 10)
            except ValueError:
                raise CronParseError(f"{label}: шаг «{step_text}» в «{chunk}» не число") from None
            if step <= 0:
                raise CronParseError(f"{label}: шаг должен быть больше нуля (в «{chunk}»)")
            base = base.strip()

        if base == "*":
            start, end = low, high
        elif "-" in base:
            left, _, right = base.partition("-")
            start = _token_to_int(left, names, label)
            end = _token_to_int(right, names, label)
            if start > end:
                raise CronParseError(
                    f"{label}: перевёрнутый диапазон «{base}» — Sherpa его не поддерживает, "
                    f"перечислите значения через запятую: «{right},{left}»"
                )
        else:
            start = _token_to_int(base, names, label)
            end = high if has_step else start

        if start < low or end > high:
            raise CronParseError(
                f"{label}: значение вне диапазона {low}–{high} (в «{chunk}»)"
            )
        values.update(range(start, end + 1, step))

    return frozenset(values)


@dataclass(frozen=True)
class Cron:
    """Разобранное выражение. None в поле означает «*» — ограничения нет."""

    expr: str
    minute: Optional[FrozenSet[int]]
    hour: Optional[FrozenSet[int]]
    day_of_month: Optional[FrozenSet[int]]
    month: Optional[FrozenSet[int]]
    day_of_week: Optional[FrozenSet[int]]
    day_of_month_and_week_both_set: bool
    warnings: Tuple[str, ...]

    def matches_day(self, day: datetime) -> bool:
        if self.month is not None and day.month not in self.month:
            return False
        weekday = (day.weekday() + 1) % 7  # Пн=1 … Сб=6, Вс=0
        dom_set = self.day_of_month is not None
        dow_set = self.day_of_week is not None
        if dom_set and dow_set:
            # POSIX: при обоих заданных полях день подходит по ЛЮБОМУ из них
            return day.day in self.day_of_month or weekday in self.day_of_week
        if dom_set:
            return day.day in self.day_of_month
        if dow_set:
            return weekday in self.day_of_week
        return True

    def matches(self, moment: datetime) -> bool:
        """Срабатывает ли выражение в этот момент (локальное время Sherpa)."""
        if not self.matches_day(moment):
            return False
        if self.hour is not None and moment.hour not in self.hour:
            return False
        if self.minute is not None and moment.minute not in self.minute:
            return False
        return True


def parse_cron(expr: str, warnings: List[str]) -> Cron:
    """Разбирает выражение из пяти полей, собирая предупреждения о непроверенном синтаксисе."""
    text = " ".join(expr.split())
    if not text:
        raise CronParseError("пустое выражение")
    if text.startswith("@"):
        raise CronParseError(
            f"«{text}» — макрос. Sherpa макросы (@daily, @hourly, @reboot) не поддерживает, "
            "задайте выражение из пяти полей"
        )

    parts = text.split(" ")
    if len(parts) != 5:
        raise CronParseError(
            "нужно ровно 5 полей (минута час день_месяца месяц день_недели), "
            f"получено {len(parts)}: «{text}»"
        )

    minute = _parse_field(parts[0], MINUTE_RANGE, {}, "минута")
    hour = _parse_field(parts[1], HOUR_RANGE, {}, "час")
    day_of_month = _parse_field(parts[2], DAY_OF_MONTH_RANGE, {}, "день месяца")
    month = _parse_field(parts[3], MONTH_RANGE, MONTH_NAMES, "месяц")
    day_of_week = _parse_field(parts[4], DAY_OF_WEEK_RANGE, DAY_NAMES, "день недели")

    if day_of_week is not None and 7 in day_of_week:
        day_of_week = frozenset(0 if value == 7 else value for value in day_of_week)
        warnings.append(
            "день недели 7 — в проде Sherpa не встречается, воскресенье надёжнее задавать как 0"
        )

    if re.search(r"[A-Za-z]", parts[3]) or re.search(r"[A-Za-z]", parts[4]):
        warnings.append(
            "в выражении есть имена дней или месяцев — в проде Sherpa только цифры, "
            "такой синтаксис не подтверждён"
        )

    both_set = day_of_month is not None and day_of_week is not None
    if both_set:
        warnings.append(
            "заданы и день месяца, и день недели: по POSIX срабатывает при совпадении любого "
            "из них, но поведение Sherpa в этом случае не подтверждено"
        )

    return Cron(
        expr=text,
        minute=minute,
        hour=hour,
        day_of_month=day_of_month,
        month=month,
        day_of_week=day_of_week,
        day_of_month_and_week_both_set=both_set,
        warnings=tuple(warnings),
    )


def resolve_timezone(name: str) -> Tuple[str, float]:
    """Возвращает (подпись для вывода, смещение в часах)."""
    try:
        from zoneinfo import ZoneInfo

        zone = ZoneInfo(name)
        offset = datetime.now(zone).utcoffset()
        hours = offset.total_seconds() / 3600 if offset else 0.0
        return f"{name} (база tzdata), UTC{hours:+g}", hours
    except Exception:
        pass

    if name in FIXED_OFFSETS:
        hours = float(FIXED_OFFSETS[name])
        return (
            f"{name} (UTC{hours:+g}, фиксированное смещение — базы tzdata нет)",
            hours,
        )
    raise CronParseError(
        f"часовой пояс «{name}» недоступен: базы tzdata нет, "
        f"а фиксированного смещения для него в скрипте не задано"
    )


def _parse_moment(text: str) -> datetime:
    for fmt in (
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%d",
    ):
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    raise CronParseError(
        f"не разобран момент «{text}» — ожидается ISO 8601, например 2026-10-01T09:00"
    )


def start_moment(text: Optional[str], offset_hours: float) -> datetime:
    """Точка отсчёта в локальном времени Sherpa (наивная, без tzinfo)."""
    if text is not None:
        return _parse_moment(text)
    local_now = datetime.now(timezone.utc) + timedelta(hours=offset_hours)
    return local_now.replace(second=0, microsecond=0, tzinfo=None)


def next_runs(cron: Cron, start: datetime, count: int) -> List[datetime]:
    """Ближайшие срабатывания строго после start. Перебор по дням, не по минутам."""
    hours = sorted(cron.hour) if cron.hour is not None else range(24)
    minutes = sorted(cron.minute) if cron.minute is not None else range(60)

    limit_day = (start + timedelta(days=HORIZON_DAYS)).date()
    found: List[datetime] = []
    day = start.date()

    while day <= limit_day and len(found) < count:
        probe = datetime.combine(day, time(0, 0))
        if cron.matches_day(probe):
            for hour in hours:
                for minute in minutes:
                    moment = datetime.combine(day, time(hour, minute))
                    if moment > start:
                        found.append(moment)
                        if len(found) == count:
                            return found
        day += timedelta(days=1)

    return found


def _describe_fields(cron: Cron) -> str:
    def show(value: Optional[FrozenSet[int]]) -> str:
        return "*" if value is None else "[" + ",".join(str(v) for v in sorted(value)) + "]"

    return (
        f"мин={show(cron.minute)}  час={show(cron.hour)}  "
        f"д.мес={show(cron.day_of_month)}  мес={show(cron.month)}  "
        f"д.нед={show(cron.day_of_week)}"
    )


def _render_moment(moment: datetime) -> str:
    return f"{moment:%Y-%m-%d %H:%M} {WEEKDAY_SHORT[moment.weekday()]}"


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Разбор cron-выражения Sherpa и ближайшие срабатывания",
    )
    parser.add_argument("expr", help="cron-выражение из пяти полей, в кавычках")
    parser.add_argument("-n", "--count", type=int, default=5,
                        help=f"сколько ближайших запусков показать (1–{MAX_COUNT}, по умолчанию 5)")
    parser.add_argument("--from", dest="from_", default=None,
                        help="точка отсчёта в локальном времени Sherpa, ISO 8601")
    parser.add_argument("--tz", default="Europe/Minsk",
                        help="часовой пояс оценки (по умолчанию Europe/Minsk)")
    parser.add_argument("--json", action="store_true", help="вывод в JSON для разбора программой")
    args = parser.parse_args(argv)

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8")

    if not 1 <= args.count <= MAX_COUNT:
        print(f"ОШИБКА: --count должен быть от 1 до {MAX_COUNT}", file=sys.stderr)
        return 2

    warnings: List[str] = []
    try:
        cron = parse_cron(args.expr, warnings)
        tz_label, offset_hours = resolve_timezone(args.tz)
        start = start_moment(args.from_, offset_hours)
        runs = next_runs(cron, start, args.count)
    except CronParseError as error:
        if args.json:
            print(json.dumps(
                {"expr": args.expr, "valid": False, "errors": [str(error)], "warnings": warnings},
                ensure_ascii=False, indent=2,
            ))
        else:
            print(f"ОШИБКА: {error}", file=sys.stderr)
        return 2

    if not runs:
        warnings.append(
            f"выражение разобрано, но за {HORIZON_DAYS // 365} лет ни разу не срабатывает — "
            "проверьте день месяца и месяц (например, 30 февраля не существует)"
        )

    for warning in warnings:
        print(f"ПРЕДУПРЕЖДЕНИЕ: {warning}", file=sys.stderr)

    if args.json:
        print(json.dumps(
            {
                "expr": cron.expr,
                "valid": True,
                "fields": {
                    "minute": sorted(cron.minute) if cron.minute is not None else "*",
                    "hour": sorted(cron.hour) if cron.hour is not None else "*",
                    "day_of_month": sorted(cron.day_of_month) if cron.day_of_month is not None else "*",
                    "month": sorted(cron.month) if cron.month is not None else "*",
                    "day_of_week": sorted(cron.day_of_week) if cron.day_of_week is not None else "*",
                },
                "day_of_month_and_week_both_set": cron.day_of_month_and_week_both_set,
                "tz": tz_label,
                "utc_offset_hours": offset_hours,
                "next": [moment.isoformat() for moment in runs],
                "warnings": list(cron.warnings) + warnings,
                "errors": [],
            },
            ensure_ascii=False, indent=2,
        ))
        return 0

    print(f"cron_tab: {cron.expr}")
    print(f"Поля:     {_describe_fields(cron)}")
    print(f"Часовой пояс: {tz_label} — cron считается в локальном времени Sherpa")
    if runs:
        print(f"Следующие {len(runs)}:")
        for moment in runs:
            print(f"  {_render_moment(moment)}")
    else:
        print("Срабатываний нет.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
