#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`.github/workflows/host-scheduled.yml` の、ホストの macOS の定期の検査の形の検査 (#3220)。

ここで固定するのは:

  1. 起動は schedule と workflow_dispatch だけ — PR・push の契機を持たない (merge の前には
     重すぎる検査を置く場所で、PR の macOS の枠を奪わない)。cron は毎時 0 分を外す
  2. tsan は macos-26 (ADR-0009 の下限) で `make test-tsan` を走らせ、timeout-minutes を持つ
     (既定の 360 分で止まるとホストの macOS の枠を塞ぐ)。continue-on-error を持たない
     (赤が success に化けると起票が走らない)
  3. `issues: write` を持つのは起票の job (tsan-report) だけで、tsan が落ちた (`failure`) か
     切れた (`cancelled`) ときだけ走る。`if:` は always() を持つ — 無ければ暗黙の success() で、
     赤の回に skipped になる
  4. 起票の job は、artifact の名前と記録の綴りを tsan / Makefile と揃えて読む
  5. exit test (`#expect(processExitsWith:)`) を持つ検査は、どれも Makefile の TSAN_SKIP に
     載る — TSan の下では子が中身を走らせずに止まり、`.failure` を期待する検査は偽って緑に
     なる (#3220 の実測)。足した exit test を TSAN_SKIP に載せ忘れると、ここが赤になる
  6. 変異の mutation (#3221) は macos-26 で、固定の束と前回の commit からの範囲を、期限
     (job の timeout-minutes と mutate.py の --budget) つきで回す。持つ権限は読むだけ
     (`issues: read`) で、continue-on-error を持たない。記録が読めない回は要約の段が赤にする
  7. mutation-report は mutation の結論が何でも走り (`always()` を外すと、mutation が赤の回に
     skipped になって読めない回が黙る)、artifact と記録の綴りを mutation と揃えて読む。
     範囲を回すつもりだったか (`since`) と起点の読めなかった理由 (`reason`) を job の出力で受け取り、
     起点を進めてよいかの判定に使う
  8. Issue を書くのは main の run だけ (他の ref は --dry-run で要約に出す)。報告は concurrency で
     直列にする。起点の理由が ok / first でない回は「状態を確かめる」の段が job を赤にする。
     記録の artifact は `if: always()` と `include-hidden-files: true` で常に上がる

ワークフローの読み手は render_workflow_test.py のものを使う。実行は make hooks-test。
"""

import re
import unittest
from pathlib import Path

import render_workflow_test as workflow

REPO = Path(__file__).resolve().parents[2]
HOST = REPO / ".github" / "workflows" / "host-scheduled.yml"
MAKEFILE = REPO / "Makefile"
TESTS = REPO / "Tests"


def tsan_skip(makefile):
    """Makefile の TSAN_SKIP の並び (行継ぎを畳む)。"""
    m = re.search(r"(?ms)^TSAN_SKIP := (.*?)(?<!\\)\n", makefile)
    return m.group(1).replace("\\\n", " ").split()


def exit_tests(root):
    """exit test を持つ (Suite の型名, 関数名) の集合。関数は宣言の後で最初に出たものに帰す。"""
    found = set()
    for path in root.rglob("*.swift"):
        suite = function = None
        for line in path.read_text(encoding="utf-8").splitlines():
            m = re.match(r"^(?:final class|struct|class) (\w+)", line)
            if m:
                suite = m.group(1)
            m = re.search(r"\bfunc (\w+)\(", line)
            if m:
                function = m.group(1)
            if "processExitsWith" in line and suite and function:
                found.add((suite, function))
    return found


class HostScheduledWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = HOST.read_text(encoding="utf-8")
        cls.top, cls.jobs = workflow.split(cls.text)

    def test_起動は定期と手動だけ(self):
        on = self.top["on"]
        events = set(re.findall(r"(?m)^  ([a-z_]+):", on))
        self.assertEqual(events, {"schedule", "workflow_dispatch"})
        crons = re.findall(r'cron: "(\S+) \S+ \S+ \S+ \S+"', on)
        self.assertTrue(crons)
        for minute in crons:
            self.assertNotEqual(minute, "0", "毎時 0 分は最も混む枠")

    def test_tsan_は下限_OS_で_make_test_tsan_を走らせ期限を持つ(self):
        tsan = self.jobs["tsan"]
        self.assertRegex(tsan, r"(?m)^    runs-on: macos-26\s*$")
        self.assertRegex(tsan, r"(?m)^    timeout-minutes: \d+\s*$")
        self.assertIn("make test-tsan", tsan)
        self.assertNotIn("continue-on-error", tsan)

    def test_issues_write_は起票のジョブだけが持つ(self):
        holders = {name for name, body in self.jobs.items() if re.search(r"issues:\s*write", body)}
        self.assertEqual(holders, {"tsan-report", "mutation-report"})

    def test_起票は落ちたか切れた回だけ走る(self):
        report = self.jobs["tsan-report"]
        self.assertEqual(workflow.needs(report), {"tsan"})
        cond = workflow.condition(report)
        self.assertIn("always()", cond)
        self.assertIn("needs.tsan.result == 'failure'", cond)
        self.assertIn("needs.tsan.result == 'cancelled'", cond)
        self.assertNotIn("!=", cond)

    def test_起票は_tsan_が上げた記録の綴りで読む(self):
        tsan, report = self.jobs["tsan"], self.jobs["tsan-report"]
        self.assertIn("name: tsan-record", tsan)
        self.assertIn("name: tsan-record", report)
        makefile = MAKEFILE.read_text(encoding="utf-8")
        record = re.search(r"(?m)^TEST_RECORD_TSAN := (\S+)$", makefile).group(1)
        log = re.search(r"(?m)^TEST_LOG_TSAN := (\S+)$", makefile).group(1)
        self.assertIn(record, tsan)
        self.assertIn(log, tsan)
        self.assertIn(Path(record).name, report)
        self.assertIn(Path(log).name, report)
        self.assertIn("scripts/report-tsan.sh", report)


    def test_mutation_は下限_OS_で束と範囲を期限つきで回し_読む権限だけを持つ(self):
        mutation = self.jobs["mutation"]
        self.assertRegex(mutation, r"(?m)^    runs-on: macos-26\s*$")
        self.assertRegex(mutation, r"(?m)^    timeout-minutes: \d+\s*$")
        self.assertNotIn("continue-on-error", mutation)
        self.assertRegex(mutation, r"issues:\s*read")
        self.assertNotRegex(mutation, r"(?:issues|contents|pull-requests|actions):\s*write")
        # 範囲は履歴を要る (前回の commit が浅い clone に無いと range は回らない)
        self.assertRegex(mutation, r"fetch-depth:\s*0")
        # 束と範囲は、どちらも全体の期限と 1 件の期限を持つ (期限が無いと job の枠を塞ぐ)
        runs = re.findall(r"scripts/mutate\.py run\b.*?(?=\n\s+- |\Z)", mutation, re.S)
        self.assertEqual(len(runs), 2, "束と範囲の 2 つの run")
        for run in runs:
            self.assertRegex(run, r"--budget \d+")
            self.assertRegex(run, r"--timeout \d+")
            # cold な build を 1 件の期限に食わせない (基準の期限は別に持つ・指摘 11)
            self.assertRegex(run, r"--baseline-timeout \d+")
        self.assertIn("--bundle Tests/mutation-bundle.json", runs[0])
        self.assertIn("--since", runs[1])
        # 範囲は標本 (メンテナの決定): 評価済みを覚えて飛ばす仕組みは持たない
        self.assertNotIn("--exclude-file", mutation)
        self.assertNotIn("mutation-done", mutation)
        # mutate.py は「次の 1 件の最悪 (段の数 × (1 件の期限 + 基準の期限)) が残りに収まるときだけ」始める
        # ので、予算が 1 件の最悪より小さいと、その run は 1 件も始まらない。段の数は束が 1、範囲は 2
        # (絞った filter と target 全体)。job の期限には、予算の合計と組み立て・要約の余裕が収まる
        stages = (1, 2)
        for run, plans in zip(runs, stages):
            budget = int(re.search(r"--budget (\d+)", run).group(1))
            per = int(re.search(r"--timeout (\d+)", run).group(1))
            baseline = int(re.search(r"--baseline-timeout (\d+)", run).group(1))
            self.assertGreaterEqual(budget, plans * (per + baseline), f"{run.splitlines()[0]}: 予算が 1 件の最悪に足りない")
        timeout = int(re.search(r"timeout-minutes: (\d+)", mutation).group(1))
        budgets = sum(int(b) for b in re.findall(r"--budget (\d+)", mutation)) / 60
        self.assertLess(budgets + 30, timeout, "予算の合計 + 組み立てと要約の余裕 30 分が job の期限に収まらない")

    def test_mutation_は同時に_1_本だけ回る(self):
        mutation = self.jobs["mutation"]
        self.assertRegex(mutation, r"(?m)^    concurrency:\n      group: mutation\n      cancel-in-progress: false\s*$")

    def test_mutation_は起点の読めなかった理由を出力に残し_ok_first_以外は赤にする(self):
        mutation = self.jobs["mutation"]
        previous = re.search(r"- name: 前回の点数の commit を読む.*?(?=\n      - name: )", mutation, re.S).group(0)
        self.assertIn("scripts/mutation_state.py previous", previous)
        self.assertIn('--github-output "$GITHUB_OUTPUT"', previous)
        self.assertNotIn("--done-file", previous)
        self.assertRegex(mutation, r"outputs:\s+since: [^\n]+\s+reason: \$\{\{ steps\.previous\.outputs\.reason \}\}")
        # 理由が ok / first でない回は、束を回し終えた後の段が job を赤にする
        check = re.search(r"- name: 状態を確かめる\n        if: ([^\n]*)\n.*?run: \|\n(.*?)(?=\n      - |\Z)", mutation, re.S)
        self.assertIsNotNone(check, "状態を確かめる段が無い")
        self.assertIn("!cancelled()", check.group(1))
        self.assertIn("!= 'ok'", check.group(1))
        self.assertIn("!= 'first'", check.group(1))
        # 起点が木に無い回は報告が名乗って置き直す。自分では治らないので毎日赤にしない
        self.assertIn("!= 'missing-commit'", check.group(1))
        self.assertIn("exit 1", check.group(2))
        self.assertLess(mutation.index("固定の束を回す"), mutation.index("状態を確かめる"))

    def test_mutation_の記録は常に上がる(self):
        # 組み立てで落ちた回の記録を上げ損ねると、報告が何も読めない (指摘 12 d)
        mutation = self.jobs["mutation"]
        upload = re.search(r"- uses: actions/upload-artifact@v7\n(.*?)(?=\n      - |\Z)", mutation, re.S).group(1)
        self.assertRegex(upload, r"if: always\(\)")
        self.assertRegex(upload, r"include-hidden-files: true")
        self.assertRegex(upload, r"retention-days: 14")
        for path in (".build/mutation-bundle.json", ".build/mutation-range.json"):
            self.assertIn(path, upload)

    def test_mutation_の読めない記録は赤になる(self):
        mutation = self.jobs["mutation"]
        # 要約の段は !cancelled() で、run の段が赤でも走る。点数の低下は summary が 0 で返す
        for record in ("mutation-bundle.json", "mutation-range.json"):
            self.assertRegex(mutation, rf"scripts/mutate\.py summary \.build/{re.escape(record)}")
        for step in re.findall(r"(?m)^      - name: 要約[^\n]*\n        if: ([^\n]*)", mutation):
            self.assertIn("!cancelled()", step)

    def test_mutation_report_は結論が何でも走り_mutation_の記録の綴りで読む(self):
        mutation, report = self.jobs["mutation"], self.jobs["mutation-report"]
        self.assertEqual(workflow.needs(report), {"mutation"})
        self.assertEqual(workflow.condition(report), "always()")
        self.assertIn("name: mutation-record", mutation)
        self.assertIn("name: mutation-record", report)
        for record in ("mutation-bundle.json", "mutation-range.json"):
            self.assertIn(f".build/{record}", mutation)
            self.assertIn(record, report)
        self.assertIn("scripts/report-mutation.py", report)
        self.assertIn("needs.mutation.outputs.reason", report)
        # 起点の祖先かを見て、古い run が起点を巻き戻さないための履歴
        checkout = re.search(r"- uses: actions/checkout@v7\n(.*?)(?=\n      # |\n      - )", report, re.S).group(1)
        self.assertRegex(checkout, r"fetch-depth:\s*0")
        # 組み立てで落ちて artifact が無い回も報告する (download の失敗で止まらない)
        download = re.search(r"- uses: actions/download-artifact@v8\n(.*?)(?=\n      - |\Z)", report, re.S).group(1)
        self.assertIn("continue-on-error: true", download)
        # 範囲を回すつもりだったか (起点を進めてよいかの判定) を job の出力で受け渡す
        self.assertRegex(mutation, r"outputs:\s+since: \$\{\{ steps\.previous\.outputs\.since \}\}")
        self.assertIn("needs.mutation.outputs.since", report)
        self.assertIn("needs.mutation.result", report)
        # 範囲の段は起点が読めたときだけ走る
        self.assertIn("steps.previous.outputs.since != ''", self.jobs["mutation"])

    def test_mutation_report_は_main_の_run_だけが_Issue_に書き_同時には_1_つだけ走る(self):
        report = self.jobs["mutation-report"]
        # 共有の追跡 Issue を、枝の dispatch が書き換えない (指摘 7)
        write = re.search(r"- name: 点数を追跡用の Issue に置く\n        if: ([^\n]*)\n.*?run: \|\n(.*?)(?=\n      - |\Z)",
                          report, re.S)
        dry = re.search(r"- name: 点数を job の要約に出す[^\n]*\n        if: ([^\n]*)\n.*?run: \|\n(.*?)(?=\n      - |\Z)",
                        report, re.S)
        self.assertIsNotNone(write)
        self.assertIsNotNone(dry)
        self.assertIn("github.ref == 'refs/heads/main'", write.group(1))
        self.assertNotIn("--dry-run", write.group(2))
        self.assertIn("github.ref != 'refs/heads/main'", dry.group(1))
        self.assertIn("--dry-run", dry.group(2))
        # schedule と dispatch が重なっても、本文の更新が失われず Issue が二重に立たない (指摘 8)
        self.assertRegex(report, r"(?m)^    concurrency:\n      group: mutation-report\n      cancel-in-progress: false\s*$")

    def test_exit_test_は_TSan_の下から外す(self):
        skip = tsan_skip(MAKEFILE.read_text(encoding="utf-8"))
        found = exit_tests(TESTS)
        self.assertTrue(found, "Tests/ に exit test が 1 つも見つからない — 読み方が壊れている")
        missing = sorted(
            f"{suite}/{function}"
            for suite, function in found
            if f"{suite}/{function}" not in skip and f"{suite}/" not in skip
        )
        self.assertEqual(missing, [], "Makefile の TSAN_SKIP に足す (理由は TSAN_SKIP の上)")

    def test_TSAN_SKIP_の読み方(self):
        text = "TSAN_SKIP := A/ \\\n\tB/c \\\n\tD/e\n\nNEXT := x\n"
        self.assertEqual(tsan_skip(text), ["A/", "B/c", "D/e"])


if __name__ == "__main__":
    unittest.main()
