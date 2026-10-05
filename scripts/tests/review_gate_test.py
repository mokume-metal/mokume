#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/review-gate.sh の検査 (#44 / #104 / #309 / #618 / #1662 / #1668)。

このゲートが守るのは mokume 固有の五点だけ:
  1. PR が Issue に紐づいている (例外は no-issue ラベル)
  2. 対象 Issue に verify: ラベルがある (完了条件が固まっている)
  3. PR 本文の「確認方法」節に、閉じる Issue の番号がすべて現れる (ADR-0031 決定 2)
  4. 閉じる Issue に Bug が含まれるなら、本文に空でない「反証」の節がある (ADR-0040 決定 4)
  5. AGENTS.md を合流先との分岐点 (merge-base) より長くした PR は、本文の増分の宣言が
     実測と一致する (#1668。数え方と宣言の読み方は check-agents-md-size.py の growth が
     持ち、その細部は agents_md_size_test.py が見る。ここは材料の取り方と渡し方を見る)

**承認はどこにも無い。** ルールセットは承認を要求せず (ADR-0044)、ゲートが見るのは変更要求が
残っていないことだけである。重要パスに触れるメンテナ名義の PR を「誰も承認できない」と差し戻して
いた節 (ADR-0007 の不変条件) も、承認のゲートと一緒に外した (#2108)。

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

3 と 4 が見るのは**構造だけ**である。番号が節に現れること・節が空でないことは見るが、
書いてある内容が正しいかは見ない (check-drawing-evidence.sh と同じ形 — ADR-0019 決定 1)。

gh は PATH の先頭に置いた偽物へ差し替えるので、ネットワークも認証も要らない。実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "review-gate.sh"
TEMPLATE = REPO / ".github" / "pull_request_template.md"

# 偽 gh。review-gate が呼ぶのは 3 つだけ:
#   gh pr view <n> -R <repo> --json body,labels,latestReviews,closingIssuesReferences
#   gh issue view <n> -R <repo> --json labels,issueType   ← #1662 で型も同じ応答から取る
#   gh api repos/<repo>/pulls/<n>/files --paginate --jq .[].filename   ← #793 で分かれた
# 応答は環境変数で決める。--jq が付くときは本物と同じようにクエリを適用する。
#
#
# Issue の応答は既定で全 Issue 共通 (FAKE_ISSUE_JSON)。**番号ごとに変えるときだけ**
# FAKE_ISSUE_JSON_<番号> を置く — 複数の Issue のうち 1 つだけが Bug、を表すため (#1662)。
# FAKE_ISSUE_FAIL を置くと、古い gh が知らない欄を問われたときと同じく、それを名乗って
# 失敗する
#
# AGENTS.md の増分 (#1668) のために口が 2 つ増えた:
#   gh api repos/<repo>/compare/<base>...<head> --jq .merge_base_commit.sha
#   gh api -H 'Accept: application/vnd.github.raw' repos/<repo>/contents/AGENTS.md?ref=<sha>
# compare は FAKE_COMPARE_JSON を返す (FAKE_COMPARE_FAIL を置くと失敗する)。contents は
# FAKE_CONTENTS_DIR の下の <sha> という名前のファイルを返し、無ければ 404 で失敗する
FAKE_GH = """#!/bin/sh
printf '%s\\n' "$*" >> "${GH_CALLS:-/dev/null}"
kind=$2
query=
prev=
ref=
for arg in "$@"; do
  [ "$prev" = "--jq" ] && query=$arg
  case "$arg" in *"ref="*) ref=${arg##*ref=} ;; esac
  prev=$arg
done
case "$1 $2" in
  "pr view") json=$FAKE_PR_JSON ;;
  "issue view")
    if [ -n "${FAKE_ISSUE_FAIL:-}" ]; then
      printf '%s\\n' "$FAKE_ISSUE_FAIL" >&2
      exit 1
    fi
    # $3 は review-gate が渡す Issue 番号 (数字だけ) なので eval に載せてよい
    eval "json=\\${FAKE_ISSUE_JSON_$3:-\\$FAKE_ISSUE_JSON}" ;;
  "api "*) case "$*" in
             *"/compare/"*)
               if [ -n "${FAKE_COMPARE_FAIL:-}" ]; then
                 printf '%s\\n' "$FAKE_COMPARE_FAIL" >&2
                 exit 1
               fi
               json=$FAKE_COMPARE_JSON ;;
             *"/contents/"*)
               if [ -n "$ref" ] && [ -f "${FAKE_CONTENTS_DIR:-/nonexistent}/$ref" ]; then
                 cat "$FAKE_CONTENTS_DIR/$ref"
                 exit 0
               fi
               echo "gh: Not Found (HTTP 404)" >&2
               exit 1 ;;
             *"/files"*) json=$FAKE_FILES_JSON ;;
             *) exit 1 ;;
           esac ;;
  *) exit 1 ;;
esac
if [ -n "$query" ]; then
  printf '%s' "$json" | jq -r "$query"
else
  printf '%s' "$json"
fi
"""

# トリアージ済みの印。ADR-0031 より前は verify: machine / verify: human の 2 種類で、
# 後者だけが承認を要求していた。いまラベルが表すのは「完了条件が固まっている」だけである
TRIAGED = "verify: triaged"

# 既定のリポジトリ。closingIssuesReferences は他リポジトリの Issue も指せるので、
# review-gate は自リポの紐づけだけを採る (別リポの番号で verify ラベルを引くと、
# 同じ番号の無関係な Issue を見てしまう)
REPO_OWNER, REPO_NAME = "mokume-metal", "mokume"

# AGENTS.md の増分 (#1668) の比べる相手。base の先端 (BASE_REF の指す commit) と
# merge-base は別の commit で、review-gate が読んでよいのは merge-base の側だけである
BASE_REF = "main"
HEAD_OID = "a" * 40
MERGE_BASE = "b" * 40


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


def pr_json(body="Closes #12", closes=(12,), labels=(), reviews=(), files=(),
            refs=None, verified=None):
    """偽の gh pr view 応答。

    body と closes は**別々に**渡す。ゲートは closing keyword を body から読まないので、
    両者が食い違う形 (書いてあるのに紐づいていない) をそのまま表現できる — それが #309 の
    事象である。refs を渡すと closes を無視して紐づけをそのまま置く (他リポジトリの検査用)。

    verified には「確認方法」節へ載せる番号を渡す。既定は closes と同じ (通常の PR は
    閉じる Issue すべてに対応表を書く)。節ごと落とすには verified=() を渡す。
    """
    numbers = closes if verified is None else verified
    return json.dumps(
        {
            "body": body + verification_section(numbers),
            "labels": [{"name": n} for n in labels],
            "latestReviews": [{"state": s} for s in reviews],
            "files": [{"path": p} for p in files],
            "closingIssuesReferences": (
                closing_refs(closes) if refs is None else refs
            ),
            # AGENTS.md の増分 (#1668) を比べる相手を引くのに使う
            "baseRefName": BASE_REF,
            "headRefOid": HEAD_OID,
        }
    )


def assert_files_call_paginates(case, calls):
    """一覧を引く**その呼び出し**が `--paginate` を通っていること (#793)。

    記録全体に `--paginate` が現れるかを見てはいけない — 同じ記録に別の `--paginate` が
    混ざると、**付け忘れても緑になる** (最初にこの検査を書いたとき、描画 PR の順番の判定
    (`drawing-queue.sh`・#879 で畳んだ) が引く一覧で、まさにそれで空回りしていた)。
    """
    lines = [l for l in calls.read_text(encoding="utf-8").splitlines() if "/files" in l]
    case.assertTrue(lines, "変更ファイルの一覧を引いていない")
    for line in lines:
        case.assertIn("--paginate", line, f"ページングを通していない呼び出し: {line}")


def issue_json(*labels, issue_type="Task"):
    """偽の gh issue view 応答。

    型は gh の実物と同じ形 ({"name": ...}) で持たせる。型の付いていない Issue は
    issueType が null で返るので、issue_type=None でそれを表す。既定を Task にするのは、
    反証の検査 (ADR-0040 決定 4) に掛からない側を既存の検査の既定にするためである
    """
    return json.dumps(
        {
            "labels": [{"name": n} for n in labels],
            "issueType": None if issue_type is None else {"name": issue_type},
        }
    )


def refute_section(text="| 指摘 | 根拠 | 応え |\n| --- | --- | --- |\n"
                        "| 同じ形の口がもう 1 つある | Sources/Foo.swift:42 | 直した |"):
    """PR 本文の「反証」節 (ADR-0040 決定 4)。text を空にすれば見出しだけの節になる。"""
    return f"\n\n## 反証\n\n{text}\n"


class ReviewGateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bindir = Path(self.tmp.name) / "bin"
        self.bindir.mkdir()
        stub = self.bindir / "gh"
        stub.write_text(FAKE_GH, encoding="utf-8")
        stub.chmod(0o755)

    def run_gate(self, pr, issue=None, all_files=None, record_calls=None,
                 issues=None, issue_fail=None, agents=None, compare_fail=None,
                 run_id=None):
        """`all_files` は **`--paginate` を通した一覧** (#793)。

        省略すると `pr` が持つ `files` と同じものになる。上限を越える PR を装うときだけ
        別に渡す — `gh pr view` の側は上限で切られた前半を、こちらは全件を返す形になる。

        `issues` は {番号: issue_json(...)} で、その番号だけ `issue` と違う応答を返す。
        `issue_fail` を渡すと gh issue view がその文言を名乗って失敗する。

        `agents` は (merge-base の AGENTS.md, head の AGENTS.md) の組 (#1668)。base の
        先端 (BASE_REF) にはどちらとも長さの違う本文を置くので、先端と比べれば数が狂う。
        `compare_fail` を渡すと compare API がその文言を名乗って失敗する。

        `run_id` は Actions の中で立つ GITHUB_RUN_ID (#2134)。渡さなければ環境から外す。
        """
        contents = Path(self.tmp.name) / "contents"
        contents.mkdir(exist_ok=True)
        if agents is not None:
            base_text, head_text = agents
            (contents / MERGE_BASE).write_text(base_text, encoding="utf-8")
            (contents / HEAD_OID).write_text(head_text, encoding="utf-8")
            (contents / BASE_REF).write_text(base_text + "先端にだけ入った他の PR の追記\n", encoding="utf-8")
        env = dict(os.environ)
        env["PATH"] = f"{self.bindir}:{env['PATH']}"
        env["FAKE_PR_JSON"] = pr
        if all_files is None:
            all_files = [f["path"] for f in json.loads(pr)["files"]]
        env["FAKE_FILES_JSON"] = json.dumps([{"filename": p} for p in all_files])
        env["FAKE_ISSUE_JSON"] = issue if issue is not None else issue_json(TRIAGED)
        for n, body in (issues or {}).items():
            env[f"FAKE_ISSUE_JSON_{n}"] = body
        if issue_fail is not None:
            env["FAKE_ISSUE_FAIL"] = issue_fail
        env["FAKE_COMPARE_JSON"] = json.dumps({"merge_base_commit": {"sha": MERGE_BASE}})
        env["FAKE_CONTENTS_DIR"] = str(contents)
        if compare_fail is not None:
            env["FAKE_COMPARE_FAIL"] = compare_fail
        env["GH_CALLS"] = str(record_calls) if record_calls else "/dev/null"
        # 紐づけの所属リポジトリ判定に効くので、環境に左右されないよう固定する
        env["GITHUB_REPOSITORY"] = f"{REPO_OWNER}/{REPO_NAME}"
        # 差し戻しの文面へ埋まる (#2134)。CI の中で回しても結果が変わらないよう、渡すとき以外は外す
        env.pop("GITHUB_RUN_ID", None)
        if run_id is not None:
            env["GITHUB_RUN_ID"] = run_id
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

    def test_the_template_example_passes_the_table_check(self):
        # 実物のテンプレートから案内 (HTML コメント) を消し、見本の #N に番号を入れただけの
        # 本文が通ること (#1949)。見本がコメントの中にしか無いと、案内を消して書いた本文から
        # 番号ごと消え、その場しのぎの「閉じる Issue: #N」の行が広がった
        text = TEMPLATE.read_text(encoding="utf-8")
        body = re.sub(r"<!--.*?-->", "", text, flags=re.S).replace("#N", "#12")
        proc = self.run_gate(pr_json(body=body, verified=()), issue_json(TRIAGED))
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_the_template_names_closes_only_in_the_verification_section(self):
        # Closes #N の置き場を目的節にも案内すると、目的節に書いて確認方法節に番号が無い
        # 本文が生まれ、上の検査で差し戻される (#1908 → #1949)
        text = TEMPLATE.read_text(encoding="utf-8")
        purpose = text.split("## 目的", 1)[1].split("\n## ", 1)[0]
        self.assertNotIn("Closes #", purpose)

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

    # --- 4. Bug を閉じる PR の反証 (ADR-0040 決定 4 / #1662) -----------------

    def test_bug_with_a_refute_section_passes(self):
        proc = self.run_gate(
            pr_json(body="Closes #12" + refute_section()),
            issue_json(TRIAGED, issue_type="Bug"),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("反証の節を確認 (#12)", proc.stdout)

    def test_a_long_refute_section_passes(self):
        """長い「反証」節も、中身ありと読む (#1900)。

        pipefail の下で `… | grep -q` と書くと、grep が最初の行で抜けたときに書き手が
        SIGPIPE で止まり、長い節ほど「空」と読んでいた (#1897 の 18KB の節で踏んだ)。
        本文全体の見出しの有無も同じ形だったので、長い前置きも付ける。
        """
        rows = "".join(f"| {n} | 兄弟 | 同じ形の口 {n} | Sources/Foo.swift:{n} | 直した |\n" for n in range(4000))
        preamble = "".join(f"確認の行 {n}\n" for n in range(4000))
        proc = self.run_gate(
            pr_json(body="Closes #12\n\n" + preamble + refute_section("| # | 種類 | 指摘 | 根拠 | 応え |\n| --- | --- | --- | --- | --- |\n" + rows)),
            issue_json(TRIAGED, issue_type="Bug"),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("反証の節を確認 (#12)", proc.stdout)

    def test_bug_without_a_refute_section_is_blocked(self):
        """反証役を起こし忘れた形。

        直近の fix PR は兄弟の口を探さず、同じ根のバグが後から 1 件ずつ出ていた。
        完了条件の範囲がそのまま調べる範囲の上限になっていた (#1659)。
        """
        proc = self.run_gate(pr_json(), issue_json(TRIAGED, issue_type="Bug"))
        self.assert_blocked(proc, "「反証」の節が無い")
        self.assertIn("#12", proc.stderr)
        # 差し戻された人が起動手順へ辿り着けること
        self.assertIn(".claude/skills/bug-refute/SKILL.md", proc.stderr)

    def test_bug_with_an_empty_refute_section_is_blocked(self):
        # テンプレートの見出しと案内のコメントだけを残した形。コメントは行をまたぐ
        empty = "<!--\n反証役の指摘と応えを書く\n-->\n\n   \n"
        proc = self.run_gate(
            pr_json(body="Closes #12" + refute_section(empty)),
            issue_json(TRIAGED, issue_type="Bug"),
        )
        self.assert_blocked(proc, "「反証」の節が空")

    def test_a_later_section_ends_the_refute_section(self):
        # 「反証」の直後に同階層の見出しが来たら、そこから先は節の外。切り出しは
        # 確認方法と同じ関数なので、境界の規則も同じになる
        proc = self.run_gate(
            pr_json(body="Closes #12" + refute_section("") + "\n## 補足\n\n中身はここ\n"),
            issue_json(TRIAGED, issue_type="Bug"),
        )
        self.assert_blocked(proc, "「反証」の節が空")

    def test_a_non_bug_issue_is_not_asked_for_a_refutation(self):
        # Task も型の無い Issue も問わない
        for issue_type in ("Task", None):
            with self.subTest(issue_type=issue_type):
                proc = self.run_gate(pr_json(), issue_json(TRIAGED, issue_type=issue_type))
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertNotIn("反証", proc.stdout + proc.stderr)

    def test_one_bug_among_several_issues_is_asked(self):
        # まとめて閉じる Issue のうち 1 つでも Bug なら問う。名指しされるのは Bug の側だけ
        proc = self.run_gate(
            pr_json(body="Closes #12\nCloses #34", closes=(12, 34)),
            issue_json(TRIAGED, issue_type="Task"),
            issues={34: issue_json(TRIAGED, issue_type="Bug")},
        )
        self.assert_blocked(proc, "「反証」の節が無い")
        self.assertIn("(#34)", proc.stderr)
        self.assertNotIn("#12", proc.stderr)

    def test_an_unreadable_issue_type_names_the_reason(self):
        """gh が issueType を知らない版だと、黙って終わらずに理由を名乗る。

        代入の中の gh が失敗すると set -e でそのまま終わり、review-gate としては何も
        言わずに赤くなる。欄は gh 2.94.0 から (scripts/ready-queue.sh の冒頭)
        """
        proc = self.run_gate(
            pr_json(), issue_fail='Unknown JSON field: "issueType"'
        )
        self.assert_blocked(proc, "#12 の labels / issueType を読めなかった")

    def test_a_response_without_issue_type_is_blocked(self):
        # 欄そのものが無い応答を「Bug でない」と読むと、反証の検査が黙って外れる
        proc = self.run_gate(
            pr_json(), json.dumps({"labels": [{"name": TRIAGED}]})
        )
        self.assert_blocked(proc, "issueType が無い")

    # --- 差し戻しの文面が約束してよいこと (#2134) ---------------------------
    #
    # 本文を直すと新しい run は走るが、赤かった run の ci-gate は同じコミットに残って必須
    # チェックを赤のままにする (古い赤が新しい緑を固定する場合もある — #259)。かつての文面
    # (対応表・反証の 2 つ) は「本文を編集すれば CI は自動で再評価されます」と約束していて、
    # 直したのに必須チェックが赤のまま止まった。文面は、再評価が走ることと、必須チェックが
    # 緑になることを分けて言い、打ち直しまで案内する。変更要求の解除・no-issue ラベルの付与
    # も新しい run を起こすだけで同じなので、共通の末尾 (rerun_note) を持つ 4 つの差し戻しで
    # 固定する。verify: の差し戻しだけは Issue 側の操作で run が起きないので、別に固定する

    @staticmethod
    def squash(text):
        """空白と改行を外した本文。折り返しの位置に左右されず、語句を探すため。"""
        return re.sub(r"\s+", "", text)

    def assertSays(self, err, phrase):
        self.assertIn(self.squash(phrase), self.squash(err), f"文面に「{phrase}」が無い:\n{err}")

    def blocked_messages(self, **kwargs):
        """共通の末尾 (rerun_note) を持つ差し戻し 4 つの stderr を、名前付きで返す。"""
        cases = {
            "対応表": (pr_json(verified=()), issue_json(TRIAGED)),
            "反証": (pr_json(), issue_json(TRIAGED, issue_type="Bug")),
            "変更要求": (pr_json(reviews=["CHANGES_REQUESTED"]), issue_json(TRIAGED)),
            "no-issue の不在": (pr_json(body="Issue に触れていない本文", closes=()), None),
        }
        messages = {}
        for name, (pr, issue) in cases.items():
            proc = self.run_gate(pr, issue, **kwargs)
            self.assertEqual(proc.returncode, 1, f"{name}: 差し戻されていない: {proc.stdout}")
            messages[name] = proc.stderr
        return messages

    def test_a_blocked_message_does_not_promise_automatic_reevaluation(self):
        for name, err in self.blocked_messages().items():
            with self.subTest(name):
                self.assertNotRegex(self.squash(err), r"自動(で|的に)?再(評価|実行)", "約束が戻っている:\n" + err)
                # 新しい run が走ることまでは言えるが、それが必須チェックを緑にするとは言わない。
                # 機構は 1 つに断定せず、赤が残ること (と、古い赤が固定する場合もあること) を言う
                self.assertSays(err, "新しい run が走って")
                self.assertSays(err, "必須チェックを赤のままにします")
                self.assertSays(err, "古い赤が新しい緑を固定する場合もあります")

    def test_a_blocked_message_names_the_rerun_that_clears_a_red_ci_gate(self):
        for name, err in self.blocked_messages().items():
            with self.subTest(name):
                self.assertIn("ci-gate", err)
                self.assertRegex(err, r"gh run rerun \S+ --failed", "打ち直しの手を案内していない:\n" + err)

    def test_the_rerun_names_this_run_inside_actions_and_a_placeholder_outside(self):
        for name, err in self.blocked_messages().items():
            with self.subTest(name + " (手元)"):
                self.assertIn("gh run rerun <run-id> --failed", err)
        for name, err in self.blocked_messages(run_id="424242").items():
            with self.subTest(name + " (Actions)"):
                self.assertIn("gh run rerun 424242 --failed", err)

    def test_a_blocked_message_says_the_watch_skips_fork_prs(self):
        """当番 (stall-watch) は isCrossRepository を外す。「いずれ打ち直す」は fork の PR に当たらない。"""
        for name, err in self.blocked_messages().items():
            with self.subTest(name):
                self.assertSays(err, "同じリポジトリの PR は、打たなくても stall-watch の当番がいずれ打ち直します")
                self.assertSays(err, "fork の PR は当番の対象外なので、メンテナが打ちます")

    def test_a_blocked_message_does_not_rerun_pr_title(self):
        # 打ち直すと元のタイトルを再生して同じ赤を返す (#699)。直す手は新しいコミット
        for name, err in self.blocked_messages().items():
            with self.subTest(name):
                self.assertSays(err, "pr-title も赤い run は、打ち直すと元のタイトルを再生して同じ赤を返します")
                self.assertSays(err, "新しいコミットを push して run を作り直してください")

    def test_the_missing_issue_message_names_create_time_label_first_and_not_as_a_guarantee(self):
        err = self.blocked_messages()["no-issue の不在"]
        self.assertIn("gh pr create --label no-issue", err)
        self.assertSays(err, "通常は最初の run から通ります")
        self.assertSays(err, "まれに作成の run が先にラベルを読んで赤くなり")
        # 後付けの案内 (打ち直し) は、作成と同時の案内より後に出る
        self.assertLess(err.find("gh pr create --label no-issue"), err.find("gh run rerun"))
        # 約束のような言い方 (旧: 付けて再実行します) に戻っていない
        self.assertNotIn(self.squash("付けて再実行します"), self.squash(err))

    def test_the_changes_requested_message_says_a_dismissal_starts_a_run_but_needs_a_rerun(self):
        err = self.blocked_messages()["変更要求"]
        self.assertSays(err, "変更要求を解いてもらう")
        self.assertSays(err, "解かれると新しい run が走りますが、変更要求で赤くなった run は打ち直しが要ります")

    def test_the_missing_verify_label_message_names_the_rerun_unit(self):
        """Issue 側のラベル操作は PR の run を起こさない — 新しい緑は付かず、当番も拾わない。

        だから共通の末尾 (rerun_note) を使わず、打ち直しを直に案内する。画面の「Re-run all
        jobs」は成功済みの pr-title まで元のタイトルで走らせ直す (#699) ので、単位は
        失敗したジョブだけ (`--failed`) である。
        """
        proc = self.run_gate(pr_json(), issue_json("status: in progress"))
        self.assert_blocked(proc, "verify: ラベルが無い")
        err = proc.stderr
        self.assertRegex(err, r"gh run rerun \S+ --failed")
        self.assertSays(err, "Issue 側のラベル操作は PR の run を起こさないので、自動では再評価されない")
        self.assertSays(err, "「Re-run all jobs」は成功済みの pr-title まで元のタイトルで走らせ直す")
        # 当番は拾わない (新しい緑が付かない) ので、「いずれ打ち直す」と言わない
        self.assertNotIn("stall-watch", err)
        # 単位の無い言い方 (旧: Actions の re-run か空 push) に戻っていない
        self.assertNotIn(self.squash("Actions の re-run か空 push"), self.squash(err))

    # --- 5. 変更要求 -------------------------------------------------------

    def test_the_file_list_is_paginated(self):
        """一覧を引く呼び出しに `--paginate` が載っていること (#793)。

        判定の結果だけを見ていると、上限に収まる PR では**付け忘れても緑**になる。
        """
        calls = self.bindir.parent / "gh-calls.txt"
        proc = self.run_gate(
            pr_json(files=["README.md"]),
            issue_json(TRIAGED),
            record_calls=calls,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        assert_files_call_paginates(self, calls)

    def test_changes_requested_blocks_even_with_an_approval(self):
        proc = self.run_gate(
            pr_json(reviews=["APPROVED", "CHANGES_REQUESTED"]), issue_json(TRIAGED)
        )
        self.assert_blocked(proc, "変更要求")

    # --- 6. AGENTS.md の増分 (#1668) -----------------------------------------

    def agents_gate(self, body="", files=("AGENTS.md",), grow=0, record_calls=None, **kw):
        """AGENTS.md を merge-base から `grow` 字だけ変えた PR を review-gate に掛ける。"""
        base = "# AGENTS.md\n\n## 進め方\n\n規律。\n"
        head = base + "あ" * grow if grow >= 0 else base[:grow]
        return self.run_gate(
            pr_json(body="Closes #12\n" + body, files=list(files), **kw),
            issue_json(TRIAGED),
            agents=(base, head),
            record_calls=record_calls,
        )

    def test_growth_with_a_matching_declaration_passes(self):
        proc = self.agents_gate("AGENTS.md の増分: +5\n", grow=5)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("+5 字で宣言どおり", proc.stdout)

    def test_growth_without_a_declaration_is_blocked(self):
        proc = self.agents_gate(grow=1)
        self.assert_blocked(proc, "AGENTS.md の増分が PR 本文の宣言で説明されていない")
        self.assertIn("1 字増えている", proc.stderr)
        # 差し戻された人が、書くべき 1 行と降ろし先に辿り着けること (完了条件 4)
        self.assertIn("AGENTS.md の増分: +1", proc.stderr)
        self.assertIn("経緯と実測は Issue / PR", proc.stderr)

    def test_shrinking_or_same_length_needs_no_declaration(self):
        for grow in (0, -3):
            with self.subTest(grow=grow):
                proc = self.agents_gate(grow=grow)
                self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_a_declaration_off_by_one_is_blocked(self):
        proc = self.agents_gate("AGENTS.md の増分: +4\n", grow=5)
        self.assert_blocked(proc, "説明されていない")
        self.assertIn("「AGENTS.md の増分: +5」に直す", proc.stderr)

    def test_near_miss_declarations_name_the_right_form(self):
        for line in ("AGENTS.md の増分：+5", "AGENTS.md の増分: +5 字", "`AGENTS.md の増分: +5`"):
            with self.subTest(line=line):
                proc = self.agents_gate(line + "\n", grow=5)
                self.assert_blocked(proc, "説明されていない")
                self.assertIn("宣言の形が違う", proc.stderr)
                self.assertIn("AGENTS.md の増分: +N", proc.stderr)

    def test_two_declarations_are_blocked(self):
        proc = self.agents_gate("AGENTS.md の増分: +5\n\nAGENTS.md の増分: +5\n", grow=5)
        self.assert_blocked(proc, "説明されていない")
        self.assertIn("2 行ある", proc.stderr)

    def test_a_declaration_only_inside_an_html_comment_does_not_count(self):
        # テンプレートの案内はコメントに書いてある。その例を宣言と読まない
        proc = self.agents_gate("<!--\nAGENTS.md の増分: +5\n-->\n", grow=5)
        self.assert_blocked(proc, "説明されていない")
        self.assertIn("宣言が無い", proc.stderr)

    def test_a_crlf_body_is_read(self):
        # GitHub の Web の入力欄で編集した本文は CRLF で返る
        proc = self.agents_gate("本文\r\nAGENTS.md の増分: +5\r\n", grow=5)
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_a_declaration_without_touching_agents_md_is_blocked(self):
        # 触れていないのに宣言がある — 実測は 0 なので合わない
        proc = self.agents_gate("AGENTS.md の増分: +5\n", files=("README.md",), grow=0)
        self.assert_blocked(proc, "説明されていない")
        self.assertIn("宣言の行を消す", proc.stderr)

    def test_an_untouched_pr_without_a_declaration_does_not_call_the_api(self):
        calls = Path(self.tmp.name) / "gh-calls.txt"
        proc = self.agents_gate(files=("README.md",), record_calls=calls)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        text = calls.read_text(encoding="utf-8")
        self.assertNotIn("/compare/", text)
        self.assertNotIn("/contents/", text)

    def test_compares_with_the_merge_base_not_the_base_tip(self):
        """base の先端と比べると、後から入った他の PR の増減が自分の増分に混ざる。

        偽 gh は base の先端 (BASE_REF) に長さの違う本文を置いているので、先端を読めば
        宣言 +5 と合わずに赤くなる。呼び出しの形も固定する — compare は base と head で
        引き、contents は merge-base と head の SHA で引く。
        """
        calls = Path(self.tmp.name) / "gh-calls.txt"
        proc = self.agents_gate("AGENTS.md の増分: +5\n", grow=5, record_calls=calls)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = calls.read_text(encoding="utf-8").splitlines()
        compare = [l for l in lines if "/compare/" in l]
        self.assertEqual(len(compare), 1, lines)
        self.assertIn(f"compare/{BASE_REF}...{HEAD_OID}", compare[0])
        refs = sorted(l.rsplit("ref=", 1)[1] for l in lines if "/contents/AGENTS.md" in l)
        self.assertEqual(refs, sorted([MERGE_BASE, HEAD_OID]))
        self.assertTrue(all("application/vnd.github.raw" in l for l in lines if "/contents/" in l))

    def test_an_unreadable_merge_base_names_the_reason(self):
        proc = self.run_gate(
            pr_json(files=["AGENTS.md"]), issue_json(TRIAGED),
            agents=("a\n", "a\n"), compare_fail="gh: Not Found (HTTP 404)",
        )
        self.assert_blocked(proc, "merge-base を引けなかった")

    def test_unreadable_contents_name_the_reason(self):
        # agents を渡さない — contents が 404 で失敗する
        proc = self.run_gate(pr_json(files=["AGENTS.md"]), issue_json(TRIAGED))
        self.assert_blocked(proc, "AGENTS.md を")
        self.assertIn("読めなかった", proc.stderr)

    def test_no_issue_pr_is_also_checked(self):
        # 閉じる Issue が無くても AGENTS.md は同じ固定費である
        base = "# AGENTS.md\n"
        proc = self.run_gate(
            pr_json(body="紐づけなし", closes=(), labels=["no-issue"], files=["AGENTS.md"]),
            agents=(base, base + "足した\n"),
        )
        self.assert_blocked(proc, "説明されていない")

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

    def test_a_pr_touching_the_fences_needs_no_approval(self):
        """柵 (.github/**・.claude/**) に触れる PR も、承認なしで通す (ADR-0044)。

        承認のゲートを外す前は、メンテナ名義でここに触れる PR を「誰も承認できない」と
        差し戻していた (ADR-0007)。同じ形が戻ると、メンテナ名義の PR が柵を直せなくなる。
        """
        proc = self.run_gate(
            pr_json(files=[".github/workflows/ci.yml", ".claude/settings.json"]),
            issue_json(TRIAGED),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("承認", proc.stdout + proc.stderr)

class GateRunsFromDefaultBranchTest(unittest.TestCase):
    """判定のジョブが、PR の版ではなく既定ブランチの版のスクリプトを取ること (#2001)。

    PR の版で走らせると、同じ PR の中で自分を裁く検査を書き換えて通れる
    (ADR-0031 決定 2 の 2026-10-03 の改訂)。ジョブの範囲は字下げで切り出す
    — 2 つ目の字下げ (ジョブ名) から、同じ字下げの次の行の手前まで。
    """

    WORKFLOW = REPO / ".github" / "workflows" / "ci.yml"
    REF = "ref: ${{ github.event.repository.default_branch }}"

    def job(self, name):
        lines = self.WORKFLOW.read_text(encoding="utf-8").splitlines()
        start = lines.index(f"  {name}:")
        end = next(
            (i for i in range(start + 1, len(lines))
             if re.match(r"  \S", lines[i])),
            len(lines),
        )
        return lines[start:end]

    def test_gate_jobs_check_out_the_default_branch(self):
        for name in ("review-gate", "drawing-evidence"):
            with self.subTest(job=name):
                body = self.job(name)
                checkout = [i for i, l in enumerate(body)
                            if "actions/checkout@" in l]
                self.assertEqual(len(checkout), 1, f"{name} の checkout は 1 つ")
                i = checkout[0]
                self.assertEqual(body[i + 1].strip(), "with:")
                self.assertEqual(body[i + 2].strip(), self.REF)


if __name__ == "__main__":
    unittest.main()
