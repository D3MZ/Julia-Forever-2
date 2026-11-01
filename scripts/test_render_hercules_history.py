import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

import numpy as np
import yaml

import render_hercules_history as chart


class HerculesChartTests(unittest.TestCase):
    def report(self, *, end=1793500000, project=None):
        return yaml.safe_dump({
            "hercules": {
                "begin_unix_time": int(datetime(2026, 10, 31, 4, 12, tzinfo=timezone.utc).timestamp()),
                "end_unix_time": end,
            },
            "Burndown": {
                "tick_size": 3600, "granularity": 1, "sampling": 1,
                "project": project if project is not None else "3 0 0 0\n3 2 0 0\n3 2 7 0\n2 2 7 4",
            },
        })

    def test_crop_starts_with_the_first_substantial_hour(self):
        origin, rows = chart.parse_burndown(self.report())
        times, visible = chart.visible_history(origin, rows)
        self.assertEqual(times[0], datetime(2026, 10, 31, 6, tzinfo=timezone.utc))
        self.assertEqual(times[-1], datetime(2026, 10, 31, 8, tzinfo=timezone.utc))
        self.assertEqual(int(visible[0].sum()), 12)
        self.assertEqual(int(visible[-1].sum()), 15)
        np.testing.assert_array_equal(visible[-1], visible[-2])

    def test_rejects_invalid_or_missing_hourly_data(self):
        with self.assertRaises(ValueError):
            chart.parse_burndown(self.report(project="1 2\n3"))
        report = yaml.safe_load(self.report())
        report["Burndown"]["sampling"] = 2
        with self.assertRaises(ValueError):
            chart.parse_burndown(yaml.safe_dump(report))
        origin, rows = chart.parse_burndown(self.report())
        with self.assertRaises(ValueError):
            chart.visible_history(origin, rows, datetime(2026, 11, 1, tzinfo=timezone.utc))

    def test_non_code_head_changes_do_not_change_png(self):
        first_origin, first = chart.parse_burndown(self.report(end=100))
        later_origin, later = chart.parse_burndown(self.report(end=9999999999))
        with tempfile.TemporaryDirectory() as directory:
            a, b = Path(directory) / "a.png", Path(directory) / "b.png"
            self.assertEqual(chart.render_chart(first_origin, first, a), 15)
            self.assertEqual(chart.render_chart(later_origin, later, b), 15)
            self.assertTrue(a.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))
            self.assertEqual(a.read_bytes(), b.read_bytes())

    def test_invokes_hercules_for_hourly_first_parent_julia_history(self):
        class Result:
            stdout = self.report()
        with patch.object(chart.subprocess, "run", return_value=Result()) as run:
            origin, rows = chart.run_hercules("/repo", "/tools/hercules")
        args = run.call_args.args[0]
        self.assertEqual(args[0], "/tools/hercules")
        self.assertIn("--burndown", args)
        self.assertIn("--first-parent", args)
        self.assertEqual(args[args.index("--tick-size") + 1], "1")
        self.assertEqual(args[args.index("--granularity") + 1], "1")
        self.assertEqual(args[args.index("--sampling") + 1], "1")
        self.assertEqual(args[args.index("--whitelist") + 1], r"\.jl$")
        self.assertEqual(int(rows[-1].sum()), 15)
        self.assertEqual(origin.hour, 4)


if __name__ == "__main__":
    unittest.main()
