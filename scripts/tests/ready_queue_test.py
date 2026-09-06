#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/ready-queue.sh の検査 (#1028)。

固定したいのは六つ。

1. **何も打たない。** 判定を手元で打っただけでラベルが付いたり auto-merge が掛かったり
   すると、判定と実行を分けた意味が消える (ADR-0036 決定 1)
2. **`verify: triaged` が無ければ ready に出ない。** 着手ゲートは ADR-0002 決定 1 の
   ままで、この判定はそこを緩めない
3. **着手印が残っているものは busy か dropped に分かれる。** 紐づく PR も手元の枝も
   無いときだけ dropped で、**それは「落ちた」ではなく「落ちて見える」**である
4. **stock は署名つき・無印・型が Bug / Task / Docs のときだけ。** Design / Feature は
   判断が要る側なので出さない (ADR-0036 決定 6)
5. **描画の見込みは coverage の用途で訊く。** `Sketches/` は evidence-only なので、
   そこしか触らない Issue は描画レーンを取らない (#497)
6. **終了コードが在庫の有無を表す。** 呼ぶ側 (外に居るディスパッチャ) が「在庫が尽きたので
   B-1 へ回る」を分岐できる

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

if [ "$1 $2" = "issue list" ]; then emit "$FIX/issues.json"; exit 0; fi
if [ "$1 $2" = "pr list" ]; then emit "$FIX/prs.json"; exit 0; fi

echo "偽 gh が知らない呼び出し: $*" >&2
exit 1
"""

FAKE_GIT = """#!/bin/bash
printf '%s\\n' "$*" >> "$GIT_CALLS"

if [ "$1 $2" = "worktree list" ]; then cat "$FIX/worktrees.txt"; exit 0; fi

echo "偽 git が知らない呼び出し: $*" >&2
exit 1
"""

# 検査用の一覧。**本物を読まない** — 一覧が動いたときに、無関係な検査が赤くならないため
DRAWING_PATHS = """# 検査用
Sources/MokumeCore/
Sketches/  evidence-only
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
    owner, name = repo.split("/")
    return {
        "number": number,
        "closingIssuesReferences": [
            {"number": n, "repository": {"owner": {"login": owner}, "name": name}}
            for n in closes
        ],
    }


class ReadyQueueTest(unittest.TestCase):
    def run_queue(self, issues, prs=(), worktrees=""):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            fix = tmp / "fixtures"
            fix.mkdir()
            (fix / "issues.json").write_text(json.dumps(issues), encoding="utf-8")
            (fix / "prs.json").write_text(json.dumps(list(prs)), encoding="utf-8")
            (fix / "worktrees.txt").write_text(worktrees, encoding="utf-8")
            (tmp / "drawing-paths.txt").write_text(DRAWING_PATHS, encoding="utf-8")

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
                DRAWING_PATHS=str(tmp / "drawing-paths.txt"),
            )
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
            number, kind, guess, rest = line.split(" ", 3)
            out[int(number)] = (kind, guess, rest)
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
        self.assertIn("PR #90", seen[10][2])
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

    # 5. 描画の見込みは coverage の用途で訊く
    def test_drawing_guess(self):
        issues = [
            issue(30, labels=["verify: triaged"], body="Sources/MokumeCore/Frame.swift を直す"),
            issue(31, labels=["verify: triaged"], body="Sketches/Demo.swift だけ触る"),
            issue(32, labels=["verify: triaged"], body="どこにも触れない話"),
            issue(
                33,
                labels=["verify: triaged"],
                body="https://github.com/mokume-metal/mokume/blob/main/Sources/MokumeCore/A.swift",
            ),
        ]
        done, _ = self.run_queue(issues)
        seen = self.lines_by_number(done.stdout)
        self.assertEqual(seen[30][1], "drawing?")
        self.assertEqual(seen[31][1], "plain?", "evidence-only が coverage で外れていない")
        self.assertEqual(seen[32][1], "plain?")
        self.assertEqual(seen[33][1], "drawing?", "URL の中のパスを拾えていない")

    # 6. 終了コードが在庫の有無を表す
    def test_exit_code_says_stock_out(self):
        done, _ = self.run_queue([issue(40, type_="Bug", body=SIGNATURE)])
        self.assertEqual(done.returncode, 1, "ready が 0 件なのに 0 で終えている")
        self.assertIn("40 stock", done.stdout)

        done, _ = self.run_queue([issue(41, labels=["verify: triaged"])])
        self.assertEqual(done.returncode, 0)


if __name__ == "__main__":
    unittest.main()
