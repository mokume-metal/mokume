#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/ready-queue.sh の検査 (#1028)。

固定したいのは十。

1. **何も打たない。** 判定を手元で打っただけでラベルが付いたり auto-merge が掛かったり
   すると、判定と実行を分けた意味が消える (ADR-0036 決定 1)
2. **`verify: triaged` が無ければ ready に出ない。** 着手ゲートは ADR-0002 決定 1 の
   ままで、この判定はそこを緩めない
3. **着手印が残っているものは busy か dropped に分かれる。** 紐づく PR も手元の枝も
   無いときだけ dropped で、**それは「落ちた」ではなく「落ちて見える」**である
4. **stock は署名つき・無印・型が Bug / Task / Docs のときだけ。** Design / Feature は
   判断が要る側なので出さない (ADR-0036 決定 6)
5. **行は `<番号> <分類> <説明>` の 3 欄で、描画の見込みを持たない。** 以前は ready の行に
   `drawing?` / `plain?` を付けて描画レーンを分けていたが、専用機が描画を見るようになって
   レーンごと畳んだ (ADR-0036 決定 4 の改訂・#1769)
6. **終了コードが「打てる仕事があるか」を表す。** 呼ぶ側 (外に居るディスパッチャ) が「在庫が
   尽きたので B-1 へ回る」を分岐できる。
   **一覧を読めなかったときも在庫切れと言わない** — 1 ではなく 2 で終える (#1235)
7. **PR の check の状態は読まない。** 以前は、手元で打てる catch-up を ready より先に
   出していた (#1045) が、覆いの機構ごと #879 で畳んだ。PR が赤くても行は増えず、順番を
   引く呼び出しも起きない
8. **自分に証拠の無い着手印は、家族を見てから dropped と呼ぶ** (#1391)。家族は親・兄弟・子で、
   閉じたものは新しいときだけ数える。**家族を渡るのは 1 段だけ**で、家族を通じて busy に
   なったものは証拠にしない。家族を読むのは候補があるときだけで、読めなければ dropped のまま
   そう名乗る
9. **同じ根の群は根で直す** (#1661・ADR-0040 決定 2・3)。親が open な Bug の子と、親が open で
   印の付いた Design の Bug の子 (#2228) は ready に出さず busy (「根 #N で直す」) へ回し、ready の
   件数もそのあとで数える。Task / Feature の親の子・Design の Bug でない子・無印の Design の子は
   ready のまま (無印の Design を待つ間は症状の直しを止めない — ADR-0040 決定 3)。open な Bug の
   子を持つ無印の Design は、子の多い順に decide として最後に出す (終了コードには数えない)。親は
   open な Bug か ready の候補があるときだけ読み、読めなければ ready は従来どおり出してそう名乗る
10. **ready と stock の説明は Issue Type を `[Bug]` の形で先頭に置く** (#2136)。Type は題から
   読めず、Bug は反証の節を要るので、着手の前に目に入る必要がある (#1998)。Type の無い
   Issue は `[-]`。**番号・分類の位置は動かさない** — 既存の読み手は先頭の 2 語を読む

gh と git は PATH の先頭に置いた偽物へ差し替える。偽物は **--jq を実際に適用する**ので、
検査は判定そのものを踏む。書き込み系の呼び出しは偽物が知らないので、打とうとすれば
落ちる (1 は呼び出しログと終了コードの両方で見る)。

実行は make ci-check (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
QUEUE = REPO / "scripts" / "ready-queue.sh"

FAKE_GH = """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALLS"

filter=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then filter=$a; fi
  prev=$a
done

emit() { # $1=JSON ファイル
  [ -f "$1" ] || { printf '%s' ""; return 0; }
  if [ -n "$filter" ]; then jq -r "$filter" < "$1"; else cat "$1"; fi
}

# 一覧の読み取りを失敗させる。FAIL_LIST に issue / pr を渡す (#1235)。
# 綴りは古い gh が実際に出したもの (issueType は gh 2.94.0 からの欄)
if [ "$1 $2" = "${FAIL_LIST:-} list" ]; then
  echo 'Unknown JSON field: "issueType"' >&2
  exit 1
fi

if [ "$1 $2" = "issue list" ]; then emit "$FIX/issues.json"; exit 0; fi
if [ "$1 $2" = "pr list" ]; then emit "$FIX/prs.json"; exit 0; fi

# **URL は $2 から取る** — "$*" には --jq の値まで混ざる
if [ "$1" = "api" ]; then
  case "$2" in
    # merge queue の並び (#1266)。既定は空
    graphql) [[ "$*" == *"mergeQueue{"* ]] && { printf '%s\\n' ${QUEUED_PRS:-}; exit 0; }
      # open な Bug と ready の候補の親 (#1661)。家族の問い合わせとは issueType の綴りで
      # 見分ける (家族のほうは型を読まない)。FAIL_PARENTS で読み取りを失敗させる
      if [[ "$*" == *"issueType"* ]]; then
        [ -z "${FAIL_PARENTS:-}" ] || { echo 'HTTP 502: Bad Gateway' >&2; exit 1; }
        emit "$FIX/parents.json"; exit 0
      fi
      # 着手印の家族 (#1391)。FAIL_FAMILY で読み取りを失敗させる
      if [[ "$*" == *"subIssues"* ]]; then
        [ -z "${FAIL_FAMILY:-}" ] || { echo 'HTTP 502: Bad Gateway' >&2; exit 1; }
        emit "$FIX/family.json"; exit 0
      fi ;;
  esac
fi

echo "偽 gh が知らない呼び出し: $*" >&2
exit 1
"""

FAKE_GIT = """#!/bin/bash
printf '%s\\n' "$*" >> "$GIT_CALLS"

if [ "$1 $2" = "worktree list" ]; then cat "$FIX/worktrees.txt"; exit 0; fi

echo "偽 git が知らない呼び出し: $*" >&2
exit 1
"""

SIGNATURE = "🤖 Assisted by [Claude Code](https://claude.com/claude-code)"

# 既定は「ずっと前」。静けさを見る検査だけが新しい時刻を渡す
LONG_AGO = "2020-01-01T00:00:00Z"


def issue(number, *, title="なにか", body="", labels=(), type_=None, updated=LONG_AGO):
    return {
        "number": number,
        "title": title,
        "body": body,
        "labels": [{"name": name} for name in labels],
        "issueType": None if type_ is None else {"name": type_},
        "updatedAt": updated,
    }


def closing_pr(number, *, closes=(), repo="mokume-metal/mokume"):
    """open な PR と、それが閉じる Issue。"""
    owner, name = repo.split("/")
    return {
        "number": number,
        "title": f"PR {number}",
        "closingIssuesReferences": [
            {"number": n, "repository": {"owner": {"login": owner}, "name": name}}
            for n in closes
        ],
    }


def member(number, state="OPEN", updated=LONG_AGO):
    """家族の 1 人。GraphQL の subIssues.nodes と同じ形"""
    return {"number": number, "state": state, "updatedAt": updated}


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def family_response(families):
    """{候補: {"parent": member か None, "siblings": [...], "children": [...]}} から応答を組む。

    siblings は親の子すべてで、本物と同じく候補自身も混ぜて返す (除くのはスクリプトの仕事)
    """
    repo = {}
    for n, f in families.items():
        parent = f.get("parent")
        if parent is not None:
            parent = dict(parent, subIssues={"nodes": [member(n)] + list(f.get("siblings", []))})
        repo[f"i{n}"] = {"parent": parent, "subIssues": {"nodes": list(f.get("children", []))}}
    return {"data": {"repository": repo}}


def parent(number, state="OPEN", type_="Bug", labels=()):
    """親の 1 件。GraphQL の parent と同じ形 (印は Design の根を見分けるのに読む — #2228)"""
    return {
        "number": number,
        "state": state,
        "issueType": None if type_ is None else {"name": type_},
        "labels": {"nodes": [{"name": name} for name in labels]},
    }


def parents_response(parents):
    """{番号: parent(...) か None} から応答を組む。載っていない番号は親を持たない"""
    return {"data": {"repository": {f"i{n}": {"parent": p} for n, p in parents.items()}}}


class ReadyQueueTest(unittest.TestCase):
    def run_queue(self, issues, prs=(), worktrees="", families=None, parents=None, **extra_env):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            fix = tmp / "fixtures"
            fix.mkdir()
            (fix / "issues.json").write_text(json.dumps(issues), encoding="utf-8")
            (fix / "prs.json").write_text(json.dumps(list(prs)), encoding="utf-8")
            (fix / "worktrees.txt").write_text(worktrees, encoding="utf-8")
            if families is not None:
                (fix / "family.json").write_text(
                    json.dumps(family_response(families)), encoding="utf-8"
                )
            (fix / "parents.json").write_text(
                json.dumps(parents_response(parents or {})), encoding="utf-8"
            )

            bindir = tmp / "bin"
            bindir.mkdir()
            for name, body in (("gh", FAKE_GH), ("git", FAKE_GIT)):
                path = bindir / name
                path.write_text(body, encoding="utf-8")
                path.chmod(0o755)

            calls = tmp / "gh-calls"
            env = dict(os.environ)
            env.update(
                PATH=f"{bindir}:{env['PATH']}",
                FIX=str(fix),
                GH_CALLS=str(calls),
                GIT_CALLS=str(tmp / "git-calls"),
                GITHUB_REPOSITORY="mokume-metal/mokume",
            )
            env.update(extra_env)
            done = subprocess.run(
                ["/bin/bash", str(QUEUE)],
                env=env,
                capture_output=True,
                text=True,
                errors="replace",
            )
            log = calls.read_text(encoding="utf-8") if calls.exists() else ""
            return done, log

    def lines_by_number(self, stdout):
        out = {}
        for line in stdout.splitlines():
            number, kind, rest = line.split(" ", 2)
            out[int(number)] = (kind, rest)
        return out

    # 1. 何も打たない
    def test_reads_only(self):
        done, log = self.run_queue([issue(1, labels=["verify: triaged"])])
        self.assertEqual(done.returncode, 0, done.stderr)
        for verb in ("issue edit", "pr merge", "issue create", "issue close", "--add-label"):
            self.assertNotIn(verb, log, f"判定が {verb} を打っている:\n{log}")
        self.assertIn("issue list", log)
        self.assertIn("pr list", log)

    # 2. verify: triaged が無ければ ready に出ない
    def test_untriaged_is_not_ready(self):
        done, _ = self.run_queue(
            [
                issue(1, labels=["verify: triaged"]),
                issue(2, type_="Bug"),  # 無印・署名なし
            ]
        )
        seen = self.lines_by_number(done.stdout)
        self.assertEqual(seen[1][0], "ready")
        self.assertNotIn(2, seen, "無印の Issue が出ている")

    # 3. 着手印は busy か dropped へ分かれる
    def test_in_progress_splits(self):
        issues = [
            issue(10, labels=["verify: triaged", "status: in progress"]),
            issue(11, labels=["verify: triaged", "status: in progress"]),
            issue(12, labels=["verify: triaged", "status: in progress"]),
            issue(13, labels=["verify: triaged"]),
        ]
        done, _ = self.run_queue(
            issues,
            prs=[closing_pr(90, closes=[10])],
            worktrees="worktree /w/issue-11-abc\nbranch refs/heads/fix/whatever\n",
        )
        seen = self.lines_by_number(done.stdout)
        self.assertEqual(seen[10][0], "busy")
        self.assertIn("PR #90", seen[10][1])
        self.assertEqual(seen[11][0], "busy", "手元の worktree を見ていない")
        self.assertEqual(seen[12][0], "dropped")
        self.assertEqual(seen[13][0], "ready")

    # 3b. 番号の部分一致で「生きている」へ倒れない
    def test_worktree_match_is_not_substring(self):
        done, _ = self.run_queue(
            [issue(27, labels=["status: in progress"])],
            worktrees="worktree /w/issue-1279-abc\n",
        )
        seen = self.lines_by_number(done.stdout)
        self.assertEqual(seen[27][0], "dropped", "1279 が 27 に当たっている")

    # 3d. 静かになるまでは dropped と呼ばない (枝の名前は番号を持たないことが多い)
    def test_recent_activity_is_still_busy(self):
        fresh = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        done, _ = self.run_queue(
            [
                issue(50, labels=["status: in progress"], updated=fresh),
                issue(51, labels=["status: in progress"]),  # LONG_AGO
            ]
        )
        seen = self.lines_by_number(done.stdout)
        self.assertEqual(seen[50][0], "busy", "着手した直後の Issue を落ちたと呼んでいる")
        self.assertEqual(seen[51][0], "dropped")

    # 3c. 別リポジトリを閉じる PR は紐づけに数えない
    def test_other_repo_claim_is_ignored(self):
        done, _ = self.run_queue(
            [issue(5, labels=["verify: triaged"])],
            prs=[closing_pr(91, closes=[5], repo="someone/else")],
        )
        seen = self.lines_by_number(done.stdout)
        self.assertEqual(seen[5][0], "ready", "別リポジトリの番号で busy にしている")

    # 4. stock は署名つき・無印・小さい型のときだけ
    def test_stock_selection(self):
        issues = [
            issue(20, type_="Bug", body=SIGNATURE),
            issue(21, type_="Task", body=SIGNATURE),
            issue(22, type_="Docs", body=SIGNATURE),
            issue(23, type_="Design", body=SIGNATURE),  # 判断が要る側
            issue(24, type_="Feature", body=SIGNATURE),  # 同上
            issue(25, type_="Bug", body="人が書いた本文"),  # 署名なし
            issue(26, type_="Bug", body=SIGNATURE, labels=["verify: triaged"]),  # 印あり
            issue(27, labels=["verify: triaged"]),  # ready を 1 件作る
        ]
        done, _ = self.run_queue(issues)
        seen = self.lines_by_number(done.stdout)
        self.assertEqual([n for n, v in seen.items() if v[0] == "stock"], [20, 21, 22])
        self.assertEqual(seen[26][0], "ready")

    # 5. 行は 3 欄で、描画の見込みを持たない (描画レーンは #1769 で畳んだ)
    def test_rows_have_no_drawing_guess(self):
        issues = [
            issue(30, labels=["verify: triaged"], body="Sources/MokumeCore/Frame.swift を直す"),
            issue(32, labels=["verify: triaged"], body="どこにも触れない話"),
        ]
        done, _ = self.run_queue(issues)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout, "30 ready [-] なにか\n32 ready [-] なにか\n")
        for mark in ("drawing?", "plain?"):
            self.assertNotIn(mark, done.stdout)

    # 5b. ready と stock の説明は Type を先頭に置く (#2136)。番号・分類は動かさない
    def test_ready_and_stock_rows_lead_with_the_issue_type(self):
        issues = [
            issue(70, labels=["verify: triaged"], type_="Bug", title="直す"),
            issue(71, labels=["verify: triaged"], type_="Task", title="整える"),
            issue(72, labels=["verify: triaged"], type_="Feature", title="足す"),
            issue(73, labels=["verify: triaged"], title="型なし"),  # Type が付いていない
            issue(74, type_="Docs", body=SIGNATURE, title="書く"),  # stock
        ]
        done, _ = self.run_queue(issues)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(
            done.stdout.splitlines(),
            [
                "70 ready [Bug] 直す",
                "71 ready [Task] 整える",
                "72 ready [Feature] 足す",
                "73 ready [-] 型なし",
                "74 stock [Docs] エージェントの起票が無印のまま (書く)",
            ],
        )
        # 番号・分類を先頭の 2 語で読む側は、Type が増えても同じ答えを得る
        seen = self.lines_by_number(done.stdout)
        self.assertEqual({n: v[0] for n, v in seen.items()}, {
            70: "ready", 71: "ready", 72: "ready", 73: "ready", 74: "stock",
        })

    # 5c. 根へ回した子は busy のままで Type を出さず、根のほうは ready に Type つきで出る
    def test_type_is_shown_for_the_root_that_stays_ready(self):
        done, _ = self.run_queue(
            [
                issue(100, labels=["verify: triaged"], type_="Bug", title="根"),
                issue(101, labels=["verify: triaged"], type_="Bug", title="症状"),
            ],
            parents={101: parent(100)},
        )
        self.assertEqual(
            done.stdout.splitlines(),
            ["100 ready [Bug] 根", "101 busy 根 #100 で直す (症状)"],
        )

    # 6. 終了コードが在庫の有無を表す
    def test_exit_code_says_stock_out(self):
        done, _ = self.run_queue([issue(40, type_="Bug", body=SIGNATURE)])
        self.assertEqual(done.returncode, 1, "ready が 0 件なのに 0 で終えている")
        self.assertIn("40 stock", done.stdout)

        done, _ = self.run_queue([issue(41, labels=["verify: triaged"])])
        self.assertEqual(done.returncode, 0)

    # 6b. 一覧を読めなかったときは在庫切れ (1) と言わない (#1235)
    def test_unreadable_list_is_not_stock_out(self):
        for listing in ("issue", "pr"):
            with self.subTest(listing=listing):
                # 読めていれば ready が 1 件ある状態 — 成功時の値に引きずられないことも見る
                done, _ = self.run_queue([issue(42, labels=["verify: triaged"])], FAIL_LIST=listing)
                self.assertEqual(
                    done.returncode, 2, f"読めなかったのに {done.returncode} で終えている:\n{done.stderr}"
                )
                self.assertEqual(done.stdout, "", "判定できないのに行を出している")
                self.assertIn("読めなかった", done.stderr)

    # 7. PR の check の状態は読まない (catch-up は #879 で畳んだ)
    def test_pr_checks_do_not_add_rows(self):
        prs = [closing_pr(900), closing_pr(901)]
        done, log = self.run_queue([issue(62, type_="Bug", body=SIGNATURE)], prs=prs)
        self.assertEqual(done.returncode, 1, "在庫切れなのに 0 で終えている")
        self.assertEqual(done.stdout, "62 stock [Bug] エージェントの起票が無印のまま (なにか)\n")
        self.assertNotIn("catch-up", done.stdout + done.stderr)
        self.assertNotIn("statusCheckRollup", log, "PR の check を読んでいる")
        # **api の呼び出しそのものは 0 にならない** — #62 は open な Bug なので、その親を読む
        # GraphQL が 1 回走る (#1661 の「根と判断」)。それ以外の api が無いことを見る
        others = [
            line
            for line in log.splitlines()
            if line.startswith("api ") and "parent { number state issueType" not in line
        ]
        self.assertEqual(others, [], f"順番を引いている:\n{log}")

    # 8. 家族も見る (#1391)
    def test_parent_is_busy_while_child_has_pr(self):
        done, _ = self.run_queue(
            [issue(1350, labels=["status: in progress"]), issue(1357)],
            prs=[closing_pr(1374, closes=[1357])],
            families={1350: {"children": [member(1357), member(1351, "CLOSED")]}},
        )
        seen = self.lines_by_number(done.stdout)
        self.assertEqual(seen[1350][0], "busy", "子に PR が出ている親を落ちたと呼んでいる")
        self.assertIn("家族 #1357", seen[1350][1])
        self.assertIn("PR #1374", seen[1350][1])

    def test_reserved_sibling_is_busy_while_sibling_has_pr(self):
        done, _ = self.run_queue(
            [
                issue(1352, labels=["status: in progress"]),
                issue(1357, labels=["status: in progress"]),
            ],
            prs=[closing_pr(1374, closes=[1357])],
            families={1352: {"parent": member(1350), "siblings": [member(1357)]}},
        )
        seen = self.lines_by_number(done.stdout)
        self.assertEqual(seen[1352][0], "busy", "予約された兄弟を落ちたと呼んでいる")
        self.assertIn("家族 #1357 に PR #1374", seen[1352][1])

    def test_recently_closed_sibling_keeps_reservation_busy(self):
        done, _ = self.run_queue(
            [issue(1355, labels=["status: in progress"])],
            families={
                1355: {"parent": member(1350), "siblings": [member(1354, "CLOSED", now())]}
            },
        )
        seen = self.lines_by_number(done.stdout)
        self.assertEqual(seen[1355][0], "busy", "閉じたばかりの兄弟を数えていない")
        self.assertIn("家族 #1354 が閉じたばかり", seen[1355][1])

    def test_old_closed_family_does_not_keep_busy(self):
        done, _ = self.run_queue(
            [issue(1355, labels=["status: in progress"])],
            families={1355: {"parent": member(1350), "siblings": [member(1354, "CLOSED")]}},
        )
        seen = self.lines_by_number(done.stdout)
        self.assertEqual(seen[1355][0], "dropped", "古く閉じた家族で生きていると読んでいる")

    def test_family_evidence_is_one_hop(self):
        # X の子 Z に PR → X は busy。X の兄弟 Y の家族は P・X・Y で、Z は居ない
        done, _ = self.run_queue(
            [
                issue(10, labels=["status: in progress"]),  # X
                issue(11, labels=["status: in progress"]),  # Y
                issue(12),  # Z
            ],
            prs=[closing_pr(90, closes=[12])],
            families={
                10: {"parent": member(1), "siblings": [member(11)], "children": [member(12)]},
                11: {"parent": member(1), "siblings": [member(10)]},
            },
        )
        seen = self.lines_by_number(done.stdout)
        self.assertEqual(seen[10][0], "busy")
        self.assertEqual(seen[11][0], "dropped", "家族を通じた busy を、さらに証拠に数えている")

    def test_unreadable_family_stays_dropped(self):
        done, _ = self.run_queue(
            [issue(1352, labels=["status: in progress"])],
            prs=[closing_pr(1374, closes=[1357])],
            families={1352: {"parent": member(1350), "siblings": [member(1357)]}},
            FAIL_FAMILY="1",
        )
        self.assertNotEqual(done.returncode, 2, "家族が読めないだけで一覧の失敗と名乗っている")
        seen = self.lines_by_number(done.stdout)
        self.assertEqual(seen[1352][0], "dropped", "読めなかった家族を生きていると読んでいる")
        self.assertIn("家族を読めなかった", seen[1352][1])

    def test_family_is_read_only_for_candidates(self):
        done, log = self.run_queue(
            [
                issue(1, labels=["verify: triaged"]),
                issue(2, labels=["status: in progress"]),
            ],
            prs=[closing_pr(90, closes=[2])],
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        # 見るのは家族の問い合わせ (subIssues) だけ。**graphql の呼び出しそのものは 0 に
        # ならない** — #1 は ready の候補なので、その親を読む GraphQL が 1 回走る
        # (#1661 の「根と判断」。そちらを引かない条件は test_parents_are_not_read_without_bugs_or_candidates)
        self.assertNotIn("subIssues", log, "候補が無いのに家族を読んでいる")

    # 9. 根と判断 (#1661)
    def test_child_of_an_open_bug_goes_to_its_root(self):
        """親が open な Bug の子は ready に出さない — 根を直す PR が子をまとめて閉じる。"""
        done, _ = self.run_queue(
            [
                issue(100, labels=["verify: triaged"], type_="Bug", title="根"),
                issue(101, labels=["verify: triaged"], type_="Bug", title="症状"),
            ],
            parents={101: parent(100)},
        )
        seen = self.lines_by_number(done.stdout)
        self.assertEqual(seen[100][0], "ready")
        self.assertEqual(seen[101][0], "busy", "根が open なのに子を ready に出している")
        self.assertEqual(seen[101][1], "根 #100 で直す (症状)")
        self.assertIn("ready 1 /", done.stderr)

    def test_child_is_ready_unless_its_root_is_open(self):
        done, _ = self.run_queue(
            [
                issue(102, labels=["verify: triaged"]),
                issue(103, labels=["verify: triaged"]),
                issue(104, labels=["verify: triaged"]),
                issue(105, labels=["verify: triaged"], type_="Bug"),
            ],
            parents={
                102: parent(100, state="CLOSED"),  # 根は直った
                103: parent(200, type_="Design"),  # 親は判断の Issue (子は Bug でない)
                104: parent(201, type_=None),  # 型の無い親
                # 印の付いた Design の根でも、閉じていれば子は自分で直す
                105: parent(202, state="CLOSED", type_="Design", labels=["verify: triaged"]),
            },
        )
        seen = self.lines_by_number(done.stdout)
        for n in (102, 103, 104, 105):
            self.assertEqual(seen[n][0], "ready", f"#{n} を根で直す側へ回している")

    def test_bug_child_of_a_triaged_design_goes_to_its_root(self):
        """印の付いた Design を根にした Bug の子も、根で直す (#2228)。

        根の Design に印が付くと (b) の decide からは外れ、根そのものが ready に出る。子を
        ready に残すと、根を直さずに症状の 1 か所だけを閉じる直しが拾われる (#1659 の形)。
        例は 2026-10-08 に #2209 へ束ねた #1561。根が着手中でも、子は根で直す
        """
        triaged = ["verify: triaged"]
        reserved = ["verify: triaged", "status: in progress"]
        done, _ = self.run_queue(
            [
                issue(2209, labels=triaged, type_="Design", title="根"),
                issue(1561, labels=triaged, type_="Bug", title="症状"),
                issue(500, labels=reserved, type_="Design", title="着手中の根"),
                issue(501, labels=triaged, type_="Bug", title="着手中の根の症状"),
            ],
            prs=[closing_pr(90, closes=[500])],
            parents={
                1561: parent(2209, type_="Design", labels=triaged),
                501: parent(500, type_="Design", labels=reserved),
            },
        )
        self.assertEqual(
            done.stdout.splitlines(),
            [
                "2209 ready [Design] 根",
                "500 busy PR #90 が出ている (着手中の根)",
                "1561 busy 根 #2209 で直す (症状)",
                "501 busy 根 #500 で直す (着手中の根の症状)",
            ],
        )
        self.assertIn("ready 1 /", done.stderr)

    def test_children_that_are_not_symptoms_of_an_open_root_stay_ready(self):
        """根で直すのは、open な Bug の子と、印の付いた open な Design の Bug の子だけ (#2228)。"""
        triaged = ["verify: triaged"]
        done, _ = self.run_queue(
            [
                issue(1767, labels=triaged, type_="Task"),
                issue(1768, labels=triaged, type_="Task"),
                issue(410, labels=triaged, type_="Bug"),
                issue(420, labels=triaged, type_="Bug"),
                issue(1663, labels=triaged, type_="Task"),
                issue(402, type_="Design", title="無印の根"),
                issue(430, labels=triaged, type_="Bug"),
            ],
            parents={
                # 自分の作業を持たない入れ物の親は巻き込まない (#180 の子 #1767・#1768)。
                # 子が Bug でも同じ
                1767: parent(180, type_="Task"),
                1768: parent(180, type_="Task"),
                410: parent(400, type_="Task"),
                420: parent(401, type_="Feature"),
                # 印の付いた Design でも、Bug でない子は根の症状ではない (#1659 の子 #1663)
                1663: parent(1659, type_="Design", labels=triaged),
                # 無印の Design を待つ間は症状の直しを止めない (ADR-0040 決定 3)。根は decide に出る
                430: parent(402, type_="Design"),
            },
        )
        seen = self.lines_by_number(done.stdout)
        for n in (1767, 1768, 410, 420, 1663, 430):
            self.assertEqual(seen[n][0], "ready", f"#{n} を根で直す側へ回している")
        self.assertEqual(seen[402][0], "decide", "無印の根を人に見せていない")
        self.assertIn("ready 6 /", done.stderr)

    def test_children_waiting_on_their_root_are_not_work(self):
        """ready の件数は親を読んでから数える (終了コードに効く)。"""
        done, _ = self.run_queue(
            [issue(101, labels=["verify: triaged"], type_="Bug")],
            parents={101: parent(100)},
        )
        self.assertEqual(done.returncode, 1, "根を待つ子しか無いのに打てる仕事があると言った")
        self.assertIn("ready 0 /", done.stderr)

    def test_design_with_open_bug_children_is_decide(self):
        issues = [
            issue(300, type_="Design", title="子 1 件"),
            issue(301, type_="Design", title="子 2 件"),
            issue(302, type_="Design", title="Task の子だけ"),
            issue(303, type_="Design", title="子なし"),
            issue(310, type_="Bug"),
            issue(311, type_="Bug"),
            issue(312, type_="Bug", labels=["verify: triaged"]),  # 印の有無は問わない
            issue(320, type_="Task"),
        ]
        done, _ = self.run_queue(
            issues,
            parents={
                310: parent(300, type_="Design"),
                311: parent(301, type_="Design"),
                312: parent(301, type_="Design"),
                320: parent(302, type_="Design"),
            },
        )
        lines = done.stdout.splitlines()
        decide = [line for line in lines if line.split(" ")[1] == "decide"]
        self.assertEqual(
            decide,
            [
                "301 decide open な Bug の子 2 件が根本の判断を待っている (子 2 件)",
                "300 decide open な Bug の子 1 件が根本の判断を待っている (子 1 件)",
            ],
            f"子の多い順に出ていない:\n{done.stdout}",
        )
        self.assertEqual(lines[-len(decide):], decide, "decide が最後に出ていない")
        self.lines_by_number(done.stdout)  # 4 列を守っている (崩れていれば分解で落ちる)
        self.assertIn("/ decide 2", done.stderr)

    def test_decide_is_not_work(self):
        """decide は人が決める行で、打てる仕事ではない — 終了コードに数えない。"""
        done, _ = self.run_queue(
            [issue(300, type_="Design"), issue(310, type_="Bug")],
            parents={310: parent(300, type_="Design")},
        )
        self.assertIn("300 decide", done.stdout)
        self.assertEqual(done.returncode, 1, "decide しか無いのに打てる仕事があると言った")

    def test_parents_are_not_read_without_bugs_or_candidates(self):
        done, log = self.run_queue(
            [
                issue(1, type_="Task", body=SIGNATURE),  # stock
                issue(2, labels=["status: in progress"]),
                issue(3, type_="Design"),
            ],
            prs=[closing_pr(90, closes=[2])],
        )
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertNotIn("graphql", log, "open な Bug も ready の候補も無いのに親を読んでいる")

    def test_unreadable_parents_keep_ready_and_say_so(self):
        done, _ = self.run_queue(
            [
                issue(101, labels=["verify: triaged"], type_="Bug"),
                issue(300, type_="Design"),
            ],
            parents={101: parent(300, type_="Design")},
            FAIL_PARENTS="1",
        )
        self.assertEqual(done.returncode, 0, "親が読めないだけで ready を消している")
        seen = self.lines_by_number(done.stdout)
        self.assertEqual(seen[101][0], "ready")
        self.assertNotIn(300, seen, "読めなかったのに decide を出している")
        self.assertIn("親を読めなかった", done.stderr)


if __name__ == "__main__":
    unittest.main()
