#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-published-reference.py の検査 (#478)。

この検査が塞ぐのは「置いても出ない」— 変換は成功し、警告も出ず、出力にだけ
存在しない、という壊れ方である。だから固定するのは**出ていないものを赤くする**側と、
**検査自身が空回りしていたら赤くする**側の 2 つになる。

**逆向き** (#515) も同じ形で固定する — 面に出ているのに入口に並んでいない最上位は、
道具が既定の束へ自動で入れるので**面には出るし緑のまま**になる。

`--catalog` から期待を導くので、台帳を別に持たない。入口の書式が変わって記号を
1 つも読み取れなくなった状態は「全部出ている」と見分けが付かないため、そこも赤にする。

URL 版は実際に HTTP で引く経路を通す — 公開の後に走るのはそちらで、手元でしか
確かめていないと配信側の分岐が一度も動かないまま出ていくことになる。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import functools
import http.server
import json
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-published-reference.py"

LANDING = """\
# ``Mod``

<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

面の入口。

## Topics

### 束

- ``Foo``
- ``Bar``
- ``Foo/draw(_:_:)``
- ``Foo/fill(_:)-1a2b3``
"""

ARTICLE = "# 手引き\n\n本文。\n"


class PublishedReferenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.catalog = self.root / "mokume.docc"
        self.catalog.mkdir()
        (self.catalog / "Mod.md").write_text(LANDING, encoding="utf-8")
        (self.catalog / "guide.md").write_text(ARTICLE, encoding="utf-8")
        self.out = self.root / "out"
        self.build_output()

    def build_output(self, paths=None, title="Mod", bundle="mokume", html=True, middle="mod/"):
        """出来上がった面の最小の形。壊すときは引数で 1 か所だけ動かす。"""
        if paths is None:
            paths = [
                "/documentation/mod",
                "/documentation/mod/foo",
                "/documentation/mod/bar",
                "/documentation/mod/foo/draw(_:_:)",
                "/documentation/mod/foo/fill(_:)-1a2b3",
                "/documentation/mokume/guide",
            ]
        (self.out / "data" / "documentation" / "mod").mkdir(parents=True, exist_ok=True)
        (self.out / "index").mkdir(parents=True, exist_ok=True)
        (self.out / "metadata.json").write_text(
            json.dumps({"bundleDisplayName": bundle}), encoding="utf-8"
        )
        (self.out / "index" / "index.json").write_text(
            json.dumps(
                {
                    "interfaceLanguages": {
                        "swift": [{"path": p, "children": []} for p in paths]
                    }
                }
            ),
            encoding="utf-8",
        )
        (self.out / "data" / "documentation" / "mod.json").write_text(
            json.dumps({"metadata": {"title": title}}), encoding="utf-8"
        )
        if html:
            page = self.out / "documentation" / "mod"
            page.mkdir(parents=True, exist_ok=True)
            (page / "index.html").write_text("<!doctype html>", encoding="utf-8")
        # 手で被せる層のうち、中間の経路を塞ぐ 1 枚 (#549)。道具の出力ではないが、
        # `make reference` を通った時点では面の一部として置かれている
        (self.out / "documentation").mkdir(parents=True, exist_ok=True)
        stub = self.out / "documentation" / "index.html"
        if middle is None:
            stub.unlink(missing_ok=True)  # 組み直しなので、前に置いたものを消す
        else:
            stub.write_text(
                f'<meta http-equiv="refresh" content="0; url={middle}" />', encoding="utf-8"
            )

    def run_check(self, target=None):
        return subprocess.run(
            [
                "python3",
                str(SCRIPT),
                target or str(self.out),
                "--catalog",
                str(self.catalog),
            ],
            capture_output=True,
            text=True,
        )

    def test_全部出ていれば通る(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("入口に並べた記号: 4", result.stdout)

    def test_面に出ているのに入口に並んでいなければ赤い(self):
        # 逆向き (#515)。並べ忘れは道具が既定の束へ拾うので、**面には出るし緑になる**
        self.build_output(
            paths=[
                "/documentation/mod",
                "/documentation/mod/foo",
                "/documentation/mod/bar",
                "/documentation/mod/baz",
                "/documentation/mod/foo/draw(_:_:)",
                "/documentation/mod/foo/fill(_:)-1a2b3",
                "/documentation/mokume/guide",
            ]
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("入口に並んでいない最上位: baz", result.stderr)
        self.assertIn("REFERENCE_OMIT", result.stderr)

    def test_口_1_本は最上位として数えない(self):
        # `Foo/draw(_:_:)` は `Foo` のページの下に居るので、最上位の並べ漏れではない
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("面に出ている最上位: 2 (並べ漏れ 0)", result.stdout)

    def test_口_1_本の粒度でも期待に数える(self):
        # 索引が型の粒度だった頃は現れなかった形 (#582)。**拾えないと黙って期待から
        # 落ちる** — 並べたのに出ていなくても、誰も言わないまま緑になる
        self.build_output(
            paths=[
                "/documentation/mod",
                "/documentation/mod/foo",
                "/documentation/mod/bar",
                "/documentation/mod/foo/fill(_:)-1a2b3",
                "/documentation/mokume/guide",
            ]
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("``Foo/draw(_:_:)``", result.stderr)

    def test_入口に並べた記号が出ていなければ赤い(self):
        self.build_output(
            paths=["/documentation/mod", "/documentation/mod/foo", "/documentation/mokume/guide"]
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("``Bar``", result.stderr)

    def test_記事が出ていなければ赤い(self):
        self.build_output(
            paths=["/documentation/mod", "/documentation/mod/foo", "/documentation/mod/bar"]
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("guide.md", result.stderr)

    def test_静的配信の形になっていなければ赤い(self):
        (self.out / "documentation" / "mod" / "index.html").unlink()
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("静的配信", result.stderr)

    def test_中間の経路が塞がれていなければ赤い(self):
        # URL を後ろから削って上の階層へ行く読者が、そこで行き止まりになる (#549)
        self.build_output(middle=None)
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("行き止まり", result.stderr)

    def test_中間の経路の行き先が腐っていれば赤い(self):
        # モジュールの名前が変われば、手で書いた行き先は黙って取り残される
        self.build_output(middle="別のなにか/")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("指していない", result.stderr)

    def test_モジュールの面の題が違えば赤い(self):
        self.build_output(title="別物")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("題", result.stderr)

    def test_面が組み上がっていなければ赤い(self):
        (self.out / "metadata.json").unlink()
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("metadata.json", result.stderr)

    def test_入口から記号を読み取れなければ赤い(self):
        # 期待が 0 件のまま通ると、この検査は何も見ていない緑になる
        (self.catalog / "Mod.md").write_text("# ``Mod``\n\n面の入口。\n", encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("成立していない", result.stderr)

    def test_入口が_1_つに決まらなければ赤い(self):
        (self.catalog / "Other.md").write_text("# ``Other``\n\n別の入口。\n", encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("1 つに決まらない", result.stderr)

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

        (self.out / "documentation" / "mod" / "index.html").unlink()
        self.assertEqual(self.run_check(target=base).returncode, 1)


if __name__ == "__main__":
    unittest.main()
