#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/render-turn.sh (専用機へ積む順番の門番) の検査 (#2062)。

固定したいのは七つ。

1. **先頭の group は待たない。** 1 つ前の group の run が無いか終わっていれば、すぐに通す
2. **1 つ前の group の run が終わるまで待つ。** 待つ相手は自分の base sha を head に持つ
   render.yml の merge_group の run で、門番で待っている間の run も数える
3. **上限を越えたら通す。** 越えて待てば、自分の render が走る前に queue の期限で弾かれる
4. **API が読めなければ通す (go=true・終了 0)。** 門番の失敗で検査が走らないほうが重い
5. **yield は merge_group の run が 1 本でも残っていれば go=false。** status が queued でも
   in_progress でも見送る (門番で待っている group の run は in_progress)
6. **wait は merge_group の run が無くなるまで待ってから通す**
7. **使い方の誤りだけ非 0 (2)**

gh は PATH の先頭に置いた偽物へ差し替える。偽物は **--jq を実際に適用する**ので、
検査は絞り込みそのものを踏む (queue_sweep_test.py と同じ理由)。応答は呼ばれた回数で
切り替え、待つ側の「何回目で相手が終わったか」を表す。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TURN = REPO / "scripts" / "render-turn.sh"

# 応答は $DATA/<種類>-<回>.json。<回> はその種類が呼ばれた回数で、ファイルが無い回は
# それより前の最後の応答を繰り返す。1 つも無ければ空の一覧を返す
FAKE_GH = """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALLS"
[ -z "${GH_FAIL:-}" ] || { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }

filter=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then filter=$a; fi
  prev=$a
done

all="$*"
case "$all" in
  *"/actions/workflows/render.yml/runs?event=merge_group&head_sha="*) kind=prev ;;
  *"/actions/workflows/render.yml/runs?event=merge_group&status="*)
    kind=${all#*status=}; kind=${kind%%&*} ;;
  *) echo "偽 gh が知らない呼び出し: $*" >&2; exit 1 ;;
esac

counter="$DATA/count-$kind"
n=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$counter"

file=""
for ((i = n; i >= 1; i--)); do
  if [ -f "$DATA/$kind-$i.json" ]; then file="$DATA/$kind-$i.json"; break; fi
done
if [ -n "$file" ]; then jq -r "$filter" < "$file"; else echo '{"workflow_runs":[]}' | jq -r "$filter"; fi
"""

BASE = "354c03f3f696172be44123d56c4cdfc90d536bb6"
PREV = "gh-readonly-queue/main/pr-1257-c3af40e4d7db9d77266c48b3d84a98f30f8e9daf"
OTHER = "gh-readonly-queue/main/pr-1260-0a1b2c3d4e5f60718293a4b5c6d7e8f901234567"


def run_of(run_id, branch, status, conclusion=None):
    return {"id": run_id, "head_branch": branch, "status": status, "conclusion": conclusion}


class RenderTurnTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)

        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        gh = self.bin_dir / "gh"
        gh.write_text(FAKE_GH, encoding="utf-8")
        gh.chmod(0o755)

        self.data = root / "data"
        self.data.mkdir()
        self.calls = root / "gh-calls.txt"
        self.calls.write_text("", encoding="utf-8")
        self.output = root / "output.txt"
        self.summary = root / "summary.md"

    def answer(self, kind, round_no, runs):
        """<kind> の <round_no> 回目以降の応答を置く。"""
        (self.data / f"{kind}-{round_no}.json").write_text(
            json.dumps({"workflow_runs": runs}), encoding="utf-8"
        )

    def turn(self, *args, **extra):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}:{env['PATH']}"
        env["GH_CALLS"] = str(self.calls)
        env["DATA"] = str(self.data)
        env["GITHUB_OUTPUT"] = str(self.output)
        env["GITHUB_STEP_SUMMARY"] = str(self.summary)
        env["RENDER_TURN_INTERVAL"] = "0"
        env.pop("GITHUB_REPOSITORY", None)
        env.pop("RENDER_TURN_LIMIT", None)
        env.pop("GH_FAIL", None)
        env.update({k: str(v) for k, v in extra.items()})
        return subprocess.run(
            ["/bin/bash", str(TURN), *args],
            capture_output=True,
            text=True,
            env=env,
            check=False,
            timeout=30,
        )

    def go(self):
        lines = [ln for ln in self.output.read_text(encoding="utf-8").splitlines() if ln.startswith("go=")]
        self.assertEqual(len(lines), 1, lines)
        return lines[0].removeprefix("go=")

    def calls_of(self, needle):
        return [ln for ln in self.calls.read_text(encoding="utf-8").splitlines() if needle in ln]

    # --- merge_group ---------------------------------------------------------

    def test_先頭の_group_は待たない(self):
        r = self.turn("merge_group", BASE)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "true")
        self.assertEqual(len(self.calls_of("head_sha=")), 1)

    def test_前の_group_の_run_を自分の_base_sha_で引く(self):
        self.turn("merge_group", BASE)
        (call,) = self.calls_of("head_sha=")
        self.assertIn("/actions/workflows/render.yml/runs?", call)
        self.assertIn("event=merge_group", call)
        self.assertIn(f"head_sha={BASE}", call)

    def test_前の_group_の_run_が終わるまで待つ(self):
        # 門番で待っている (in_progress) → render が queued → 終わった
        self.answer("prev", 1, [run_of(11, PREV, "in_progress")])
        self.answer("prev", 2, [run_of(11, PREV, "queued")])
        self.answer("prev", 3, [run_of(11, PREV, "completed", "success")])
        r = self.turn("merge_group", BASE)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "true")
        self.assertEqual(len(self.calls_of("head_sha=")), 3)
        self.assertIn("待っている相手: 11 " + PREV, r.stdout)

    def test_前の_group_が_cancel_されていれば待たない(self):
        self.answer("prev", 1, [run_of(11, PREV, "completed", "cancelled")])
        r = self.turn("merge_group", BASE)
        self.assertEqual(self.go(), "true")
        self.assertEqual(len(self.calls_of("head_sha=")), 1, r.stdout)

    def test_上限を越えたら通す(self):
        self.answer("prev", 1, [run_of(11, PREV, "in_progress")])
        r = self.turn("merge_group", BASE, RENDER_TURN_LIMIT=0)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "true")
        self.assertIn("::warning::", r.stdout)
        self.assertIn(PREV, self.summary.read_text(encoding="utf-8"))

    def test_API_が読めなければ通す(self):
        r = self.turn("merge_group", BASE, GH_FAIL=1)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "true")
        self.assertIn("::warning::", r.stdout)

    # --- yield ---------------------------------------------------------------

    def test_yield_は_queued_の_run_があれば見送る(self):
        self.answer("queued", 1, [run_of(21, OTHER, "queued")])
        r = self.turn("yield")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "false")
        self.assertIn("見送った", self.summary.read_text(encoding="utf-8"))

    def test_yield_は門番で待っている_run_でも見送る(self):
        self.answer("in_progress", 1, [run_of(22, OTHER, "in_progress")])
        r = self.turn("yield")
        self.assertEqual(self.go(), "false", r.stdout)

    def test_yield_は_run_が無ければ通す(self):
        r = self.turn("yield")
        self.assertEqual(self.go(), "true", r.stdout)
        # 待たない: どの status も 1 回ずつしか引かない
        self.assertEqual(len(self.calls_of("status=queued")), 1)

    def test_yield_は_API_が読めなければ通す(self):
        r = self.turn("yield", GH_FAIL=1)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "true")

    # --- wait ----------------------------------------------------------------

    def test_wait_は_run_が無くなるまで待ってから通す(self):
        self.answer("in_progress", 1, [run_of(22, OTHER, "in_progress")])
        self.answer("in_progress", 3, [])
        r = self.turn("wait")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.go(), "true")
        self.assertEqual(len(self.calls_of("status=in_progress")), 3)

    def test_wait_も上限を越えたら通す(self):
        self.answer("queued", 1, [run_of(21, OTHER, "queued")])
        r = self.turn("wait", RENDER_TURN_LIMIT=0)
        self.assertEqual(self.go(), "true")
        self.assertIn("::warning::", r.stdout)

    # --- 使い方 --------------------------------------------------------------

    def test_使い方の誤りは_2_で終わり_go_を書かない(self):
        for args in [(), ("merge_group",), ("merge_group", ""), ("yield", "x"), ("nope",)]:
            r = self.turn(*args)
            self.assertEqual(r.returncode, 2, args)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.calls.read_text(encoding="utf-8"), "")

    def test_help_は冒頭の説明を出して_0_で終わる(self):
        r = self.turn("--help")
        self.assertEqual(r.returncode, 0)
        self.assertIn("render-turn.sh merge_group <base sha>", r.stdout)
        self.assertNotIn("set -euo", r.stdout)


if __name__ == "__main__":
    unittest.main()
