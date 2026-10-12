#!/usr/bin/env python3
"""Автопроверка разбора cron для Sherpa.

Эталон — прод, а не представления о том, как cron должен работать. Все выражения
в PRODUCTION_EXPRESSIONS и пары в PRODUCTION_RUNS взяты из выгрузки Job_sherpa.csv
(wiki.a1.by, пространство SRPA, страница «SOX Список фоновых задач (jobs)»).
Если тест расходится с этим списком — ошибается парсер, а не список.

Запуск:  python scripts/tests/test_cron_next.py
"""

import pathlib
import sys
import unittest
from datetime import datetime, timedelta

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import cron_next  # noqa: E402

# Все непустые выражения из прода (67 штук, без пустого cron_tab)
PRODUCTION_EXPRESSIONS = [
    "* * * * *",
    "0 8 * * *",
    "0,10,20,30,40,50 * * * *",
    "5 * * * *",
    "15 5,8 * * *",
    "30 4,7,9,11,13,15,17,19,23 * * *",
    "0,45 6 * * *",
    "15 8 * * *",
    "0,15,30,45 * * * *",
    "0 * * * *",
    "30 11 * * 5",
    "0 9 * * *",
    "0 11 * * *",
    "0 9 30 9,11,12 *",
    "0 9 29 10 *",
    "2 * * * *",
    "0 10 17 9,12 *",
    "59 7 * * *",
    "0 10 15 10 *",
    "0 10 16 11 *",
    "0 9 18 9,12 *",
    "0 9 20 10,11 *",
    "5 11 * * *",
    "0 8 * * 1-6",
    "30 10,19 * * *",
    "0 0,2,4,6,8,10,12,14,16,18,20,22 * * *",
    "0 16 * * *",
    "0 8 13 11 *",
    "0 8 15 10,12 *",
    "0,30 * * * *",
    "2,32 * * * *",
    "0 10 * * *",
    "6 * * * *",
    "3 * * * *",
    "13 * * * *",
    "*/30 * * * *",
    "4 * * * *",
    "50 * * * *",
    "30 17 * * *",
    "0 2 * * *",
    "29 10,12,14,15,16,18,19 * * 1-5",
    "29 11,13,15,17 * * 0,6",
    "29 11,13,15,17 25 12 *",
    "0 21 * * *",
    "0 9 4-31 * *",
    "0 9,13 * * *",
    "0 10,14 * * *",
    "0 18 * * *",
    "10 8 1 * *",
    "10 14 1,5,10,20,25,26,27,28,29,30,31 * *",
    "20 8 1 * *",
    "20 14 1,5,10,15,20,25,26,27,28,29,30,31 * *",
    "0 8 * * 1-5",
    "30 8 1 * *",
    "30 14 1,5,10,15,20,25,26,27,28,29,30,31 * *",
    "40 8 1 * *",
    "40 14 1,5,10,15,19,20,25,26,27,28,29,30,31 * *",
    "50 8 1 * *",
    "50 14 1,5,10,15,19,20,25,26,27,28,29,30,31 * *",
    "0 9-13 * * 1-6",
    "0 9 6 10 *",
    "0 9 4 1 *",
    "0 9 7 4,7 *",
    "0 14 * * 1-5",
    "5 12 * * *",
    "0 10 26 * *",
    "0 14 26 * *",
]

