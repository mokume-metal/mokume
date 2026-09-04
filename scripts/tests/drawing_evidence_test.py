#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-drawing-evidence.sh の検査 (#306)。

このスクリプトが守るのは 1 つ — **描画に触れる PR は、絵が本文に載るまで赤い**こと。
通してしまう側へ倒れると #306 の穴 (絵の貼り忘れに誰も気付かない) に戻るので、
赤くする条件と、赤くしてはいけない条件を 1 つずつ固定する。

判定できない事情 (PR がまだ無い・認証が無い) で赤くならないことも併せて固定する。
手元では PR を作る前に make ci-check を打つのが普通で、そこで赤くすると入口が塞がる。

gh は PATH の先頭に置いた偽物へ差し替えるので、ネットワークも認証も要らない。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-drawing-evidence.sh"

# `Sketches/` は印つきの行 — 絵の証跡は要るが、覆いの判定には数えない (#497)
PATHS = "# 見出し\n\nSources/MokumeCore/\nSketches/  evidence-only\n"

DRAWING_FILES = ["Sources/MokumeCore/Drawing/Canvas.swift"]
# 覆いの判定からは外れるが、証跡はここでも要る (#497)
SKETCH_FILES = ["Sketches/Shapes/Circles.swift"]
OTHER_FILES = ["AGENTS.md", "scripts/check-drawing-evidence.sh"]

# gh pr view の応答を PR_JSON からそのまま返す。auth status は通る。
# GH_UNAUTHED を立てると認証が無い機械を、GH_NO_PR を立てると PR の無いブランチを装う。
#
# **変更ファイルは別の口から返す** (#793)。gh pr view の files は上限のある口なので、
# 検査もそれを装わない — ALL_FILES が `--paginate` を通した全件で、PR_JSON の files は
# 上限で切られた前半を表す。GH_FILES_FAIL を立てると一覧が読めない機械を装う
FAKE_GH = """#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "auth status") [ -n "${GH_UNAUTHED:-}" ] && exit 1; exit 0 ;;
  "pr view") [ -n "${GH_NO_PR:-}" ] && { echo "no pull requests found" >&2; exit 1; }
             cat "$PR_JSON"; exit 0 ;;
esac
case "$*" in
  *"/files"*) [ -n "${GH_FILES_FAIL:-}" ] && { echo "gh: 500" >&2; exit 1; }
              printf '%s\\n' ${ALL_FILES:-}; exit 0 ;;
esac
exit 0
"""


class DrawingEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)

        self.calls = self.root / "gh-calls.txt"
        self.pr_json = self.root / "pr.json"
        (self.root / "paths.txt").write_text(PATHS)

        self.env = dict(os.environ)
        self.env.update(
            PATH=f"{bin_dir}:{os.environ['PATH']}",
            GH_CALLS=str(self.calls),
            PR_JSON=str(self.pr_json),
            DRAWING_PATHS=str(self.root / "paths.txt"),
        )
        self.env.pop("GITHUB_REPOSITORY", None)
        self.env.pop("PR_NUMBER", None)

    def run_script(self, *, body="", labels=(), files=DRAWING_FILES, args=("101",),
                   all_files=None, **env):
        """`all_files` は **`--paginate` を通した一覧** (#793)。

        省略すると `files` と同じ。上限を越える PR を装うときだけ別に渡す。
        """
        self.pr_json.write_text(json.dumps({
            "body": body,
            "labels": [{"name": n} for n in labels],
            "number": 101,
            # gh pr view はもう読まれないが、上限で切られた前半として残す
            "files": [{"path": p} for p in files],
        }))
        self.env["ALL_FILES"] = " ".join(files if all_files is None else all_files)
        self.env.update(env)
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), *args], cwd=self.root, env=self.env,
            capture_output=True, text=True, encoding="utf-8"
        )

    # --- 赤くなるべきとき -------------------------------------------------

    def test_描画に触れるのに絵が無ければ赤い(self):
        r = self.run_script(body="## 目的\n\nCloses #1\n\n## 確認方法\n\nmake ci-check")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("絵が無い", r.stderr)
        # 逃がしの手順を必ず示す — 示さないと逃げ道が読めず、機構ごと迂回される
        self.assertIn("no-visual-change", r.stderr)

    def test_本文が空でも赤い(self):
        self.assertEqual(self.run_script(body="").returncode, 1)

    def test_画像でないURLは絵として数えない(self):
        r = self.run_script(body="詳細は https://github.com/mokume-metal/mokume/issues/306 を参照")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)

    # --- 絵として数える形 -------------------------------------------------

    def test_絵の形をひととおり通す(self):
        forms = {
            "markdown": "![before](https://example.invalid/a)",
            "gyazo ページ": "before https://gyazo.com/0123456789abcdef",
            "gyazo 直": "after https://i.gyazo.com/0123456789abcdef.png",
            "github の添付": "![b](https://github.com/user-attachments/assets/1-2-3)",
            "img タグ": '<img src="https://example.invalid/a.webp" width="400">',
            "拡張子付きの裸 URL": "https://example.invalid/shots/after.webp",
            "動画": "https://example.invalid/motion.mp4",
        }
        for name, body in forms.items():
            with self.subTest(name):
                r = self.run_script(body=body)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertIn("ok:", r.stdout)

    # --- 赤くしてはいけないとき -------------------------------------------

    def test_逃がしのラベルが付いていれば通る(self):
        r = self.run_script(body="絵は変わらない", labels=["no-visual-change"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("no-visual-change", r.stdout)

    def test_覆いの判定から外れる場所でも絵は要る(self):
        """`Sketches/` は手元の実行の覆いには数えないが (#497)、描くのは絵なので
        証跡の問いでは従来どおり赤くなる。2 つの問いの答えが分かれる場所である。"""
        r = self.run_script(body="", files=SKETCH_FILES)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("絵が無い", r.stderr)

    def test_描画に触れないPRは絵が無くても通る(self):
        r = self.run_script(body="", files=OTHER_FILES)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("描画に触れていない", r.stdout)

    def test_後半にだけ描画のパスがある大きなPRでも絵は要る(self):
        """**上限を越える PR** (#793)。

        `gh pr view --json files` は GraphQL の接続を引くので上限があり、大きな PR では
        後半のファイルが落ちる。落ちれば「描画に触れていない」と読み、**絵の証跡の要求が
        黙って外れる** — #306 の機構が緑のまま効かなくなる形である。

        ここでは上限で切られる側に無害な 100 件だけを持たせ、全件の側にだけ描画のパスを
        101 件目として置く。上限のある口を読んでいれば緑で通ってしまう。
        """
        truncated = [f"docs/note{i}.md" for i in range(100)]
        r = self.run_script(body="", files=truncated, all_files=truncated + DRAWING_FILES)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("絵が無い", r.stderr)

    def test_一覧はページングを通して引く(self):
        """判定の結果だけを見ていると、上限に収まる PR では**付け忘れても緑**になる。"""
        self.run_script(body="![a](https://example.invalid/a.png)")
        # **記録全体ではなく、一覧を引いたその行を見る** — 他の呼び出しの --paginate で
        # 緑になると、付け忘れを見逃す
        lines = [l for l in self.calls.read_text(encoding="utf-8").splitlines() if "/files" in l]
        self.assertTrue(lines, "変更ファイルの一覧を引いていない")
        for line in lines:
            self.assertIn("--paginate", line, f"ページングを通していない呼び出し: {line}")

    def test_一覧が読めなければ判定しない(self):
        """**読めなかったことを「触れていない」と混ぜない。**

        混ぜると、まさにこの Issue が塞いだ緩み方 (絵の要求が黙って外れる) に戻る。
        """
        r = self.run_script(body="", GH_FILES_FAIL="1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("判定しない", r.stdout)
        self.assertIn("変更ファイルを読めなかった", r.stdout)

    def test_このブランチにPRが無ければ判定しない(self):
        r = self.run_script(body="", args=(), GH_NO_PR="1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PR が無い", r.stdout)

    def test_ghが認証されていなければ判定しない(self):
        r = self.run_script(body="", GH_UNAUTHED="1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("認証", r.stdout)

    # --- 呼び方 -----------------------------------------------------------

    def test_PR番号は引数と環境変数のどちらでも渡せる(self):
        self.run_script(body="![a](x.png)", args=("101",))
        self.assertIn("101", self.calls.read_text())
        self.calls.write_text("")
        self.run_script(body="![a](x.png)", args=(), PR_NUMBER="202")
        self.assertIn("202", self.calls.read_text())

    def test_GITHUB_REPOSITORYがあれば宛先に渡す(self):
        self.run_script(body="![a](x.png)", GITHUB_REPOSITORY="mokume-metal/mokume")
        self.assertIn("-R mokume-metal/mokume", self.calls.read_text())


if __name__ == "__main__":
    unittest.main()
