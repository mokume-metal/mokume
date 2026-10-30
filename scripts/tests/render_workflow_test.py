#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""専用機のワークフロー (`.github/workflows/render.yml`) の、起動と権限の形の検査 (#1983)。

ADR-0019 決定 7 は、専用機に届くきっかけを 3 つ (merge_group・同じリポジトリの PR・
schedule) に限り、それぞれの理由を持つ。**どれも `if:` と権限の 1 行が崩れると、理由ごと
外れる** — しかも崩れても run は緑のままで、気付くのは専用機に想定外のものが届いた後になる。
ここで固定するのは次の 14 個:

  1. schedule の cron は 6 時間おきで、毎時 0 分を避けている (このリポジトリの慣習)
  2. `render` (必須) と `render-pr` は schedule では起動しない — 必須チェックの結論を
     定期の run が動かさない。`workflow_dispatch` も足さない (任意のブランチで起こせる)
  3. 定期の専用機のジョブ (`scheduled-debug` / `scheduled-release` / `scheduled-drift`) は
     schedule でだけ起動し、30 分で切る — 専用機は 1 台で、必須の `render` の待ちを延ばさないため
  4. `scheduled-release` は `scheduled-debug` と、その後の門番を待つ — 間に待っている
     `render` を先に通す (1 本の長いジョブにしない)。`scheduled-drift` (例の絵の前後の比較・
     #2706) は release と、その後の門番 (`scheduled-drift-turn`) を待つ
  5. 専用機のジョブは権限を広げず (`permissions` を持たず workflow 既定の `contents: read`)、
     秘密を持たない
  6. `issues: write` を持つのは GitHub ホストの後続ジョブ (`scheduled-report` と
     `render-environment-report`) だけ
  7. `scheduled-report` は定期の専用機のジョブ (debug・release・例の絵の比較の `scheduled-drift`)
     が落ちた (`failure`) か切れた (`cancelled`) とき、または `scheduled-drift` が変わった絵を
     名指ししたときだけ走り、3 つの結論を起票のスクリプトへ渡す。赤の発信の step は赤の回にだけ走る (例の絵の名指しだけで
     走った回に、緑の検査を「落ちている」と起票しない)。timeout で切れた回は `cancelled` に
     なるので、`failure` だけを見ると黙って抜ける (#2084)。`if:` は状態の関数を持つ —
     無ければ暗黙の success() で、needs が赤の回に skipped になる
  8. 専用機のジョブはすべて門番 (`render-turn` / `scheduled-release-turn` /
     `scheduled-drift-turn`) の後に積まれ、
     門番が赤でも走る (`!cancelled()`)。render が skipped になると必須チェックを満たして
     しまう (#2062)
  9. 門番は GitHub ホストで、`actions: read` だけを持つ。待ちの上限は門番が自分で守り
     (job の timeout より内側)、merge_group の上限は queue の期限より手前にある
 10. schedule で起動する専用機のジョブは `scheduled-debug` / `scheduled-release` /
     `scheduled-drift` だけで、`needs` の鎖で 1 本ずつ並び、どれも `wait` の門番の後ろに
     いる。門番より前に積まれた定期の job を退かせないことを受け入れる根拠 — 先頭の render と
     並ぶのは定期の job 1 本まで — がこの形である (#2064・ADR-0019 決定 7)。鎖に並ばない
     job を足すと、ここが赤になる
 11. 専用機のジョブはすべて、checkout の直後に環境の前検査 (`scripts/runner-preflight.sh`)
     を走らせる。`render` はその理由を job の出力へ上げ、`render-environment-report` は
     前検査で落ちた回 (理由が空でない) にだけ走って発信する (#2588)。理由を見ずに
     `failure` だけで走らせると、PR の中身による赤まで「専用機が壊れている」と起票する
 12. 外のパッケージ mokume-syphon の検査 (`scripts/syphon-check-pr.sh`) は `render-pr` にだけ
     あり、`continue-on-error` で merge を止めない (#1973)。必須の `render` や定期のジョブに
     入ると、外のリポジトリの赤が本体の merge や起票を動かす
 13. 専用機のジョブの、前検査より後の共通の step (検査の make・落ちた文面の要約・GPU の
     打ち切りの名乗り・artifact) が揃っている (#2267・#2275)。debug の 3 本 (`render`・
     `render-pr`・`scheduled-debug`) は、その 5 step が artifact の名前を除いて同じ。段の違う `scheduled-release` を含む 4 本
     すべてで、検査の make は `CI=` を渡し、要約は自分が上げる記録を読み、artifact は
     `include-hidden-files: true` を持つ。GPU の打ち切りの名乗りは、検査が赤でも緑でも
     走り (`!cancelled()`)、結論を変えない (`continue-on-error` も `exit` も持たず、
     読み手が常に 0 で終わる)。step は 4 本へ手で写してあり、**割れても黙って
     緑になる側がある** — `CI=` を落とすと Metal の検証レイヤが切れたまま緑になり
     (Makefile の METAL_VALIDATION)、`include-hidden-files` を落とすと `.build/` の記録が
     1 つも上がらない。違うべき部分 (artifact の名前・`if`・`concurrency`・`render-pr` の
     checkout の `with:` と末尾の 2 step・release の段) は比べない

5・6 は権限の置き場の方針で、ジョブが打つ書き込みと権限の対応 (要る権限を持つか・使わない
権限を持たないか) は workflow_permissions_test.py が全 workflow ぶんを見る (#2675)。

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
DEBUG_RUNNER_JOBS = ("render", "render-pr", "scheduled-debug")
TURN_JOBS = ("render-turn", "scheduled-release-turn", "scheduled-drift-turn")
TURN_SCRIPT = REPO / "scripts" / "render-turn.sh"
RULESET = REPO / ".github" / "rulesets" / "main-protection.json"
# 例の絵の前後の比較 (#2706)。定期の専用機のジョブの 3 本目で、release の後ろに 1 本ずつ積む。
# 落ちた・切れた回は debug・release と同じく scheduled-report が起票する (起点は success の回から
# 引くので、起票しなければ区間が伸びるだけで誰にも届かない)
DRIFT_JOB = "scheduled-drift"
SCHEDULED_RUNNER_JOBS = ("scheduled-debug", "scheduled-release", DRIFT_JOB)
SCHEDULED_ALL_JOBS = SCHEDULED_RUNNER_JOBS
ALL_RUNNER_JOBS = RUNNER_JOBS + (DRIFT_JOB,)


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


def steps(body):
    """ジョブの `steps:` を step ごとの本文 (行の並び) にして返す。無ければ空。"""
    lines = body.splitlines()
    try:
        start = lines.index("    steps:")
    except ValueError:
        return []
    out = []
    for ln in lines[start + 1 :]:
        if re.match(r"^    \S", ln):
            break
        if ln.startswith("      - "):
            out.append([ln])
        elif out and ln.strip():
            out[-1].append(ln)
    return ["\n".join(s) for s in out]


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
        for name in SCHEDULED_ALL_JOBS:
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

    def test_scheduled_drift_は_release_の後に_queue_へ入り起点は門番が引く(self):
        # 例の絵の前後の比較 (#2706)。debug は 30 分の枠の 28 分を使うので、別の job で、
        # release の後ろに 1 本ずつ積む
        self.assertRegex(
            self.jobs[DRIFT_JOB],
            r"(?m)^    needs: \[scheduled-release, scheduled-drift-turn\]\s*$",
        )
        self.assertRegex(self.jobs["scheduled-drift-turn"], r"(?m)^    needs: scheduled-release\s*$")
        self.assertIn("!cancelled()", condition(self.jobs[DRIFT_JOB]))
        self.assertNotIn("always()", condition(self.jobs[DRIFT_JOB]))
        # 起点は actions: read を持つ GitHub ホストの門番だけが API から引き、専用機の job は
        # 出力で受ける (専用機の job に token も権限も足さない・ADR-0019 決定 7)
        turn = self.jobs["scheduled-drift-turn"]
        self.assertIn("run: bash scripts/drift-base.sh", turn)
        self.assertIn("base: ${{ steps.base.outputs.base }}", turn)
        self.assertNotIn("drift-base.sh", self.jobs[DRIFT_JOB])
        self.assertIn("DRIFT_BASE: ${{ needs.scheduled-drift-turn.outputs.base }}", self.jobs[DRIFT_JOB])
        self.assertIn("run: bash scripts/scheduled-drift.sh", self.jobs[DRIFT_JOB])
        # 変わった絵の本数を出力で渡す。scheduled-report の `if:` が読む
        self.assertIn("drift-count: ${{ steps.drift.outputs.drift-count }}", self.jobs[DRIFT_JOB])
        # 記録は隠しディレクトリごと上げる。無いと .build/ の記録が 1 つも上がらない
        for body in steps(self.jobs[DRIFT_JOB]):
            if body.startswith("      - uses: actions/upload-artifact@"):
                self.assertIn("include-hidden-files: true", body)
                self.assertIn("name: scheduled-drift-record", body)

    def test_定期の専用機のジョブは_1_本ずつ並び_wait_の門番の後ろにいる(self):
        # schedule で起動する専用機のジョブを、名前の一覧に頼らず本文から拾う
        scheduled = {
            name
            for name, body in self.jobs.items()
            if "runs-on: [self-hosted" in body
            and "github.event_name == 'schedule'" in condition(body)
        }
        self.assertEqual(scheduled, set(SCHEDULED_ALL_JOBS))

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
        for name in ALL_RUNNER_JOBS:
            self.assertNotIn("permissions:", self.jobs[name], name)
        self.assertNotIn("secrets.", "\n".join(self.jobs[n] for n in ALL_RUNNER_JOBS))

    def test_issues_write_を持つのは_GitHub_ホストの後続ジョブだけ(self):
        holders = [name for name, body in self.jobs.items() if re.search(r"issues:\s*write", body)]
        self.assertEqual(sorted(holders), ["render-environment-report", "scheduled-report"])
        for name in holders:
            self.assertNotIn("self-hosted", self.jobs[name], name)
            self.assertIn("runs-on: ubuntu-latest", self.jobs[name], name)

    def test_専用機のジョブは_checkout_の直後に前検査を走らせる(self):
        # make より後に置くと、壊れた環境で 14 分走ってから落ちる (#2507) のに戻る
        for name in ALL_RUNNER_JOBS:
            steps = re.findall(r"(?m)^      - (.+)$", self.jobs[name])
            self.assertEqual(steps[0], "uses: actions/checkout@v7", name)
            self.assertEqual(steps[1], "id: preflight", name)
            self.assertRegex(
                self.jobs[name], r"(?m)^      - id: preflight\n        run: bash scripts/runner-preflight.sh$", name
            )

    def test_debug_の専用機のジョブは前検査の後の_step_が揃う(self):
        # 4 step は 3 本へ手で写してある。1 本だけ割れると、割れた側だけが黙って違う検査になる。
        # 違ってよいのは artifact の名前 (上げ先が job ごとに分かれる) だけで、ほかは一字一句比べる。
        # render-pr の checkout の with: (fetch-depth) と末尾の 2 step は比べる範囲の外
        def common(name):
            body = steps(self.jobs[name])[2:7]
            return [re.sub(r"(?m)^          name: \S+$", "          name: <artifact>", s) for s in body]

        base = common("render")
        self.assertEqual(len(base), 5)
        self.assertTrue(base[0].startswith("      - run: make ci-check "), base[0])
        self.assertIn("scripts/read-test-record.py --failure-messages", base[1])
        self.assertIn("scripts/read-test-record.py --gpu-dropped", base[2])
        for s in base[3:]:
            self.assertTrue(s.startswith("      - uses: actions/upload-artifact@"), s)
        for name in DEBUG_RUNNER_JOBS:
            self.assertEqual(common(name), base, f"{name} の step が render と割れている")

    def test_専用機のジョブは検査に_CI_を渡し記録を隠しファイルごと上げる(self):
        # 段の違う scheduled-release も含めて 4 本すべてで見る。3 本が揃って落としても、
        # 上の揃いの検査は緑のままなので、黙って壊れる 2 点はここで名指しする。
        # 段の名前 (ci-check / test-release-scheduled) と記録の名前は固定しない
        for name in RUNNER_JOBS:
            body = steps(self.jobs[name])
            runs = [s for s in body if re.search(r"(?m)^\s*(- run: )?make [\w-]+", s)]
            self.assertEqual(len(runs), 1, f"{name} の検査の make が 1 つでない")
            make = re.search(r"make [^|\n]*", runs[0]).group(0)
            # CI= で GitHub の CI=true を空に戻す。無いと Metal の検証レイヤが切れたまま緑になる
            self.assertRegex(make, r"\sCI=(\s|$)", name)

            summaries = [s for s in body if "name: 落ちた検査の文面を要約へ書く" in s]
            self.assertEqual(len(summaries), 1, name)
            self.assertIn("if: failure()", summaries[0], name)
            record = re.search(r"--failure-messages (\S+)", summaries[0]).group(1)

            # GPU の打ち切りの名乗り (#2275): 検査が赤でも緑でも走り、結論は変えない。読む test-log は
            # 下の always の artifact に入っている (上げる材料と、要約が読む材料が同じ)
            dropped = [s for s in body if "name: GPU の打ち切りを要約へ名乗る" in s]
            self.assertEqual(len(dropped), 1, name)
            self.assertIn("if: ${{ !cancelled() }}", dropped[0], name)
            self.assertIn("scripts/read-test-record.py --gpu-dropped .build/test-log.txt", dropped[0], name)
            self.assertNotIn("continue-on-error", dropped[0], name)
            self.assertNotIn("exit ", dropped[0], name)

            uploads = [s for s in body if s.startswith("      - uses: actions/upload-artifact@")]
            self.assertTrue(uploads, name)
            for s in uploads:
                # .build は隠しディレクトリで、無いと記録が 1 つも上がらないまま緑になる
                self.assertIn("include-hidden-files: true", s, name)
                self.assertIn("if-no-files-found: ignore", s, name)
                self.assertIn("retention-days: 14", s, name)
            # 要約が読む記録と test-log は、成否によらず上がる artifact に入っている
            always = [s for s in uploads if "if: always()" in s]
            self.assertEqual(len(always), 1, name)
            self.assertIn(record, always[0], name)
            self.assertIn(".build/test-log.txt", always[0], name)

    def test_mokume_syphon_の検査は_render_pr_にだけあり_merge_を止めない(self):
        holders = [name for name, body in self.jobs.items() if "syphon-check" in body]
        self.assertEqual(holders, ["render-pr"])
        self.assertRegex(
            self.jobs["render-pr"],
            r"(?m)^        continue-on-error: true\n        run: bash scripts/syphon-check-pr.sh$",
        )

    def test_render_environment_report_は前検査で落ちた回にだけ走る(self):
        self.assertIn(
            "preflight-reason: ${{ steps.preflight.outputs.reason }}", self.jobs["render"]
        )
        body = self.jobs["render-environment-report"]
        self.assertEqual(needs(body), {"render"})
        cond = condition(body)
        # 状態の関数が無いと暗黙の success() で、render が赤の回にこそ skipped になる
        self.assertIn("!cancelled() && ", cond)
        self.assertIn("needs.render.result == 'failure'", cond)
        # 理由を見ないと、PR の中身による赤まで専用機の故障として起票する
        self.assertIn("needs.render.outputs.preflight-reason != ''", cond)
        self.assertIn("scripts/report-runner-environment.sh", body)

    def test_scheduled_report_は専用機のジョブが落ちたか切れたときだけ走る(self):
        body = self.jobs["scheduled-report"]
        self.assertRegex(body, r"needs: \[scheduled-debug, scheduled-release, scheduled-drift\]")
        cond = condition(body)
        for job in SCHEDULED_RUNNER_JOBS:
            self.assertIn(f"needs.{job}.result == 'failure'", cond, job)
            # 30 分の timeout で切れた回は cancelled で終わる。ここを外すと、何も起票されずに
            # 黙って抜ける (#2084 の 6 回)。人の cancel と見分けないのは ADR-0019 決定 7
            self.assertIn(f"needs.{job}.result == 'cancelled'", cond, job)
        # 例の絵の名指し (#2706): 変わった絵が 1 本でもあれば走る。出力が空 (job が skipped・
        # 落ちた) でも式が崩れないよう、`|| '0'` を持つ
        self.assertIn("fromJSON(needs.scheduled-drift.outputs.drift-count || '0') > 0", cond)
        # 成功・skipped のときに走らせない。`!=` 側で書くと、skipped で起票する
        self.assertNotIn("!=", cond)

    def test_scheduled_report_は赤の発信と例の絵の発信を別の_step_で出す(self):
        # 同じ step に畳むと、例の絵の名指しだけで走った回に、緑の検査を「落ちている」と
        # 起票するか、赤の発信が落ちた回に例の絵の名指しが消えるかのどちらかになる
        body = self.jobs["scheduled-report"]
        by_name = {re.search(r"name: (.+)", s).group(1): s for s in steps(body) if "name:" in s}
        red = by_name["赤を発信する"]
        self.assertIn("scripts/report-scheduled-render.sh", red)
        # 赤の発信は debug・release・比べる job の failure / cancelled を拾い、結論を渡す (7 つ目の引数)
        for job in SCHEDULED_RUNNER_JOBS:
            self.assertIn(f"needs.{job}.result == 'failure'", red, job)
            self.assertIn(f"needs.{job}.result == 'cancelled'", red, job)
        self.assertIn("DRIFT_RESULT: ${{ needs.scheduled-drift.result }}", red)
        self.assertIn('"$DRIFT_RESULT"', red)
        # 変わった絵の本数 (drift-count) では動かない。それは下の step の問い
        self.assertNotIn("drift-count", red)
        shots = by_name["画素の変わった例の絵を発信する"]
        self.assertIn("scripts/report-example-drift.sh", shots)
        # 手前の赤の発信が落ちても走る (別の問い)。cancel された run では走らない
        self.assertIn("!cancelled() && fromJSON(needs.scheduled-drift.outputs.drift-count || '0') > 0", shots)
        # 記録を落とせなかった回も、名乗った本数を渡して起票する
        self.assertIn("DRIFT_COUNT: ${{ needs.scheduled-drift.outputs.drift-count }}", shots)

    def test_scheduled_report_は_needs_が赤でも走る(self):
        # `if:` に状態の関数が無いと、GitHub は暗黙の success() を足す。needs が failure /
        # cancelled の回にこそ走る job が skipped になり、#2084 と同じく黙って抜ける。
        # 専用機の job の検査 (test_門番が赤でも専用機のジョブは走る) と同じく、`if:` の
        # 先頭の項として持つことを見る
        cond = condition(self.jobs["scheduled-report"])
        self.assertRegex(cond, r"^(always\(\)|!cancelled\(\)) && ", cond)

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
            DRIFT_JOB: "scheduled-drift-turn",
        }
        self.assertEqual(set(gate), set(ALL_RUNNER_JOBS))
        for name, turn in gate.items():
            needs = re.search(r"(?m)^    needs: (.+)$", self.jobs[name])
            self.assertIsNotNone(needs, name)
            self.assertIn(turn, needs.group(1), name)

    def test_門番が赤でも専用機のジョブは走る(self):
        # needs が落ちると、if に状態の関数が無いジョブは skipped になる。render の skipped は
        # 必須チェックを満たすので、描かずに merge される
        # always() ではなく !cancelled() — always() は cancel された run (queue-sweep が捨てた
        # group など) でも専用機に積み、取り合いを増やす
        for name in ALL_RUNNER_JOBS:
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
            # 門番ごとに、その job が呼ぶ mode の上限と比べる。merge_group の上限 (期限の手前) を
            # 伸ばしても、wait だけを待つ定期の門番の timeout を巻き込まない (#3502)
            called = set(re.findall(r"render-turn\.sh (merge_group|yield|wait)\b", self.jobs[name]))
            self.assertTrue(called, name)
            # 上限は門番が自分で守る。timeout に任せると GitHub の cancel の扱いになる
            self.assertGreater(timeout, max(limits[m] for m in called), name)


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

    def test_step_を切り_steps_の外の行を混ぜない(self):
        text = (
            "jobs:\n  a:\n    steps:\n      - uses: x\n        with:\n          k: v\n"
            "      # 説明\n      - run: make t CI=\n    timeout-minutes: 5\n"
        )
        _, jobs = split(text)
        self.assertEqual(
            steps(jobs["a"]), ["      - uses: x\n        with:\n          k: v", "      - run: make t CI="]
        )
        self.assertEqual(steps("    runs-on: r"), [])


if __name__ == "__main__":
    unittest.main()
