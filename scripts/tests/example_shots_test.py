#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/example-shots.py の検査 (#480)。

固定するのは 3 つで、どれも破れ方が無言である。

- **囲みの外を壊さない** — 撮り直しが人の書いた説明を消したら、消えたことに
  気付けるのは公開された面を読んだときになる
- **書き戻しがべき等** — 初回・撮り直し・中断後の再実行が同じ結果になること。
  ここが崩れると、撮るたびに差分が出て「絵が変わった」と見分けが付かなくなる
- **例を書き換えたのに撮り直していない状態を赤くする** — 絵と例が食い違ったまま
  公開されるのが、この仕組みでいちばん困る壊れ方

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "example-shots.py"


def _load():
    spec = importlib.util.spec_from_file_location("example_shots", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    # dataclass は自分のモジュールを sys.modules から引くので、登録してから読む
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


shots = _load()

SOURCE = """\
// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Sketch {
    /// 円を塗る。
    ///
    /// ```swift
    /// circle(200, 150, 160)
    /// ```
    /// <!-- shot: 中央の橙色の円 -->
    /// <!-- /shot -->
    ///
    /// 直径を変えても中心は動かない。
    ///
    /// ```swift
    /// circle(200, 150, 80)
    /// ```
    /// <!-- shot: 中央の小さな円 -->
    /// <!-- /shot -->
    public func circle() {}
}
"""


class ExampleShotsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        (self.root / "Sources").mkdir()
        self.path = self.root / "Sources" / "Sketch.swift"
        self.path.write_text(SOURCE, encoding="utf-8")

    def collect(self):
        return shots.collect(self.root)

    def test_囲みと直前の例を拾う(self):
        found = self.collect()
        self.assertEqual(len(found), 2)
        self.assertEqual(found[0].alt, "中央の橙色の円")
        self.assertEqual(found[0].snippet, ["circle(200, 150, 160)"])
        self.assertEqual([shot.index for shot in found], [1, 2])
        self.assertEqual(found[0].width, 400)
        self.assertFalse(found[0].is_motion)

    def test_撮影設定を読む(self):
        self.path.write_text(
            SOURCE.replace("<!-- shot: 中央の橙色の円 -->", "<!-- shot: 動く円 | frames=30 size=200x200 -->"),
            encoding="utf-8",
        )
        found = self.collect()
        self.assertTrue(found[0].is_motion)
        self.assertEqual((found[0].width, found[0].height, found[0].frames), (200, 200, 30))

    def test_指紋はスニペットで変わり説明文では変わらない(self):
        before = self.collect()[0].fingerprint
        self.path.write_text(SOURCE.replace("直径を変えても中心は動かない。", "別の言い方。"), encoding="utf-8")
        self.assertEqual(self.collect()[0].fingerprint, before)
        self.path.write_text(SOURCE.replace("circle(200, 150, 160)", "circle(200, 150, 161)"), encoding="utf-8")
        self.assertNotEqual(self.collect()[0].fingerprint, before)

    def write_back(self, found=None):
        found = found or self.collect()
        urls = {shot.name: f"https://example.invalid/{shot.name}.png" for shot in found}
        return shots.write_back(self.root, found, urls, "abc1234")

    def test_書き戻しは囲みの中と記録だけを書く(self):
        self.write_back()
        text = self.path.read_text(encoding="utf-8")
        self.assertIn("/// ![中央の橙色の円](https://example.invalid/", text)
        self.assertIn("// shot: 1 snippet=", text)
        self.assertIn("// shot: 2 snippet=", text)
        # 囲みの外の文章は 1 文字も動かない
        self.assertIn("/// 直径を変えても中心は動かない。", text)
        self.assertIn("/// 円を塗る。", text)
        self.assertIn("    public func circle() {}", text)

    def test_書き戻しはべき等(self):
        self.write_back()
        once = self.path.read_text(encoding="utf-8")
        self.assertEqual(self.write_back(), 0, "2 回目は書き換えが起きないはず")
        self.assertEqual(self.path.read_text(encoding="utf-8"), once)

    def test_撮った後は検査が通る(self):
        self.write_back()
        self.assertEqual(shots.check(self.root, self.collect()), [])

    def test_例を書き換えたのに撮り直していなければ赤い(self):
        self.write_back()
        text = self.path.read_text(encoding="utf-8").replace("circle(200, 150, 160)", "circle(200, 150, 200)")
        self.path.write_text(text, encoding="utf-8")
        problems = shots.check(self.root, self.collect())
        self.assertTrue(any("撮り直していない" in problem for problem in problems), problems)

    def test_一文の説明が空なら赤い(self):
        self.path.write_text(SOURCE.replace("<!-- shot: 中央の橙色の円 -->", "<!-- shot: -->"), encoding="utf-8")
        problems = shots.check(self.root, self.collect())
        self.assertTrue(any("一文の説明が空" in problem for problem in problems), problems)

    def test_例の塊が無ければ赤い(self):
        self.path.write_text(
            SOURCE.replace("    /// ```swift\n    /// circle(200, 150, 160)\n    /// ```\n", ""),
            encoding="utf-8",
        )
        problems = shots.check(self.root, self.collect())
        self.assertTrue(any("```swift の塊が無い" in problem for problem in problems), problems)

    def test_囲みが閉じていなければ落ちる(self):
        self.path.write_text(SOURCE.replace("    /// <!-- /shot -->\n", "", 1), encoding="utf-8")
        with self.assertRaises(SystemExit):
            self.collect()

    def test_生成した実行ファイルは全部の例を持つ(self):
        found = self.collect()
        package = self.root / "generated"
        shots.generate(self.root, found, package)
        body = (package / "Sources" / "example-shots" / "Shots.swift").read_text(encoding="utf-8")
        for shot in found:
            self.assertIn(f"final class {shots._type_name(shot)}: Sketch {{", body)
            self.assertIn(shot.snippet[0], body)
        # **実行ファイルは 1 つ。** 1 例 1 ターゲットにするとビルドが現実的でなくなる
        self.assertEqual(
            (package / "Package.swift").read_text(encoding="utf-8").count(".executableTarget"), 1
        )

    def test_実物のソースの囲みが揃っている(self):
        result = subprocess.run(
            ["python3", str(SCRIPT)], cwd=REPO, capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
