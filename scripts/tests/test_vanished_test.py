#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""make test の、検査のプロセスが要約を残さずに消えた回の名乗りと材料の検査 (#1526)。

`make ci-check` の test 段で、本体の検査のプロセス (`swiftpm-testing-helper`) が要約も
記録も残さずに消えた回が 3 度あった。そのとき出ていたのは「test で止まった」だけで、
打ち直すと `.build/test-log.txt` も記録も消え、原因 (#1527) を調べる材料が何も残らなかった。

守るのは 3 つ。

1. **消えた回だけを名乗る。** `swift test` が非 0 で終わり、記録が無い / 読めない / 失敗を
   1 件も持たない回と、0 で終わったのに記録が無い / 読めない (見出しだけで閉じていない) 回
   である (#1688)。普通の赤 (記録に失敗がある)・ビルドで止まった回・0 で終わり記録が閉じて
   いる回には名乗らない。**判定に console を使わない** (#1056 — console は緑の回でも要約を
   落とす)。偽の console は、失敗 0 件の回に要約を出し、失敗 1 件の回に出さない。console を
   読む実装ならこの 2 つで逆に倒れる
2. **材料を、次の実行で上書きされない置き場へ残す。** 採れなかった項目はそう名乗って続ける
3. **test 段の終了コードは非 0 のまま変えない。** 0 で終わって名乗った回だけ、段を赤にする

`swift` と、材料を採る道具 (`log` / `sysctl` / `vm_stat` / `uptime` / `ps`) は PATH の
先頭に置いた偽物へ差し替え、本物の Makefile を一時ディレクトリで走らせる
(`ci_check_test.py` が偽の make を置くのと同じ流儀)。Swift も GPU も要らない。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import fcntl
import os
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MAKEFILE = REPO / "Makefile"
READER = REPO / "scripts" / "read-test-record.py"

RECORD = ".build/test-results-swift-testing.xml"
VANISHED = "検査のプロセスが要約を残さずに終わった"


def _record(*cases):
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n'
        '  <testsuite name="TestResults" tests="%d">\n%s  </testsuite>\n</testsuites>\n'
        % (len(cases), "".join(cases))
    )


PASSED_CASE = '    <testcase classname="MokumeCoreTests.CanvasTests" name="draws()" time="0.1" />\n'
FAILED_CASE = (
    '    <testcase classname="MokumeCoreTests.CanvasTests" name="clears()" time="0.1">\n'
    '      <failure message="色が違う" />\n    </testcase>\n'
)
ERROR_CASE = (
    '    <testcase classname="MokumeCoreTests.CanvasTests" name="throws()" time="0.1">\n'
    '      <error message="投げた" />\n    </testcase>\n'
)

RECORD_ALL_PASSED = _record(PASSED_CASE, PASSED_CASE)
RECORD_ONE_FAILED = _record(PASSED_CASE, FAILED_CASE)
RECORD_ONE_ERROR = _record(PASSED_CASE, ERROR_CASE)
# 本物の helper を kill -9 したときに残った形 (#1526 の本物での確かめ)。宣言と根の開きだけ。
# swift test が 0 で終わった回にも、同じ 52 バイトが残っていた (#1688)
RECORD_TRUNCATED = '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n'
# 検査は書かれているが、根が閉じる前に切れた形
RECORD_UNCLOSED = RECORD_ALL_PASSED.rsplit("</testsuites>", 1)[0]

# 偽の swift。build は FAKE_BUILD_EXIT で終わる。test は --xunit-output の名前に
# SwiftPM と同じく -swift-testing を挟んだ先へ FAKE_RECORD を写し、FAKE_CONSOLE を出し、
# FAKE_TEST_EXIT で終わる。直す前の Makefile は build を分けずに swift test でビルドまで
# するので、そちらでビルドの誤りを作るときは test も FAKE_BUILD_EXIT で止める
FAKE_SWIFT = r"""#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_CALLS"
sub=$1
skip_build=0
base=
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build) skip_build=1 ;;
    --xunit-output) base=$2; shift ;;
  esac
  shift
done
if [ "$sub" = build ] || [ "$skip_build" -eq 0 ]; then
  if [ "${FAKE_BUILD_EXIT:-0}" -ne 0 ]; then
    echo "error: 組めなかった"
    exit "$FAKE_BUILD_EXIT"
  fi
  [ "$sub" = build ] && { echo "Build complete!"; exit 0; }
fi
[ -n "${FAKE_NEW_REPORT:-}" ] && : > "$FAKE_NEW_REPORT"
[ -n "${FAKE_RECORD:-}" ] && cp "$FAKE_RECORD" "${base%.xml}-swift-testing.xml"
printf '%s\n' "${FAKE_CONSOLE:-}"
exit "${FAKE_TEST_EXIT:-0}"
"""

# 材料を採る道具の偽物。FAKE_FAIL に自分の名前があれば、何も出さずに 1 で終わる
FAKE_TOOL = r"""#!/bin/bash
me=$(basename "$0")
case " ${FAKE_FAIL:-} " in *" $me "*) exit 1 ;; esac
printf 'fake-%s %s\n' "$me" "$*"
"""


class ReadFailuresTest(unittest.TestCase):
    """`read-test-record.py --failures` — 記録全体の失敗の数を返す口。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def read(self, content):
        path = self.root / "record.xml"
        if content is not None:
            path.write_text(content, encoding="utf-8")
        proc = subprocess.run(
            ["python3", str(READER), "--failures", str(path)],
            capture_output=True, text=True,
        )
        # 呼ぶ側 (test-vanished.sh・gpu-ran) との約束 — 終了コードは常に 0
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def test_counts_failures_and_errors(self):
        self.assertEqual(self.read(RECORD_ALL_PASSED), "failures 0")
        self.assertEqual(self.read(RECORD_ONE_FAILED), "failures 1")
        self.assertEqual(self.read(RECORD_ONE_ERROR), "failures 1")

    def test_tells_missing_from_unreadable(self):
        self.assertEqual(self.read(None), "missing")
        self.assertEqual(self.read(""), "missing")
        self.assertEqual(self.read(RECORD_TRUNCATED), "unreadable")

    def test_the_existing_mouth_is_unchanged(self):
        """gpu-ran が呼ぶ口 (<記録> <classname>) はそのまま。"""
        path = self.root / "record.xml"
        path.write_text(RECORD_ONE_FAILED, encoding="utf-8")
        proc = subprocess.run(
            ["python3", str(READER), str(path), "MokumeCoreTests.CanvasTests"],
            capture_output=True, text=True,
        )
        self.assertEqual((proc.returncode, proc.stdout.strip()), (0, "failed 0"))


DIGEST = "ab" * 32
# 関所が閉じた後の文面 (RenderFailure.notResponding の本物の形・#2074 の実測から)
GATE_CLOSED_MESSAGE = (
    "A wait for the GPU went past its limit earlier in this process, so no new drawing foundation"
    " is set up in it (the first was while waiting for the GPU to finish, past 5.0 seconds, at"
    " 2026-10-14T15:42:56+0900). That can be one frame drawing too much or a GPU that stopped"
    " answering, and the two look the same from here."
)


def _failed(classname, name, message):
    esc = message.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace("\n", "&#10;")
    return (
        '    <testcase classname="%s" name="%s" time="0.1">\n'
        '      <failure message="%s" />\n    </testcase>\n' % (classname, name, esc)
    )


# 台帳の「絵が変わった」の文面の形 (SceneLedgerTests.compare)。行は 4 字下げで名乗られる
LEDGER_FAILED = _failed(
    "MokumeCoreTests.SceneLedgerTests", "sceneMatchesLedger(_:)",
    "Issue recorded (error): シーン disc の絵が変わった。\n\n"
    "意図した変更なら、行を次へ書き換える:\n\n    disc %s\n\nbefore / after を載せる" % DIGEST,
)
LEDGER_FAILED_OS = _failed(
    "MokumeCoreTests.SceneLedgerTests", "glyphSceneMatchesLedger(_:)",
    "Issue recorded (error): シーン text の絵が変わった。\n\n    text %s os=27\n" % DIGEST,
)


class ReadFailureMessagesTest(unittest.TestCase):
    """`read-test-record.py --failure-messages` — 専用機の赤を run の要約へ残す口 (#1773)。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def read(self, content):
        path = self.root / "record.xml"
        if content is not None:
            path.write_text(content, encoding="utf-8")
        proc = subprocess.run(
            ["python3", str(READER), "--failure-messages", str(path)],
            capture_output=True, text=True,
        )
        # 呼ぶ側 (render.yml の要約の step) との約束 — 終了コードは常に 0
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout

    def test_collects_the_ledger_lines_first(self):
        out = self.read(_record(PASSED_CASE, LEDGER_FAILED, LEDGER_FAILED_OS, FAILED_CASE))
        self.assertIn("落ちた検査 (3 件)", out)
        block = out.split("台帳の書き換え後の行")[1].split("####")[0]
        self.assertIn("disc %s\ntext %s os=27\n" % (DIGEST, DIGEST), block)
        # 絵の置き場の既定は render / render-pr の artifact の名前 (定期の起票は別の名前を渡す)
        self.assertIn("artifact の `ledger-shots` にある", out)
        # 文面そのものも、台帳以外の失敗も載る
        self.assertIn("シーン disc の絵が変わった", out)
        self.assertIn("色が違う", out)

    def test_reads_raw_newlines_as_the_runner_writes_them(self):
        """専用機 (macOS 27) の SwiftPM は、文面の改行を生のまま属性へ書く (#1773)。

        XML の仕様どおりに読むと改行が空白へ潰れ、台帳の行を拾えなかった。
        """
        raw = LEDGER_FAILED.replace("&#10;", "\n")
        self.assertIn('message="Issue recorded (error): シーン disc の絵が変わった。\n', raw)
        out = self.read(_record(raw))
        block = out.split("台帳の書き換え後の行")[1].split("####")[0]
        self.assertIn("disc %s\n" % DIGEST, block)
        self.assertIn("シーン disc の絵が変わった。\n\n意図した変更なら", out)

    def test_does_not_take_lines_from_other_tests(self):
        """台帳の外の検査が同じ形の行を名乗っても、台帳の案には入れない。"""
        other = _failed("MokumeCoreTests.CanvasTests", "hashes()", "期待:\n\n    disc %s" % DIGEST)
        out = self.read(_record(other))
        self.assertNotIn("台帳の書き換え後の行", out)
        self.assertIn("hashes()", out)

    def test_fence_outlives_backticks_in_the_message(self):
        out = self.read(_record(_failed("A", "b()", "```swift\nfoo()\n```")))
        self.assertIn("````text\n```swift", out)

    def test_caps_the_messages_under_the_summary_limit(self):
        """要約は 1 step あたり 1 MiB まで。切ったことと残りの数を名乗る。"""
        out = self.read(_record(*[FAILED_CASE] * 81))
        self.assertIn("落ちた検査 (81 件)", out)
        self.assertEqual(out.count("色が違う"), 80)
        self.assertIn("ほか 1 件", out)

    def test_folds_the_gate_closed_failures_and_names_the_environment(self):
        """GPU の待ちが期限を越えた回は、関所の巻き込みを畳み、本物の赤を先に載せる (#2662)。

        2026-10-13 09:20Z の専用機の release は 2,108 件が関所で落ち、先頭 80 件が巻き込みで
        埋まって、引き金も release 固有の赤も載らなかった。
        """
        gate = _failed(
            "MokumeNetworkTests.OSCSketchTests", "stopEndsDelivery()",
            "Caught error: " + GATE_CLOSED_MESSAGE + " (error)",
        )
        trigger = _failed(
            "MokumeCoreTests.RecordMovieTests", "records()",
            "Caught error: Waited 5 seconds for the GPU and it never finished. (error)",
        )
        out = self.read(_record(*[gate] * 100, trigger, FAILED_CASE))
        self.assertIn("落ちた検査 (102 件)", out)
        self.assertIn("環境で成り立たなかった回", out)
        self.assertIn("102 件のうち 100 件", out)
        self.assertIn("次に走らせ直すまで", out)
        self.assertIn("最初の期限切れ: the first was while waiting for the GPU to finish", out)
        # 本物の赤 (引き金と、それ以外) は 80 件の枠に押し出されない
        self.assertIn("records()", out)
        self.assertIn("色が違う", out)
        self.assertLess(out.index("色が違う"), out.index("関所が閉じた後の失敗"))
        # 関所の分は 1 例に畳む
        self.assertEqual(out.count("stopEndsDelivery()"), 1)
        self.assertNotIn("ほか", out)

    def test_does_not_name_the_environment_without_the_gate(self):
        out = self.read(_record(FAILED_CASE))
        self.assertNotIn("環境で成り立たなかった", out)
        self.assertNotIn("関所", out)

    def test_does_not_sweep_the_suites_that_check_the_gate_wording(self):
        """関所の文面を検査する Suite の赤は本物の赤で、環境の停止と名乗らない (#2665 の反証 1)。"""
        own = _failed(
            "MokumeCoreTests.CommandQueueGateWordingTests", "theRefusalNamesTheFirstWait()",
            "Expectation failed: headline.contains(...) " + GATE_CLOSED_MESSAGE,
        )
        out = self.read(_record(own))
        self.assertNotIn("環境で成り立たなかった", out)
        self.assertIn("theRefusalNamesTheFirstWait()", out)

    def test_the_wording_suites_are_all_listed(self):
        """Tests/ で関所の文面を扱う Suite が、畳まない一覧に揃っている。"""
        reader = READER.read_text(encoding="utf-8")
        found = set()
        for path in (REPO / "Tests").rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            if "notResponding" not in text and "went past its limit" not in text:
                continue
            for name in re.findall(r"(?m)^(?:@MainActor\s+)?(?:final\s+)?(?:struct|class)\s+(\w+)", text):
                found.add("%s.%s" % (path.parent.name, name))
        self.assertTrue(found)
        for suite in sorted(found):
            with self.subTest(suite=suite):
                self.assertIn('"%s"' % suite, reader)

    def test_the_gate_marker_matches_the_real_message(self):
        """畳む目印は Swift の文面の写しなので、本物から外れたら黙って畳まなくなる。"""
        swift = (REPO / "Sources" / "MokumeCore" / "Rendering" / "RenderFailure.swift").read_text(encoding="utf-8")
        reader = READER.read_text(encoding="utf-8")
        marker = 'GATE_CLOSED_OWN = "A wait for the GPU went past its limit earlier in this process"'
        self.assertIn(marker, reader)
        self.assertIn("A wait for the GPU went past its limit earlier in this process", swift)
        # gpu-slot の記録で止まった別の回の断り (#2235)。畳む目印は 2 つ目の句
        record_marker = 'GATE_CLOSED_RECORD = "A wait for the GPU went past its limit in another run under gpu-slot.py"'
        self.assertIn(record_marker, reader)
        self.assertIn("A wait for the GPU went past its limit \\(origin)", swift)
        self.assertIn('"in another run under gpu-slot.py (record: \\(record))"', swift)
        self.assertIn("(the first was ", GATE_CLOSED_MESSAGE)
        self.assertIn("first = closure.map { \" (\\($0.summary))\" }", swift)

    def test_folds_the_record_refusals_and_names_the_record(self):
        """gpu-slot の記録で止まった断り (別の回・自分の回) も、関所が閉じた後として畳み、記録が残ることを言う (#2235)。"""
        other = (
            "A wait for the GPU went past its limit in another run under gpu-slot.py (record: /slots/wait-expired.json),"
            " so no new drawing foundation is set up.\nA person checks that the GPU answers, and then deletes that record;"
            " starting this process again does not remove it."
        )
        own = (
            "A wait for the GPU went past its limit earlier in this process (the first was while waiting for the GPU to"
            " finish, past 5.0 seconds, at 2026-10-22T09:00:00+0900), and gpu-slot.py's record (/slots/wait-expired.json)"
            " stops later runs too, so no new drawing foundation is set up."
        )
        out = self.read(
            _record(
                _failed("MokumeCoreTests.CanvasTests", "a()", other),
                _failed("MokumeCoreTests.CanvasTests", "b()", own),
                FAILED_CASE,
            )
        )
        self.assertIn("環境で成り立たなかった回", out)
        self.assertIn("落ちた 3 件のうち 2 件", out)
        self.assertIn("gpu-slot の期限切れの記録が残っている", out)
        self.assertIn("人が GPU の答えを確かめて記録を消すまで", out)
        # 自分の印だけの回 (記録を持たない) には、記録の一文を足さない
        plain = self.read(_record(_failed("MokumeCoreTests.CanvasTests", "a()", GATE_CLOSED_MESSAGE), FAILED_CASE))
        self.assertIn("環境で成り立たなかった回", plain)
        self.assertNotIn("gpu-slot の期限切れの記録が残っている", plain)

    def test_names_green_missing_and_unreadable(self):
        # 無い記録を先に見る (read は同じ置き場へ書くので、後に回すと前の記録が残る)
        self.assertIn("記録が無い", self.read(None))
        self.assertIn("記録が無い", self.read(""))
        self.assertEqual(self.read(RECORD_ALL_PASSED).strip(), "記録に落ちた検査は無い")
        self.assertIn("記録を読めなかった", self.read(RECORD_TRUNCATED))


class MakeTestTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.work = self.root / "work"
        self.work.mkdir()
        # Makefile は scripts/ を相対で呼ぶ
        (self.work / "scripts").symlink_to(REPO / "scripts")

        self.bin = self.root / "bin"
        self.bin.mkdir()
        self._tool("swift", FAKE_SWIFT)
        for name in ("log", "sysctl", "vm_stat", "uptime", "ps"):
            self._tool(name, FAKE_TOOL)
        # 読むだけの材料に、圧迫を**掛ける**道具を使っていないことを見る見張り
        self.pressure_called = self.root / "memory-pressure-called"
        self._tool("memory_pressure", f"#!/bin/bash\n: > '{self.pressure_called}'\n")

        # 報告の置き場を 2 つ。古い報告 (段の始まりより前) は名前に出てはいけない
        self.reports_user = self.root / "reports-user"
        self.reports_system = self.root / "reports-system"
        self.reports_user.mkdir()
        self.reports_system.mkdir()
        old = self.reports_system / "JetsamEvent-old.ips"
        old.write_text("")
        past = time.time() - 3600
        os.utime(old, (past, past))
        self.new_report = self.reports_user / "swiftpm-testing-helper-new.ips"

        self.record_src = self.root / "fake-record.xml"

    def _tool(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def run_make(self, test_exit, record=None, console="", build_exit=0, fail="", extra_env=None):
        env = dict(os.environ)
        env.pop("MAKEFLAGS", None)
        env.pop("MFLAGS", None)
        env.update(
            PATH=f"{self.bin}:{env['PATH']}",
            FAKE_CALLS=str(self.root / "swift-calls.txt"),
            FAKE_TEST_EXIT=str(test_exit),
            FAKE_BUILD_EXIT=str(build_exit),
            FAKE_CONSOLE=console,
            FAKE_FAIL=fail,
            FAKE_NEW_REPORT=str(self.new_report),
            MOKUME_DIAGNOSTIC_REPORTS=f"{self.reports_user}:{self.reports_system}",
            # 本物の GPU の枠 (#1898) を使わない。他のセッションが本物の検査で枠を埋めていると、
            # 偽の swift test がそこで待たされる
            MOKUME_GPU_SLOT_DIR=str(self.root / "gpu-slots"),
            MOKUME_GPU_SLOT_LOG=str(self.root / "gpu-slot.jsonl"),
        )
        env.update(extra_env or {})
        env.pop("FAKE_RECORD", None)
        if record is not None:
            self.record_src.write_text(record, encoding="utf-8")
            env["FAKE_RECORD"] = str(self.record_src)
        with tempfile.TemporaryFile("w+") as out:
            code = subprocess.call(
                ["make", "--no-print-directory", "-f", str(MAKEFILE), "test"],
                cwd=self.work, env=env, stdout=out, stderr=subprocess.STDOUT, timeout=60,
            )
            out.seek(0)
            return code, out.read()

    def evidence_dirs(self):
        base = self.work / ".build" / "test-vanished"
        return sorted(base.iterdir()) if base.exists() else []

    def assert_vanished(self, code, out, form):
        self.assertNotEqual(code, 0, out)
        self.assertIn(VANISHED, out)
        self.assertIn(form, out)
        # 貼り先は原因の Issue
        self.assertIn("#1527", out)
        dirs = self.evidence_dirs()
        self.assertEqual(len(dirs), 1, out)
        # 置き場を名乗る
        self.assertIn(str(dirs[0].relative_to(self.work)), out)
        return dirs[0]

    def assert_not_vanished(self, out):
        self.assertNotIn(VANISHED, out)
        self.assertEqual(self.evidence_dirs(), [], out)

    # --- 名乗る回 -----------------------------------------------------------

    def test_gpu_slot_stopped_by_an_expiry_record_is_not_a_vanished_run(self):
        """gpu-slot が、期限切れの記録 (76) で検査を起こさなかった回は、「消えた」と名乗らない (#2235)。"""
        slots = self.root / "gpu-slots"
        slots.mkdir()
        (slots / "wait-expired.json").write_text("{}", encoding="utf-8")
        code, out = self.run_make(0, record=RECORD_ALL_PASSED)
        # make は recipe の失敗を 2 で返す。gpu-slot の 76 は make の出力に残る
        self.assertNotEqual(code, 0, out)
        self.assertIn("Error 76", out)
        self.assert_not_vanished(out)
        self.assertIn("検査のプロセスは起こされなかった", out)
        self.assertIn("消えた回 (#1527) ではない", out)
        # 検査は起きていない。build は走るが、test は走らない
        calls = (self.root / "swift-calls.txt").read_text()
        self.assertNotIn("--skip-build", calls)

    def test_gpu_slot_that_could_not_get_a_slot_is_not_a_vanished_run(self):
        """gpu-slot が枠を期限まで取れなかった回 (75) も、検査は起きていないので「消えた」と名乗らない (#2235)。"""
        slots = self.root / "gpu-slots"
        slots.mkdir()
        with open(slots / "slot-0.lock", "a+") as held:
            fcntl.flock(held, fcntl.LOCK_EX)  # 枠 1 つを、この検査が握る
            code, out = self.run_make(
                0, record=RECORD_ALL_PASSED,
                extra_env={"MOKUME_GPU_SLOTS": "1", "MOKUME_GPU_SLOT_WAIT": "0.3", "MOKUME_GPU_SLOT_POLL": "0.05"})
        self.assertNotEqual(code, 0, out)
        self.assertIn("Error 75", out)
        self.assert_not_vanished(out)
        self.assertIn("検査のプロセスは起こされなかった", out)
        self.assertIn("枠を期限まで取れなかった", out)
        self.assertIn("消えた回 (#1527) ではない", out)
        self.assertNotIn("--skip-build", (self.root / "swift-calls.txt").read_text())

    def test_no_record(self):
        code, out = self.run_make(1, console="✔ Test draws() passed")
        evidence = self.assert_vanished(code, out, "記録が無い")
        # ビルドと実行の両方の出力が 1 つのログに残る
        log = (evidence / "test-log.txt").read_text()
        self.assertIn("Build complete!", log)
        self.assertIn("✔ Test draws() passed", log)
        self.assertFalse((evidence / "record.xml").exists())

    def test_truncated_record(self):
        code, out = self.run_make(1, record=RECORD_TRUNCATED)
        evidence = self.assert_vanished(code, out, "記録が読めない")
        # 途中までの記録も残す
        self.assertEqual((evidence / "record.xml").read_text(), RECORD_TRUNCATED)

    def test_record_without_failures(self):
        # console に要約が在っても、記録に失敗が無ければ消えた回である (console を読まない)
        code, out = self.run_make(
            1, record=RECORD_ALL_PASSED, console="✔ Test run with 2 tests passed",
        )
        evidence = self.assert_vanished(code, out, "失敗を 1 件も持たない")
        self.assertEqual((evidence / "record.xml").read_text(), RECORD_ALL_PASSED)

    def test_keeps_the_exit_code_of_swift_test(self):
        code, out = self.run_make(3)
        self.assert_vanished(code, out, "記録が無い")
        self.assertIn("Error 3", out)

    def test_collects_the_evidence(self):
        code, out = self.run_make(1)
        evidence = self.assert_vanished(code, out, "記録が無い")
        jetsam = (evidence / "jetsam.txt").read_text()
        self.assertIn("fake-log show", jetsam)
        self.assertIn("memorystatus", jetsam)
        self.assertIn('process == "kernel"', jetsam)
        memory = (evidence / "memory.txt").read_text()
        for tool in ("fake-sysctl", "fake-vm_stat", "fake-uptime"):
            self.assertIn(tool, memory)
        # 圧迫を掛ける道具は使わない (man memory_pressure)
        self.assertFalse(self.pressure_called.exists(), "memory_pressure を起こした")
        self.assertIn("fake-ps", (evidence / "processes.txt").read_text())
        reports = (evidence / "reports.txt").read_text()
        self.assertIn(self.new_report.name, reports)
        self.assertNotIn("JetsamEvent-old.ips", reports)

    def test_names_what_it_could_not_collect_and_goes_on(self):
        code, out = self.run_make(1, fail="log vm_stat")
        evidence = self.assert_vanished(code, out, "記録が無い")
        self.assertIn("採れなかった", out)
        self.assertIn("log show", out)
        self.assertIn("vm_stat", out)
        # 残りは採れている
        self.assertIn("fake-ps", (evidence / "processes.txt").read_text())
        self.assertIn("fake-sysctl", (evidence / "memory.txt").read_text())
        self.assertIn(self.new_report.name, (evidence / "reports.txt").read_text())

    def test_names_an_unreadable_report_directory(self):
        shutil.rmtree(self.reports_system)
        code, out = self.run_make(1)
        evidence = self.assert_vanished(code, out, "記録が無い")
        self.assertIn("採れなかった", out)
        self.assertIn(str(self.reports_system), out)
        self.assertIn(self.new_report.name, (evidence / "reports.txt").read_text())

    def test_a_rerun_does_not_overwrite_the_evidence(self):
        self.run_make(1, console="一度目")
        self.run_make(1, console="二度目")
        dirs = self.evidence_dirs()
        self.assertEqual(len(dirs), 2)
        logs = sorted((d / "test-log.txt").read_text() for d in dirs)
        self.assertTrue(any("一度目" in t for t in logs), logs)
        self.assertTrue(any("二度目" in t for t in logs), logs)

    # 0 で終わった回 (#1688)。段の赤は swift test ではなく記録から来る

    def test_zero_exit_with_header_only_record(self):
        self.assertEqual(len(RECORD_TRUNCATED.encode()), 52)
        code, out = self.run_make(0, record=RECORD_TRUNCATED, console="✔ Test run with 2 tests passed")
        evidence = self.assert_vanished(code, out, "記録が読めない")
        self.assertIn("swift test の終了コード 0", out)
        self.assertEqual((evidence / "record.xml").read_text(), RECORD_TRUNCATED)
        self.assertIn("swift test の終了コード: 0", (evidence / "summary.txt").read_text())

    def test_zero_exit_with_unclosed_record(self):
        self.assertNotIn("</testsuites>", RECORD_UNCLOSED)
        self.assertIn("<testcase", RECORD_UNCLOSED)
        code, out = self.run_make(0, record=RECORD_UNCLOSED)
        evidence = self.assert_vanished(code, out, "記録が読めない")
        self.assertEqual((evidence / "record.xml").read_text(), RECORD_UNCLOSED)

    def test_zero_exit_without_record(self):
        # SwiftPM が --xunit-output の綴りを変えた回もこの形になるので、その案内も添える
        code, out = self.run_make(0)
        self.assert_vanished(code, out, "記録が無い")
        self.assertIn("綴り", out)

    # --- 名乗らない回 -------------------------------------------------------

    def test_ordinary_failure(self):
        # 要約の無い console でも、記録に失敗があれば普通の赤である
        code, out = self.run_make(1, record=RECORD_ONE_FAILED, console="✘ Test clears() failed")
        self.assertNotEqual(code, 0, out)
        self.assert_not_vanished(out)

    def test_build_error(self):
        code, out = self.run_make(1, build_exit=1)
        self.assertNotEqual(code, 0, out)
        self.assertIn("組めなかった", out)
        self.assert_not_vanished(out)

    def test_green(self):
        # 0 で終わり、記録が閉じていて失敗が 0 件。console に要約が無くても緑である
        code, out = self.run_make(0, record=RECORD_ALL_PASSED)
        self.assertEqual(code, 0, out)
        self.assert_not_vanished(out)


if __name__ == "__main__":
    unittest.main()