# Пары «cron_tab, last_run» из той же выгрузки. last_run в UTC, cron — в местном
# времени Sherpa (Europe/Minsk, UTC+3). Поэтому совпадение проверяется по +3.
PRODUCTION_RUNS = [
    ("15 5,8 * * *", "2026-09-30 05:15:00"),
    ("30 4,7,9,11,13,15,17,19,23 * * *", "2026-09-30 10:30:00"),
    ("0,45 6 * * *", "2026-09-30 03:45:00"),
    ("0 8 * * *", "2026-09-30 05:00:00"),
    ("2 * * * *", "2026-09-30 11:02:00"),
    ("59 7 * * *", "2026-09-30 04:59:00"),
    ("15 8 * * *", "2026-09-30 05:15:00"),
    ("5 11 * * *", "2026-09-30 08:05:00"),
    ("0 8 * * 1-6", "2026-09-30 05:00:00"),
    ("30 10,19 * * *", "2026-09-30 07:30:00"),
    ("0,10,20,30,40,50 * * * *", "2026-09-30 11:10:00"),
    ("5 * * * *", "2026-09-30 11:05:00"),
    ("0 0,2,4,6,8,10,12,14,16,18,20,22 * * *", "2026-09-30 11:00:00"),
    ("0 16 * * *", "2026-09-29 13:00:00"),
    ("0,15,30,45 * * * *", "2026-09-30 11:00:00"),
    ("0,30 * * * *", "2026-09-30 11:00:00"),
    ("2,32 * * * *", "2026-09-30 11:02:00"),
    ("0 10 * * *", "2026-09-30 07:00:00"),
    ("0 * * * *", "2026-09-30 11:00:00"),
    ("6 * * * *", "2026-09-30 11:06:00"),
    ("3 * * * *", "2026-09-30 11:03:00"),
    ("13 * * * *", "2026-09-30 11:13:00"),
    ("*/30 * * * *", "2026-09-30 11:00:00"),
    ("4 * * * *", "2026-09-30 11:04:00"),
    ("50 * * * *", "2026-09-30 10:50:00"),
    ("30 11 * * 5", "2026-09-25 08:30:00"),
    ("0 9 * * *", "2026-09-30 06:00:00"),
    ("30 17 * * *", "2026-09-29 14:30:00"),
    ("0 2 * * *", "2026-09-29 23:00:00"),
    ("29 10,12,14,15,16,18,19 * * 1-5", "2026-09-30 09:29:00"),
    ("29 11,13,15,17 * * 0,6", "2026-09-27 14:29:00"),
    ("0 21 * * *", "2026-09-29 18:00:00"),
    ("0 9 4-31 * *", "2026-09-30 06:00:00"),
    ("0 9,13 * * *", "2026-09-30 10:00:00"),
    ("0 10,14 * * *", "2026-09-30 11:00:00"),
    ("0 18 * * *", "2026-09-29 15:00:00"),
    ("10 14 1,5,10,20,25,26,27,28,29,30,31 * *", "2026-09-30 11:10:00"),
    ("20 14 1,5,10,15,20,25,26,27,28,29,30,31 * *", "2026-09-29 11:20:00"),
    ("0 8 * * 1-5", "2026-09-30 05:00:00"),
    ("30 14 1,5,10,15,20,25,26,27,28,29,30,31 * *", "2026-09-29 11:30:00"),
    ("40 14 1,5,10,15,19,20,25,26,27,28,29,30,31 * *", "2026-09-29 11:40:00"),
    ("50 14 1,5,10,15,19,20,25,26,27,28,29,30,31 * *", "2026-09-29 11:50:00"),
    ("0 9-13 * * 1-6", "2026-09-30 10:00:00"),
    ("0 14 * * 1-5", "2026-09-30 11:00:00"),
    ("5 12 * * *", "2026-09-30 09:05:00"),
    ("0 10 26 * *", "2026-09-26 07:00:00"),
    ("0 14 26 * *", "2026-09-26 11:00:00"),
]

SHERPA_OFFSET_HOURS = 3  # Europe/Minsk: летнее время не переводится с 2011 года


def parse(expr):
    warnings = []
    return cron_next.parse_cron(expr, warnings), warnings


class ProductionCatalogueTest(unittest.TestCase):
    """Каталог прода должен разбираться целиком и давать срабатывания."""

    def test_all_production_expressions_parse(self):
        for expr in PRODUCTION_EXPRESSIONS:
            with self.subTest(expr=expr):
                cron, _ = parse(expr)
                self.assertTrue(cron_next.next_runs(
                    cron, datetime(2026, 10, 1, 0, 0), 1
                ), f"нет срабатываний у «{expr}»")

    def test_cron_is_evaluated_in_local_time(self):
        """Правило «cron = UTC+3, last_run = UTC» объясняет все пары из прода."""
        for expr, last_run in PRODUCTION_RUNS:
            with self.subTest(expr=expr, last_run=last_run):
                cron, _ = parse(expr)
                local = datetime.strptime(last_run, "%Y-%m-%d %H:%M:%S") + timedelta(
                    hours=SHERPA_OFFSET_HOURS
                )
                self.assertTrue(cron.matches(local), f"«{expr}» не покрывает {local}")

    def test_utc_interpretation_does_not_explain_them(self):
        """Обратная проверка: без сдвига на +3 совпадает заметно меньше пар.

        Без этого теста правило о времени проходило бы и при ошибке в парсере.
        """
        matched = 0
        for expr, last_run in PRODUCTION_RUNS:
            cron, _ = parse(expr)
            if cron.matches(datetime.strptime(last_run, "%Y-%m-%d %H:%M:%S")):
                matched += 1
        self.assertLess(
            matched, len(PRODUCTION_RUNS) - 10,
            f"в UTC совпало {matched} из {len(PRODUCTION_RUNS)} — тест перестал различать",
        )

    def test_local_date_can_differ_from_utc_date(self):
        """0 2 * * * при last_run 23:00 UTC — это 02:00 следующих суток по Минску."""
        cron, _ = parse("0 2 * * *")
        utc = datetime(2026, 9, 29, 23, 0, 0)
        self.assertFalse(cron.matches(utc))
        self.assertTrue(cron.matches(utc + timedelta(hours=SHERPA_OFFSET_HOURS)))


