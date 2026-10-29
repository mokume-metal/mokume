#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/read-test-record.py の `read_cancellations` が、事象の記録 (JSON Lines) をレコード単位で読むことの検査 (#3499)。

JSON Lines のレコード境界は LF だけである。JSON の文字列には U+2028 / U+2029 / U+0085 が
そのまま書けるので、`str.splitlines()` で割ると正常なレコードが途中で切れ、読めない行として
落ちる (run 40871485076 では宣言 1 件・事象 8 件を取りこぼした)。守るのは 4 つ。

1. **JSON 文字列の中の行区切りで切らない。** U+2028 を含むキャンセルが testID と理由つきで 1 件返る
2. **正常な記録を落とさない。** 最終 LF の有無・CRLF・空行があっても事象の数が合う
3. **壊れた JSON は `broken` として数え、黙って捨てない。** 注に件数が出る。空行は数えない
4. **記録が無い・形式が違う回の名乗りと、取り消しの重複の畳み方は変えない** (#3348)

`scripts/mutate.py` が同じ関数を共有するので、そちらの入口でも 1 を見る。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


READER = _load("read_test_record", "read-test-record.py")

TEST_ID = "Demo/test"


def _event(kind, **fields):
    payload = {"kind": kind, "messages": [], "version": 0}
    payload.update(fields)
    # ensure_ascii=False が要点: U+2028 を \u2028 に逃がさず、実際の文字として書く
    return json.dumps({"kind": "event", "payload": payload}, ensure_ascii=False)


class ReadCancellationsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "events.jsonl"

    def read(self, text):
        # newline="" で書いた文字をそのまま (CRLF も) 残す
        with open(self.path, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        return READER.read_cancellations(str(self.path))

    def lines(self, *lines, final_newline=True):
        return "\n".join(lines) + ("\n" if final_newline else "")

    def test_a_cancellation_with_a_unicode_line_separator_is_read_whole(self):
        """JSON 文字列の中の U+2028 / U+2029 / U+0085 は、レコードの境界ではない。"""
        for separator in ("\u2028", "\u2029", "\u0085"):
            with self.subTest(separator=repr(separator)):
                reason = "reason%scontinued" % separator
                line = _event("testCancelled", testID=TEST_ID, _comments=[reason])
                self.assertEqual(len(line.splitlines()), 2, "再現の前提: splitlines では割れる")
                why, items, event_count, notes = self.read(
                    self.lines(_event("runStarted"), line, _event("runEnded")))
                self.assertIsNone(why)
                self.assertEqual(items, [(TEST_ID, "丸ごと", 1, reason)])
                self.assertEqual(event_count, 3)
                self.assertEqual(notes, [])

    def test_ordinary_events_around_the_cancellation_are_kept(self):
        """割れた断片に挟まれた通常の事象も数に入る (取りこぼすと事象の数が合わない)。"""
        text = self.lines(
            _event("runStarted"),
            _event("testStarted", testID="A/x", _comments=["a\u2028b"]),
            _event("testCancelled", testID=TEST_ID, _comments=["x\u2028y"]),
            _event("testEnded", testID="A/x"),
            _event("runEnded"),
        )
        _, items, event_count, notes = self.read(text)
        self.assertEqual(event_count, 5)
        self.assertEqual(len(items), 1)
        self.assertEqual(notes, [])

    def test_the_final_newline_and_crlf_do_not_change_the_result(self):
        records = [_event("runStarted"),
                   _event("testCancelled", testID=TEST_ID, _comments=["a\u2028b"]),
                   _event("runEnded")]
        expected = self.read(self.lines(*records))
        self.assertEqual(self.read(self.lines(*records, final_newline=False)), expected)
        self.assertEqual(self.read("\r\n".join(records) + "\r\n"), expected)
        self.assertEqual(self.read("\r\n".join(records)), expected)

    def test_blank_lines_are_skipped_without_counting_as_broken(self):
        _, items, event_count, notes = self.read(
            "\n" + self.lines(_event("runStarted"), "", "   ",
                              _event("testCancelled", testID=TEST_ID, _comments=["r"]),
                              _event("runEnded")) + "\n\n")
        self.assertEqual(len(items), 1)
        self.assertEqual(event_count, 3)
        self.assertEqual(notes, [])

    def test_a_truly_broken_record_is_counted_not_swallowed(self):
        """正常な U+2028 つきの記録は読み、壊れた 1 行だけを `読めない行` に数える。"""
        _, items, event_count, notes = self.read(self.lines(
            _event("runStarted"),
            '{"kind": "event", "payload": {"kind": "testCancelled", ',
            _event("testCancelled", testID=TEST_ID, _comments=["a\u2028b"]),
            _event("runEnded")))
        self.assertEqual(items, [(TEST_ID, "丸ごと", 1, "a\u2028b")])
        self.assertEqual(event_count, 3)
        self.assertEqual(notes, ["読めない行が 1 行あった"])

    def test_only_broken_records_are_still_named(self):
        why, items, event_count, _ = self.read("not json\n{\n")
        self.assertEqual(why, "記録に事象が 1 件も無い (読めない行 2 行)")
        self.assertEqual((items, event_count), ([], 0))

    def test_missing_empty_and_unversioned_records_keep_their_words(self):
        self.assertEqual(READER.read_cancellations(str(Path(self.tmp.name) / "none")),
                         ("記録が無い", [], 0, []))
        self.assertEqual(self.read("")[0], "記録が無い")
        why, items, event_count, _ = self.read(self.lines(_event("testStarted", testID="A/x")))
        self.assertIn("runStarted が無い", why)
        self.assertEqual((items, event_count), ([], 1))
        self.path.write_bytes(b"\xff\xfe\n")
        self.assertEqual(READER.read_cancellations(str(self.path))[0],
                         "記録が壊れている — 文字として読めない")

    def test_the_whole_and_case_duplicates_are_still_folded(self):
        _, items, _, _ = self.read(self.lines(
            _event("runStarted"),
            _event("testCancelled", testID=TEST_ID, _comments=["a\u2028b"]),
            _event("testCaseCancelled", testID=TEST_ID, _comments=["a\u2028b"]),
            _event("runEnded")))
        self.assertEqual(items, [(TEST_ID, "丸ごと", 1, "a\u2028b")])


    def test_mutate_shares_the_reader_and_sees_the_same_cancellation(self):
        """`scripts/mutate.py` の入口 (`read_cancelled`) も、U+2028 つきの取り消しを 1 件読む。"""
        mutate = _load("mutate", "mutate.py")
        path = Path(self.tmp.name) / "shared.jsonl"
        path.write_text(self.lines(
            _event("runStarted"),
            _event("testCancelled", testID=TEST_ID + "/File.swift:1:2", _comments=["a\u2028b"]),
            _event("runEnded")), encoding="utf-8")
        problem, cancelled = mutate.read_cancelled(str(path))
        self.assertIsNone(problem)
        self.assertEqual(cancelled, [(TEST_ID, "cancelled")])

    def test_mutate_does_not_read_a_record_with_broken_lines_as_having_no_cancellations(self):
        """読めない行 (途中で切れた最終行など) があった回は、`read_cancelled` が問題として返す。"""
        mutate = _load("mutate", "mutate.py")
        path = Path(self.tmp.name) / "broken.jsonl"
        path.write_text(self.lines(
            _event("runStarted"),
            _event("testCancelled", testID=TEST_ID + "/File.swift:1:2", _comments=["r"]),
            '{"kind": "event", "payload": {"kind": "testCancelled", "testID": "Cut/',
            final_newline=False), encoding="utf-8")
        problem, cancelled = mutate.read_cancelled(str(path))
        self.assertEqual(problem, "事象の記録: 読めない行が 1 行あった")
        self.assertEqual(cancelled, [])

    def test_a_line_of_only_non_json_whitespace_is_broken_not_blank(self):
        """空行は JSON の空白 (space・tab・CR・LF) だけの行。U+2028・U+0085・U+001C 以降の制御文字だけの行は壊れた行。"""
        odd = [chr(0x2028), chr(0x2029), chr(0x85), chr(0x1C), chr(0x1F), chr(0x0B), chr(0x0C)]
        for char in odd:
            with self.subTest(char=hex(ord(char))):
                _, items, event_count, notes = self.read(self.lines(
                    _event("runStarted"), char, _event("runEnded")))
                self.assertEqual(notes, ["読めない行が 1 行あった"])
                self.assertEqual(event_count, 2)
        # JSON の空白だけの行は、今までどおり読み飛ばす (壊れた行に数えない)
        _, _, _, notes = self.read(self.lines(
            _event("runStarted"), " \t\r", _event("runEnded")))
        self.assertEqual(notes, [])

    def test_this_file_keeps_its_separators_escaped(self):
        """生の U+2028・U+2029・U+0085 をソースに書かない。エディタや整形が正規化すると意味が黙って変わる。"""
        text = Path(__file__).read_text(encoding="utf-8")
        for code in (0x2028, 0x2029, 0x85):
            self.assertNotIn(chr(code), text, "生の U+%04X がソースに書かれている (エスケープで書く)" % code)


if __name__ == "__main__":
    unittest.main()
