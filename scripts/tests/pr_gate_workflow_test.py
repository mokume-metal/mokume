#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""`.github/workflows/pr-gate.yml` の、PR の作法の必須チェックの形の検査 (#2611・#2668)。

pr-gate は PR の作法 (タイトル・マージ判定・描画の絵) を、コードの検査の ci-gate と別の
必須チェックにまとめる。**どれも `if:` や 1 行の綴りが崩れると、run は緑のまま保証が外れる。**
ここで固定するのは次の 9 つ:

  1. 起動は pull_request (ready_for_review を含む)・pull_request_review・merge_group だけ。
     pull_request_target / workflow_dispatch / push を持たない
  2. pr-gate は merge_group でだけ skipped になる — merge_group で報告が無いと queue が期限まで
     待ち、PR の出来事 (Draft を含む) で skipped になると判定せずに必須を満たす。Draft を
     skipped にすると、ready の直後の数秒に判定していない skipped が最新として残る
  3. pr-gate は必須チェックに載っている (main-protection.json)
  4. 判定のスクリプトは既定ブランチの版で走らせる — PR の木 (head / merge ref / base) を
     checkout すると、同じ PR の中で自分を裁く検査を書き換えて通れる (#2001)。ADR-0031 決定 2 の
     脱出口を使う PR は、この固定も同じ PR で外す (その検査の docstring・#2724)
  5. 権限は読むだけ (contents / issues / pull-requests の read)。秘密を持たない
  6. ペイロードの可変な欄 (title / body / labels) を読まない — rerun が古い値を再生しない (#699)
  7. 3 つの判定はどの起動でも走り、前が赤でも後ろが走る。continue-on-error で赤を化かさない
  8. タイトルの照合は API で読んだタイトルに当たり、Conventional Commits の type だけを通す。
     落ちたときの文面は、直せば付け直されると言い、新しいコミット (空コミット) を案内しない —
     作法の検査が ci.yml の ci-gate から外れた (#2669) ので、古い赤を外す手は要らない
  9. PR の材料 (メタデータ・変更ファイル) は先頭の pr-snapshot が 1 回だけ取り、3 つの判定は
     それを読む (#3261)。取得が欠けても緩まない (落ちれば job が赤・環境変数が立たなければ
     読み手は自前で取る)。API の呼び出しの回数は SingleFetchTest が偽の gh で数える

PR と queue で実際に結論が返ることは、使い捨ての Draft PR で確かめる (#2668 の PR 本文)。
ワークフローの読み手 (split / condition) は render_workflow_test.py のものを使う (写しを持たない)。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

import render_workflow_test as workflow

REPO = Path(__file__).resolve().parents[2]
GATE = REPO / ".github" / "workflows" / "pr-gate.yml"
RULESET = REPO / ".github" / "rulesets" / "main-protection.json"

CHECKS = ("pr-title (Conventional Commits)", "review-gate", "drawing-evidence")
# 3 つの判定が読む PR の材料を 1 回だけ取る step (#3261)。checkout の次、判定の前
SNAPSHOT = "pr-snapshot"


def steps(body):
    """ジョブの steps を、step ごとの本文 (先頭の `- ` を外したもの) の並びで返す。"""
    found, current = [], None
    in_steps = False
    for ln in body.splitlines():
        if re.match(r"^    steps:\s*$", ln):
            in_steps = True
            continue
        if not in_steps:
            continue
        if re.match(r"^    \S", ln):
            break
        m = re.match(r"^      - (.*)$", ln)
        if m:
            current = [m.group(1)]
            found.append(current)
        elif current is not None:
            current.append(ln)
    return ["\n".join(s) for s in found]


def step_named(body, name):
    for s in steps(body):
        if re.search(rf"(?m)^(name: |\s+name: ){re.escape(name)}\s*$", s):
            return s
    raise KeyError(name)


def run_block(step):
    """step の `run: |` の中身 (字下げを外したもの)。"""
    m = re.search(r"(?ms)^        run: \|\n(.*)", step)
    if m:
        return textwrap.dedent(m.group(1))
    # 1 行の run: (判定の step は scripts を呼ぶだけ)
    m = re.search(r"(?m)^        run: (\S.*)$", step)
    if not m:
        raise ValueError("run: が無い")
    return m.group(1)


class PrGateWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = GATE.read_text(encoding="utf-8")
        cls.top, cls.jobs = workflow.split(cls.text)
        cls.gate = cls.jobs["pr-gate"]

    def test_起動は_PR_とレビューと_merge_group_だけ(self):
        triggers = set(re.findall(r"^  ([a-z_]+):", self.top["on"], re.M))
        self.assertEqual(triggers, {"pull_request", "pull_request_review", "merge_group"})
        types = re.search(r"(?m)^    types: \[(.*)\]\s*$", self.top["on"]).group(1)
        self.assertEqual(
            {t.strip() for t in types.split(",")},
            {"opened", "edited", "synchronize", "reopened", "labeled", "unlabeled", "ready_for_review"},
        )

    def test_merge_group_でだけ_skipped_になる(self):
        self.assertEqual(workflow.condition(self.gate), "github.event_name != 'merge_group'")

    def test_必須チェックに載っている(self):
        rules = json.loads(RULESET.read_text(encoding="utf-8"))["rules"]
        required = next(r for r in rules if r["type"] == "required_status_checks")
        contexts = {c["context"] for c in required["parameters"]["required_status_checks"]}
        self.assertIn("pr-gate", contexts)
        # ci-gate はコードの検査の必須として残る (#2669 で外したのは作法の検査だけ)
        self.assertIn("ci-gate", contexts)

    def test_判定は既定ブランチの版で走らせる(self):
        """ADR-0031 決定 2 の脱出口を使う PR では、この ref の固定も同じ PR で外し、後続の PR で戻す。

        脱出口は、判定が壊れていて、それを直す PR も同じ判定で赤になるときに、pr-gate.yml の checkout の
        with: と ref の 2 行を外して PR の版の判定で走らせる形である。2 行だけを外すとここが赤になり、
        必須の ci-gate (make hooks-test) で止まる (#2724)。外すのは下の ref の assertIn (案内の文ごと)
        だけで、checkout が先頭にあること・PR の木を指す式が無いことの固定は残す。後続の PR で、
        pr-gate.yml の 2 行とこの assertIn を両方戻す。
        """
        checkouts = [s for s in steps(self.gate) if s.startswith("uses: actions/checkout@")]
        self.assertEqual(len(checkouts), 1)
        self.assertIn(
            "ref: ${{ github.event.repository.default_branch }}", checkouts[0],
            "脱出口 (ADR-0031 決定 2) で pr-gate.yml の with: と ref の行を外す PR なら、"
            "この assertIn も同じ PR で外し、後続の PR で両方戻す",
        )
        self.assertEqual(steps(self.gate)[0], checkouts[0], "checkout より前に何かを走らせている")
        for bad in ("pull_request.head", "pull_request.base", "github.sha", "github.head_ref", "github.ref }}"):
            self.assertNotIn(bad, self.gate, bad)

    def test_権限は読むだけで秘密を持たない(self):
        self.assertRegex(self.top["permissions"], r"^\s*contents:\s*read\s*$")
        perms = re.search(r"(?ms)^    permissions:\n((?:      .*\n)+)", self.gate + "\n").group(1)
        granted = dict(re.findall(r"(?m)^      ([a-z-]+):\s*(\w+)", perms))
        self.assertEqual(granted, {"contents": "read", "issues": "read", "pull-requests": "read"})
        self.assertNotIn("secrets.", self.text)
        self.assertNotIn("pull_request_target", self.top["on"])

    def test_ペイロードの可変な欄を読まない(self):
        body = "\n".join(ln for ln in self.text.splitlines() if not ln.lstrip().startswith("#"))
        for field in ("title", "body", "labels"):
            self.assertNotIn(f"github.event.pull_request.{field}", body, field)

    def test_3_つの判定はどの起動でも走り_前が赤でも後ろが走る(self):
        names = [m for s in steps(self.gate) for m in re.findall(r"(?m)^\s*name: (.+?)\s*$", s)]
        self.assertEqual(names, [SNAPSHOT, *CHECKS])
        self.assertNotIn("continue-on-error", self.gate)
        # pr-snapshot が落ちても (材料の取得が先に赤になっても) 3 つの判定は走る。環境変数が
        # 立たないので、読み手は自前で取る (緩む方向には倒れない)
        for name in CHECKS:
            self.assertRegex(step_named(self.gate, name), r"(?m)^        if: \$\{\{ !cancelled\(\) \}\}$", name)
        # 判定の step は起動の種類で絞らない (1 つの check に束ねるので、絞った起動の緑が
        # ほかの赤を隠す)
        for name in (SNAPSHOT, *CHECKS):
            self.assertNotIn("event_name", step_named(self.gate, name), name)
        self.assertIn("bash scripts/review-gate.sh", step_named(self.gate, "review-gate"))
        self.assertIn("bash scripts/check-drawing-evidence.sh", step_named(self.gate, "drawing-evidence"))

    def test_材料は_checkout_の次の_pr_snapshot_が1回だけ取る(self):
        """3 つの判定が各自で取ると、メタデータ 3 回・変更ファイル 2 回になる (#3261)。"""
        order = [re.search(r"(?m)^(?:name: |\s+name: )(.+?)\s*$", s) for s in steps(self.gate)]
        self.assertEqual([m.group(1) if m else None for m in order], [None, SNAPSHOT, *CHECKS])
        snapshot = step_named(self.gate, SNAPSHOT)
        self.assertNotRegex(snapshot, r"(?m)^        if:", "取得は条件なしで走る")
        # メタデータは 3 つの読み手の欄の和集合を 1 回で、変更ファイルは pr_files で 1 回
        self.assertEqual(snapshot.count("gh pr view"), 1)
        self.assertEqual(snapshot.count("pr_files "), 1)
        for field in (
            "title", "body", "labels", "number", "latestReviews", "closingIssuesReferences",
            "baseRefName", "headRefOid", "createdAt",
        ):
            self.assertRegex(snapshot, rf"--json [\w,]*\b{field}\b", field)
        # 環境変数は取り終えた後で立てる — 途中で落ちた回に、半端な置き場を読み手へ渡さない
        self.assertRegex(snapshot, r"(?s)pr_files .*MOKUME_PR_SNAPSHOT_DIR=.*>>\"\$GITHUB_ENV\"")
        # 判定の step は自分で取りに行かない (review-gate・drawing-evidence の取得は scripts/pr-files.sh)
        for name in CHECKS[1:]:
            self.assertNotIn("gh ", step_named(self.gate, name), name)

    def test_concurrency_を持たず_どの_run_も打ち切らない(self):
        """必須は作成順で最新の suite を読み、完了順は問わない (scripts/ci-gate.sh 冒頭の規則・#2577)。
        group の効果は打ち切りだけで、打ち切られた run が最新の suite なら必須を塞ぐ。走っている run の
        打ち切り (#2712) も、待ちの置き換え (ジョブの無い cancelled・#2716 の 2 回目の反証) も起こさない。
        ワークフロー単位にも、ジョブ単位にも置かない。"""
        self.assertNotIn("concurrency", self.top)
        for name, body in self.jobs.items():
            self.assertNotRegex(body, r"(?m)^    concurrency:", name)


class TitleCheckTest(unittest.TestCase):
    """タイトルの照合の step を、API の代わりの gh を置いて実際に走らせる。"""

    @classmethod
    def setUpClass(cls):
        _, jobs = workflow.split(GATE.read_text(encoding="utf-8"))
        cls.script = run_block(step_named(jobs["pr-gate"], CHECKS[0]))

    def check(self, title):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "gh"
            # 引数を記録し、API の返すタイトルを出す
            fake.write_text('#!/bin/bash\necho "$*" >"$FAKE_LOG"\nprintf "%s\\n" "$FAKE_TITLE"\n')
            fake.chmod(0o755)
            log = Path(tmp) / "log"
            env = dict(
                os.environ,
                PATH=f"{tmp}:{os.environ['PATH']}",
                FAKE_TITLE=title,
                FAKE_LOG=str(log),
                GITHUB_REPOSITORY="owner/repo",
                PR_NUMBER="42",
            )
            r = subprocess.run(
                ["/bin/bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", self.script],
                env=env,
                capture_output=True,
                text=True,
            )
            return r, log.read_text() if log.exists() else ""

    def test_API_で読んだタイトルを照合する(self):
        r, log = self.check("ci: pr-gate を足す")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("repos/owner/repo/pulls/42", log)

    def test_type_と_scope_と_破壊的変更の印を通す(self):
        for title in ("feat(audio): 入力を足す", "fix!: 戻す", "build(deps)!: 上げる", "perf: 速くする"):
            with self.subTest(title=title):
                r, _ = self.check(title)
                self.assertEqual(r.returncode, 0, r.stderr)

    def test_誤ったタイトルを落とす(self):
        for title in ("Initial commit", "design: 方針", "feat:要約に空白が無い", "feat(): 空の scope", "style: 整形", "ci:"):
            with self.subTest(title=title):
                r, _ = self.check(title)
                self.assertEqual(r.returncode, 1, r.stdout)
                self.assertIn("Conventional Commits ではない", r.stderr)

    def test_落ちた文面は付け直されると言い_新しいコミットを案内しない(self):
        r, _ = self.check("Initial commit")
        self.assertEqual(r.returncode, 1, r.stdout)
        squash = lambda t: re.sub(r"\s+", "", t)  # noqa: E731
        self.assertIn(squash("pr-gate はその run で付け直される (打ち直しも新しいコミットも要らない)"), squash(r.stderr))
        for gone in ("空コミット", "ci-gate", "新しいコミットを push"):
            self.assertNotIn(gone, r.stderr, gone)


# 偽の gh。呼ばれた引数を 1 行ずつ記録し、PR 42 (no-issue・変更ファイルは 1 つ) の応答を返す。
# --jq が付けば本物と同じようにクエリを適用する
FAKE_GH_SINGLE = """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALLS"
query=; prev=
for arg in "$@"; do [ "$prev" = "--jq" ] && query=$arg; prev=$arg; done
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr view") json='{"number":42,"title":"ci: 取得を1回にする","body":"","labels":[{"name":"no-issue"}],"latestReviews":[],"closingIssuesReferences":[],"baseRefName":"main","headRefOid":"aaaa","createdAt":"2026-10-27T00:00:00Z"}' ;;
  "api "*) case "$*" in
             *"/files"*) json='[{"filename":"README.md"}]' ;;
             *) json='{"title":"ci: 取得を1回にする"}' ;;
           esac ;;
  *) exit 1 ;;
esac
if [ -n "$query" ]; then printf '%s' "$json" | jq -r "$query"; else printf '%s' "$json"; fi
"""

# review-gate・drawing-evidence の step は bash scripts/… を呼ぶだけなので、run: の本文をそのまま走らせる
BASH_FLAGS = ["/bin/bash", "--noprofile", "--norc", "-eo", "pipefail", "-c"]


class SingleFetchTest(unittest.TestCase):
    """3 つの判定が同じ PR の材料を 1 回ずつしか取らないこと (#3261)。

    workflow の run: をそのまま順に走らせる (pr-snapshot → 3 つの判定)。gh は偽で、呼び出しを数える。
    **この PR 自身の run では効かない** (判定は既定ブランチの scripts で走る) ので、効く経路はここでだけ確かめる。
    """

    ALL = (SNAPSHOT, *CHECKS)

    @classmethod
    def setUpClass(cls):
        _, jobs = workflow.split(GATE.read_text(encoding="utf-8"))
        cls.gate = jobs["pr-gate"]

    def run_steps(self, names, *, extra_env=None, before=None):
        """`names` の step を順に走らせ、([(名前, 終了コード, 出力)], gh の呼び出しの並び) を返す。

        `before(root, env)` は走らせる前の準備 (置き場を壊すなど)。
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = root / "bin" / "gh"
            fake.parent.mkdir()
            fake.write_text(FAKE_GH_SINGLE)
            fake.chmod(0o755)
            calls = root / "calls"
            github_env = root / "github_env"
            github_env.touch()
            (root / "runner").mkdir()
            env = dict(
                os.environ,
                PATH=f"{fake.parent}:{os.environ['PATH']}",
                GH_CALLS=str(calls),
                GITHUB_REPOSITORY="owner/repo",
                PR_NUMBER="42",
                RUNNER_TEMP=str(root / "runner"),
                GITHUB_ENV=str(github_env),
            )
            env.pop("MOKUME_PR_SNAPSHOT_DIR", None)
            env.update(extra_env or {})
            if before:
                before(root, env)
            results = []
            for name in names:
                r = subprocess.run(
                    [*BASH_FLAGS, run_block(step_named(self.gate, name))],
                    env=env, cwd=REPO, capture_output=True, text=True,
                )
                results.append((name, r.returncode, r.stdout + r.stderr))
                # 本物の runner と同じく、GITHUB_ENV に書かれた変数を次の step へ渡す
                for line in github_env.read_text().splitlines():
                    key, _, value = line.partition("=")
                    env[key] = value
            made = calls.read_text().splitlines() if calls.exists() else []
            return results, made

    @staticmethod
    def kinds(calls):
        """呼び出しを (PR のメタデータ, 変更ファイル, タイトルの REST) に数える。"""
        views = [c for c in calls if c.startswith("pr view")]
        files = [c for c in calls if "/files" in c]
        titles = [c for c in calls if c.startswith("api") and "/files" not in c]
        return len(views), len(files), len(titles)

    def assert_all_ok(self, results):
        for name, code, out in results:
            self.assertEqual(code, 0, f"{name}: {out}")

    def test_材料の取得は_メタデータ1回と変更ファイル1回(self):
        # pr-snapshot がこの 2 回を取り、title の REST も判定ごとの取得も呼ばれない
        results, calls = self.run_steps(self.ALL)
        self.assert_all_ok(results)
        self.assertEqual(self.kinds(calls), (1, 1, 0), calls)

    def test_事前取得が無ければ_従来どおり判定ごとに自前で取る(self):
        """pr-snapshot が落ちた回・この PR 自身の run (読み手が古い) と同じ形。緩まず、取り直す。"""
        results, calls = self.run_steps(CHECKS)
        self.assert_all_ok(results)
        # メタデータは review-gate と drawing-evidence、変更ファイルも同じ 2 つ、タイトルは REST
        self.assertEqual(self.kinds(calls), (2, 2, 1), calls)

    def test_置き場が壊れていても_判定は自前で取り直して通る(self):
        def corrupt(root, env):
            snap = root / "runner" / "pr-snapshot"
            snap.mkdir()
            (snap / "view-42.json").write_text("{not json")
            env["MOKUME_PR_SNAPSHOT_DIR"] = str(snap)

        results, calls = self.run_steps(CHECKS, before=corrupt)
        self.assert_all_ok(results)
        self.assertEqual(self.kinds(calls), (2, 2, 1), calls)

    def test_pr_snapshot_は取り終えてから環境変数を立てる(self):
        """gh が途中で落ちる回は環境変数が立たない — 半端な置き場を後ろの判定へ渡さない。"""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = root / "gh"
            fake.write_text("#!/bin/bash\nexit 1\n")
            fake.chmod(0o755)
            github_env = root / "github_env"
            github_env.touch()
            (root / "runner").mkdir()
            env = dict(
                os.environ, PATH=f"{tmp}:{os.environ['PATH']}", GITHUB_REPOSITORY="owner/repo",
                PR_NUMBER="42", RUNNER_TEMP=str(root / "runner"), GITHUB_ENV=str(github_env),
            )
            r = subprocess.run(
                [*BASH_FLAGS, run_block(step_named(self.gate, SNAPSHOT))],
                env=env, cwd=REPO, capture_output=True, text=True,
            )
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(github_env.read_text(), "")


class StepsReaderTest(unittest.TestCase):
    """読み手そのものの検査 — 壊れた読み手は、上の検査を黙って緑にする。"""

    def test_step_を切り_次のキーで止まる(self):
        body = (
            "    runs-on: x\n    steps:\n      - uses: a@v1\n        with:\n          ref: r\n"
            "      - name: b\n        run: |\n          echo b\n    outputs:\n      - name: c\n"
        )
        got = steps(body)
        self.assertEqual(len(got), 2)
        self.assertTrue(got[0].startswith("uses: a@v1"))
        self.assertEqual(run_block(step_named(body, "b")).strip(), "echo b")


if __name__ == "__main__":
    unittest.main()
