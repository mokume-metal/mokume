#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/ready-queue.sh の検査 (#1028)。

固定したいのは七つ。

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
6. **終了コードが「打てる仕事があるか」を表す。** 呼ぶ側 (外に居るディスパッチャ) が「在庫が
   尽きたので B-1 へ回る」を分岐できる。**打てる catch-up があれば在庫切れと言わない** (#1045)
7. **手元で打てる catch-up を ready より先に出す** (#1045)。当番が ejected と名乗る描画 PR の
   うち、行列の先頭のものだけを出す — 先に別の描画 PR が居るものは打っても無駄になる。
   弾かれた PR が無い平常時は、呼び出しも出力も従来のまま

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

# 描画 PR の順番の判定 (drawing-queue.sh) が引く 2 つ。**URL は $2 から取る** —
# "$*" には --jq の値まで混ざる
if [ "$1" = "api" ]; then
  case "$2" in
    *"/pulls?state=open"*) emit "$FIX/pulls.json"; exit 0 ;;
    */files) n=${2%/files}; n=${n##*/}; emit "$FIX/$n.files.json"; exit 0 ;;
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


def closing_pr(
    number, *, closes=(), repo="mokume-metal/mokume", render=None, draft=False, files=()
):
    """open な PR。render に local-render の状態 (StatusContext の state) を渡す。

    files は順番の判定が読む変更ファイル。run_queue がそこから偽 gh の応答を組む。
    """
    owner, name = repo.split("/")
    return {
        "number": number,
        "title": f"PR {number}",
        "isDraft": draft,
        "closingIssuesReferences": [
            {"number": n, "repository": {"owner": {"login": owner}, "name": name}}
            for n in closes
        ],
        # 本物の gh と同じく、commit status は context / state の欄で来る
        "statusCheckRollup": (
            []
            if render is None
            else [{"__typename": "StatusContext", "context": render[0], "state": render[1]}]
        ),
        "_files": list(files),
    }


DRAWING_FILE = "Sources/MokumeCore/Canvas.swift"


class ReadyQueueTest(unittest.TestCase):
    def run_queue(self, issues, prs=(), worktrees="", **extra_env):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            fix = tmp / "fixtures"
            fix.mkdir()
            (fix / "issues.json").write_text(json.dumps(issues), encoding="utf-8")
            listing = [{k: v for k, v in pr.items() if k != "_files"} for pr in prs]
            (fix / "prs.json").write_text(json.dumps(listing), encoding="utf-8")
            # 順番の判定が読む一覧 (REST の形)。Draft は API 側で外れる前提なので残しておく
            pulls = [{"number": pr["number"], "draft": pr["isDraft"]} for pr in prs]
            (fix / "pulls.json").write_text(json.dumps(pulls), encoding="utf-8")
            for pr in prs:
                (fix / f"{pr['number']}.files.json").write_text(
                    json.dumps([{"filename": f} for f in pr["_files"]]), encoding="utf-8"
                )
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
            env.pop("RENDER_CONTEXT", None)
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

    # 7a. 先頭の弾かれた描画 PR は catch-up として ready より先に出る
    def test_head_ejected_drawing_pr_is_catch_up(self):
        for state in ("FAILURE", "ERROR"):
            with self.subTest(state=state):
                done, log = self.run_queue(
                    [issue(60, labels=["verify: triaged"])],
                    prs=[closing_pr(900, render=("local-render", state), files=[DRAWING_FILE])],
                )
                self.assertEqual(done.returncode, 0, done.stderr)
                lines = done.stdout.splitlines()
                self.assertTrue(lines, "何も出ていない")
                self.assertTrue(
                    lines[0].startswith("900 catch-up - PR #900"),
                    f"catch-up が先頭に出ていない:\n{done.stdout}",
                )
                self.assertIn("make catch-up PR=900", lines[0])
                self.assertIn("60 ready", done.stdout)
                self.assertIn("catch-up 1 / ready 1", done.stderr)
                for verb in ("pr merge", "--add-label", "statuses"):
                    self.assertNotIn(verb, log, f"判定が {verb} を打っている")

    # 7b. 先に別の描画 PR が居るものは出さない (打っても無駄になる)
    def test_catch_up_waits_behind_earlier_drawing_pr(self):
        done, _ = self.run_queue(
            [issue(61, labels=["verify: triaged"])],
            prs=[
                closing_pr(800, files=[DRAWING_FILE]),  # 先に居る描画 PR (弾かれてはいない)
                closing_pr(900, render=("local-render", "FAILURE"), files=[DRAWING_FILE]),
            ],
        )
        self.assertNotIn("catch-up -", done.stdout, "行列の後ろの PR を打てると言っている")
        self.assertIn("catch-up 0 /", done.stderr)

        # 先に居る PR が描画に触れていなければ、行列の先頭である
        done, _ = self.run_queue(
            [],
            prs=[
                closing_pr(800, files=["docs/README.md"]),
                closing_pr(900, render=("local-render", "FAILURE"), files=[DRAWING_FILE]),
            ],
        )
        self.assertIn("900 catch-up", done.stdout)

    # 7c. 弾かれた PR が無ければ、呼び出しも出力も終了コードも従来のまま
    def test_no_ejected_pr_changes_nothing(self):
        prs = [
            closing_pr(900, render=("local-render", "SUCCESS"), files=[DRAWING_FILE]),
            closing_pr(901, render=("local-render", "PENDING"), files=[DRAWING_FILE]),
            closing_pr(902, render=("ci-gate", "FAILURE"), files=[DRAWING_FILE]),  # 別の check
            closing_pr(903, files=[DRAWING_FILE]),  # 報告が無い
        ]
        done, log = self.run_queue([issue(62, type_="Bug", body=SIGNATURE)], prs=prs)
        self.assertEqual(done.returncode, 1, "在庫切れなのに 0 で終えている")
        self.assertEqual(done.stdout, f"62 stock - エージェントの起票が無印のまま (Bug・なにか)\n")
        self.assertNotIn("api ", log, f"弾かれた PR が無いのに順番を引いている:\n{log}")

    # 7d. Draft は見ない (作業中の PR を Draft にしておくのが opt-out)
    def test_draft_is_not_catch_up(self):
        done, log = self.run_queue(
            [],
            prs=[
                closing_pr(
                    900, render=("local-render", "FAILURE"), draft=True, files=[DRAWING_FILE]
                )
            ],
        )
        self.assertEqual(done.returncode, 1)
        self.assertEqual(done.stdout, "")
        self.assertNotIn("api ", log)

    # 7e. 打てる catch-up だけでも在庫切れと言わない
    def test_catch_up_alone_is_work(self):
        done, _ = self.run_queue(
            [],
            prs=[closing_pr(900, render=("local-render", "FAILURE"), files=[DRAWING_FILE])],
        )
        self.assertEqual(done.returncode, 0, "打てる catch-up があるのに在庫切れを返した")

    # 7f. 報告の綴りは render-context.sh の 1 つを読む (当番と同じ実体 — ADR-0008 決定 6)
    def test_reads_shared_render_context(self):
        prs = [closing_pr(900, render=("別の綴り", "FAILURE"), files=[DRAWING_FILE])]
        done, _ = self.run_queue([], prs=prs, RENDER_CONTEXT="別の綴り")
        self.assertIn("900 catch-up", done.stdout)

        done, _ = self.run_queue([], prs=prs)  # 既定の綴りでは当たらない
        self.assertNotIn("catch-up -", done.stdout)


if __name__ == "__main__":
    unittest.main()
