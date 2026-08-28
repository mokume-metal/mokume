#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/review-gate.sh の検査 (#44 / #104 / #309)。

このゲートが守るのは mokume 固有の四点だけ:
  1. PR が Issue に紐づいている (例外は no-issue ラベル)
  2. 対象 Issue に verify: ラベルがある (完了条件が固まっている)
  3. 承認が要る PR の author が、唯一の承認者になっていない (ADR-0007 / #88)
  4. verify: human なら人間の Approve がある

重要パスの承認要求そのものはルールセットの required_reviewers が担うので、ここでは見ない — 3 が
CODEOWNERS を読むのは「誰が承認できるか」を知るためで、承認を重ねて要求するため
ではない。`review: approved` ラベルの fallback は identity 分離 (ADR-0003) で
廃止した。**外したことが戻らない**ことを最後の 2 ケースで固定する。

終了コードは三つに分かれる — 0 (通過) / 20 (承認待ち) / 1 (差し戻し)。**承認待ちだけが
正常な状態**で、これを 1 と同じにすると ci-gate が承認待ちで赤くなり、監視の誤検出
(#111) と「承認しても自動で進まない」(#256) の二つが起きる。assert_pending がその
区別を固定する。

1 の紐づけは **GitHub が実際に作った紐づけ (closingIssuesReferences)** で判定する。本文の
文字列を照合していた頃は、コードスパンに入れた `Closes #N` を通していた — GitHub は
closing keyword をコードスパンの中では読まないので、緑のままマージされて Issue が開いた
まま残った (#307 → #309)。偽 gh が返す紐づけは実測値をそのまま写す (下の closes 引数)。

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
#   gh pr view <n> -R <repo> --json labels,latestReviews,author,files,closingIssuesReferences
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


# 既定のリポジトリ。closingIssuesReferences は他リポジトリの Issue も指せるので、
# review-gate は自リポの紐づけだけを採る (別リポの番号で verify ラベルを引くと、
# 同じ番号の無関係な Issue を見てしまう)
REPO_OWNER, REPO_NAME = "mokume-metal", "mokume"


def closing_refs(numbers, owner=REPO_OWNER, name=REPO_NAME):
    """GitHub が返す紐づけの形 (gh pr view --json closingIssuesReferences)。"""
    return [
        {"number": n, "repository": {"name": name, "owner": {"login": owner}}}
        for n in numbers
    ]


def pr_json(body="Closes #12", closes=(12,), labels=(), reviews=(), author=APP, files=(),
            refs=None):
    """偽の gh pr view 応答。

    body と closes は**別々に**渡す。ゲートは body を読まないので、両者が食い違う形
    (書いてあるのに紐づいていない) をそのまま表現できる — それが #309 の事象である。
    refs を渡すと closes を無視して紐づけをそのまま置く (他リポジトリの検査用)。
    """
    login, is_bot = author
    return json.dumps(
        {
            "body": body,
            "labels": [{"name": n} for n in labels],
            "latestReviews": [{"state": s} for s in reviews],
            "author": {"login": login, "is_bot": is_bot},
            "files": [{"path": p} for p in files],
            "closingIssuesReferences": (
                closing_refs(closes) if refs is None else refs
            ),
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
        # 紐づけの所属リポジトリ判定に効くので、環境に左右されないよう固定する
        env["GITHUB_REPOSITORY"] = f"{REPO_OWNER}/{REPO_NAME}"
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), "12"], capture_output=True, text=True, env=env
        )

    def assert_blocked(self, proc, message):
        self.assertNotEqual(proc.returncode, 0, f"通ってしまった: {proc.stdout}")
        self.assertEqual(proc.returncode, 1, f"差し戻しは 1 で表す: {proc.stdout}")
        self.assertIn(message, proc.stderr)
        self.assertIn("次にすること", proc.stderr)

    def assert_pending(self, proc):
        """承認待ち — 差し戻し (1) と区別できる終了コード 20 で抜ける (#111 / #256)。

        1 と一緒にすると ci.yml が両者を見分けられず、承認待ちが ci-gate の赤に
        なる。赤くなると監視が故障と誤検出し (#111)、承認しても古い失敗 run が
        判定を固定して自動では進まなくなる (#256)。
        """
        self.assertEqual(proc.returncode, 20, f"承認待ちではない: {proc.stdout} {proc.stderr}")
        self.assertIn("承認待ち", proc.stdout)
        self.assertIn("次にすること", proc.stdout)

    # --- 1. Issue への紐づけ ------------------------------------------------

    def test_pr_without_issue_is_blocked(self):
        proc = self.run_gate(pr_json(body="Issue に触れていない本文", closes=()))
        self.assert_blocked(proc, "Issue に紐づいていない")

    def test_no_issue_label_is_an_accepted_exception(self):
        proc = self.run_gate(pr_json(body="紐づけなし", closes=(), labels=["no-issue"]))
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_plain_closes_passes(self):
        # 素の Closes #N。GitHub が紐づけを作るので通る (PR #313 / #316 の実測と同じ形)
        proc = self.run_gate(
            pr_json(body="Closes #12", closes=(12,)), issue_json("verify: machine")
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_closes_inside_a_code_span_is_blocked(self):
        """#309 — 書いてあるが GitHub には効かない形。

        バックティックで囲むと GitHub は closing keyword を読まないので、紐づけは
        作られない (PR #307 の closingIssuesReferences は実際に空だった)。本文の文字列
        を照合していた頃はここが通り、マージしても Issue #290 が開いたまま残った。
        引用・打ち消しなど他の「効かない形」も、GitHub が答える以上まとめて弾ける。
        """
        proc = self.run_gate(pr_json(body="`Closes #12`", closes=()))
        self.assert_blocked(proc, "Issue に紐づいていない")
        # 書いたのに差し戻された人が理由に辿り着けること (緑にも赤にも合図が
        # 無かったのが事象の半分だった)
        self.assertIn("コードスパン", proc.stderr)

    def test_closing_reference_to_another_repository_does_not_count(self):
        # Closes owner/repo#N は他リポジトリの Issue を閉じる。番号をそのまま採ると
        # 自リポの同じ番号の Issue を見にいくので、紐づけなしとして扱う
        proc = self.run_gate(
            pr_json(
                body="Closes other-org/other-repo#12",
                refs=closing_refs([12], owner="other-org", name="other-repo"),
            )
        )
        self.assert_blocked(proc, "Issue に紐づいていない")

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
        self.assert_pending(proc)  # 承認待ちであって詰みではない

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
        self.assert_pending(proc)

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

    def test_verify_human_without_review_is_pending_not_blocked(self):
        # **赤ではなく承認待ち** (#111 / #256)。ここを 1 に戻すと二つの害が復活する
        proc = self.run_gate(pr_json(), issue_json("verify: human"))
        self.assert_pending(proc)

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
        self.assert_pending(proc)

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
