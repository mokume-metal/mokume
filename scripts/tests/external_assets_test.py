#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-external-assets.py の検査 (#483)。

固定するのは 4 つで、どれが抜けても検査は「何も見ていない緑」か「直しようのない赤」に
倒れる。

- **資産だけを拾う** — 説明文 (`///`) と Markdown の本文に書かれた画像・動きの指し先。
  素のリンクも、コード塊の中の書き方の例示も、検査の資材に書かれた例の URL も資産ではない
- **0 件は赤** — 書式が変わって拾えなくなった状態は、全部生きているのと同じ緑で表れる
- **出所を添えて名指しする** — 24 本ある指し先のどれを撮り直すのかが出力だけで分かる
- **一時的な失敗を消失と数えない** (#1676) — 5xx・429・接続の失敗は 1 度だけ待って引き直し、
  それでも応えないものは「消えた」ではなく「応えない」と名乗る。撮り直しを求める赤が、
  生きている絵に向かないようにする

実行は make hooks-test (CI もこれを呼ぶ)。**引く部分はここでは動かさない** — 単体の
検査がネットワークに依存すると、相手の不調でこちらが赤くなる。実際に引くのは
.github/workflows/publication.yml の定期実行である。
"""

import importlib.util
import subprocess
import contextlib
import io
import ssl
import tempfile
import unittest
import urllib.error
from unittest import mock
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-external-assets.py"

_spec = importlib.util.spec_from_file_location("check_external_assets", SCRIPT)
assets = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(assets)

SWIFT = '''\
/// 図形を描く。
///
///     ![橙色の長方形](https://i.example.test/rect.png)
///
/// - Parameter x: 左上。
public func rect(x: Double) {
    // 説明文ではない行の URL は資産ではない: https://i.example.test/comment.png
    let banner = "![罠](https://i.example.test/string.png)"
}
'''

MARKDOWN = """\
# 面の入口

![動きの見本](https://i.example.test/motion.gif)

@Image(source: "https://i.example.test/docc.png", alt: "説明")

素のリンクは資産ではない: [手引き](https://example.test/guide)

書き方の例示も資産ではない:

```markdown
![説明](https://i.example.test/fence.png)
```
"""


class ExtractTest(unittest.TestCase):
    def urls(self, name, text):
        return [reference.url for reference in assets.references_in(text, name)]

    def test_説明文の画像を拾う(self):
        found = self.urls("Sketch.swift", SWIFT)
        self.assertEqual(found, ["https://i.example.test/rect.png"])

    def test_説明文でない行は拾わない(self):
        found = self.urls("Sketch.swift", SWIFT)
        self.assertNotIn("https://i.example.test/comment.png", found)
        self.assertNotIn("https://i.example.test/string.png", found)

    def test_Markdown_の画像と_docc_の指定を拾う(self):
        found = self.urls("guide.md", MARKDOWN)
        self.assertIn("https://i.example.test/motion.gif", found)
        self.assertIn("https://i.example.test/docc.png", found)

    def test_素のリンクとコード塊は拾わない(self):
        found = self.urls("guide.md", MARKDOWN)
        self.assertNotIn("https://example.test/guide", found)
        self.assertNotIn("https://i.example.test/fence.png", found)

    def test_出所は行番号まで返す(self):
        found = assets.references_in(SWIFT, "Sketch.swift")
        self.assertEqual(found[0].origin, "Sketch.swift:3")


class CommandTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        # 使い捨てのリポジトリは手元の署名設定を継ぐ。継がせない (#344)
        subprocess.run(
            ["git", "config", "commit.gpgsign", "false"], cwd=self.root, check=True
        )

    def add(self, name, text):
        path = self.root / name
        path.write_text(text, encoding="utf-8")
        subprocess.run(["git", "add", name], cwd=self.root, check=True)

    def run_script(self, *arguments):
        return subprocess.run(
            ["python3", str(SCRIPT), "--root", str(self.root), *arguments],
            capture_output=True,
            text=True,
        )

    def test_指し先が_1_つも無ければ赤(self):
        self.add("guide.md", "# 絵の無い文書\n")
        result = self.run_script("--list")
        self.assertEqual(result.returncode, 1)
        self.assertIn("検査が成立していない", result.stderr)

    def test_見つけた指し先を出所つきで並べる(self):
        self.add("Sketch.swift", SWIFT)
        result = self.run_script("--list")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("https://i.example.test/rect.png", result.stdout)
        self.assertIn("Sketch.swift:3", result.stdout)

    def test_追跡していないファイルは見ない(self):
        self.add("Sketch.swift", SWIFT)
        (self.root / "untracked.md").write_text(
            "![追跡外](https://i.example.test/untracked.png)\n", encoding="utf-8"
        )
        result = self.run_script("--list")
        self.assertNotIn("untracked.png", result.stdout)


class ProbeTest(unittest.TestCase):
    """引けなかった理由の作り方。**外へは出さない** — 解決しない名前で分岐だけ通す。"""

    def test_引けなければ理由が返る(self):
        failure = assets.probe("https://mokume-does-not-exist.invalid/a.png")
        self.assertIsNotNone(failure)
        self.assertTrue(failure.transient)


def http_error(url, code, headers=None):
    return urllib.error.HTTPError(url, code, "status", headers or {}, None)


class RetryTest(unittest.TestCase):
    """一時的な失敗を消失と数えない (#1676)。

    赤は「指し先が消えた」を意味し、日次の実行ではそのまま撮り直しを求める起票になる。
    生きている指し先が続けて引いたときだけ 503 を返した実測があるので、一時的でありうる
    失敗は 1 度だけ待って引き直す。**引く部分は差し替える** (冒頭のとおり外へは出さない)。
    """

    def run_probe(self, answers):
        """URL ごとに応答の列を渡して probe_all を回す。

        列の要素は None (引けた) か、送出する例外。呼ばれた回数と待った回数も返す。
        """
        calls = {url: 0 for url in answers}

        def fake_urlopen(request, timeout):
            url = request.full_url
            # 数えてから引く。用意した列を越えて呼ばれたときの例外は probe が理由として
            # 握るので、先に数えておかないと「余計に引いた」が回数に表れない
            calls[url] += 1
            script = answers[url]
            answer = script[calls[url] - 1] if calls[url] <= len(script) else None
            if answer is not None:
                raise answer
            return mock.MagicMock()

        self.sleep = mock.Mock()
        with mock.patch.object(assets.urllib.request, "urlopen", fake_urlopen):
            self.failures = assets.probe_all(sorted(answers), sleep=self.sleep)
        dead = {url: failure.reason for url, failure in self.failures.items()}
        return dead, calls, self.sleep.call_count

    def test_一時的な_503_は引き直して通れば緑(self):
        url = "https://i.example.test/a.png"
        dead, calls, waits = self.run_probe({url: [http_error(url, 503), None]})
        self.assertEqual(dead, {})
        self.assertEqual(calls[url], 2)
        self.assertEqual(waits, 1)

    def test_接続の失敗も引き直す(self):
        url = "https://i.example.test/a.png"
        # 本物の接続失敗は、URLError が OSError を reason に包んで来る
        for cause in (TimeoutError("timed out"), ConnectionRefusedError(61, "refused")):
            with self.subTest(cause=type(cause).__name__):
                dead, _calls, _waits = self.run_probe(
                    {url: [urllib.error.URLError(cause), None]}
                )
                self.assertEqual(dead, {})

    def test_包まれずに来た待ち切れも引き直す(self):
        # 応答の途中で待ち切れると URLError に包まれず TimeoutError のまま来る
        url = "https://i.example.test/a.png"
        dead, _calls, _waits = self.run_probe({url: [TimeoutError("timed out"), None]})
        self.assertEqual(dead, {})

    def test_429_は待てば通りうるので引き直す(self):
        url = "https://i.example.test/a.png"
        dead, _calls, _waits = self.run_probe({url: [http_error(url, 429), None]})
        self.assertEqual(dead, {})

    def test_404_は引き直さずに赤(self):
        url = "https://i.example.test/a.png"
        dead, calls, waits = self.run_probe({url: [http_error(url, 404)]})
        self.assertEqual(dead, {url: "HTTP 404"})
        self.assertEqual(calls[url], 1)
        self.assertEqual(waits, 0)

    def test_503_が続けば赤(self):
        url = "https://i.example.test/a.png"
        dead, calls, _waits = self.run_probe(
            {url: [http_error(url, 503), http_error(url, 503)]}
        )
        self.assertEqual(dead, {url: "HTTP 503"})
        self.assertEqual(calls[url], 2)

    def test_待つのは本数によらず全体で_1_回(self):
        urls = [f"https://i.example.test/{name}.png" for name in "abc"]
        dead, _calls, waits = self.run_probe(
            {url: [http_error(url, 502), None] for url in urls}
        )
        self.assertEqual(dead, {})
        self.assertEqual(waits, 1)

    def test_Retry_After_があればその秒数だけ待つ(self):
        url = "https://i.example.test/a.png"
        self.run_probe({url: [http_error(url, 429, {"Retry-After": "30"}), None]})
        self.sleep.assert_called_once_with(30.0)

    def test_Retry_After_は上限で切る(self):
        url = "https://i.example.test/a.png"
        self.run_probe({url: [http_error(url, 503, {"Retry-After": "3600"}), None]})
        self.sleep.assert_called_once_with(assets.RETRY_WAIT_LIMIT_SECONDS)

    def test_読めない_Retry_After_は既定の待ちに任せる(self):
        url = "https://i.example.test/a.png"
        self.run_probe(
            {url: [http_error(url, 503, {"Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"}), None]}
        )
        self.sleep.assert_called_once_with(assets.RETRY_WAIT_SECONDS)

    def test_証明書の失敗は引き直さない(self):
        url = "https://i.example.test/a.png"
        error = urllib.error.URLError(ssl.SSLCertVerificationError("certificate verify failed"))
        dead, calls, waits = self.run_probe({url: [error]})
        self.assertIn(url, dead)
        self.assertEqual((calls[url], waits), (1, 0))

    def test_URL_の書き方の誤りは引き直さない(self):
        url = "https://i.example.test/a.png"
        dead, calls, waits = self.run_probe({url: [urllib.error.URLError("unknown url type")]})
        self.assertIn(url, dead)
        self.assertEqual((calls[url], waits), (1, 0))

    def test_引き直しても応えないものは応えないと印が立つ(self):
        gone = "https://i.example.test/gone.png"
        down = "https://i.example.test/down.png"
        self.run_probe(
            {gone: [http_error(gone, 404)], down: [http_error(down, 503), http_error(down, 503)]}
        )
        self.assertFalse(self.failures[gone].transient)
        self.assertTrue(self.failures[down].transient)

    def test_引けたものは引き直さない(self):
        ok = "https://i.example.test/ok.png"
        flaky = "https://i.example.test/flaky.png"
        _dead, calls, _waits = self.run_probe(
            {ok: [None], flaky: [http_error(flaky, 503), None]}
        )
        self.assertEqual(calls[ok], 1)


class MainWiringTest(unittest.TestCase):
    """引いた結果の「応えない」が報せまで届くこと (#1676)。引く部分と集める部分は差し替える。"""

    def test_応えない印は報せまで届く(self):
        url = "https://i.example.test/a.png"
        stderr = io.StringIO()
        with mock.patch.object(
            assets, "collect", return_value=[assets.Reference(url, "A.swift", 1)]
        ), mock.patch.object(
            assets, "probe_all", return_value={url: assets.Failure("HTTP 503", True)}
        ), mock.patch.object(
            assets.sys, "argv", ["check-external-assets.py"]
        ), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            status = assets.main()
        self.assertEqual(status, 1)
        self.assertIn(f"{url} — HTTP 503 (引き直しても応えない)", stderr.getvalue())


class ReportTest(unittest.TestCase):
    """引けなかったときの報せ方 (#1333)。

    **ホストごとの内訳を、1 本ずつの一覧より先に出す。** 起票は検査の出力を先頭 200 行で
    切るので (`scripts/report-check-failure.sh`)、後ろに置いた要約は Issue の本文に載らない
    — 「1 本か、全部か」は起票の「対処」が最初に問うことである。ここは**引かずに**組み立て
    だけを見る (このファイルの冒頭のとおり、単体の検査は外へ出さない)。
    """

    ORIGINS = {
        "https://i.example.test/a.png": ["A.swift:1"],
        "https://i.example.test/b.png": ["A.swift:2"],
        "https://cdn.example.test/c.png": ["B.md:3"],
        "https://cdn.example.test/d.png": ["B.md:4"],
    }

    def report(self, *dead, unanswered=frozenset()):
        return "\n".join(
            assets.dead_report(
                self.ORIGINS,
                [(url, "HTTP 404", self.ORIGINS[url]) for url in dead],
                frozenset(unanswered),
            )
        )

    def test_応えないものは消えたと名乗らず流し直しを勧める(self):
        url = "https://cdn.example.test/c.png"
        text = self.report(url, unanswered={url})
        self.assertIn(f"{url} — HTTP 404 (引き直しても応えない)", text)
        self.assertIn("消えたのではなく", text)
        self.assertIn("撮り直す前に、時間を置いて検査をもう一度流す", text)

    def test_応えないものの断りは_1_本ずつの一覧より先に来る(self):
        url = "https://cdn.example.test/c.png"
        text = self.report(url, unanswered={url})
        self.assertLess(text.index("消えたのではなく"), text.index("B.md:3"))

    def test_消えただけなら応えない断りは付かない(self):
        text = self.report("https://cdn.example.test/c.png")
        self.assertNotIn("応えない", text)

    def test_全滅したホストは全滅と名乗る(self):
        text = self.report("https://i.example.test/a.png", "https://i.example.test/b.png")
        self.assertIn("i.example.test: 指し先 2 本のうち 2 本 — 全滅", text)

    def test_一部だけ引けないホストは全滅と名乗らない(self):
        text = self.report("https://cdn.example.test/c.png")
        self.assertIn("cdn.example.test: 指し先 2 本のうち 1 本", text)
        self.assertNotIn("全滅", text)

    def test_全滅があれば撮り直す前に確かめよと言う(self):
        text = self.report("https://i.example.test/a.png", "https://i.example.test/b.png")
        self.assertIn("撮り直す前に", text)
        self.assertIn("#1331", text)

    def test_全滅が無ければその断りは付かない(self):
        self.assertNotIn("撮り直す前に", self.report("https://cdn.example.test/c.png"))

    def test_内訳は_1_本ずつの一覧より先に来る(self):
        text = self.report("https://i.example.test/a.png", "https://i.example.test/b.png")
        self.assertLess(text.index("i.example.test: 指し先"), text.index("A.swift:1"))

    def test_出所は_1_本ずつの一覧に残る(self):
        text = self.report("https://i.example.test/a.png")
        self.assertIn("https://i.example.test/a.png — HTTP 404", text)
        self.assertIn("A.swift:1", text)


if __name__ == "__main__":
    unittest.main()
