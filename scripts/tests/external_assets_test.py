#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-external-assets.py の検査 (#483)。

固定するのは 3 つで、どれが抜けても検査は「何も見ていない緑」か「直しようのない赤」に
倒れる。

- **資産だけを拾う** — 説明文 (`///`) と Markdown の本文に書かれた画像・動きの指し先。
  素のリンクも、コード塊の中の書き方の例示も、検査の資材に書かれた例の URL も資産ではない
- **0 件は赤** — 書式が変わって拾えなくなった状態は、全部生きているのと同じ緑で表れる
- **出所を添えて名指しする** — 24 本ある指し先のどれを撮り直すのかが出力だけで分かる

実行は make hooks-test (CI もこれを呼ぶ)。**引く部分はここでは動かさない** — 単体の
検査がネットワークに依存すると、相手の不調でこちらが赤くなる。実際に引くのは
.github/workflows/publication.yml の定期実行である。
"""

import importlib.util
import subprocess
import tempfile
import unittest
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
        reason = assets.probe("https://mokume-does-not-exist.invalid/a.png")
        self.assertIsNotNone(reason)


if __name__ == "__main__":
    unittest.main()
