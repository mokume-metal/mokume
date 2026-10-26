#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""#3338: 全skipや部分実行を日次の成功と数えない。実際のXML読み手を壊れた記録に当てる。"""
import importlib.util
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("geometry_record", REPO / "scripts/check-geometry-record.py")
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


class GeometryRecordTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "record.xml"
        self.root = ET.Element("testsuites")
        self.suite = ET.SubElement(self.root, "testsuite", tests="6", errors="0", failures="0")
        for suite, name in sorted(reader.REQUIRED):
            ET.SubElement(self.suite, "testcase", classname="MokumeCoreTests." + suite, name=name, time="0.1")

    def inspect(self):
        ET.ElementTree(self.root).write(self.path)
        return reader.inspect(self.path)

    def test_all_required_pass(self):
        errors, count, skipped, seconds = self.inspect()
        self.assertEqual(errors, [])
        self.assertEqual((count, skipped), (6, 0))
        self.assertAlmostEqual(seconds, .6)

    def test_missing_each_required_test_fails(self):
        for case in list(self.suite):
            with self.subTest(name=case.get("name")):
                self.suite.remove(case)
                self.assertTrue(self.inspect()[0])
                self.suite.append(case)

    def test_skipped_failed_error_and_duplicate_fail(self):
        for tag in ("skipped", "failure", "error"):
            with self.subTest(tag=tag):
                child = ET.SubElement(self.suite[0], tag)
                self.assertTrue(self.inspect()[0])
                self.suite[0].remove(child)
        self.suite.append(ET.fromstring(ET.tostring(self.suite[0])))
        self.assertTrue(self.inspect()[0])

    def test_non_target_gpu_skip_is_allowed_but_failure_is_not(self):
        other = ET.SubElement(self.suite, "testcase", classname="MokumeCoreTests.ShapeTests", name="draw()")
        ET.SubElement(other, "skipped")
        self.assertEqual(self.inspect()[0], [])
        ET.SubElement(other, "failure")
        self.assertTrue(self.inspect()[0])

    def test_suite_error_is_not_hidden_by_green_cases(self):
        self.suite.set("errors", "1")
        self.assertTrue(self.inspect()[0])

    def test_wrong_module_is_not_a_substitute(self):
        self.suite[0].set("classname", "Other." + self.suite[0].get("classname"))
        self.assertTrue(self.inspect()[0])

    def test_zero_missing_truncated_and_wrong_root_fail(self):
        self.assertTrue(reader.inspect(self.path)[0])
        for text in ("", "<testsuites>", "<testsuites/>", "<wrong/>"):
            with self.subTest(text=text):
                self.path.write_text(text)
                self.assertTrue(reader.inspect(self.path)[0])

    def test_missing_or_invalid_duration_fails(self):
        for duration in (None, "NaN", "inf", "-1", "bad"):
            with self.subTest(duration=duration):
                if duration is None:
                    self.suite[0].attrib.pop("time", None)
                else:
                    self.suite[0].set("time", duration)
                self.assertTrue(self.inspect()[0])


if __name__ == "__main__":
    unittest.main()
