#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/parent-guard.sh の検査 (#23 / #798)。

parent-guard は「親の close = 全作業完了」というツリーの不変条件を守る (ADR-0002)。
open の sub-issue を残したまま completed で close されたら reopen して警告する。
not planned での close は対象外で、その切り分けは呼び出し側 (workflow の if:) が
イベントの state_reason で行うので、ここには来ない。

この workflow は issues イベントで走るため既定ブランチのものしか実行されず、
ブランチ上では実地確認できない。だからロジックを YAML から出してここで検査する
(#66 で確認した性質)。**その性質を最初に踏んだのがこの判定である** — #23 で
parent-guard が空振りし、scripts/check-workflows.sh:8-11 がそれを実害の例に
挙げている。規律を作ったきっかけのファイルだけが規律の外に残っていた (#798)。

固定したいのは 3 つ:
  - open の子が残っていれば reopen して、その一覧をコメントに載せる
  - 残っていなければ何もしない (reopen も comment も呼ばない)
  - **引けなかったことを「子が居ない」に混ぜない** (#865 が宣言した向き)。
    以前は 2>/dev/null || true で握り潰し、API が落ちても「ok」と名乗っていた

gh は PATH の先頭に置いた偽物へ差し替えるので、ネットワークも認証も要らない。
実行は make ci-check (CI もこれを呼ぶ)。
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "parent-guard.sh"

# 偽 gh。呼ばれた引数を残し、問い合わせには環境変数の値を返す。
#   gh api --paginate repos/<r>/issues/<n>/sub_issues --jq … → FAKE_CHILDREN (本物が
#       畳んだ後の行の並び。FAKE_API_FAILS=1 なら stderr に書いて非 0)
#   gh issue reopen / comment                                → 記録するだけ
FAKE_GH = """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_GH_LOG"
case "$*" in
  *sub_issues*)
    if [ "${FAKE_API_FAILS:-0}" = "1" ]; then
      echo 'gh: Server Error (HTTP 502)' >&2
      exit 1
    fi
    [ -n "$FAKE_CHILDREN" ] && printf '%s\\n' "$FAKE_CHILDREN"
    ;;
  *"issue comment"*) printf '%s' "$*" > "$FAKE_COMMENT_LOG" ;;
esac
exit 0
"""


class ParentGuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bindir = Path(self.tmp.name) / "bin"
        self.bindir.mkdir()
        stub = self.bindir / "gh"
        stub.write_text(FAKE_GH, encoding="utf-8")
        stub.chmod(0o755)
        self.log = Path(self.tmp.name) / "gh.log"
        self.log.touch()
        self.comment = Path(self.tmp.name) / "comment.log"
        self.comment.touch()

    def run_guard(self, children="", api_fails=False, number="42"):
        env = dict(os.environ)
        env["PATH"] = f"{self.bindir}:{env['PATH']}"
        env["FAKE_GH_LOG"] = str(self.log)
        env["FAKE_COMMENT_LOG"] = str(self.comment)
        env["FAKE_CHILDREN"] = children
        env["FAKE_API_FAILS"] = "1" if api_fails else "0"
        proc = subprocess.run(
            ["/bin/bash", str(SCRIPT), number],
            capture_output=True,
            text=True,
            env=env,
        )
        return proc, self.log.read_text(encoding="utf-8")

    # --- 1. open の子が残っていれば reopen する -----------------------------

    def test_open_children_reopen_the_parent(self):
        proc, calls = self.run_guard(children="- #7 まだ終わっていない子")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("issue reopen 42", calls)
        self.assertIn("issue comment 42", calls)

    def test_the_comment_names_which_children_are_open(self):
        # 一覧が落ちると「reopen された理由」が読み手に伝わらない
        _, _ = self.run_guard(children="- #7 ひとつめ\n- #9 ふたつめ")
        body = self.comment.read_text(encoding="utf-8")
        self.assertIn("#7 ひとつめ", body)
        self.assertIn("#9 ふたつめ", body)
        self.assertIn("not planned", body, "ツリーごと畳む逃がし道を書いていない")

    # --- 2. 残っていなければ何もしない --------------------------------------

    def test_no_open_children_changes_nothing(self):
        proc, calls = self.run_guard(children="")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("issue reopen", calls)
        self.assertNotIn("issue comment", calls)

    # --- 3. 引けなかったことを「子が居ない」に混ぜない (#865) ---------------

    def test_unreachable_api_is_not_read_as_no_children(self):
        proc, calls = self.run_guard(api_fails=True)
        self.assertNotEqual(proc.returncode, 0, "握り潰して ok と名乗ってしまった")
        self.assertIn("引けなかった", proc.stderr)
        self.assertIn("次にすること", proc.stderr)
        # 憶測で人の Issue を開け直さない — 名乗って赤で止まる側に倒す
        self.assertNotIn("issue reopen", calls)

    # --- 4. 30 件を超える子を取りこぼさない ---------------------------------

    def test_children_are_paginated(self):
        # 既定は 1 ページ 30 件。取りこぼしはこの見張りでは「ok」に化けるので、
        # 不変条件が黙って破れる (#793 で同じ穴を踏んでいる)
        _, calls = self.run_guard(children="- #7 子")
        self.assertIn("--paginate", calls)

    # --- 5. 投稿はラッパーを通さない ----------------------------------------

    def test_the_comment_carries_no_ai_signature(self):
        # comment.sh は「どの AI が書いたか」を名乗らせるラッパーで、ここは AI では
        # なく決定論的な機械である。github.token での投稿は GitHub が bot として
        # 出所を描くので、ラッパーが埋める穴が空いていない (理由は comment.sh 冒頭)
        _, _ = self.run_guard(children="- #7 子")
        self.assertNotIn("Assisted by", self.comment.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
