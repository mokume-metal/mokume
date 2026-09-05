#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/site_source.py の検査 (#815)。

面を検める検査は 3 本あり、`pages.yml` と `publication.yml` から**必ず一緒に**呼ばれる。
以前はその 3 本 + `check-publication.py` が読み口・タイムアウト・`<img>` の綴りを
それぞれ写しで持っていた。畳んだので、ここで固定するのは 2 つ:

1. **読み口の契約** — ディレクトリでも URL でも同じ形で引け、無いものは `None`、
   引けなかったものは `Unreachable` で名乗る (握り潰すと「置いても出ない」が緑のまま
   通り、traceback にすると読める面と揃わない。向きは #865 で宣言した)
2. **写しが戻ってこないこと** — 検査のどれかがまた自前の綴りを持ったら赤くする

**新しい検査 (Makefile の的) は足さない。** `make hooks-test` が `-p '*_test.py'` で
discover するので、ここに 1 ファイル置けば CI にも載る (`bash_invocation_test.py` /
`surface_vocabulary_test.py` と同じ構え・ADR-0008 決定 5 段 1)。

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import functools
import gc
import http.server
import importlib.util
import re
import socket
import tempfile
import threading
import unittest
import warnings
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "scripts"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


site_source = _load("site_source", SCRIPTS / "site_source.py")

# 公開物を読む側。**この 4 本は同じ公開先を見る** ので、綴りが割れると
# 「手元では通るが公開先だけ落ちる」が起きる
READERS = (
    "check-entry.py",
    "check-published-reference.py",
    "check-external-assets.py",
    "check-publication.py",
)


class SourceTest(unittest.TestCase):
    """読み口の契約。ディレクトリと URL で同じ形になる。"""

    def test_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "a.txt").write_text("中身", encoding="utf-8")
            source = site_source.Source(tmp)
            self.assertFalse(source.is_url)
            self.assertEqual(source.read("a.txt"), "中身".encode())
            self.assertIsNone(source.read("無い.txt"))

    def test_directory_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "a.json").write_text('{"k": 1}', encoding="utf-8")
            source = site_source.Source(tmp)
            self.assertEqual(source.read_json("a.json"), {"k": 1})
            self.assertIsNone(source.read_json("無い.json"))

    def test_trailing_slash_does_not_change_the_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "a.txt").write_text("x", encoding="utf-8")
            self.assertEqual(site_source.Source(tmp + "/").read("a.txt"), b"x")

    def test_url(self):
        """**公開の後に走るのはこちらの経路である。**

        手元でしか確かめていないと、配信側の分岐が一度も動かないまま出ていく
        (`published_reference_test.py` が同じ理由で本物の HTTP を通している)。
        """
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "a.txt").write_text("中身", encoding="utf-8")
            handler = functools.partial(QuietHandler, directory=tmp)
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                source = site_source.Source(f"http://127.0.0.1:{server.server_port}")
                self.assertTrue(source.is_url)
                self.assertEqual(source.read("a.txt"), "中身".encode())
                # 無いものは None。**投げない** — 「置いても出ない」を呼び出し側が言う
                # (URL の側は ASCII の綴りで引く。相対パスの百分率符号化はしていない)
                self.assertIsNone(source.read("missing.txt"))
                # 404 以外は投げる。握り潰すと、配信の事故が緑のまま通る。
                # **符号まで見る** — 素の Exception で受けると、接続断でも緑になる
                # (最初にこの検査を書いたとき、まさにそれで空回りしていた)
                with self.assertRaises(site_source.Unreachable) as raised:
                    source.read("500")
                self.assertIn("500", str(raised.exception))
                # 502 も同じ向き。**日次の公開検査が踏むのはこちらである** (#865)
                with self.assertRaises(site_source.Unreachable) as raised:
                    source.read("502")
                self.assertIn("502", str(raised.exception))
                self.assertIn("が引けない", str(raised.exception))

                # **応答を閉じる。** 例外そのものが応答なので、閉じないと
                # ResourceWarning が残る (read_stamp が同じ理由で閉じている)
                with warnings.catch_warnings(record=True) as caught:
                    warnings.simplefilter("always")
                    self.assertIsNone(source.read("missing.txt"))
                    gc.collect()
                leaked = [w for w in caught if issubclass(w.category, ResourceWarning)]
                self.assertEqual(leaked, [], [str(w.message) for w in leaked])
            finally:
                server.shutdown()
                server.server_close()

    def test_引けない先は_Unreachable_で名乗る(self):
        """**traceback にしない。** 名前解決・接続断・証明書はどれもこの枝を通る (#865)。

        誰も listen していない口を狙う。`HTTPError` ではないので、`URLError` を
        受けていなければここで素の traceback が上がる。
        """
        # 空いている口を借りてすぐ閉じる。**閉じた後の番号を狙う**のが要点
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        source = site_source.Source(f"http://127.0.0.1:{port}")
        with self.assertRaises(site_source.Unreachable) as raised:
            source.read("a.txt")
        self.assertIn("が引けない", str(raised.exception))


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    """検査の出力を汚さないアクセスログ抑止つきのハンドラ。"""

    def log_message(self, *args):  # noqa: D102
        pass

    def do_GET(self):  # noqa: N802
        if self.path == "/502":
            self.send_error(502, "bad gateway on purpose")
            return
        if self.path == "/500":
            # 理由句は ASCII で書く。非 ASCII を渡すと send_error 自身が latin-1 の
            # 符号化で落ち、応答ではなく接続断になる
            self.send_error(500, "broken on purpose")
            return
        super().do_GET()


