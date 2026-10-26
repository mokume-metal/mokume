#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`.github/workflows/release.yml` の、版を出す前の関門の形の検査 (#2662)。

release でだけ出る赤は merge の前には止めない (merge queue から外した)。代わりに、版は
**下限 OS の release の検査 (`release-check`) が緑の SHA にだけ**打つ。ここで固定するのは:

  1. release は release-check を needs に持ち、自分の `if:` を持たない — needs の暗黙の
     success() で、release-check が赤・切れた・走らなかった回には版を出さない。release に
     `always()` などを書くと、赤のまま版が出る。release-check に `continue-on-error` を足しても
     同じ (赤が success に化ける)
  2. release-check は macos-26 (ADR-0009 の下限) で `make test-release` を走らせ、
     出すものが無い日も走る (版の判定より前に置く) — ホストの日次の検査を兼ねる。
     起動の可否 (release:now の PR だけ) は release-check の `if:` が持つ
  3. タグは release-check が検査した SHA に打ち、版にする HEAD と食い違えば打たない
  4. `issues: write` を持つのは起票のジョブ (release-check-report) だけで、release-check が
     落ちた (`failure`) か切れた (`cancelled`) ときだけ走る。`if:` は状態の関数を持つ —
     無ければ暗黙の success() で、赤の回に skipped になる
  5. 版を出す run は release ジョブの concurrency で 1 本ずつ並ぶ (#2666)。日次と release:now が
     重なっても、待った側が先の版のタグを見てから版を決める (checkout と next-version が
     同じジョブの中にある)。走っている版を止めない (`cancel-in-progress: false`)。
     **ワークフロー単位にも release-check にも掛けない** — 保留は group に 1 本で新しい保留が
     古い保留を cancel するので、全 PR の closed で起きる run が待っている release:now を
     cancel する。共有の group に入るのは release-check が緑の run だけ (それ以外は run ごと)

ワークフローの読み手は render_workflow_test.py のものを使う。実行は make hooks-test。
"""

import re
import unittest
from pathlib import Path

import render_workflow_test as workflow

REPO = Path(__file__).resolve().parents[2]
RELEASE = REPO / ".github" / "workflows" / "release.yml"


class ReleaseWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.top, cls.jobs = workflow.split(RELEASE.read_text(encoding="utf-8"))

    def test_release_は_release_check_の緑を待ち_自分の_if_を持たない(self):
        release = self.jobs["release"]
        self.assertEqual(workflow.needs(release), {"release-check"})
        self.assertEqual(workflow.condition(release), "")

    def test_release_check_は下限_OS_で_make_test_release_を走らせる(self):
        check = self.jobs["release-check"]
        self.assertRegex(check, r"(?m)^    runs-on: macos-26\s*$")
        self.assertIn("make test-release", check)
        self.assertEqual(workflow.needs(check), set())
        # 版の判定 (release.py) より前に置く — 出すものが無い日も走る
        self.assertNotIn("release.py", check)

    def test_図形探索は版と同じ_SHAで実行し記録と報告を残す(self):
        check = self.jobs["release-check"]
        self.assertLess(check.index("make test-geometry-exploration"), check.index("make test-release"))
        for name in ("test-results-geometry-swift-testing.xml", "test-log-geometry.txt",
                     "geometry-debug.md", "geometry-release.md"):
            self.assertIn(name, check)
        report = self.jobs["release-check-report"]
        self.assertIn("test-results-geometry-swift-testing.xml", report)
        self.assertIn("geometry-missing.xml", report)
        makefile = (REPO / "Makefile").read_text()
        self.assertIn("env MOKUME_GEOMETRY_EXPLORATION=1 python3 scripts/gpu-slot.py -- swift test -c release", makefile)
        self.assertIn("env MOKUME_GEOMETRY_EXPLORATION=1 python3 scripts/gpu-slot.py -- swift test --skip-build --sanitize=thread", makefile)
        self.assertIn("scripts/check-geometry-record.py $(GEOMETRY_RECORD)", makefile)
        self.assertIn("scripts/check-geometry-record.py $(TEST_RECORD_RELEASE)", makefile)

    def test_release_check_の赤を緑に化かさない(self):
        # continue-on-error があると、検査が赤でも release-check が success になり、版が出る
        self.assertNotIn("continue-on-error", self.jobs["release-check"])

    def test_release_check_は_release_now_の_PR_のときだけ_PR_の契機で走る(self):
        cond = workflow.condition(self.jobs["release-check"])
        self.assertIn("github.event_name != 'pull_request'", cond)
        self.assertIn("github.event.pull_request.merged", cond)
        self.assertIn("'release:now'", cond)

    def test_タグは検査した_SHA_に打ち_食い違えば打たない(self):
        release = self.jobs["release"]
        self.assertIn("CHECKED_SHA: ${{ needs.release-check.outputs.sha }}", release)
        self.assertIn('git tag "$VERSION" "$CHECKED_SHA"', release)
        self.assertRegex(release, r'"\$head" != "\$CHECKED_SHA"')
        self.assertIn("sha: ${{ steps.sha.outputs.sha }}", self.jobs["release-check"])

    def test_issues_write_は起票のジョブだけが持つ(self):
        holders = {name for name, body in self.jobs.items() if re.search(r"issues:\s*write", body)}
        self.assertEqual(holders, {"release-check-report"})

    def test_起票は落ちたか切れた回だけ走る(self):
        report = self.jobs["release-check-report"]
        self.assertEqual(workflow.needs(report), {"release-check"})
        cond = workflow.condition(report)
        self.assertTrue(cond.startswith("always()"), cond)
        self.assertIn("needs.release-check.result == 'failure'", cond)
        self.assertIn("needs.release-check.result == 'cancelled'", cond)
        self.assertIn("scripts/report-release-check.sh", report)


    def test_版を出すジョブだけが_concurrency_で並び_走っている版を止めない(self):
        release = self.jobs["release"]
        self.assertRegex(release, r"(?m)^    concurrency:\s*$")
        self.assertRegex(release, r"(?m)^      cancel-in-progress: false\s*$")
        # 版を決めるのも、タグを取ってくる checkout も、並んだ後 (同じジョブの中) にある
        self.assertIn("python3 scripts/release.py next-version", release)
        self.assertIn("fetch-depth: 0", release)

    def test_共有の_group_に入るのは_release_check_が緑の_run_だけ(self):
        # 緑でない run (全 PR の closed で起きる run を含む) が共有の group に入ると、待っている
        # release:now の保留を置き換えて cancel する。skipped のジョブが group に入るかに頼らない
        m = re.search(r"(?m)^      group:\s*(.+?)\s*$", self.jobs["release"])
        self.assertIsNotNone(m)
        self.assertEqual(
            m.group(1),
            "${{ needs.release-check.result == 'success' && 'release-tag'"
            " || format('release-tag-unused-{0}', github.run_id) }}",
        )

    def test_ワークフロー単位にも_release_check_にも_concurrency_を掛けない(self):
        self.assertNotIn("concurrency", self.top)
        holders = {name for name, body in self.jobs.items() if re.search(r"(?m)^    concurrency:", body)}
        self.assertEqual(holders, {"release"})


if __name__ == "__main__":
    unittest.main()
