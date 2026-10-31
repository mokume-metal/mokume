#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`.github/workflows/release.yml` の、版を出す前の関門の形の検査 (#2662)。

release でだけ出る赤は merge の前には止めない (merge queue から外した)。代わりに、版は
**下限 OS の release の検査 (`release-check`) と、並走する debug の全探索
(`geometry-exploration`・#3342) がどちらも緑の SHA にだけ**打つ。ここで固定するのは:

  1. release は release-check と geometry-exploration を needs に持ち、自分の `if:` を持たない —
     needs の暗黙の success() で、どちらかが赤・切れた・走らなかった回には版を出さない。release に
     `always()` などを書くと、赤のまま版が出る。release-check に `continue-on-error` を足しても
     同じ (赤が success に化ける)
  2. release-check は macos-26 (ADR-0009 の下限) で `make test-release` を走らせ、
     出すものが無い日も走る (版の判定より前に置く) — ホストの日次の検査を兼ねる。
     起動の可否 (release:now の PR だけ) は release-check の `if:` が持ち、geometry-exploration も
     同じ式を持つ (食い違うと、片方だけ走った回が skipped になり、版が出ないまま気付かれない)
  3. タグは release-check と geometry-exploration が検査した SHA に打ち、版にする HEAD と
     食い違えば打たない
  4. `issues: write` を持つのは起票のジョブ (release-check-report) だけで、どちらかの job が
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
        self.assertEqual(workflow.needs(release), {"release-check", "geometry-exploration"})
        self.assertEqual(workflow.condition(release), "")

    def test_release_check_は下限_OS_で_make_test_release_を走らせる(self):
        check = self.jobs["release-check"]
        self.assertRegex(check, r"(?m)^    runs-on: macos-26\s*$")
        self.assertIn("make test-release", check)
        self.assertEqual(workflow.needs(check), set())
        # 版の判定 (release.py) より前に置く — 出すものが無い日も走る
        self.assertNotIn("release.py", check)

    def test_専用機の定期debugも全探索を維持する(self):
        _, jobs = workflow.split((REPO / ".github/workflows/render.yml").read_text(encoding="utf-8"))
        self.assertRegex(jobs["scheduled-debug"], r'(?m)^      MOKUME_GEOMETRY_EXPLORATION: "1"$')
        for job in ("render", "render-pr"):
            self.assertNotIn("MOKUME_GEOMETRY_EXPLORATION", jobs[job])

    def test_debug_全探索は_release_check_と並走する別_job_で走る(self):
        # 同じ job の中に直列で足すと、release のビルドの伸びとあわせて timeout で切れた (#3342)
        check = self.jobs["release-check"]
        exploration = self.jobs["geometry-exploration"]
        self.assertNotIn("make test-geometry-exploration", check)
        self.assertIn("make test-geometry-exploration", exploration)
        self.assertRegex(exploration, r"(?m)^    runs-on: macos-26\s*$")
        # 並走する — release-check を待たない (待つと直列に戻る)
        self.assertEqual(workflow.needs(exploration), set())
        self.assertEqual(workflow.needs(check), set())
        # 同じ run の中で走るので、起動の可否は同じ式でなければならない
        self.assertEqual(workflow.condition(exploration), workflow.condition(check))
        self.assertNotIn("continue-on-error", exploration)

    def test_各_job_の_timeout_は実測の余裕を持つ(self):
        # 実測 (#3342): release-check は遅い日で約 50 分 → 60。全探索は debug のビルドを含め 8〜16 分 → 30。
        # 黙って下げて切れる回を作らない・黙って上げて症状だけ隠さない — 数字を変えるなら
        # 根拠 (release.yml の注釈) と一緒に変える
        def minutes(job):
            m = re.search(r"(?m)^    timeout-minutes:\s*(\d+)\s*$", self.jobs[job])
            self.assertIsNotNone(m, job)
            return int(m.group(1))

        self.assertEqual(minutes("release-check"), 60)
        self.assertEqual(minutes("geometry-exploration"), 30)

    def test_図形探索は版と同じ_SHAで実行し記録と報告を残す(self):
        check = self.jobs["release-check"]
        exploration = self.jobs["geometry-exploration"]
        for name in ("test-results-release-swift-testing.xml", "geometry-release.md"):
            self.assertIn(name, check)
        for name in ("test-results-geometry-swift-testing.xml", "test-log-geometry.txt", "geometry-debug.md"):
            self.assertIn(name, exploration)
            self.assertNotIn(name, check)
        summary = exploration[exploration.index("- name: 全探索の記録をまとめる"):exploration.index("- uses: actions/upload-artifact")]
        self.assertIn("if: always()", summary)
        self.assertIn("--configuration debug --summary .build/geometry-debug.md", summary)
        check_summary = check[check.index("- name: 全探索の記録をまとめる"):check.index("- uses: actions/upload-artifact")]
        self.assertIn("if: always()", check_summary)
        self.assertIn("--configuration release --summary .build/geometry-release.md", check_summary)
        # 記録は赤の回にも上げる (落ちた回の起票が読む)
        for job in (check, exploration):
            self.assertRegex(job, r"(?m)^        if: always\(\)\s*$")
        self.assertIn("name: geometry-exploration-record", exploration)
        report = self.jobs["release-check-report"]
        self.assertIn("name: geometry-exploration-record", report)
        self.assertIn("test-results-geometry-swift-testing.xml", report)
        self.assertIn("geometry-missing.xml", report)
        self.assertIn("GEOMETRY_RESULT: ${{ needs.geometry-exploration.result }}", report)
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
        self.assertIn("GEOMETRY_SHA: ${{ needs.geometry-exploration.outputs.sha }}", release)
        self.assertIn('git tag "$VERSION" "$CHECKED_SHA"', release)
        self.assertRegex(release, r'"\$head" != "\$CHECKED_SHA"')
        # 別 job の checkout が別の SHA を取った回 (間に main が進んだ) も打たない
        self.assertRegex(release, r'"\$head" != "\$GEOMETRY_SHA"')
        self.assertIn("sha: ${{ steps.sha.outputs.sha }}", self.jobs["release-check"])
        self.assertIn("sha: ${{ steps.sha.outputs.sha }}", self.jobs["geometry-exploration"])

    def test_issues_write_は起票のジョブだけが持つ(self):
        holders = {name for name, body in self.jobs.items() if re.search(r"issues:\s*write", body)}
        self.assertEqual(holders, {"release-check-report"})

    def test_起票は落ちたか切れた回だけ走る(self):
        report = self.jobs["release-check-report"]
        self.assertEqual(workflow.needs(report), {"release-check", "geometry-exploration"})
        cond = workflow.condition(report)
        self.assertTrue(cond.startswith("always()"), cond)
        for job in ("release-check", "geometry-exploration"):
            self.assertIn(f"needs.{job}.result == 'failure'", cond)
            self.assertIn(f"needs.{job}.result == 'cancelled'", cond)
        self.assertIn("scripts/report-release-check.sh", report)


    def test_版を出すジョブだけが_concurrency_で並び_走っている版を止めない(self):
        release = self.jobs["release"]
        self.assertRegex(release, r"(?m)^    concurrency:\s*$")
        self.assertRegex(release, r"(?m)^      cancel-in-progress: false\s*$")
        # 版を決めるのも、タグを取ってくる checkout も、並んだ後 (同じジョブの中) にある
        self.assertIn("python3 scripts/release.py next-version", release)
        self.assertIn("fetch-depth: 0", release)

    def test_共有の_group_に入るのは_release_check_と全探索が緑の_run_だけ(self):
        # 緑でない run (全 PR の closed で起きる run を含む) が共有の group に入ると、待っている
        # release:now の保留を置き換えて cancel する。skipped のジョブが group に入るかに頼らない
        m = re.search(r"(?m)^      group:\s*(.+?)\s*$", self.jobs["release"])
        self.assertIsNotNone(m)
        self.assertEqual(
            m.group(1),
            "${{ needs.release-check.result == 'success'"
            " && needs.geometry-exploration.result == 'success' && 'release-tag'"
            " || format('release-tag-unused-{0}', github.run_id) }}",
        )

    def test_ワークフロー単位にも_release_check_にも_concurrency_を掛けない(self):
        self.assertNotIn("concurrency", self.top)
        holders = {name for name, body in self.jobs.items() if re.search(r"(?m)^    concurrency:", body)}
        self.assertEqual(holders, {"release"})


if __name__ == "__main__":
    unittest.main()