class HtmlImageTest(unittest.TestCase):
    """`<img src>` の綴り。**`data-src=` を本物と数えない**のが要点。"""

    def test_external_image_is_found(self):
        found = site_source.HTML_IMAGE.findall('<img alt="x" src="https://example.com/a.png">')
        self.assertEqual(found, ["https://example.com/a.png"])

    def test_data_src_is_not_an_image(self):
        self.assertEqual(site_source.HTML_IMAGE.findall('<img data-src="https://e.com/a.png">'), [])

    def test_relative_source_is_not_external(self):
        self.assertEqual(site_source.HTML_IMAGE.findall('<img src="/local/a.png">'), [])


class NoCopyTest(unittest.TestCase):
    """**写しが戻ってこないことを構造で見る。**

    畳む理由は 4 本が揃って持っている設計意図である — どれも「手元で組んだ `_site`
    にも、公開された URL にも同じ形で当てられる」ようにしてあり、片方だけ直すと
    その切り分けが崩れる。

    **一覧は数え上げない** — `scripts/check-*.py` を glob するので、5 本目の検査が
    自前の綴りを持ったらそこで赤くなる。
    """

    def checkers(self):
        found = sorted(SCRIPTS.glob("check-*.py"))
        # 対象が 0 件の緑は、通っていることに意味が無い
        self.assertTrue(found, f"検査対象の check-*.py が 1 つも無い ({SCRIPTS})")
        return found

    def offending(self, pattern, message):
        found = []
        for path in self.checkers():
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if re.search(pattern, line):
                    found.append(f"  {path.name}:{number}: {line.strip()}")
        if found:
            self.fail(message + "\n" + "\n".join(found))

    def test_no_checker_defines_its_own_timeout(self):
        self.offending(
            r"^FETCH_TIMEOUT_SECONDS\s*=",
            "自前のタイムアウトを持っている検査がある (site_source から import すること):",
        )

    def test_no_checker_defines_its_own_source(self):
        self.offending(
            r"^class Source\b",
            "自前の読み口を持っている検査がある (site_source から import すること):",
        )

    def test_no_checker_spells_the_image_pattern_itself(self):
        self.offending(
            r"<img\\s",
            "自前の <img> の綴りを持っている検査がある (site_source.HTML_IMAGE を使うこと):",
        )

    def test_every_reader_takes_it_from_the_shared_place(self):
        for name in READERS:
            with self.subTest(reader=name):
                text = (SCRIPTS / name).read_text(encoding="utf-8")
                self.assertIn(
                    "from site_source import",
                    text,
                    f"{name} が共有の置き場から取っていない",
                )

    def test_the_shared_place_is_not_empty(self):
        """畳んだ先が空になっていない (この検査自身が空回りしていたら赤くする)。"""
        text = (SCRIPTS / "site_source.py").read_text(encoding="utf-8")
        self.assertIn("FETCH_TIMEOUT_SECONDS", text)
        self.assertIn("class Source", text)
        self.assertIn("<img", text)
        # 向きの宣言 (#865)。畳んだ先から消えたら、読み手はまた自分で決め始める
        self.assertIn("class Unreachable", text)


if __name__ == "__main__":
    unittest.main()