class FieldParsingTest(unittest.TestCase):

    def test_star_means_no_restriction(self):
        cron, _ = parse("* * * * *")
        self.assertIsNone(cron.minute)
        self.assertIsNone(cron.day_of_week)
        self.assertTrue(cron.matches(datetime(2026, 10, 1, 13, 47)))

    def test_step_on_star(self):
        cron, _ = parse("*/30 * * * *")
        self.assertEqual(sorted(cron.minute), [0, 30])

    def test_step_on_bare_value_counts_to_end_of_range(self):
        """Викси: 5/15 в минутах — это 5,20,35,50."""
        cron, _ = parse("5/15 * * * *")
        self.assertEqual(sorted(cron.minute), [5, 20, 35, 50])

    def test_step_on_range(self):
        cron, _ = parse("0 8-20/3 * * *")
        self.assertEqual(sorted(cron.hour), [8, 11, 14, 17, 20])

    def test_lists_ranges_and_leading_zeros(self):
        cron, _ = parse("0 8 04,15,20-22 * 1-5")
        self.assertEqual(sorted(cron.day_of_month), [4, 15, 20, 21, 22])
        self.assertEqual(sorted(cron.day_of_week), [1, 2, 3, 4, 5])

    def test_extra_whitespace_is_tolerated(self):
        cron, _ = parse("  0   9  *  *  1-5 ")
        self.assertEqual(cron.expr, "0 9 * * 1-5")

    def test_duplicates_are_deduplicated(self):
        cron, _ = parse("0,0,30 * * * *")
        self.assertEqual(sorted(cron.minute), [0, 30])

    def test_day_of_week_zero_is_sunday(self):
        cron, _ = parse("0 9 * * 0")
        self.assertTrue(cron.matches(datetime(2026, 9, 27, 9, 0)))   # воскресенье
        self.assertFalse(cron.matches(datetime(2026, 9, 28, 9, 0)))  # понедельник

    def test_weekday_range_is_monday_to_friday(self):
        cron, _ = parse("0 9 * * 1-5")
        self.assertTrue(cron.matches(datetime(2026, 10, 2, 9, 0)))   # пятница
        self.assertFalse(cron.matches(datetime(2026, 10, 3, 9, 0)))  # суббота
        self.assertFalse(cron.matches(datetime(2026, 10, 4, 9, 0)))  # воскресенье


class UnverifiedSyntaxTest(unittest.TestCase):
    """Синтаксис, которого нет в проде: принимаем, но обязательно предупреждаем."""

    def test_seven_is_sunday_with_warning(self):
        cron, warnings = parse("30 11 * * 7")
        self.assertEqual(sorted(cron.day_of_week), [0])
        self.assertTrue(cron.matches(datetime(2026, 9, 27, 11, 30)))
        self.assertTrue(any("7" in w for w in warnings), warnings)

    def test_day_names_are_parsed_with_warning(self):
        named, named_warnings = parse("0 9 * * MON-FRI")
        numeric, _ = parse("0 9 * * 1-5")
        self.assertEqual(named.day_of_week, numeric.day_of_week)
        self.assertTrue(named_warnings, "имена дней должны порождать предупреждение")

    def test_month_names_are_parsed_with_warning(self):
        cron, warnings = parse("0 9 30 SEP,NOV,DEC *")
        self.assertEqual(sorted(cron.month), [9, 11, 12])
        self.assertTrue(warnings)

    def test_both_day_fields_set_warns_about_union(self):
        cron, warnings = parse("0 9 15 * 3")
        self.assertTrue(cron.day_of_month_and_week_both_set)
        self.assertTrue(any("ИЛИ" in w or "любого" in w for w in warnings), warnings)

    def test_union_semantics_match_either_field(self):
        cron, _ = parse("0 9 15 * 3")
        self.assertTrue(cron.matches(datetime(2026, 10, 15, 9, 0)))  # по дню месяца
        self.assertTrue(cron.matches(datetime(2026, 10, 7, 9, 0)))   # по дню недели
        self.assertFalse(cron.matches(datetime(2026, 10, 8, 9, 0)))


