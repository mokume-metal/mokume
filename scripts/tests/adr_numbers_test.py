#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-adr-numbers.sh の検査 (#500)。

このスクリプトが守るのは 1 つ — **ADR の番号が重複したら赤い**こと。#490 と #491 が
並走して両方 0026 を取ったとき、別ファイルなので git も CI も止めなかった。通す側へ
倒れれば同じことがまた起きるので、赤くなる条件を最初に固定する (ADR-0002 決定 4 の
「壊しても緑の検査は検査ではない」)。

一時ディレクトリを位置引数で渡すので、git も認証もネットワークも要らない。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-adr-numbers.sh"


class AdrNumbersTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def place(self, *names):
        for name in names:
            (self.dir / name).write_text("# 見出し\n", encoding="utf-8")

    def run_script(self, *args):
        return subprocess.run(
            ["bash", str(SCRIPT), *(args or (str(self.dir),))],
            capture_output=True, text=True, encoding="utf-8"
        )

    def test_番号が重複していれば赤い(self):
        self.place("0026-plugin-repository-alignment.md", "0026-readable-surfaces.md")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        # どの番号が・どのファイルで衝突したかを名指しする。名指しが無いと
        # 27 本の一覧から人が探すことになる
        self.assertIn("ADR-0026", r.stderr)
        self.assertIn("0026-plugin-repository-alignment.md", r.stderr)
        self.assertIn("0026-readable-surfaces.md", r.stderr)
        # 直し方まで出す — 見出しと参照の綴りも一緒に動くので、改番だけでは済まない
        self.assertIn("改番", r.stderr)

    def test_番号が一意なら緑(self):
        self.place("0026-plugin-repository-alignment.md", "0027-readable-surfaces.md")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("ok:", r.stdout)

    def test_番号を名乗らないファイルは数えない(self):
        # 番号を持たないファイルは ADR-00NN の綴りで参照されようがないので、
        # 同居していても検査の対象ではない (2 つ置いても重複扱いにしない)
        self.place("0026-plugin-repository-alignment.md", "README.md", "NOTES.md")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("1 本検査", r.stdout)

    def test_置き場が無ければ赤い(self):
        # 既定の置き場を打ち間違えたまま緑を返すと、検査が「何も見ていない」ことを
        # 緑で答えることになる
        r = self.run_script(str(self.dir / "not-there"))
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("置き場が無い", r.stderr)

    def test_引数を省略するとリポジトリのADRを見る(self):
        # 既定の配線 (git root の docs/decisions) が生きていることを見る。
        # ここが切れると、テストだけが緑で ci-check は何も検査しない状態になる
        r = subprocess.run(
            ["bash", str(SCRIPT)], cwd=str(REPO),
            capture_output=True, text=True, encoding="utf-8"
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("ok:", r.stdout)


if __name__ == "__main__":
    unittest.main()
