#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/review-gate.sh の検査 (#44 / #104 / #309 / #618)。

このゲートが守るのは mokume 固有の四点だけ:
  1. PR が Issue に紐づいている (例外は no-issue ラベル)
  2. 対象 Issue に verify: ラベルがある (完了条件が固まっている)
  3. PR 本文の「確認方法」節に、閉じる Issue の番号がすべて現れる (ADR-0031 決定 2)
  4. 承認が要る PR の author が、唯一の承認者になっていない (ADR-0007 / #88)

重要パスの承認要求そのものはルールセットの required_reviewers が担うので、ここでは見ない —
4 がその file_patterns を読むのは「承認が要る PR か」を知るためで、承認を重ねて要求するため
ではない。

**承認待ちはもう無い。** verify: human の Issue に紐づく PR へ Approve を要求していた頃は、
終了コード 20 で「承認待ち」を表し、それを 1 (差し戻し) と混ぜないことを固定していた
(#111 / #256)。263 件のマージで測ったら、この経路が固有に承認を要求したのは 36 件・変更要求は
0 件・初承認までの中央値は 11 分で、**止めていたのではなく待たせていただけ**だった (#618)。
ADR-0031 が畳んだので終了コードは 0 と 1 だけである。承認の判定が減ったぶん、赤は本物の故障に
近づいた。外したものが戻らないことは末尾の 2 ケースで押さえる。

1 の紐づけは **GitHub が実際に作った紐づけ (closingIssuesReferences)** で判定する。本文の
文字列を照合していた頃は、コードスパンに入れた `Closes #N` を通していた — GitHub は
closing keyword をコードスパンの中では読まないので、緑のままマージされて Issue が開いた
まま残った (#307 → #309)。偽 gh が返す紐づけは実測値をそのまま写す (下の closes 引数)。

3 が見るのは**構造だけ**である。番号が節に現れることは見るが、書いてある内容が正しいかは
見ない (check-drawing-evidence.sh と同じ形 — ADR-0019 決定 1)。

gh は PATH の先頭に置いた偽物へ差し替え、ルールセットの定義も一時ファイルへ差し替えるので、
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

# 実物と同じ形のルールセット定義 (承認を要求するパスの正本)。
# review-gate はここの file_patterns だけを読む
RULESET = json.dumps(
    {
        "name": "main-protection",
        "target": "branch",
        "enforcement": "active",
        "rules": [
            {
                "type": "pull_request",
                "parameters": {
                    "required_approving_review_count": 0,
                    "required_reviewers": [
                        {
                            "file_patterns": [
                                "docs/decisions/**",
                                ".github/**",
                                ".claude/**",
                            ],
                            "minimum_approvals": 1,
                            "reviewer": {"id": 1, "type": "Team"},
                        }
                    ],
                },
            }
        ],
    }
)

# 偽 gh。review-gate が呼ぶのは 4 つだけ:
#   gh pr view <n> -R <repo> --json body,labels,latestReviews,author,closingIssuesReferences
#   gh issue view <n> -R <repo> --json labels --jq <query>
#   gh api repos/<repo>/pulls/<n> --jq .author_association
#   gh api repos/<repo>/pulls/<n>/files --paginate --jq .[].filename   ← #793 で分かれた
# 応答は環境変数で決める。--jq が付くときは本物と同じようにクエリを適用する。
#
# **2 つの api を綴りで分ける。** 変更ファイルの一覧は別の口になったので (#793)、
# 一緒に返すと author_association の判定に一覧が流れ込む
FAKE_GH = """#!/bin/sh
printf '%s\\n' "$*" >> "${GH_CALLS:-/dev/null}"
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
  "api "*) case "$*" in
             *"/files"*) json=$FAKE_FILES_JSON ;;
             *) json=$FAKE_API_JSON ;;
           esac ;;
  *) exit 1 ;;
esac
if [ -n "$query" ]; then
  printf '%s' "$json" | jq -r "$query"
else
  printf '%s' "$json"
fi
"""

# author は (login, is_bot, author_association) の 3 つ組。3 つ目が承認可能性の検査に効く。
# 値は実測 (PR #529 / #528 の App は CONTRIBUTOR、#88 のメンテナは MEMBER)
# 既定の author は App — エージェントの常道であり、承認可能性の検査を素通しする側
APP = ("app/mokume-agent", True, "CONTRIBUTOR")
MAINTAINER = ("shinyaoguri", False, "MEMBER")
OUTSIDER = ("drive-by-contributor", False, "NONE")

# トリアージ済みの印。ADR-0031 より前は verify: machine / verify: human の 2 種類で、
# 後者だけが承認を要求していた。いまラベルが表すのは「完了条件が固まっている」だけである
TRIAGED = "verify: triaged"

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


def verification_section(numbers):
    """PR 本文の「確認方法」節 (ADR-0031 決定 2)。

    実物の .github/pull_request_template.md と同じ形 — Issue ごとに小見出しを立て、
    完了条件と確かめたことを並べる。**番号が小見出しにしか現れない**のが自然な書き方
    なので、節の取り出しが内側の見出しを落とさないこともここで固定される。
    """
    if not numbers:
        return ""
    rows = "\n\n".join(
        f"### Closes #{n}\n\n"
        "| 完了条件 | 着手時の現況 | 確かめたこと |\n"
        "| --- | --- | --- |\n"
        "| 1. …… | まだ有効 | make ci-check が緑 |"
        for n in numbers
    )
    return f"\n\n## 確認方法\n\n{rows}\n"


def pr_json(body="Closes #12", closes=(12,), labels=(), reviews=(), author=APP, files=(),
            refs=None, verified=None):
    """偽の gh pr view 応答。

    body と closes は**別々に**渡す。ゲートは closing keyword を body から読まないので、
    両者が食い違う形 (書いてあるのに紐づいていない) をそのまま表現できる — それが #309 の
    事象である。refs を渡すと closes を無視して紐づけをそのまま置く (他リポジトリの検査用)。

    verified には「確認方法」節へ載せる番号を渡す。既定は closes と同じ (通常の PR は
    閉じる Issue すべてに対応表を書く)。節ごと落とすには verified=() を渡す。
    """
    login, is_bot, assoc = author
    numbers = closes if verified is None else verified
    return json.dumps(
        {
            "body": body + verification_section(numbers),
            "labels": [{"name": n} for n in labels],
            "latestReviews": [{"state": s} for s in reviews],
            "author": {"login": login, "is_bot": is_bot},
            "files": [{"path": p} for p in files],
            "closingIssuesReferences": (
                closing_refs(closes) if refs is None else refs
            ),
            # gh pr view は返さない。run_gate が偽 gh api の応答を組むために持たせる
            "authorAssociation": assoc,
        }
    )


def assert_files_call_paginates(case, calls):
    """一覧を引く**その呼び出し**が `--paginate` を通っていること (#793)。

    記録全体に `--paginate` が現れるかを見てはいけない — 順番の判定が引く open な PR の
    一覧 (`drawing-queue.sh`) も `--paginate` を使うので、**付け忘れても緑になる**
    (最初にこの検査を書いたとき、まさにそれで空回りしていた)。
    """
    lines = [l for l in calls.read_text(encoding="utf-8").splitlines() if "/files" in l]
    case.assertTrue(lines, "変更ファイルの一覧を引いていない")
    for line in lines:
        case.assertIn("--paginate", line, f"ページングを通していない呼び出し: {line}")


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
        self.ruleset = Path(self.tmp.name) / "main-protection.json"
        self.ruleset.write_text(RULESET, encoding="utf-8")

    def run_gate(self, pr, issue=None, ruleset=None, all_files=None, record_calls=None):
        """`all_files` は **`--paginate` を通した一覧** (#793)。

        省略すると `pr` が持つ `files` と同じものになる。上限を越える PR を装うときだけ
        別に渡す — `gh pr view` の側は上限で切られた前半を、こちらは全件を返す形になる。
        """
        if ruleset is not None:
            self.ruleset.write_text(ruleset, encoding="utf-8")
        env = dict(os.environ)
        env["PATH"] = f"{self.bindir}:{env['PATH']}"
        env["FAKE_PR_JSON"] = pr
        if all_files is None:
            all_files = [f["path"] for f in json.loads(pr)["files"]]
        env["FAKE_FILES_JSON"] = json.dumps([{"filename": p} for p in all_files])
        env["FAKE_ISSUE_JSON"] = issue if issue is not None else issue_json(TRIAGED)
        env["FAKE_API_JSON"] = json.dumps(
            {"author_association": json.loads(pr)["authorAssociation"]}
        )
        env["RULESET_FILE"] = str(self.ruleset)
        env["GH_CALLS"] = str(record_calls) if record_calls else "/dev/null"
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

    # --- 1. Issue への紐づけ ------------------------------------------------

    def test_pr_without_issue_is_blocked(self):
        proc = self.run_gate(pr_json(body="Issue に触れていない本文", closes=()))
        self.assert_blocked(proc, "Issue に紐づいていない")

    def test_no_issue_label_is_an_accepted_exception(self):
        proc = self.run_gate(pr_json(body="紐づけなし", closes=(), labels=["no-issue"]))
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_plain_closes_passes(self):
        # 素の Closes #N。GitHub が紐づけを作るので通る (PR #313 / #316 の実測と同じ形)
        proc = self.run_gate(pr_json(body="Closes #12", closes=(12,)), issue_json(TRIAGED))
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

    def test_triaged_issue_passes_unattended(self):
        proc = self.run_gate(pr_json(), issue_json(TRIAGED))
        self.assertEqual(proc.returncode, 0, proc.stderr)

    # --- 3. 完了条件 × 検証の対応表 (ADR-0031 決定 2) -----------------------

    def test_pr_without_a_verification_table_is_blocked(self):
        """承認を外した代わりに置いた記録。無ければ通さない。

        直近 100 PR に付いたコメントは 32 件・行単位のレビューは 0 件で、「何をどう
        処理したか」がほとんど残っていなかった (#618)。承認が形式であっても「人が一度
        見た」印ではあったので、外すなら代わりが要る。
        """
        proc = self.run_gate(pr_json(verified=()), issue_json(TRIAGED))
        self.assert_blocked(proc, "対応表が無い")
        self.assertIn("#12", proc.stderr)

    def test_several_issues_can_be_closed_together(self):
        """1 PR は「1 つの説明で筋が通る範囲」 (ADR-0031 決定 3)。

        同じ親の sub-issue 群も、作業中に踏んで起票した障害もまとめて閉じてよい。
        粒度が大きくなっても追跡が効くのは、Issue ごとに対応表を要求するからである。
        """
        proc = self.run_gate(
            pr_json(body="Closes #12\nCloses #34", closes=(12, 34)), issue_json(TRIAGED)
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_table_must_cover_every_closed_issue(self):
        # まとめて閉じたのに片方しか書いていない — 書き忘れた側が名指しで出る
        proc = self.run_gate(
            pr_json(body="Closes #12\nCloses #34", closes=(12, 34), verified=(12,)),
            issue_json(TRIAGED),
        )
        self.assert_blocked(proc, "対応表が無い")
        self.assertIn("#34", proc.stderr)
        self.assertNotIn("#12)", proc.stderr)

    def test_numbers_outside_the_section_do_not_count(self):
        # 目的節の Closes #12 は節の外なので数えない。数えると「確認方法を書いた」が
        # 「Closes を書いた」で満たされ、検査が何も要求しなくなる
        proc = self.run_gate(
            pr_json(body="Closes #12 に対応する", verified=()), issue_json(TRIAGED)
        )
        self.assert_blocked(proc, "対応表が無い")

    def test_a_later_section_ends_the_verification_section(self):
        # 「確認方法」の後に同階層の見出しが来たら、そこから先は節の外
        body = "Closes #12" + verification_section([]) + "\n\n## 確認方法\n\n書いた\n\n## 補足\n\n#12 はここでは数えない\n"
        proc = self.run_gate(pr_json(body=body, verified=()), issue_json(TRIAGED))
        self.assert_blocked(proc, "対応表が無い")

    def test_no_issue_pr_is_exempt_from_the_table(self):
        # 閉じる Issue が無ければ、対応する完了条件も無い
        proc = self.run_gate(
            pr_json(body="紐づけなし", closes=(), labels=["no-issue"], verified=())
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_a_similar_number_does_not_satisfy_the_table(self):
        # #6180 を書いても #618 の対応表にはならない (境界を見る)
        proc = self.run_gate(
            pr_json(body="Closes #618", closes=(618,), verified=(6180,)),
            issue_json(TRIAGED),
        )
        self.assert_blocked(proc, "対応表が無い")

    # --- 4. 承認可能性の不変条件 (ADR-0007 / #88) ---------------------------

    def test_maintainer_authored_pr_touching_a_protected_path_is_blocked(self):
        # #88 と同じ形。唯一の承認者が author 本人なので、承認は永久に来ない
        proc = self.run_gate(
            pr_json(author=MAINTAINER, files=[".claude/settings.json"]),
            issue_json(TRIAGED),
        )
        self.assert_blocked(proc, "誰も承認できない")
        # ADR-0007 決定 4 — 回復手順まで示し、待てば済むと読めてはいけない
        self.assertIn("close", proc.stderr)
        self.assertIn("作り直して", proc.stderr)
        self.assertIn("永久に来ません", proc.stderr)

    def test_app_authored_pr_touching_a_protected_path_passes(self):
        # 同じ PR を App identity で作れば通る。App は org の外なので
        # author_association が CONTRIBUTOR になり、承認者集合に入りようがない。
        # 承認そのものはルールセットが要求し、GitHub 側で待つ
        proc = self.run_gate(
            pr_json(author=APP, files=[".claude/settings.json"]), issue_json(TRIAGED)
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_maintainer_authored_pr_without_required_approval_passes(self):
        # ルールセットの file_patterns 対象外 — 承認が要らないので詰みようがない
        proc = self.run_gate(
            pr_json(author=MAINTAINER, files=["README.md", "scripts/foo.sh"]),
            issue_json(TRIAGED),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_outside_contributor_is_not_blocked(self):
        # author が承認者集合の外 — メンテナが承認できるので詰んでいない。
        # 「author が bot でなければ差し戻す」という近似ではここを誤って止める
        proc = self.run_gate(
            pr_json(author=OUTSIDER, files=["docs/decisions/0009-x.md"]),
            issue_json(TRIAGED),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_a_protected_path_beyond_the_graphql_cap_is_still_seen(self):
        """**上限を越える PR** (#793)。

        `gh pr view --json files` は GraphQL の接続を引くので上限があり、大きな PR では
        後半のファイルが落ちる。落ちた先で起きるのは「保護パスに触れているのに触れて
        いないと読む」で、**赤くならずに緩む** — 誰も承認できない PR がそのまま作られる。

        ここでは `gh pr view` の側に無害な 100 件だけを持たせ、`--paginate` の側にだけ
        保護パスを 101 件目として置く。上限のある口を読んでいれば緑で通ってしまう。
        """
        truncated = [f"Sources/MokumeCore/Filler{i}.swift" for i in range(100)]
        proc = self.run_gate(
            pr_json(author=MAINTAINER, files=truncated),
            issue_json(TRIAGED),
            all_files=truncated + [".github/rulesets/main-protection.json"],
        )
        self.assert_blocked(proc, "誰も承認できない")

    def test_the_file_list_is_paginated(self):
        """一覧を引く呼び出しに `--paginate` が載っていること (#793)。

        判定の結果だけを見ていると、上限に収まる PR では**付け忘れても緑**になる。
        """
        calls = self.bindir.parent / "gh-calls.txt"
        proc = self.run_gate(
            pr_json(author=APP, files=["README.md"]),
            issue_json(TRIAGED),
            record_calls=calls,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        assert_files_call_paginates(self, calls)

    def test_protected_paths_come_from_the_ruleset_not_a_copy(self):
        """承認が要るパスの正本はルールセットで、写しを持たない (#530)。

        定義から `.claude/**` を外せば、同じ PR は承認不要として通る。CODEOWNERS を
        代理に読んでいた頃は、同じ 3 パスが 2 ファイルに綴り違いで写されていて、
        整合を見る検査が無かった。
        """
        narrowed = json.loads(RULESET)
        params = narrowed["rules"][0]["parameters"]
        params["required_reviewers"][0]["file_patterns"] = ["docs/decisions/**"]
        proc = self.run_gate(
            pr_json(author=MAINTAINER, files=[".claude/settings.json"]),
            issue_json(TRIAGED),
            ruleset=json.dumps(narrowed),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_an_existing_approval_proves_the_pr_was_approvable(self):
        # 現に承認が付いているなら詰んでいない (自己承認はできないので他人が付けた)
        proc = self.run_gate(
            pr_json(author=MAINTAINER, files=[".claude/settings.json"], reviews=["APPROVED"]),
            issue_json(TRIAGED),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_changes_requested_blocks_even_with_an_approval(self):
        proc = self.run_gate(
            pr_json(reviews=["APPROVED", "CHANGES_REQUESTED"]), issue_json(TRIAGED)
        )
        self.assert_blocked(proc, "変更要求")

    # --- 廃止したものが戻らないことの固定 -----------------------------------

    def test_the_gate_no_longer_waits_for_a_human_approval(self):
        """承認待ち (終了コード 20) が戻らないことの固定 (#618 / ADR-0031)。

        移行の途中で verify: human が残っている Issue に当たっても、見るのはラベルの
        有無だけである。ここが再び Approve を要求し始めたら、**承認を待つ状態が CI に
        戻る** — それは #111 (監視の誤検出) と #256 (承認しても進まない) を連れてくる。
        """
        proc = self.run_gate(
            pr_json(files=["README.md"]), issue_json("verify: human")
        )
        self.assertEqual(proc.returncode, 0, f"承認を待っている: {proc.stdout} {proc.stderr}")
        self.assertNotIn("承認待ち", proc.stdout + proc.stderr)

    def test_important_paths_are_left_to_the_ruleset(self):
        # 重要パスに触れていても、author が承認者集合の外なら通す。承認を要求するのは
        # ルールセットの required_reviewers 側 (native の Review required)
        proc = self.run_gate(
            pr_json(files=[".github/workflows/ci.yml"]), issue_json(TRIAGED)
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("重要パス", proc.stdout + proc.stderr)


if __name__ == "__main__":
    unittest.main()