class RejectedSyntaxTest(unittest.TestCase):
    """То, что должно быть отвергнуто с понятным сообщением, а не разобрано молча."""

    def assert_rejected(self, expr, fragment):
        with self.assertRaises(cron_next.CronParseError) as caught:
            parse(expr)
        self.assertIn(fragment, str(caught.exception))

    def test_macros_are_rejected_specifically(self):
        self.assert_rejected("@daily", "макрос")
        self.assert_rejected("@every 5m", "макрос")

    def test_wrong_field_count(self):
        self.assert_rejected("* * * *", "ровно 5 полей")
        self.assert_rejected("* * * * * *", "ровно 5 полей")

    def test_reversed_range_is_rejected_with_hint(self):
        self.assert_rejected("22-2 * * * *", "перевёрнутый")
        self.assert_rejected("0 0 * * 5-1", "перевёрнутый")

    def test_zero_step_is_rejected(self):
        self.assert_rejected("*/0 * * * *", "шаг")

    def test_out_of_range_values_name_the_field(self):
        self.assert_rejected("60 * * * *", "минута")
        self.assert_rejected("0 25 * * *", "час")
        self.assert_rejected("0 0 32 * *", "день месяца")
        self.assert_rejected("0 0 * 13 *", "месяц")
        self.assert_rejected("0 0 * * 8", "день недели")

    def test_out_of_range_is_caught_inside_a_step_range(self):
        """Шаг не должен маскировать выход за границы поля."""
        self.assert_rejected("0 10-40/2 * * *", "час")

    def test_question_mark_is_rejected(self):
        self.assert_rejected("0 9 ? * *", "«?»")

    def test_empty_field_is_rejected(self):
        self.assert_rejected("0  9 * *", "ровно 5 полей")
        self.assert_rejected("0 9 , * *", "пустой элемент")

    def test_garbage_is_rejected(self):
        self.assert_rejected("каждый день", "ровно 5 полей")


class NextRunsTest(unittest.TestCase):

    def test_weekdays_skip_the_weekend(self):
        cron, _ = parse("0 9 * * 1-5")
        runs = cron_next.next_runs(cron, datetime(2026, 10, 1, 0, 0), 3)
        self.assertEqual(
            runs,
            [datetime(2026, 10, 1, 9, 0), datetime(2026, 10, 2, 9, 0), datetime(2026, 10, 5, 9, 0)],
        )

    def test_result_is_strictly_after_the_start(self):
        cron, _ = parse("0 9 * * *")
        runs = cron_next.next_runs(cron, datetime(2026, 10, 1, 9, 0), 1)
        self.assertEqual(runs, [datetime(2026, 10, 2, 9, 0)])

    def test_impossible_date_yields_no_runs_without_crashing(self):
        cron, _ = parse("0 9 30 2 *")
        self.assertEqual(cron_next.next_runs(cron, datetime(2026, 10, 1), 5), [])

    def test_leap_day_is_found_within_the_horizon(self):
        """Из-за редкого срабатывания горизонт должен быть шире года."""
        cron, _ = parse("0 0 29 2 *")
        runs = cron_next.next_runs(cron, datetime(2026, 10, 1), 1)
        self.assertEqual(runs, [datetime(2028, 2, 29, 0, 0)])

    def test_yearly_multi_date(self):
        cron, _ = parse("0 9 30 9,11,12 *")
        runs = cron_next.next_runs(cron, datetime(2026, 10, 1), 3)
        self.assertEqual(
            runs,
            [datetime(2026, 11, 30, 9, 0), datetime(2026, 12, 30, 9, 0), datetime(2027, 9, 30, 9, 0)],
        )

    def test_start_moment_uses_sherpa_local_time(self):
        moment = cron_next.start_moment("2026-10-01T09:00", SHERPA_OFFSET_HOURS)
        self.assertEqual(moment, datetime(2026, 10, 1, 9, 0))
        self.assertEqual(
            cron_next.start_moment("2026-10-01", SHERPA_OFFSET_HOURS),
            datetime(2026, 10, 1, 0, 0),
        )

    def test_bad_moment_is_rejected(self):
        with self.assertRaises(cron_next.CronParseError):
            cron_next.start_moment("вчера", SHERPA_OFFSET_HOURS)


class TimezoneTest(unittest.TestCase):

    def test_minsk_resolves_even_without_tzdata(self):
        """На Windows базы tzdata нет: должен сработать фиксированный UTC+3."""
        label, hours = cron_next.resolve_timezone("Europe/Minsk")
        self.assertEqual(hours, 3.0)
        self.assertIn("Europe/Minsk", label)

    def test_unknown_zone_without_fallback_is_rejected(self):
        with self.assertRaises(cron_next.CronParseError):
            cron_next.resolve_timezone("America/New_York")


class CommandLineTest(unittest.TestCase):

    def test_valid_expression_exits_zero(self):
        self.assertEqual(cron_next.main(["0 9 * * 1-5", "--from", "2026-10-01T00:00"]), 0)

    def test_invalid_expression_exits_two(self):
        self.assertEqual(cron_next.main(["@daily"]), 2)

    def test_json_mode_reports_the_same_verdict(self):
        self.assertEqual(cron_next.main(["0 9 30 2 *", "--json"]), 0)
        self.assertEqual(cron_next.main(["0 25 * * *", "--json"]), 2)

    def test_count_is_bounded(self):
        self.assertEqual(cron_next.main(["0 9 * * *", "-n", "999"]), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
