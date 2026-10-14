#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/reuse_encoding_fixtures.py の検査 (#817)。

`check-reuse-encoding.sh` が守っているのは #48 — reuse 6.x は SPDX を探す前に先頭
2048 バイトだけを encoding 判定器へ渡し、判定器の一つ charset_normalizer は途中で
切れた UTF-8 に None を返す。そのファイルは「バイナリ」と見なされ、SPDX ヘッダが
丸ごと無視される。日本語で厚く書くほど踏みやすい。

**検査の値は雛形が境界で文字を割っていることに全部乗っている。** 割らなくなると
`reuse lint` は当然通り、検査は**何も検査しないまま緑**になる。雛形の側にはそれを
防ぐ自己検査があるが、shell の heredoc に埋まっていたあいだ、その自己検査が効くかを
見るものは無かった。

ここで固定するのは 3 つ:

1. 雛形が 2048 バイト境界で 2 通り以上、文字を割っていること
2. **詰め物を ASCII にすると自己検査が落ちること** (自己検査が効いていることの検査)
3. **`check-reuse-encoding.sh` 本体が `/bin/bash` で動くこと** (#2612)。この段は CI では ubuntu の
   ci-static で走るので、手元とエージェントの `/bin/bash` (3.2) と BSD の道具で動くことは、
   macOS に残るここが持つ (#702)。reuse は代役で、判定の結論と名乗りの分かれ方だけを見る

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "reuse_encoding_fixtures.py"
CHECK = REPO / "scripts" / "check-reuse-encoding.sh"

# reuse の代役。--version と lint の結論を環境変数で選び、--debug の lint では判定モジュールを名乗る
FAKE_REUSE = """#!/bin/sh
case " $* " in
  *" --version "*) exit "${FAKE_REUSE_VERSION_RC:-0}" ;;
  *" --debug "*) echo "DEBUG: using encoding module 'charset_normalizer'"; exit 1 ;;
  *" lint "*)
    echo "fake lint output"
    exit "${FAKE_REUSE_LINT_RC:-0}" ;;
esac
exit 2
"""


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fixtures = _load("reuse_encoding_fixtures", SCRIPT)


class FixturesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)

    def test_three_fixtures_are_written(self):
        fixtures.write_fixtures(self.work)
        for pad in fixtures.PADDINGS:
            self.assertTrue((self.work / f"header-{pad}.txt").is_file())

    def test_at_least_two_split_a_character_at_the_boundary(self):
        """**ここが検査の値そのもの。** 割らなければ #48 を踏ませられない。"""
        split = fixtures.write_fixtures(self.work)
        self.assertGreaterEqual(len(split), 2, f"境界で文字を割ったのは {split} だけ")

    def test_every_fixture_carries_the_spdx_header(self):
        fixtures.write_fixtures(self.work)
        head = (self.work / "header-0.txt").read_bytes()[:80].decode("utf-8")
        # 帰属が無ければ reuse は当然落ちる — 検査が見たい症状と混ざる
        self.assertIn("SPDX-FileCopyrightText", head)
        self.assertIn("SPDX-License-Identifier", head)

    def test_an_ascii_filler_makes_the_self_check_fail(self):
        """詰め物が ASCII に変わると「何も検査しないまま緑」になる。そこで落ちること。"""
        split = fixtures.write_fixtures(self.work, filler=b"x" * 30)
        self.assertEqual(split, [], "ASCII の詰め物で境界が割れている")

    def test_the_command_refuses_when_nothing_splits(self):
        """口の側でも落ちること (呼び出し側の shell は終了コードだけを見る)。"""
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.work)], capture_output=True, text=True
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

        # 詰め物を ASCII に差し替えた版を組み、非 0 で落ちることを見る
        broken = self.work / "broken.py"
        broken.write_text(
            SCRIPT.read_text(encoding="utf-8").replace(
                'FILLER = "この行は日本語のコメントヘッダを模した検査用の詰め物である。".encode("utf-8")',
                'FILLER = b"x" * 30',
            ),
            encoding="utf-8",
        )
        proc = subprocess.run(
            [sys.executable, str(broken), str(self.work)], capture_output=True, text=True
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("文字を割っていない", proc.stderr)



class CheckScriptTest(unittest.TestCase):
    """`check-reuse-encoding.sh` を `/bin/bash` で起こす (#2612)。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        # PATH は代役と python3 と OS の道具だけにする (本物の reuse を拾わない)
        self.tools = Path(self.tmp.name) / "tools"
        self.tools.mkdir()
        (self.tools / "python3").symlink_to(sys.executable)
        self.stubs = Path(self.tmp.name) / "stubs"
        self.stubs.mkdir()

    def put_reuse(self):
        reuse = self.stubs / "reuse"
        reuse.write_text(FAKE_REUSE)
        reuse.chmod(0o755)

    def run_check(self, **env):
        return subprocess.run(
            ["/bin/bash", str(CHECK)],
            env={**os.environ, "PATH": f"{self.stubs}:{self.tools}:/usr/bin:/bin", **env},
            cwd=REPO, capture_output=True, text=True, timeout=60,
        )

    def test_読めていれば緑(self):
        self.put_reuse()
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("ok: 2048 バイト境界", r.stdout)

    def test_読み落とせば赤で原因の判定モジュールを名乗る(self):
        self.put_reuse()
        r = self.run_check(FAKE_REUSE_LINT_RC="1")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("#48 の再発", r.stderr)
        self.assertIn("charset_normalizer", r.stderr)
        self.assertIn("fake lint output", r.stderr)
        self.assertIn("make setup", r.stderr)

    def test_reuse_が起動しなければ赤で入れ直しを案内する(self):
        self.put_reuse()
        r = self.run_check(FAKE_REUSE_VERSION_RC="1")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("reuse が起動できない", r.stderr)
        self.assertIn("make setup", r.stderr)

    def test_reuse_が無ければ赤(self):
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("reuse が見つからない", r.stderr)


if __name__ == "__main__":
    unittest.main()
