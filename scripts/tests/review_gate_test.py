#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/review-gate.sh の検査 (#44 / #104)。

このゲートが守るのは mokume 固有の四点だけ:
  1. PR が Issue に紐づいている (例外は no-issue ラベル)
  2. 対象 Issue に verify: ラベルがある (完了条件が固まっている)
  3. 承認が要る PR の author が、唯一の承認者になっていない (ADR-0007 / #88)
  4. verify: human なら人間の Approve がある

重要パスの承認要求そのものは CODEOWNERS が担うので、ここでは見ない — 3 が
CODEOWNERS を読むのは「誰が承認できるか」を知るためで、承認を重ねて要求するため
ではない。`review: approved` ラベルの fallback は identity 分離 (ADR-0003) で
廃止した。**外したことが戻らない**ことを最後の 2 ケースで固定する。

gh は PATH の先頭に置いた偽物へ差し替え、CODEOWNERS も一時ファイルへ差し替えるので、
ネットワークも認証も実ファイルの内容も要らない。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "review-gate.sh"

# 実物と同じ形の CODEOWNERS (owner はメンテナ 1 人)
CODEOWNERS = """# 重要パス
/docs/decisions/ @shinyaoguri
/.github/        @shinyaoguri
/.claude/        @shinyaoguri
"""

# 偽 gh。review-gate が呼ぶのは 2 つだけ:
#   gh pr view <n> -R <repo> --json body,labels,latestReviews,author,files
#   gh issue view <n> -R <repo> --json labels --jq <query>
# 応答は環境変数で決める。--jq が付くときは本物と同じようにクエリを適用する
FAKE_GH = """#!/bin/sh
kind=$2
query=
prev=
for arg in "$@"; do
  [ "$prev" = "--jq" ] && query=$arg
  prev=$arg
done
case "$1 $2" in
  "pr view") json=$FAKE_PR_JSON ;;
  "issue view") json=$FAKE_ISSUE_JSON ;;
  *) exit 1 ;;
esac
if [ -n "$query" ]; then
  printf '%s' "$json" | jq -r "$query"
else
  printf '%s' "$json"
fi
"""

# 既定の author は App — エージェントの常道であり、承認可能性の検査を素通しする側
APP = ("app/mokume-agent", True)
MAINTAINER = ("shinyaoguri", False)
OUTSIDER = ("drive-by-contributor", False)


def pr_json(body="Closes #12", labels=(), reviews=(), author=APP, files=()):
    login, is_bot = author
    return json.dumps(
        {
            "body": body,
            "labels": [{"name": n} for n in labels],
            "latestReviews": [{"state": s} for s in reviews],
            "author": {"login": login, "is_bot": is_bot},
            "files": [{"path": p} for p in files],
        }
    )


def issue_json(*labels):
    return json.dumps({"labels": [{"name": n} for n in labels]})


class ReviewGateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bindir = Path(self.tmp.name) / "bin"
        self.bindir.mkdir()
        stub = self.bindir / "gh"
        stub.write_text(FAKE_GH, encoding="utf-8")
        stub.chmod(0o755)
        self.codeowners = Path(self.tmp.name) / "CODEOWNERS"
        self.codeowners.write_text(CODEOWNERS, encoding="utf-8")

    def run_gate(self, pr, issue=None, codeowners=None):
        if codeowners is not None:
            self.codeowners.write_text(codeowners, encoding="utf-8")
        env = dict(os.environ)
        env["PATH"] = f"{self.bindir}:{env['PATH']}"
        env["FAKE_PR_JSON"] = pr
        env["FAKE_ISSUE_JSON"] = issue if issue is not None else issue_json()
        env["CODEOWNERS_FILE"] = str(self.codeowners)
        return subprocess.run(
            ["bash", str(SCRIPT), "12"], capture_output=True, text=True, env=env
        )

    def assert_blocked(self, proc, message):
        self.assertNotEqual(proc.returncode, 0, f"通ってしまった: {proc.stdout}")
        self.assertIn(message, proc.stderr)
        self.assertIn("次にすること", proc.stderr)

    # --- 1. Issue への紐づけ ------------------------------------------------

    def test_pr_without_issue_is_blocked(self):
        proc = self.run_gate(pr_json(body="Issue に触れていない本文"))
        self.assert_blocked(proc, "Issue に紐づいていない")

    def test_no_issue_label_is_an_accepted_exception(self):
        proc = self.run_gate(pr_json(body="紐づけなし", labels=["no-issue"]))
        self.assertEqual(proc.returncode, 0, proc.stderr)

    # --- 2. verify ラベル ---------------------------------------------------

    def test_issue_without_verify_label_is_blocked(self):
        proc = self.run_gate(pr_json(), issue_json("status: in progress"))
        self.assert_blocked(proc, "verify: ラベルが無い")

    def test_verify_machine_passes_unattended(self):
        proc = self.run_gate(pr_json(), issue_json("verify: machine"))
        self.assertEqual(proc.returncode, 0, proc.stderr)

    # --- 3. 承認可能性の不変条件 (ADR-0007 / #88) ---------------------------

    def test_maintainer_authored_verify_human_pr_is_blocked(self):
        # #88 と同じ形。唯一の承認者が author 本人なので、承認は永久に来ない
        proc = self.run_gate(
            pr_json(author=MAINTAINER, files=["README.md"]),
            issue_json("verify: human"),
        )
        self.assert_blocked(proc, "誰も承認できない")
        # ADR-0007 決定 4 — 回復手順まで示し、待てば済むと読めてはいけない
        self.assertIn("close", proc.stderr)
        self.assertIn("作り直して", proc.stderr)
        self.assertIn("永久に来ません", proc.stderr)

    def test_app_authored_verify_human_pr_passes(self):
        # 同じ PR を App identity で作れば通る (CODEOWNERS に App は書けないので
        # 承認者集合に入りようがない)
        proc = self.run_gate(
            pr_json(author=APP, files=["README.md"]), issue_json("verify: human")
        )
        self.assert_blocked(proc, "メンテナの承認が必要")  # 承認待ちであって詰みではない

    def test_maintainer_authored_pr_without_required_approval_passes(self):
        # verify: machine かつ CODEOWNERS 対象外 — そもそも承認が要らない
        proc = self.run_gate(
            pr_json(author=MAINTAINER, files=["README.md", "scripts/foo.sh"]),
            issue_json("verify: machine"),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_maintainer_authored_pr_touching_a_codeowned_path_is_blocked(self):
        # verify: machine でも CODEOWNERS が承認を要求するので同じく詰む
        proc = self.run_gate(
            pr_json(author=MAINTAINER, files=[".claude/settings.json"]),
            issue_json("verify: machine"),
        )
        self.assert_blocked(proc, "誰も承認できない")

    def test_outside_contributor_is_not_blocked(self):
        # author が承認者集合の外 — メンテナが承認できるので詰んでいない。
        # 「author が bot でなければ差し戻す」という近似ではここを誤って止める
        proc = self.run_gate(
            pr_json(author=OUTSIDER, files=["docs/decisions/0009-x.md"]),
            issue_json("verify: human"),
        )
        self.assert_blocked(proc, "メンテナの承認が必要")

    def test_a_second_owner_makes_the_pr_approvable(self):
        # メンテナが増えれば不変条件は自然に満たされる (ADR-0007 影響節)
        proc = self.run_gate(
            pr_json(author=MAINTAINER, files=[".claude/settings.json"]),
            issue_json("verify: machine"),
            codeowners="/.claude/ @shinyaoguri @second-maintainer\n",
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_an_existing_approval_proves_the_pr_was_approvable(self):
        # 現に承認が付いているなら詰んでいない (自己承認はできないので他人が付けた)
        proc = self.run_gate(
            pr_json(author=MAINTAINER, files=[".claude/settings.json"], reviews=["APPROVED"]),
            issue_json("verify: human"),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    # --- 4. verify: human は人間の承認を待つ --------------------------------

    def test_verify_human_without_review_is_blocked(self):
        proc = self.run_gate(pr_json(), issue_json("verify: human"))
        self.assert_blocked(proc, "メンテナの承認が必要")

    def test_verify_human_with_approval_passes(self):
        proc = self.run_gate(
            pr_json(reviews=["APPROVED"]), issue_json("verify: human")
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_changes_requested_blocks_even_with_an_approval(self):
        proc = self.run_gate(
            pr_json(reviews=["APPROVED", "CHANGES_REQUESTED"]),
            issue_json("verify: machine"),
        )
        self.assert_blocked(proc, "変更要求")

    # --- 廃止したものが戻らないことの固定 -----------------------------------

    def test_review_approved_label_no_longer_substitutes_for_a_review(self):
        # identity 分離 (ADR-0003) までの暫定 fallback。ラベルはエージェント自身も
        # 付けられるので、承認の代わりにはならない
        proc = self.run_gate(
            pr_json(labels=["review: approved"]), issue_json("verify: human")
        )
        self.assert_blocked(proc, "メンテナの承認が必要")

    def test_important_paths_are_left_to_codeowners(self):
        # 重要パスに触れていても、対象 Issue が verify: machine で author が
        # 承認者集合の外なら通す。承認を要求するのは CODEOWNERS 側 (native の
        # Review required)
        proc = self.run_gate(
            pr_json(files=[".github/workflows/ci.yml"]), issue_json("verify: machine")
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("重要パス", proc.stdout + proc.stderr)


if __name__ == "__main__":
    unittest.main()
