#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-entry.py の検査 (#482)。

この検査が塞ぐのは、**壊れても両方の面が 200 を返し続ける**壊れ方である。

- 入口から面へ出て行くリンクが切れる → 手で書いた層も面も生きているのに入れない
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
import socket
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

書ける口の説明は**参照の面**にある: <https://mokume.org/documentation/mokumecore/>
"""

# 面が名乗る名前の出どころ。**カタログの入口の記号見出しが正本**で、判定はここから導く
# (site_source.landing_of。check-published-reference.py と同じ 1 本を読む)
LANDING = """\
# ``mokumecore``

面の入口。
"""

# 属性を改行で分けて書く。**この形で拾えること**が要件で、1 行に畳んだ作り物で
# 通しても、実物 (Documentation/site/index.html) は同じ書き方をしている
ENTRY = """\
<!doctype html>
<html lang="ja">
  <body>
    <img
      src="https://i.gyazo.com/aaaa.png"
      alt="絵" />
    <pre><code>brew install mokume-metal/tap/mokume</code></pre>
    <a href="documentation/mokumecore/">参照の面</a>
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
        self.catalog = self.root / "mokume.docc"
        self.catalog.mkdir()
        (self.catalog / "Landing.md").write_text(LANDING, encoding="utf-8")
        self.out = self.root / "out"
        self.out.mkdir()
        self.write(ENTRY)

    def write(self, page):
        (self.out / "index.html").write_text(page, encoding="utf-8")

    def run_check(self, target=None):
        return subprocess.run(
            [
                "python3", str(SCRIPT), target or str(self.out),
                "--readme", str(self.readme),
                "--catalog", str(self.catalog),
            ],
            capture_output=True,
            text=True,
        )

    # --- 通る側 -----------------------------------------------------------

    def test_揃っていれば通る(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_行き先を先頭のドット付きで書いても通る(self):
        self.write(ENTRY.replace('href="documentation/', 'href="./documentation/'))
        self.assertEqual(self.run_check().returncode, 0)

    # --- 行き先の名前 (#568 で責務の線を引き直した) ----------------------
    #
    # **当初ここは「モジュール名までは見ない」を固定していた** — 面の内側を見るのは
    # check-published-reference.py の責務で、重ねると同じことを 2 か所で見ることに
    # なるからである。だが結果として入口と README の手書きリンクが誰の担当でもなく
    # なり、名前が変われば 404 になるのに CI は緑のままだった。線は引き直した:
    # あちらが見るのは**面の出力**、こちらが見るのは**手で書いた層と README** で、
    # 名前の導出は site_source の 1 本を両者が読む

    def test_入口の行き先が面の名前と違えば赤い(self):
        self.write(ENTRY.replace("documentation/mokumecore/", "documentation/nonexistent/"))
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("nonexistent", result.stderr)

    def test_入口の行き先に名前が無ければ赤い(self):
        # 面の入口で止めた行き先は、面の中のどこにも着かない
        self.write(ENTRY.replace("documentation/mokumecore/", "documentation/"))
        self.assertEqual(self.run_check().returncode, 1)

    def test_README_の面の_URL_が面の名前と違えば赤い(self):
        # **面の出力を読むだけの道具では届かない場所である。** README は面の出力に無い
        self.readme.write_text(
            README.replace("/documentation/mokumecore/", "/documentation/nonexistent/"),
            encoding="utf-8",
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("README", result.stderr)

    def test_README_に面の_URL_が無ければ赤い(self):
        self.readme.write_text(
            README.replace(
                "書ける口の説明は**参照の面**にある: <https://mokume.org/documentation/mokumecore/>",
                "",
            ),
            encoding="utf-8",
        )
        self.assertEqual(self.run_check().returncode, 1)

    # --- 行き来が切れる ---------------------------------------------------

    def test_面へのリンクが無ければ赤い(self):
        self.write(ENTRY.replace('<a href="documentation/mokumecore/">参照の面</a>', ""))
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("面へ入れない", result.stderr)

    def test_絶対_URL_で面を指していたら赤い(self):
        # 基準パスは公開先で変わる。絶対で書くと github.io と独自ドメインの
        # 片方でしか繋がらない
        self.write(
            ENTRY.replace(
                'href="documentation/mokumecore/"',
                'href="https://mokume.org/documentation/mokumecore/"',
            )
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

        self.write(ENTRY.replace('<a href="documentation/mokumecore/">参照の面</a>', ""))
        self.assertEqual(self.run_check(target=base).returncode, 1)


    def test_引けない先は_traceback_ではなく_1_行で名乗る(self):
        """**「出ていない」と「読めなかった」を混ぜない** (#865)。

        誰も listen していない口を狙う。かつては Python の traceback が出ていて、
        問題を 1 行ずつ並べる他の出力と揃っていなかった。
        """
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        result = self.run_check(target=f"http://127.0.0.1:{port}")
        self.assertEqual(result.returncode, 1)
        self.assertIn("が引けない", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
