#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""専用機のワークフロー (`.github/workflows/render.yml`) の、起動と権限の形の検査 (#1983)。

ADR-0019 決定 7 は、専用機に届くきっかけを 3 つ (merge_group・同じリポジトリの PR・
schedule) に限り、それぞれの理由を持つ。**どれも `if:` と権限の 1 行が崩れると、理由ごと
外れる** — しかも崩れても run は緑のままで、気付くのは専用機に想定外のものが届いた後になる。
ここで固定するのは次の 10 個:

  1. schedule の cron は 6 時間おきで、毎時 0 分を避けている (このリポジトリの慣習)
  2. `render` (必須) と `render-pr` は schedule では起動しない — 必須チェックの結論を
     定期の run が動かさない。`workflow_dispatch` も足さない (任意のブランチで起こせる)
  3. 定期の専用機のジョブ (`scheduled-debug` / `scheduled-release`) は schedule でだけ
     起動し、30 分で切る — 専用機は 1 台で、必須の `render` の待ちを延ばさないため
  4. `scheduled-release` は `scheduled-debug` と、その後の門番を待つ — 間に待っている
     `render` を先に通す (1 本の長いジョブにしない)
  5. 専用機のジョブは権限を広げず (`permissions` を持たず workflow 既定の `contents: read`)、
     秘密を持たない
  6. `issues: write` を持つのは GitHub ホストの後続ジョブ (`scheduled-report`) だけ
  7. `scheduled-report` は専用機のジョブが落ちた (`failure`) か切れた (`cancelled`) ときだけ
     走り、2 つの job の結論を起票のスクリプトへ渡す。timeout で切れた回は `cancelled` に
     なるので、`failure` だけを見ると黙って抜ける (#2084)
  8. 専用機のジョブはすべて門番 (`render-turn` / `scheduled-release-turn`) の後に積まれ、
     門番が赤でも走る (`!cancelled()`)。render が skipped になると必須チェックを満たして
     しまう (#2062)
  9. 門番は GitHub ホストで、`actions: read` だけを持つ。待ちの上限は門番が自分で守り
     (job の timeout より内側)、merge_group の上限は queue の期限より手前にある
 10. schedule で起動する専用機のジョブは `scheduled-debug` / `scheduled-release` だけで、
     `needs` の鎖で 1 本ずつ並び、どれも `wait` の門番の後ろにいる。門番より前に積まれた
     定期の job を退かせないことを受け入れる根拠 — 先頭の render と並ぶのは定期の job 1 本
     まで — がこの形である (#2064・ADR-0019 決定 7)。3 本目を足すと、ここが赤になる

PyYAML は入れていない (標準の Python だけで回す) ので、`jobs:` の直下の 2 字下げの
キーでジョブを切り、本文を行で読む。YAML の構文そのものは actionlint が見る。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WORKFLOW = REPO / ".github" / "workflows" / "render.yml"

RUNNER_JOBS = ("render", "render-pr", "scheduled-debug", "scheduled-release")
TURN_JOBS = ("render-turn", "scheduled-release-turn")
TURN_SCRIPT = REPO / "scripts" / "render-turn.sh"
RULESET = REPO / ".github" / "rulesets" / "main-protection.json"
SCHEDULED_RUNNER_JOBS = ("scheduled-debug", "scheduled-release")


def split(text):
    """(トップのキー → 本文) と (jobs の ジョブ名 → 本文)。コメント行は落とす。"""
    lines = [ln for ln in text.splitlines() if not ln.lstrip().startswith("#")]
    top, jobs = {}, {}
    key, job = None, None
    for ln in lines:
        m = re.match(r"^([A-Za-z_-]+):", ln)
        if m:
            key, job = m.group(1), None
            top[key] = []
            continue
        if key is None:
            continue
        top[key].append(ln)
        if key == "jobs":
            m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", ln)
            if m:
                job = m.group(1)
                jobs[job] = []
                continue
            if job is not None:
                jobs[job].append(ln)
    return {k: "\n".join(v) for k, v in top.items()}, {k: "\n".join(v) for k, v in jobs.items()}


def needs(body):
    """ジョブの `needs:` (1 つでも並びでも、名前の集合で返す)。無ければ空。"""
    m = re.search(r"(?m)^    needs:\s*(.+?)\s*$", body)
    if not m:
        return set()
    return {n.strip() for n in m.group(1).strip("[]").split(",") if n.strip()}


def condition(body):
    """ジョブの `if:` (折り返しも 1 行にして返す)。無ければ空。"""
    lines = body.splitlines()
    for i, ln in enumerate(lines):
        m = re.match(r"^    if:\s*(.*)$", ln)
        if not m:
            continue
        parts = [m.group(1)] if m.group(1) not in (">-", ">", "|", "|-") else []
        for nxt in lines[i + 1 :]:
            if not nxt.startswith("      "):
                break
            parts.append(nxt.strip())
        return " ".join(" ".join(parts).split())
    return ""


class RenderWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")
        cls.top, cls.jobs = split(cls.text)

    def test_cron_は6時間おきで毎時0分を避ける(self):
        crons = re.findall(r'cron:\s*"([^"]+)"', self.top["on"])
        self.assertEqual(crons, ["13 2,8,14,20 * * *"])

    def test_起動のきっかけは_3_つだけで_dispatch_を持たない(self):
        triggers = set(re.findall(r"^  ([a-z_]+):", self.top["on"], re.M))
        self.assertEqual(triggers, {"pull_request", "merge_group", "schedule"})

    def test_必須の_render_と_render_pr_は_schedule_で起動しない(self):
        self.assertEqual(
            condition(self.jobs["render"]),
            "${{ !cancelled() && github.event_name == 'merge_group' }}",
        )
        pr = condition(self.jobs["render-pr"])
        self.assertIn("github.event_name == 'pull_request'", pr)
        self.assertNotIn("schedule", pr)

    def test_定期の専用機のジョブは_schedule_でだけ起動し_30_分で切る(self):
        for name in SCHEDULED_RUNNER_JOBS:
            body = self.jobs[name]
            self.assertIn("github.event_name == 'schedule'", condition(body), name)
            self.assertIn("runs-on: [self-hosted, mokume-render]", body, name)
            self.assertIn("timeout-minutes: 30", body, name)

    def test_scheduled_release_は_debug_の後に_queue_へ入る(self):
        self.assertRegex(
            self.jobs["scheduled-release"],
            r"(?m)^    needs: \[scheduled-debug, scheduled-release-turn\]\s*$",
        )
        self.assertRegex(self.jobs["scheduled-release-turn"], r"(?m)^    needs: scheduled-debug\s*$")
        # debug が赤でも release は走らせる。状態の関数が無いと skipped になって赤を覆い隠す。
        # always() ではなく !cancelled() — cancel された run で専用機に積まない
        self.assertIn("!cancelled()", condition(self.jobs["scheduled-release"]))
        self.assertNotIn("always()", condition(self.jobs["scheduled-release"]))

    def test_定期の専用機のジョブは_1_本ずつ並び_wait_の門番の後ろにいる(self):
        # schedule で起動する専用機のジョブを、名前の一覧に頼らず本文から拾う
        scheduled = {
            name
            for name, body in self.jobs.items()
            if "runs-on: [self-hosted" in body
            and "github.event_name == 'schedule'" in condition(body)
        }
        self.assertEqual(scheduled, set(SCHEDULED_RUNNER_JOBS))

        def ancestors(name):
            seen, todo = set(), list(needs(self.jobs[name]))
            while todo:
                n = todo.pop()
                if n not in seen:
                    seen.add(n)
                    todo.extend(needs(self.jobs[n]))
            return seen

        # どの 2 本も、片方がもう片方の後に積まれる (1 つの run の中で同時に queue に並ばない)
        names = sorted(scheduled)
        for i, a in enumerate(names):
            for b in names[i + 1 :]:
                self.assertTrue(
                    a in ancestors(b) or b in ancestors(a), f"{a} と {b} が needs で並んでいない"
                )

        # どれも、直前の needs に wait の門番を持つ (merge_group の run が残る間は積まれない)
        def waits(gate):
            body = self.jobs[gate]
            return "schedule) bash scripts/render-turn.sh wait" in body or (
                "run: bash scripts/render-turn.sh wait" in body
            )

        for name in names:
            self.assertTrue(
                any(waits(g) for g in needs(self.jobs[name]) if g in TURN_JOBS),
                f"{name} の直前に wait の門番が無い",
            )

    def test_専用機のジョブは権限を広げず秘密を持たない(self):
        # 専用機のジョブごとに permissions を書くと、そこで広げられる。workflow 既定の
        # contents: read のままにする。secrets は 1 度も参照しない (github.token は
        # contents: read の token で、secrets ではない)
        self.assertRegex(self.top["permissions"], r"contents:\s*read")
        self.assertNotIn("issues", self.top["permissions"])
        for name in RUNNER_JOBS:
            self.assertNotIn("permissions:", self.jobs[name], name)
        self.assertNotIn("secrets.", "\n".join(self.jobs[n] for n in RUNNER_JOBS))

    def test_issues_write_を持つのは_GitHub_ホストの後続ジョブだけ(self):
        holders = [name for name, body in self.jobs.items() if re.search(r"issues:\s*write", body)]
        self.assertEqual(holders, ["scheduled-report"])
        self.assertNotIn("self-hosted", self.jobs["scheduled-report"])
        self.assertIn("runs-on: ubuntu-latest", self.jobs["scheduled-report"])

    def test_scheduled_report_は専用機のジョブが落ちたか切れたときだけ走る(self):
        body = self.jobs["scheduled-report"]
        self.assertRegex(body, r"needs: \[scheduled-debug, scheduled-release\]")
        cond = condition(body)
        for job in SCHEDULED_RUNNER_JOBS:
            self.assertIn(f"needs.{job}.result == 'failure'", cond, job)
            # 30 分の timeout で切れた回は cancelled で終わる。ここを外すと、何も起票されずに
            # 黙って抜ける (#2084 の 6 回)。人の cancel と見分けないのは ADR-0019 決定 7
            self.assertIn(f"needs.{job}.result == 'cancelled'", cond, job)
        # 成功・skipped のときに走らせない。`!=` 側で書くと、skipped で起票する
        self.assertNotIn("!=", cond)

    def test_scheduled_report_は_job_ごとの結論を起票のスクリプトへ渡す(self):
        # 渡さないと、切れた回の本文が「記録が無い = ビルドで落ちた」と読み違えさせる (#2211)。
        # `if:` は `${{ }}` で包まずに書いてあるので、この綴りに当たるのは step の側だけ
        body = self.jobs["scheduled-report"]
        for job in SCHEDULED_RUNNER_JOBS:
            self.assertIn(f"${{{{ needs.{job}.result }}}}", body, job)

    def test_専用機のジョブはすべて門番の後に積まれる(self):
        gate = {
            "render": "render-turn",
            "render-pr": "render-turn",
            "scheduled-debug": "render-turn",
            "scheduled-release": "scheduled-release-turn",
        }
        self.assertEqual(set(gate), set(RUNNER_JOBS))
        for name, turn in gate.items():
            needs = re.search(r"(?m)^    needs: (.+)$", self.jobs[name])
            self.assertIsNotNone(needs, name)
            self.assertIn(turn, needs.group(1), name)

    def test_門番が赤でも専用機のジョブは走る(self):
        # needs が落ちると、if に状態の関数が無いジョブは skipped になる。render の skipped は
        # 必須チェックを満たすので、描かずに merge される
        # always() ではなく !cancelled() — always() は cancel された run (queue-sweep が捨てた
        # group など) でも専用機に積み、取り合いを増やす
        for name in RUNNER_JOBS:
            cond = condition(self.jobs[name])
            self.assertIn("!cancelled()", cond, name)
            self.assertNotIn("always()", cond, name)
        # render は門番の結論を読まない。読めば、門番の出力ひとつで必須の検査が飛ぶ
        self.assertNotIn("needs.", condition(self.jobs["render"]))
        # render は捨てられた group (queue-sweep が cancel した run) で専用機に積まない
        self.assertNotIn("always()", condition(self.jobs["render"]))

    def test_render_pr_は門番が見送ったときだけ外れる(self):
        cond = condition(self.jobs["render-pr"])
        # == 'true' と書くと、門番が赤 (出力が空) のときにも外れる
        self.assertIn("needs.render-turn.outputs.go != 'false'", cond)
        self.assertNotIn("== 'true'", cond)

    def test_門番は_GitHub_ホストで_actions_read_だけを持つ(self):
        holders = [name for name, body in self.jobs.items() if re.search(r"actions:\s*\w+", body)]
        self.assertEqual(sorted(holders), sorted(TURN_JOBS))
        for name in TURN_JOBS:
            body = self.jobs[name]
            self.assertIn("runs-on: ubuntu-latest", body, name)
            self.assertNotIn("self-hosted", body, name)
            self.assertRegex(body, r"actions:\s*read", name)
            self.assertNotRegex(body, r":\s*write", name)
            self.assertIn("scripts/render-turn.sh", body, name)

    def test_待ちの上限は門番の_timeout_より内側で_queue_の期限より手前(self):
        script = TURN_SCRIPT.read_text(encoding="utf-8")
        limits = {m: int(v) for m, v in re.findall(r"mode=(\w+)[^\n]*limit_default=(\d+)", script)}
        self.assertEqual(set(limits), {"merge_group", "yield", "wait"})
        deadline = int(
            re.search(r'"check_response_timeout_minutes":\s*(\d+)', RULESET.read_text(encoding="utf-8")).group(1)
        )
        # merge_group は期限より手前で自分から通す。期限を越えて待てば、自分の render が
        # 走る前に弾かれる
        self.assertLess(limits["merge_group"], deadline)
        for name in TURN_JOBS:
            timeout = int(re.search(r"(?m)^    timeout-minutes: (\d+)", self.jobs[name]).group(1))
            # 上限は門番が自分で守る。timeout に任せると GitHub の cancel の扱いになる
            self.assertGreater(timeout, max(limits.values()), name)


class SplitterTest(unittest.TestCase):
    """読み手そのものの検査 — 壊れた読み手は、上の検査を黙って緑にする。"""

    def test_ジョブを名前で切り_コメントは読まない(self):
        text = (
            "on:\n  merge_group:\njobs:\n  a:\n    # if: false\n    if: x == 1\n"
            "  b:\n    if: >-\n      y\n      && z\n    runs-on: r\n"
        )
        _, jobs = split(text)
        self.assertEqual(set(jobs), {"a", "b"})
        self.assertEqual(condition(jobs["a"]), "x == 1")
        self.assertEqual(condition(jobs["b"]), "y && z")


if __name__ == "__main__":
    unittest.main()
