#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-adrs.sh の検査 (#500 / #545)。

このスクリプトが守るのは 2 つ — **番号が重複したら赤い** (#490 と #491 が並走して
両方 0026 を取ったとき、別ファイルなので git も CI も止めなかった) ことと、
**本文に改訂があるのに状態欄が名乗っていなければ赤い** (29 本中 27 本の状態欄が
`採用` のままで、節が情報を運んでいなかった) こと。どちらも通す側へ倒れれば同じ
ことがまた起きるので、赤くなる条件を先に固定する (ADR-0002 決定 4 の
「壊しても緑の検査は検査ではない」)。

状態欄の側でとくに固定したいのは**誤検出しないこと**である。日付を持たない
「〜は改訂しない」という散文は改訂ではない (ADR-0006 決定 6 が実例)。ここを
拾ってしまう検査は、正しい ADR を赤くして書き手に嘘の宿題を出す。

一時ディレクトリを位置引数で渡すので、git も認証もネットワークも要らない。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-adrs.sh"


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
            ["/bin/bash", str(SCRIPT), *(args or (str(self.dir),))],
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
            ["/bin/bash", str(SCRIPT)], cwd=str(REPO),
            capture_output=True, text=True, encoding="utf-8"
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("ok:", r.stdout)


class AdrStatusTest(unittest.TestCase):
    """状態欄が本文の改訂に追随しているか (#545)。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def place(self, status, *body, name="0003-agent-identity-separation.md"):
        text = "# ADR-0003: 見出し\n\n## 状態\n\n" + status + "\n\n## 決定\n\n"
        text += "\n\n".join(body) + "\n"
        (self.dir / name).write_text(text, encoding="utf-8")

    def run_script(self):
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), str(self.dir)],
            capture_output=True, text=True, encoding="utf-8"
        )

    def test_決定見出しに併記した改訂が状態欄に無ければ赤い(self):
        self.place("採用 (2026-08-26)",
                   "### 4. `required_approving_review_count` は 0 のままにする (2026-08-28 改訂)")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        # 日付を名指しする。名指しが無いと、どの改訂が漏れたかを本文から探す
        # ことになる (改訂を 4 つ抱えた ADR-0003 が実在する)
        self.assertIn("2026-08-28", r.stderr)
        self.assertIn("0003-agent-identity-separation.md", r.stderr)

    def test_追記節として立てた改訂が状態欄に無ければ赤い(self):
        self.place("採用 (2026-08-26)",
                   "#### 改訂 (2026-08-30) — CODEOWNERS を畳む")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("2026-08-30", r.stderr)

    def test_追補も同じに扱う(self):
        self.place("採用 (2026-08-27)", "## 追補 — 手段は自前の補間にする (2026-08-29)")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("2026-08-29", r.stderr)

    def test_複数の改訂は漏れたぶんだけ挙がる(self):
        self.place("採用 (2026-08-26) / 改訂 (2026-08-28): 決定 4",
                   "### 4. …… (2026-08-28 改訂)",
                   "#### 改訂 (2026-08-30) — CODEOWNERS を畳む")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("2026-08-30", r.stderr)
        # 名乗れているほうを蒸し返さない
        self.assertNotIn("本文の改訂: 2026-08-28", r.stderr)

    def test_状態欄が名乗っていれば緑(self):
        self.place("採用 (2026-08-26) / 改訂 (2026-08-28): 決定 4 / 改訂 (2026-08-30): 決定 4",
                   "### 4. …… (2026-08-28 改訂)",
                   "#### 改訂 (2026-08-30) — CODEOWNERS を畳む")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_日付を持たない改訂の話は拾わない(self):
        # ADR-0006 決定 6 「ADR-0003 決定 1 の権限表は改訂しない」。改訂について
        # 語っているだけで改訂していない。素朴な grep はここで誤検出する
        self.place("採用 (2026-08-27)",
                   "### 6. ADR-0003 決定 1 の権限表は改訂しない",
                   "引き上げは本 ADR の改訂として、そのとき判断する (2026-08-29 に何かした訳ではない)")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_状態欄が見出しより多く名乗るのは正常(self):
        # ADR-0020 は改訂の見出しを持たないまま「決定 7 を追加」と名乗っている。
        # 向きは片方向で、状態欄の側が厚いことを咎めない
        self.place("採用 (2026-08-28) / 改訂 (2026-08-29): 決定 7 を追加", "### 7. 数の道具")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_状態欄が実在しないADRを指していれば赤い(self):
        self.place("採用 (2026-08-26) / 一部置換 (→ ADR-0031): 決定 4", "### 4. 決定")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("ADR-0031", r.stderr)

    def test_状態欄が指す先が在れば緑(self):
        self.place("採用 (2026-08-26) / 一部置換 (→ ADR-0004): 決定 1", "### 1. 決定")
        (self.dir / "0004-issue-classification-by-issue-type.md").write_text(
            "# ADR-0004\n\n## 状態\n\n採用 (2026-08-26)\n", encoding="utf-8")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_改訂を抱えるのに状態節が無ければ赤い(self):
        (self.dir / "0003-agent-identity-separation.md").write_text(
            "# ADR-0003\n\n## 決定\n\n#### 改訂 (2026-08-30) — 畳む\n", encoding="utf-8")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("状態欄が読めない", r.stderr)


if __name__ == "__main__":
    unittest.main()
