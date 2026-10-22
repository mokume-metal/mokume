#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/syphon-check.sh と scripts/syphon-check-pr.sh — 本体の木で mokume-syphon を検査する (#1973)。

守るのは 4 つ。

1. **GPU の検査が飛んだまま緑にしない。** 代表の Suite が skipped か記録に無ければ 30 で、
   0 にはしない (gpu-ran と同じ考え方)
2. **組めない (10)・検査が落ちた (20)・判定できない (その他) を読み分ける。** swift test が
   0 以外で終わっても、記録に落ちた検査が無ければ検査の赤 (20) とは名乗らない
3. **この PR が壊したのか、もう壊れていたのかを分ける。** head で落ちたときだけ base の木
   (HEAD^1) で走らせ、base で通れば「この PR が壊した」(段は 1)、base でも落ちれば
   「前から壊れている」(段は 0)
4. **ライブラリに触れない PR では走らせない。** SYPHON_CHECK_FORCE=1 のときだけ判定を飛ばす

swift と mokume-syphon の clone 元は偽物に差し替える (本物の build は make syphon-check で見る)。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CHECK = REPO / "scripts" / "syphon-check.sh"
CHECK_PR = REPO / "scripts" / "syphon-check-pr.sh"

GATED = ("SyphonRoundTripTests", "SyphonReceiveTests")

# 偽の swift。振る舞いは環境変数で決める。test は --xunit-output の名前に SwiftPM と同じく
# -swift-testing を挟んで、FAKE_RECORD の中身を書く
FAKE_SWIFT = textwrap.dedent(
    """\
    #!/bin/bash
    echo "swift $*" >> "$FAKE_LOG"
    case "$1 $2" in
      "package edit") exit "${FAKE_EDIT_EXIT:-0}" ;;
      "build --build-tests") exit "${FAKE_BUILD_EXIT:-0}" ;;
    esac
    if [ "$1" = test ]; then
      while [ "$#" -gt 0 ]; do
        if [ "$1" = --xunit-output ]; then out="$2"; fi
        shift
      done
      if [ -n "${FAKE_RECORD:-}" ]; then
        cp "$FAKE_RECORD" "${out%.xml}-swift-testing.xml"
      fi
      exit "${FAKE_TEST_EXIT:-0}"
    fi
    exit 99
    """
)


def record(cases):
    """(classname, 結果) の並びから xunit の記録を作る。結果は passed / failed / skipped"""
    body = []
    for classname, result in cases:
        inner = {
            "passed": "",
            "failed": '<failure message="x"></failure>',
            "skipped": "<skipped/>",
        }[result]
        body.append(f'<testcase classname="{classname}" name="t()" time="0">{inner}</testcase>')
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites><testsuite name="TestResults">'
        + "".join(body)
        + "</testsuite></testsuites>\n"
    )


def gated(result, other="passed"):
    return [(f"MokumeSyphonTests.{s}", result) for s in GATED] + [
        ("MokumeSyphonTests.SyphonPluginShapeTests", other)
    ]


def git(cwd, *args):
    # 使い捨てのリポジトリなので commit 署名を切る (手元の設定に左右されない)
    subprocess.run(
        ["git", "-c", "commit.gpgsign=false", *args], cwd=cwd, check=True, capture_output=True, text=True
    )


class SyphonCheckTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        # clone 元 (mokume-syphon の代わり)
        self.upstream = self.tmp / "upstream"
        self.upstream.mkdir()
        git(self.upstream, "init", "-q", "-b", "main")
        (self.upstream / "Package.swift").write_text("// fake\n")
        git(self.upstream, "add", ".")
        git(self.upstream, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "init")
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        swift = self.bin / "swift"
        swift.write_text(FAKE_SWIFT)
        swift.chmod(0o755)
        self.tree = self.tmp / "tree"
        self.tree.mkdir()
        self.log = self.tmp / "swift.log"

    def run_check(self, cases=None, **env_extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("FAKE_", "SYPHON_"))}
        env["PATH"] = f"{self.bin}:{env['PATH']}"
        env["FAKE_LOG"] = str(self.log)
        env["SYPHON_REPO"] = str(self.upstream)
        env["MOKUME_GPU_SLOT_DIR"] = str(self.tmp / "slots")
        if cases is not None:
            path = self.tmp / "record.xml"
            path.write_text(record(cases))
            env["FAKE_RECORD"] = str(path)
        env.update(env_extra)
        return subprocess.run(
            ["/bin/bash", str(CHECK), str(self.tree), str(self.tmp / "work")],
            env=env,
            capture_output=True,
            text=True,
        )

    def test_passes_when_gpu_suites_ran(self):
        r = self.run_check(gated("passed"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"package edit mokume --path {self.tree}", self.log.read_text())

    def test_gpu_suites_skipped_is_not_green(self):
        r = self.run_check(gated("skipped"))
        self.assertEqual(r.returncode, 30, r.stderr)
        self.assertIn("GPU が見えていない", r.stderr)

    def test_gpu_suite_absent_is_not_green(self):
        r = self.run_check([("MokumeSyphonTests.SyphonRoundTripTests", "passed")])
        self.assertEqual(r.returncode, 30, r.stderr)
        self.assertIn("SyphonReceiveTests が記録に無い", r.stderr)

    def test_gpu_suite_failed(self):
        r = self.run_check(gated("failed"), FAKE_TEST_EXIT="1")
        self.assertEqual(r.returncode, 20, r.stderr)

    def test_failure_outside_gpu_suites_counts(self):
        r = self.run_check(gated("passed", other="failed"), FAKE_TEST_EXIT="1")
        self.assertEqual(r.returncode, 20, r.stderr)

    def test_nonzero_test_without_failures_is_not_a_test_failure(self):
        r = self.run_check(gated("passed"), FAKE_TEST_EXIT="1")
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertIn("記録に落ちた検査が無い", r.stderr)

    def test_an_expiry_record_stops_the_check_and_is_not_read_as_a_missing_record(self):
        """gpu-slot が期限切れの記録 (76) で検査を起こさなかった回は、40 で名乗る (#2235)。"""
        slots = self.tmp / "slots"
        slots.mkdir()
        (slots / "wait-expired.json").write_text("{}", encoding="utf-8")
        r = self.run_check(gated("passed"))
        self.assertEqual(r.returncode, 40, r.stderr)
        self.assertIn("期限を越えた記録", r.stderr)
        self.assertNotIn("test の記録が無い", r.stderr)

    def test_missing_record(self):
        r = self.run_check(None, FAKE_TEST_EXIT="1")
        self.assertEqual(r.returncode, 4, r.stderr)

    def test_edit_fails_is_build_failure(self):
        r = self.run_check(gated("passed"), FAKE_EDIT_EXIT="1")
        self.assertEqual(r.returncode, 10, r.stderr)

    def test_build_fails_is_build_failure(self):
        r = self.run_check(gated("passed"), FAKE_BUILD_EXIT="1")
        self.assertEqual(r.returncode, 10, r.stderr)
        self.assertNotIn("swift test", self.log.read_text())

    def test_clone_fails(self):
        r = self.run_check(gated("passed"), SYPHON_REPO=str(self.tmp / "nowhere"))
        self.assertEqual(r.returncode, 3, r.stderr)

    def test_wrong_arguments(self):
        r = subprocess.run(["/bin/bash", str(CHECK)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)


# 偽の syphon-check.sh。base の木 (名前が base-tree) か head の木かで、返す終了コードを変える。
# 渡された木の marker を記録して、base の木が HEAD^1 の中身かを確かめられるようにする
FAKE_CHECK = textwrap.dedent(
    """\
    #!/bin/bash
    tree="$1"
    case "$tree" in
      */base-tree) label=base-tree; status="${FAKE_BASE:-0}" ;;
      *) label=head; status="${FAKE_HEAD:-0}" ;;
    esac
    echo "$label $(cat "$tree/marker")" >> "$FAKE_LOG"
    exit "$status"
    """
)


class SyphonCheckPrTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.root = self.tmp / "root"
        self.root.mkdir()
        self.fake = self.tmp / "fake-check.sh"
        self.fake.write_text(FAKE_CHECK)
        self.log = self.tmp / "check.log"
        self.summary = self.tmp / "summary.md"
        git(self.root, "init", "-q", "-b", "main")
        (self.root / "marker").write_text("base\n")
        (self.root / "Sources").mkdir()
        (self.root / "Sources" / "a.swift").write_text("// a\n")
        (self.root / "docs").mkdir()
        (self.root / "docs" / "a.md").write_text("a\n")
        self.commit("base")

    def commit(self, message):
        git(self.root, "add", ".")
        git(self.root, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", message)

    def change(self, path):
        (self.root / path).write_text("changed\n")
        (self.root / "marker").write_text("head\n")
        self.commit("head")

    def run_pr(self, **env_extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("FAKE_", "SYPHON_", "GITHUB_"))}
        env["FAKE_LOG"] = str(self.log)
        env["SYPHON_CHECK_SCRIPT"] = str(self.fake)
        env["SYPHON_CHECK_WORK"] = str(self.tmp / "work")
        env["GITHUB_STEP_SUMMARY"] = str(self.summary)
        env.update(env_extra)
        return subprocess.run(
            ["/bin/bash", str(CHECK_PR)], cwd=self.root, env=env, capture_output=True, text=True
        )

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_skips_when_library_untouched(self):
        self.change("docs/a.md")
        r = self.run_pr()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls(), [])
        self.assertIn("検査しない", r.stdout)

    def test_force_runs_even_when_untouched(self):
        self.change("docs/a.md")
        r = self.run_pr(SYPHON_CHECK_FORCE="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls(), ["head head"])

    def test_package_swift_counts_as_library(self):
        self.change("Package.swift")
        r = self.run_pr()
        self.assertEqual(self.calls(), ["head head"], r.stdout)

    def test_head_passes_does_not_run_base(self):
        self.change("Sources/a.swift")
        r = self.run_pr()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls(), ["head head"])
        self.assertIn("::notice", r.stdout)
        self.assertIn("GPU の検査まで通った", self.summary.read_text())

    def test_this_pr_broke_it(self):
        self.change("Sources/a.swift")
        r = self.run_pr(FAKE_HEAD="20", FAKE_BASE="0")
        self.assertEqual(r.returncode, 1, r.stdout)
        # base の木は HEAD^1 の中身で走る
        self.assertEqual(self.calls(), ["head head", "base-tree base"])
        self.assertIn("::warning", r.stdout)
        self.assertIn("この PR が mokume-syphon を壊した", self.summary.read_text())

    def test_build_break_is_named(self):
        self.change("Sources/a.swift")
        r = self.run_pr(FAKE_HEAD="10", FAKE_BASE="0")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("この PR の木では組めない", self.summary.read_text())

    def test_already_broken_before_this_pr(self):
        self.change("Sources/a.swift")
        r = self.run_pr(FAKE_HEAD="20", FAKE_BASE="20")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("この PR より前から壊れている", self.summary.read_text())
        self.assertNotIn("::warning", r.stdout)

    def test_gpu_not_visible_warns_without_base(self):
        self.change("Sources/a.swift")
        r = self.run_pr(FAKE_HEAD="30")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(self.calls(), ["head head"])
        self.assertIn("GPU の検査が走っていない", self.summary.read_text())

    def test_undecidable_head(self):
        self.change("Sources/a.swift")
        r = self.run_pr(FAKE_HEAD="3")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertEqual(self.calls(), ["head head"])

    def test_undecidable_base(self):
        self.change("Sources/a.swift")
        r = self.run_pr(FAKE_HEAD="20", FAKE_BASE="3")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("見分けていない", self.summary.read_text())

    def test_base_worktree_is_removed(self):
        self.change("Sources/a.swift")
        self.run_pr(FAKE_HEAD="20", FAKE_BASE="0")
        self.assertFalse((self.tmp / "work" / "base-tree").exists())
        listed = subprocess.run(
            ["git", "worktree", "list"], cwd=self.root, capture_output=True, text=True
        ).stdout
        self.assertNotIn("base-tree", listed)


if __name__ == "__main__":
    unittest.main()
