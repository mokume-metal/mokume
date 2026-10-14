#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/ci_tools.py (make setup の道具の版の突き合わせ) の検査 (#2612)。

版の正本は scripts/ci-tools.txt の 1 か所で、CI はそこから入れ、手元は make setup がそこを
読んで突き合わせる。ここで固定するのは次の 4 つ:

  1. 3 つの道具が ci-tools.txt と同じ版なら 0 で抜ける
  2. 1 つでも違えば 1 で抜け、違う道具と、ci-tools.txt の版つきの入れ方を名乗る
  3. chardet は reuse と同じ環境のものを読む — pip が Python の置き場の空白を避けて書く
     sh の 2 行 (pipx の既定の置き場がそれに当たる) からも読める
  4. reuse が無い・起動しないときも黙らずに名乗る

道具は PATH の先に置いた代役で、版は本物の ci-tools.txt から読む (写しを持たない)。
実行は make hooks-test。
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci_tools.py"

spec = importlib.util.spec_from_file_location("ci_tools", SCRIPT)
ci_tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci_tools)


class CiToolsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        (self.bin / "python3").symlink_to(sys.executable)
        # reuse の環境の Python。置き場に空白を含める (pipx の既定の置き場と同じ形)
        self.venv = Path(self.tmp.name) / "Application Support" / "venv"
        self.venv.mkdir(parents=True)
        self.pinned = ci_tools.pins()

    def put(self, name: str, text: str, where: Path | None = None) -> Path:
        path = (where or self.bin) / name
        path.write_text(text)
        path.chmod(0o755)
        return path

    def put_tools(self, reuse=None, chardet=None, jsonschema=None, reuse_rc=0):
        reuse = reuse or self.pinned["reuse"]
        chardet = chardet or self.pinned["chardet"]
        jsonschema = jsonschema or self.pinned["check-jsonschema"]
        # reuse の環境の Python の代役: -c で chardet の版を問われたら答え、それ以外は reuse として振る舞う
        python = self.put(
            "python",
            "#!/bin/sh\n"
            'if [ "$1" = "-c" ]; then\n'
            f'  [ "{chardet}" = none ] && exit 1\n'
            f'  echo "{chardet}"; exit 0\n'
            "fi\n"
            f'echo "reuse, version {reuse}"; exit {reuse_rc}\n',
            self.venv,
        )
        # pip が空白のある置き場に書く形 (1 行目は sh・2 行目で Python に起こし直す)
        self.put("reuse", f"#!/bin/sh\n'''exec' \"{python}\" \"$0\" \"$@\"\n' '''\n")
        self.put("check-jsonschema", f'#!/bin/sh\necho "check-jsonschema, version {jsonschema}"\n')

    def run_check(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "check"],
            env={**os.environ, "PATH": f"{self.bin}:/usr/bin:/bin"},
            capture_output=True, text=True, timeout=60,
        )

    def test_版を_ci_tools_txt_から読む(self):
        self.assertTrue({"reuse", "chardet", "check-jsonschema"} <= set(self.pinned))
        self.assertRegex(self.pinned["reuse"], r"^\d+\.\d+")

    def test_3_つが_CI_と同じ版なら緑(self):
        self.put_tools()
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("ok:", r.stdout)

    def test_版が違えば赤で版つきの入れ方を名乗る(self):
        self.put_tools(jsonschema="0.0.1")
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn(f"check-jsonschema: 手元 0.0.1 / CI {self.pinned['check-jsonschema']}", r.stderr)
        self.assertNotIn("reuse: 手元", r.stderr)
        self.assertIn(f"check-jsonschema=={self.pinned['check-jsonschema']}", r.stderr)
        self.assertIn(f"chardet=={self.pinned['chardet']}", r.stderr)

    def test_chardet_は_reuse_の環境から読む(self):
        self.put_tools(chardet="0.0.1")
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn(f"chardet: 手元 0.0.1 / CI {self.pinned['chardet']}", r.stderr)

    def test_chardet_が無ければ名乗る(self):
        self.put_tools(chardet="none")
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("chardet: 手元 見つからない", r.stderr)

    def test_reuse_が起動しなければ_chardet_を疑うよう名乗る(self):
        self.put_tools(reuse_rc=1)
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("reuse が起動しない", r.stderr)

    def test_道具が無ければ赤(self):
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        for name in ("reuse", "chardet", "check-jsonschema"):
            self.assertIn(f"{name}: 手元 見つからない", r.stderr)


if __name__ == "__main__":
    unittest.main()
