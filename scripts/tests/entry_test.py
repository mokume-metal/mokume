#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-entry.py の検査 (#482)。

この検査が塞ぐのは、**壊れても両方の面が 200 を返し続ける**壊れ方である。

- 入口から参照の面へのリンクが切れる → 面は 2 つとも生きているのに行き来できない
- 入口と README で入れ方の 1 行が食い違う → どちらも読めるが、片方が嘘になる

どちらも「見れば分かる」形では現れないので、固定するのは**赤くなる側**である。
併せて、検査自身が空回りしていたら赤くする側 (絵を 1 枚も拾えない = 書式が変わった)
も固定する — 0 件を緑にすると、絵が全部消えた状態と見分けが付かない。

URL 版は実際に HTTP で引く経路を通す。公開の後に走るのはそちらなので、手元でしか
確かめていないと配信側の分岐が一度も動かないまま出ていくことになる。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import functools
import http.server
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-entry.py"

README = """\
# mokume

## 入れる

```bash
brew install mokume-metal/tap/mokume
```
"""

# 属性を改行で分けて書く。**この形で拾えること**が要件で、1 行に畳んだ作り物で
# 通しても、実物 (Documentation/index.html) は同じ書き方をしている
ENTRY = """\
<!doctype html>
<html lang="ja">
  <body>
    <img
      src="https://i.gyazo.com/aaaa.png"
      alt="絵" />
    <pre><code>brew install mokume-metal/tap/mokume</code></pre>
    <a href="reference/">参照の面</a>
  </body>
</html>
"""


class EntryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

        self.readme = self.root / "README.md"
        self.readme.write_text(README, encoding="utf-8")
        self.out = self.root / "out"
        self.out.mkdir()
        self.write(ENTRY)

    def write(self, page):
        (self.out / "index.html").write_text(page, encoding="utf-8")

    def run_check(self, target=None):
        return subprocess.run(
            ["python3", str(SCRIPT), target or str(self.out), "--readme", str(self.readme)],
            capture_output=True,
            text=True,
        )

    # --- 通る側 -----------------------------------------------------------

    def test_揃っていれば通る(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_行き先を__reference__と書いても通る(self):
        self.write(ENTRY.replace('href="reference/"', 'href="./reference/"'))
        self.assertEqual(self.run_check().returncode, 0)

    # --- 行き来が切れる ---------------------------------------------------

    def test_参照の面へのリンクが無ければ赤い(self):
        self.write(ENTRY.replace('<a href="reference/">参照の面</a>', ""))
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("行き来", result.stderr)

    def test_絶対_URL_で参照の面を指していたら赤い(self):
        # 基準パスは公開先で変わる。絶対で書くと github.io と独自ドメインの
        # 片方でしか繋がらない
        self.write(
            ENTRY.replace('href="reference/"', 'href="https://mokume.org/reference/"')
        )
        self.assertEqual(self.run_check().returncode, 1)

    # --- 入れ方の 1 行 ----------------------------------------------------

    def test_入れ方の_1_行が_README_と食い違えば赤い(self):
        self.readme.write_text(
            README.replace("mokume-metal/tap/mokume", "mokume-metal/tap/mokume@2"),
            encoding="utf-8",
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("食い違う", result.stderr)

    def test_入れ方の_1_行が入口に無ければ赤い(self):
        self.write(ENTRY.replace("brew install mokume-metal/tap/mokume", "入れ方は README で"))
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("brew install", result.stderr)

    def test_README_に入れ方の_1_行が無ければ赤い(self):
        self.readme.write_text("# mokume\n", encoding="utf-8")
        self.assertEqual(self.run_check().returncode, 1)

    def test_README_が無ければ赤い(self):
        self.readme.unlink()
        self.assertEqual(self.run_check().returncode, 1)

    # --- 検査の空回り -----------------------------------------------------

    def test_絵が_1_枚も無ければ赤い(self):
        self.write(ENTRY.replace("src=", "data-src="))
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("絵が 1 枚も無い", result.stderr)

    def test_入口そのものが無ければ赤い(self):
        (self.out / "index.html").unlink()
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("入口が無い", result.stderr)

    # --- 自分だけで成立すること -------------------------------------------

    def test_外部ホストの_script_があれば赤い(self):
        self.write(ENTRY.replace("<body>", '<body><script src="https://example.invalid/a.js">'))
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("script", result.stderr)

    def test_外部ホストの_stylesheet_があれば赤い(self):
        self.write(
            ENTRY.replace(
                "<body>",
                '<body><link rel="stylesheet" href="https://example.invalid/a.css" />',
            )
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("stylesheet", result.stderr)

    # --- URL 面 -----------------------------------------------------------

    def test_URL_でも同じ判定になる(self):
        class Quiet(http.server.SimpleHTTPRequestHandler):
            # 要求のログは捨てる。既定では stderr へ出て、検査の出力に混ざる
            def log_message(self, *args):
                pass

        handler = functools.partial(Quiet, directory=str(self.out))
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        base = f"http://127.0.0.1:{server.server_address[1]}"
        self.assertEqual(self.run_check(target=base).returncode, 0)

        self.write(ENTRY.replace('<a href="reference/">参照の面</a>', ""))
        self.assertEqual(self.run_check(target=base).returncode, 1)


if __name__ == "__main__":
    unittest.main()
