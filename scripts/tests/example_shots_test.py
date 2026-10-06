#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/example-shots.py の検査 (#480 / #481)。

固定するのは 4 つで、どれも破れ方が無言である。

- **囲みの外を壊さない** — 撮り直しが人の書いた説明を消したら、消えたことに
  気付けるのは公開された面を読んだときになる
- **書き戻しがべき等** — 初回・撮り直し・中断後の再実行が同じ結果になること。
  ここが崩れると、撮るたびに差分が出て「絵が変わった」と見分けが付かなくなる
- **例を書き換えたのに撮り直していない状態を赤くする** — 絵と例が食い違ったまま
  公開されるのが、この仕組みでいちばん困る壊れ方
- **反転しても見分けが付かない絵の言い方** (#481) — 境目の当て方と、黙らせた軸の
  扱いをここで固定する。**絵を撮らずに検められる**ように、判定は純関数へ切ってある
- **包み方が、組めることを見る側と同じである** (#667) — 段を見分けること・`文脈` を
  渡すこと・型の段を落とすこと。ここが食い違うと、組める例が撮れない (あるいはその逆)
  という無言の穴が空く
- **台帳が撮った版を持たない** (#671) — 持っていた頃は撮るたびに全数の行が動き、絵を
  数枚足す PR が台帳 163 行を巻き込んでいた。古い形を読めることと、それを名乗って
  落とすこともここで固定する
- **撮るのに要る道具が無ければ、組む前に名乗って止まる** (#1598) — 止まり方が
  「全部を撮り終えた後の traceback」だと、何が足りないかも入れ方も出ない。見るだけの
  既定の実行が道具を探さないことも、ここで固定する

- **公開メンバが例か宣言を持つ** (#2116) — 例も撮れない宣言も無く許容一覧にも無い口を
  ファイルと行つきで名指しして赤にすること・許容一覧の口に例か宣言が付いたら赤にすること
  (一覧が増える方向に動けない)・拾えた口が 0 なら赤にすること。**どれも壊れ方が無言**で、
  緩むと例の無い口が黙って増える。「後で撮る」の印 (鍵を持たない人用) の扱いもここで固定する

- **前後の木の描き比べ** (#1986) — 画素の数え方・両方の木に在る絵だけを比べること・
  名指しの形・警告だけで止めないこと。**実装だけが変わって絵が古くなっても機械が何も
  言わない**のが、これを足した理由で、ここが緩むと無言に戻る

- **動く絵が動いているか** (#2117) — 全フレームが同じ絵の動きを名指しして、上げる前に
  止めること・止まる区間が一部なら通すこと・下限の当て方・`still=<理由>` で黙らせること。
  **止まった GIF は見比べても気付けない**のが足した理由で、緩むと止まった絵が黙って上がる

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import contextlib
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

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


# `setup()` を持つ例。絵を作る口はどれも投げるので、この段が撮れないと画像の口には
# 1 枚も絵が付けられない (#667)
MEMBER_SOURCE = """\
// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Sketch {
    /// 描き場所を作る。
    ///
    /// <!-- example: 文脈 var pad: Canvas! -->
    /// ```swift
    /// func setup() {
    ///     pad = try! createGraphics(64, 64)
    /// }
    ///
    /// func draw() {
    ///     image(pad, 0, 0)
    /// }
    /// ```
    /// <!-- shot: 左上に置かれた描き場所 -->
    /// <!-- /shot -->
    public func createGraphics() {}
}
"""

# 型の宣言から始まる例。`enum` に包まれて Sketch にならないので撮れない
TYPE_SOURCE = """\
// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Sketch {
    /// 設定を持つ。
    ///
    /// ```swift
    /// struct Knob {
    ///     var size: Float
    /// }
    /// ```
    /// <!-- shot: 撮れないはずの例 -->
    /// <!-- /shot -->
    public func knob() {}
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

    def check(self):
        """検査を走らせる。**印字は伏せる** (#1098)。

        `check()` は問題の一覧を返すついでに `例の絵: N 本` を印字するので、伏せずに
        呼ぶと雛形の 2 本が make ci-check のログへ出る — 本物 (169 本) と行の形が同じで
        見分けが付かない。出力そのものを検める側は self.check_output を読む。
        """
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            problems = shots.check(self.collect())
        self.check_output = out.getvalue()
        return problems

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
        return shots.write_back(self.root, found, urls)

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

    def test_台帳の行は撮った版を持たない(self):
        """#671。`taken=` を書いていた頃は、撮るたびに全数の行が動いていた。"""
        self.write_back()
        records = [
            line.strip()
            for line in self.path.read_text(encoding="utf-8").split("\n")
            if line.strip().startswith("// shot:")
        ]
        self.assertEqual(len(records), 2, records)
        for record in records:
            self.assertNotIn("taken=", record, record)
            self.assertRegex(record, r"^// shot: \d+ snippet=[0-9a-f]{8}$")

    def test_見ていないことを出力が名乗る(self):
        """#671。数を出せないなら、境目を 1 行で言う。"""
        self.write_back()
        self.check()
        text = self.check_output
        self.assertIn("実装が変わって絵が古くなっているかは、ここでは見ていない", text)
        self.assertIn("render-pr が前後の描画で名指しする", text)
        self.assertNotIn("撮影後に実装が動いている", text)
        self.assertNotIn("撮った版を辿れなかった", text)

    def test_書き戻しはべき等(self):
        self.write_back()
        once = self.path.read_text(encoding="utf-8")
        self.assertEqual(self.write_back(), 0, "2 回目は書き換えが起きないはず")
        self.assertEqual(self.path.read_text(encoding="utf-8"), once)

    def test_撮った後は検査が通る(self):
        self.write_back()
        self.assertEqual(self.check(), [])

    def test_例を書き換えたのに撮り直していなければ赤い(self):
        self.write_back()
        text = self.path.read_text(encoding="utf-8").replace("circle(200, 150, 160)", "circle(200, 150, 200)")
        self.path.write_text(text, encoding="utf-8")
        problems = self.check()
        self.assertTrue(any("撮り直していない" in problem for problem in problems), problems)

    def test_一文の説明が空なら赤い(self):
        self.path.write_text(SOURCE.replace("<!-- shot: 中央の橙色の円 -->", "<!-- shot: -->"), encoding="utf-8")
        problems = self.check()
        self.assertTrue(any("一文の説明が空" in problem for problem in problems), problems)

    def test_例の塊が無ければ赤い(self):
        self.path.write_text(
            SOURCE.replace("    /// ```swift\n    /// circle(200, 150, 160)\n    /// ```\n", ""),
            encoding="utf-8",
        )
        problems = self.check()
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


    # ---------------------------------------------------------------- 包み方 (#667)

    def test_メンバの段の例も撮れる(self):
        """`setup()` を書いた例が、Sketch として組める形で生成物へ入る。"""
        self.path.write_text(MEMBER_SOURCE, encoding="utf-8")
        found = self.collect()
        self.assertEqual(len(found), 1)
        package = self.root / "generated"
        shots.generate(self.root, found, package)
        body = (package / "Sources" / "example-shots" / "Shots.swift").read_text(encoding="utf-8")
        # 段が本体に固定されていれば `func setup()` が draw() の中へ入って組めなくなる
        self.assertIn("func setup() {", body)
        self.assertNotIn("func draw() {\n        func setup()", body)

    def test_文脈の宣言が生成物へ入る(self):
        self.path.write_text(MEMBER_SOURCE, encoding="utf-8")
        found = self.collect()
        self.assertEqual(found[0].context, ["var pad: Canvas!"])
        package = self.root / "generated"
        shots.generate(self.root, found, package)
        body = (package / "Sources" / "example-shots" / "Shots.swift").read_text(encoding="utf-8")
        self.assertIn("var pad: Canvas!", body)

    def test_型の段は名乗って落ちる(self):
        """`enum` に包まれると Sketch にならないので、走らせようがない。"""
        self.path.write_text(TYPE_SOURCE, encoding="utf-8")
        with self.assertRaises(SystemExit) as caught:
            shots.generate(self.root, self.collect(), self.root / "generated")
        self.assertIn("型の段", str(caught.exception))

    def test_文脈が無ければ指紋は文脈を足す前のまま(self):
        """**この 2 つの値は、文脈を材料に足す前 (#667 より前) に採ったものである。**

        空の文脈でも材料に鍵を置くと JSON が変わり、文脈を持たない既存の絵が
        全部「撮り直し」になる — 公開済みの URL がすべて差し替わるということでもある。
        だから値そのものを留めておく。
        """
        self.assertEqual([shot.fingerprint for shot in self.collect()], ["0325b69b", "03251561"])
        self.assertEqual([shot.context for shot in self.collect()], [[], []])

    def test_文脈を書けば指紋が動く(self):
        """文脈は絵を変えうるので、書き換えたら撮り直しが要る。"""
        self.path.write_text(MEMBER_SOURCE, encoding="utf-8")
        with_context = self.collect()[0]
        self.assertEqual(with_context.context, ["var pad: Canvas!"])
        other = self.path.read_text(encoding="utf-8").replace(
            "var pad: Canvas!", "var pad: Canvas! = nil")
        self.path.write_text(other, encoding="utf-8")
        self.assertNotEqual(self.collect()[0].fingerprint, with_context.fingerprint)

    def test_黙らせる軸を読み並びを揃える(self):
        self.path.write_text(
            SOURCE.replace("<!-- shot: 中央の橙色の円 -->", "<!-- shot: 中央の円 | symmetric=yx -->"),
            encoding="utf-8",
        )
        self.assertEqual(self.collect()[0].symmetric, "xy")

    def test_知らない軸は名乗って落ちる(self):
        self.path.write_text(
            SOURCE.replace("<!-- shot: 中央の橙色の円 -->", "<!-- shot: 中央の円 | symmetric=z -->"),
            encoding="utf-8",
        )
        with self.assertRaises(ValueError):
            self.collect()

    def test_黙らせる軸は指紋を動かさない(self):
        # **黙らせる指定を足しても絵は 1 画素も変わらない。** 指紋が動くと撮り直しを
        # 迫られ、「対称だと分かった」と書くだけで全部撮り直す羽目になる
        before = self.collect()[0].fingerprint
        self.path.write_text(
            SOURCE.replace("<!-- shot: 中央の橙色の円 -->", "<!-- shot: 中央の橙色の円 | symmetric=xy -->"),
            encoding="utf-8",
        )
        self.assertEqual(self.collect()[0].fingerprint, before)

    def test_見分けが付かない軸だけを言う(self):
        limit = shots.INDISTINGUISHABLE
        lines = shots.mirror_warnings(
            "shot-1", "Sketch.swift:10", {"x": limit, "y": limit + 0.01}, ""
        )
        self.assertEqual(len(lines), 1)
        self.assertIn("x 軸", lines[0])
        self.assertIn("symmetric=x", lines[0])

    def test_黙らせた軸は数えない(self):
        self.assertEqual(
            shots.mirror_warnings("shot-1", "Sketch.swift:10", {"x": 0.0, "y": 0.0}, "xy"), []
        )

    def test_実物のソースの囲みが揃っている(self):
        result = subprocess.run(
            ["python3", str(SCRIPT)], cwd=REPO, capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


def write_png(path: Path, rows: list[list[tuple[int, int, int, int]]], filter_kind: int = 0,
              rgb: bool = False) -> None:
    """8 bit の PNG を書く (zlib だけ。絵を描かずに、比べる側を検めるため)。

    `filter_kind` は行の差分符号 (0 None / 1 Sub / 2 Up / 3 Average / 4 Paeth) — 本物の
    PNG は行ごとに符号を選ぶので、読む側が全部を戻せることを固定するのに使う。
    """

    def chunk(kind: bytes, body: bytes) -> bytes:
        crc = zlib.crc32(kind + body) & 0xFFFFFFFF
        return len(body).to_bytes(4, "big") + kind + body + crc.to_bytes(4, "big")

    step = 3 if rgb else 4
    height, width = len(rows), len(rows[0])
    lines = [bytes(c for pixel in row for c in pixel[:step]) for row in rows]
    out, previous = [], bytes(len(lines[0]))
    for line in lines:
        filtered = bytearray()
        for i, value in enumerate(line):
            left = line[i - step] if i >= step else 0
            up = previous[i]
            corner = previous[i - step] if i >= step else 0
            if filter_kind == 1:
                predicted = left
            elif filter_kind == 2:
                predicted = up
            elif filter_kind == 3:
                predicted = (left + up) >> 1
            elif filter_kind == 4:
                estimate = left + up - corner
                da, db, dc = abs(estimate - left), abs(estimate - up), abs(estimate - corner)
                predicted = left if da <= db and da <= dc else up if db <= dc else corner
            else:
                predicted = 0
            filtered.append((value - predicted) & 255)
        out.append(bytes([filter_kind]) + bytes(filtered))
        previous = line
    header = width.to_bytes(4, "big") + height.to_bytes(4, "big") + bytes([8, 2 if rgb else 6, 0, 0, 0])
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"".join(out)))
        + chunk(b"IEND", b"")
    )


GREY = (128, 128, 128, 255)


def grey_rows(width=4, height=3, changed=None):
    """灰色一面の絵。`changed` は {(x, y): 画素} で上書きする。"""
    rows = [[GREY] * width for _ in range(height)]
    for (x, y), pixel in (changed or {}).items():
        rows[y][x] = pixel
    return rows


class DifferenceStatsTest(unittest.TestCase):
    """差の絵 (`|a - b|`) から、違う画素の数と最大の差を数える。ffmpeg は要らない。"""

    def test_差が無ければ_0_と_0(self):
        self.assertEqual(shots.difference_stats(bytes(4 * 6)), (0, 0))

    def test_1_画素の_1_階調も数える(self):
        # #1454 の shadows(_:) は、最大 1 階調の違いだった。閾値で落とさない
        diff = bytearray(4 * 6)
        diff[4 * 2 + 1] = 1
        self.assertEqual(shots.difference_stats(bytes(diff)), (1, 1))

    def test_同じ画素の複数の成分は_1_画素と数える(self):
        diff = bytearray(4 * 6)
        diff[0:3] = bytes([10, 20, 30])  # 1 画素の 3 成分
        diff[4 * 5 + 3] = 255  # 別の 1 画素 (alpha)
        self.assertEqual(shots.difference_stats(bytes(diff)), (2, 255))

    def test_最大の差を言う(self):
        diff = bytearray(4 * 3)
        diff[0], diff[4], diff[8] = 3, 9, 5
        self.assertEqual(shots.difference_stats(bytes(diff)), (3, 9))

    def test_画素に割り切れない長さは落ちる(self):
        with self.assertRaises(ValueError):
            shots.difference_stats(bytes(7))


class DecodeTest(unittest.TestCase):
    """PNG を自前で読む (専用機に ffmpeg が無いため・#1986)。符号の全種と、読めない形の名乗り。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def rows(self):
        # 行と列で値が動く絵。符号の取り違えが画素に出る
        return [[(x * 37 % 256, y * 91 % 256, (x * y * 13) % 256, 255 - x) for x in range(7)] for y in range(5)]

    def test_符号の全種を戻せる(self):
        rows = self.rows()
        expected = bytes(c for row in rows for pixel in row for c in pixel)
        for kind in range(5):
            with self.subTest(filter=kind):
                path = self.dir / f"f{kind}.png"
                write_png(path, rows, filter_kind=kind)
                size, pixels = shots.decode_rgba(path)
                self.assertEqual((size, pixels), ((7, 5), expected))

    def test_RGB_は_alpha_255_の_RGBA_として読む(self):
        path = self.dir / "rgb.png"
        write_png(path, grey_rows(2, 2), rgb=True)
        _, pixels = shots.decode_rgba(path)
        self.assertEqual(pixels, bytes(GREY) * 4)

    def test_符号が違うだけの_2_枚は画素が同じと言う(self):
        a, b = self.dir / "a.png", self.dir / "b.png"
        write_png(a, self.rows(), filter_kind=1)
        write_png(b, self.rows(), filter_kind=4)
        self.assertNotEqual(a.read_bytes(), b.read_bytes())
        self.assertEqual(shots.image_difference(a, b), (0, 35, 0))

    def test_読めない形は名乗って落ちる(self):
        path = self.dir / "gray.png"
        write_png(path, grey_rows(2, 2))
        data = bytearray(path.read_bytes())
        data[24] = 16  # IHDR のビット深度を 16 にする
        path.write_bytes(bytes(data))
        with self.assertRaises(SystemExit) as caught:
            shots.decode_rgba(path)
        self.assertIn("読めない形", str(caught.exception))

    def test_PNG_でないものは名乗って落ちる(self):
        path = self.dir / "x.png"
        path.write_bytes(b"not a png")
        with self.assertRaises(SystemExit):
            shots.decode_rgba(path)


class DriftTest(unittest.TestCase):
    """前後の木で例の絵を描き比べて名指しする (#1986)。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        (self.root / "Sources").mkdir()
        (self.root / "Sources" / "Sketch.swift").write_text(SOURCE, encoding="utf-8")
        self.shots = shots.collect(self.root)
        self.base_out, self.head_out = self.root / "base", self.root / "head"
        self.base_out.mkdir()
        self.head_out.mkdir()

    def put(self, shot, base_rows, head_rows):
        write_png(self.base_out / f"{shot.name}.png", base_rows)
        write_png(self.head_out / f"{shot.name}.png", head_rows)

    # ---- 比べる

    def test_同じ絵は名指ししない(self):
        for shot in self.shots:
            self.put(shot, grey_rows(), grey_rows())
        compared, drifts = shots.compare_trees(self.shots, self.shots, self.base_out, self.head_out)
        self.assertEqual((compared, drifts), (2, []))

    def test_バイトが同じ_PNG_は復号せずに同じと言う(self):
        shot = self.shots[0]
        self.put(shot, grey_rows(), grey_rows())
        with mock.patch.object(subprocess, "run", side_effect=AssertionError("ffmpeg を呼んだ")):
            self.assertIsNone(shots.measure_drift(self.base_out, self.head_out, shot))

    def test_画素が変わった絵だけを数と最大の差つきで名指しする(self):
        first, second = self.shots
        self.put(first, grey_rows(), grey_rows(changed={(1, 1): (128, 130, 128, 255)}))
        self.put(second, grey_rows(), grey_rows())
        compared, drifts = shots.compare_trees(self.shots, self.shots, self.base_out, self.head_out)
        self.assertEqual(compared, 2)
        self.assertEqual([d.shot.name for d in drifts], [first.name])
        self.assertEqual((drifts[0].pixels, drifts[0].total, drifts[0].largest), (1, 12, 2))

    def test_色の成分が複数違っても_1_画素(self):
        shot = self.shots[0]
        self.put(shot, grey_rows(), grey_rows(changed={(0, 0): (0, 0, 0, 255)}))
        drift = shots.measure_drift(self.base_out, self.head_out, shot)
        self.assertEqual((drift.pixels, drift.largest), (1, 128))

    def test_動きは連番を1枚ずつ比べて違う枚数を言う(self):
        source = SOURCE.replace("<!-- shot: 中央の橙色の円 -->", "<!-- shot: 中央の橙色の円 | frames=3 -->")
        (self.root / "Sources" / "Sketch.swift").write_text(source, encoding="utf-8")
        motion = next(s for s in shots.collect(self.root) if s.is_motion)
        for index in range(3):
            name = f"f.{index:04d}.png"
            for out in (self.base_out, self.head_out):
                (out / motion.name).mkdir(exist_ok=True)
            write_png(self.base_out / motion.name / name, grey_rows())
            moved = {(0, 0): (0, 0, 0, 255)} if index == 1 else None
            write_png(self.head_out / motion.name / name, grey_rows(changed=moved))
        drift = shots.measure_drift(self.base_out, self.head_out, motion)
        self.assertEqual((drift.frames, drift.pixels, drift.total), (1, 1, 36))

    def test_両方の木に在る絵だけを比べる(self):
        """例そのものが書き換わった絵は指紋が変わる。それは check の領分で、ここでは数えない。"""
        edited = SOURCE.replace("circle(200, 150, 80)", "circle(200, 150, 90)")
        (self.root / "Sources" / "Sketch.swift").write_text(edited, encoding="utf-8")
        head = shots.collect(self.root)
        asked = []

        def measure(base_out, head_out, shot):
            asked.append(shot.name)
            return None

        compared, _ = shots.compare_trees(self.shots, head, self.base_out, self.head_out, measure)
        # 1 本目 (円 160) は両方に在り、2 本目 (円 80 → 90) は head にしか無い
        self.assertEqual(compared, 1)
        self.assertEqual(asked, [self.shots[0].name])

    # ---- 言い方

    def drift_for(self, **overrides):
        values = dict(shot=self.shots[0], pixels=9644, total=120000, largest=17, frames=0)
        return shots.Drift(**{**values, **overrides})

    def test_名指しは説明文のファイル_行_snippet_違う画素_最大の差を含む(self):
        drift = self.drift_for()
        line = shots.drift_annotation(drift)
        self.assertTrue(line.startswith("::warning "), line)
        self.assertIn("file=Sources/Sketch.swift", line)
        self.assertIn(f"line={drift.shot.open_line + 1}", line)
        self.assertIn(f"snippet={drift.shot.fingerprint}", line)
        self.assertIn("違う画素 9644 / 全 120000", line)
        self.assertIn("最大の差 17", line)

    def test_警告の文字はエスケープされる(self):
        self.assertEqual(shots._escape_data("100%\nx"), "100%25%0Ax")
        self.assertEqual(shots._escape_property("a:b,c"), "a%3Ab%2Cc")

    def test_変わった絵が無ければ要約は_1_行だけで表を持たない(self):
        text = shots.drift_summary(5, [], {"比較": 1.0}, "HEAD^1")
        self.assertIn("5 本を HEAD^1 と比べて、画素が変わった絵は無い", text)
        self.assertNotIn("| 説明文 |", text)

    def test_変わった絵があれば要約の表に場所と数が出る(self):
        drift = self.drift_for()
        text = shots.drift_summary(5, [drift], {"比較": 1.0}, "HEAD^1")
        self.assertIn("| 説明文 |", text)
        self.assertIn(drift.shot.where, text)
        self.assertIn(drift.shot.fingerprint, text)
        self.assertIn("9644 / 120000", text)
        self.assertIn("merge は止めない", text)

    def report(self, drifts, **env):
        out = io.StringIO()
        with mock.patch.dict(os.environ, env, clear=False), contextlib.redirect_stdout(out):
            shots.report_drift(3, drifts, {"比較": 1.0}, "HEAD^1")
        return out.getvalue()

    def test_Actions_の上でだけ_annotation_を出す(self):
        env = {"GITHUB_ACTIONS": "true"}
        with tempfile.TemporaryDirectory() as tmp:
            summary = Path(tmp) / "summary.md"
            on = self.report([self.drift_for()], GITHUB_STEP_SUMMARY=str(summary), **env)
            written = summary.read_text(encoding="utf-8")
        self.assertIn("::warning ", on)
        self.assertIn("| 説明文 |", written)
        with mock.patch.dict(os.environ):
            os.environ.pop("GITHUB_ACTIONS", None)
            off = self.report([self.drift_for()], GITHUB_STEP_SUMMARY="")
        self.assertNotIn("::warning", off)

    def test_変わった絵が無ければ_annotation_を出さない(self):
        out = self.report([], GITHUB_ACTIONS="true", GITHUB_STEP_SUMMARY="")
        self.assertNotIn("::warning", out)

    # ---- 入口

    def run_main(self, argv, which):
        built = []
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(shots, "drift", lambda *a: built.append(a) or 0), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = shots.main(argv, which=which)
        return code, built, err.getvalue()

    def test_drift_は_ffmpeg_を探さない(self):
        """専用機には ffmpeg が入っていない (#1986)。比べるだけの実行は道具を探さない。"""

        def which(name):
            raise AssertionError(f"drift が {name} を探した")

        code, built, err = self.run_main(["--drift", "HEAD^1"], which=which)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(built), 1)

    def test_drift_は_render_と一緒に使えない(self):
        code, built, err = self.run_main(
            ["--drift", "HEAD^1", "--render", "x"], which=lambda name: "/bin/true"
        )
        self.assertNotEqual(code, 0)
        self.assertEqual(built, [])
        self.assertIn("--drift", err)


class NeededToolsTest(unittest.TestCase):
    """撮る側は ffmpeg が無ければ組む前に止まり、見る側は探しもしない (#1598)。

    探す先は `main(which=...)` で差し替える。本物の `--render` は GPU とビルドが要るので、
    組む入口 (`render`) と測る入口 (`report_mirrors`) は呼ばれたかだけを記録する偽物に
    替える — 見たいのは「組む前に止まるか」で、組めるかではない。動きの測り
    (`check_motion`) も、測る絵が無いので何も言わない偽物にする。
    """

    def run_main(self, argv, which):
        self.built = []
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(shots, "render", lambda *a: self.built.append(a)), \
                mock.patch.object(shots, "report_mirrors", lambda *a, **k: None), \
                mock.patch.object(shots, "check_motion", lambda *a: []), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = shots.main(argv, which=which)
        return code, out.getvalue(), err.getvalue()

    def assert_named_and_stopped(self, argv):
        code, _, err = self.run_main(argv, which=lambda name: None)
        self.assertNotEqual(code, 0)
        self.assertEqual(len(self.built), 0, "ffmpeg が無いのにスケッチを組みに行った")
        lines = err.splitlines()
        self.assertEqual(len(lines), 1, err)
        self.assertIn("ffmpeg", lines[0])
        self.assertIn("brew install ffmpeg", lines[0])

    def test_ffmpeg_が無ければ_render_は組む前に名乗って止まる(self):
        with tempfile.TemporaryDirectory() as out:
            self.assert_named_and_stopped(["--render", out])

    def test_ffmpeg_が無ければ_capture_は組む前に名乗って止まる(self):
        # トークンは空にしておく。確かめが外れて止まらなくても、上げには行かない
        self.assert_named_and_stopped(["--capture", "--token-command", "true"])

    def test_ffmpeg_があれば_render_は組みに行く(self):
        with tempfile.TemporaryDirectory() as out:
            code, _, err = self.run_main(
                ["--render", out], which=lambda name: f"/opt/tools/{name}"
            )
        self.assertEqual(code, 0, err)
        self.assertEqual(len(self.built), 1)

    def test_見るだけの実行は道具を探さない(self):
        def which(name):
            raise AssertionError(f"見るだけの実行が {name} を探した")

        code, _, err = self.run_main([], which=which)
        self.assertEqual(code, 0, err)

    def test_見るだけの実行は_ffmpeg_の無い_PATH_でも通る(self):
        # 既定の実行が要るのは版管理の道具だけ。OS が最初から持つ置き場 (os.defpath) に
        # それがあり ffmpeg が無ければ、そこだけを PATH にして本物の入口を通す
        path = os.defpath
        if shutil.which("git", path=path) is None:
            self.skipTest(f"{path} に版管理の道具が無い")
        if shutil.which("ffmpeg", path=path):
            self.skipTest(f"{path} に ffmpeg がある")
        result = subprocess.run(
            [sys.executable, str(SCRIPT)], cwd=REPO, capture_output=True, text=True,
            env={**os.environ, "PATH": path},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


# ---------------------------------------------------------------- 動く絵が動いているか (#2117)

BLACK = (0, 0, 0, 255)


def moving_rows(index, width=20, height=10):
    """`index` 枚目の絵。灰色の下地を、黒い縦の帯 (幅 1) が 1 枚ごとに右へ 1 画素進む。"""
    return grey_rows(width, height, changed={(index % width, y): BLACK for y in range(height)})


class MotionTest(unittest.TestCase):
    """撮った動きの隣り合う 2 枚ずつを比べ、全部の組が下限を下回れば名指しする。

    絵は撮らずに `write_png` で連番を置く。測る側 (`check_motion`) が読むのは置き場の
    PNG だけなので、GPU も ffmpeg も要らない。
    """

    FRAMES = 4

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        (self.root / "Sources").mkdir()
        self.path = self.root / "Sources" / "Sketch.swift"
        self.out = self.root / "out"
        self.use_attributes(f"frames={self.FRAMES}")

    def use_attributes(self, attributes):
        """1 本目の囲みを、`attributes` の撮影設定を持つ動きにする。2 本目は静止画のまま。"""
        source = SOURCE.replace("<!-- shot: 中央の橙色の円 -->", f"<!-- shot: 動く円 | {attributes} -->")
        self.path.write_text(source, encoding="utf-8")
        self.shots = shots.collect(self.root)
        self.motion = next(shot for shot in self.shots if shot.is_motion)

    def put_frames(self, rows_of):
        """`rows_of(index)` が返す絵を、撮る側と同じ置き場と名前 (`<name>/f.NNNN.png`) に置く。"""
        folder = self.out / self.motion.name
        folder.mkdir(parents=True, exist_ok=True)
        for index in range(self.motion.frames):
            write_png(folder / f"f.{index:04d}.png", rows_of(index))

    def check(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            problems = shots.check_motion(self.out, self.shots)
        self.check_output = output.getvalue()
        return problems

    # ---- 判定

    def test_全フレームが同じ絵なら名指しして赤い(self):
        self.put_frames(lambda index: grey_rows(20, 10))
        problems = self.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn(self.motion.where, problems[0])
        self.assertIn(self.motion.name, problems[0])
        self.assertIn(f"隣り合う {self.FRAMES - 1} 組", problems[0])
        self.assertIn("still=", problems[0])
        self.assertNotIn("ok:", self.check_output)

    def test_動いていれば通る(self):
        self.put_frames(moving_rows)
        self.assertEqual(self.check(), [])
        self.assertIn("ok: 動く絵 1 本", self.check_output)

    def test_止まる区間が一部なら通る(self):
        # 往復する動きの折り返しのように、終わりの 1 組だけが動く
        last = self.FRAMES - 1
        self.put_frames(lambda index: moving_rows(1) if index == last else moving_rows(0))
        self.assertEqual(self.check(), [])

    def test_下限に届かない差だけなら止まっている側(self):
        # 違う画素が 1 つしか無い組だけが続く。絵の大きさは、その 1 画素が下限の半分に
        # なるように取る — 画素は違うが、動いたとは言えない
        width, height = int(2 / shots.MOTION_FLOOR) // 100, 100
        nudged = {(0, 0): (129, 128, 128, 255)}
        self.put_frames(lambda index: grey_rows(width, height, changed=nudged if index % 2 else None))
        problems = self.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertNotIn("最大 0.0000%", problems[0], "差は 0 ではなく、下限に届かないだけのはず")

    def test_黙らせた動きは止まっていても言わない(self):
        self.use_attributes(f"frames={self.FRAMES} still=止めた時刻の絵が続くことを示す")
        self.put_frames(lambda index: grey_rows(20, 10))
        self.assertEqual(self.check(), [])

    def test_連番が無ければ名乗って落ちる(self):
        with self.assertRaises(SystemExit):
            self.check()

    # ---- 境目の当て方 (純関数)

    def test_下限ちょうどは動いている(self):
        floor = shots.MOTION_FLOOR
        self.assertIsNone(shots.frozen_motion("shot-1", "Sketch.swift:10", 59, floor, ""))

    def test_下限をわずかに下回れば止まっている(self):
        floor = shots.MOTION_FLOOR
        line = shots.frozen_motion("shot-1", "Sketch.swift:10", 59, floor * 0.99, "")
        self.assertIsNotNone(line)
        self.assertTrue(line.startswith("Sketch.swift:10: shot-1 "), line)

    def test_1_枚だけの動きは確かめられないので止まっている側(self):
        line = shots.frozen_motion("shot-1", "Sketch.swift:10", 0, 0.0, "")
        self.assertIsNotNone(line)
        self.assertIn("1 枚しか無く", line)

    def test_黙らせてあれば言わない(self):
        self.assertIsNone(shots.frozen_motion("shot-1", "Sketch.swift:10", 59, 0.0, "理由"))

    # ---- 差の測り方

    def test_同じ画素の差は_0(self):
        pixels = bytes(GREY) * 6
        self.assertEqual(shots.frame_change(pixels, pixels), 0.0)

    def test_違う画素の割合を言う(self):
        # 白へ変わった 1 画素は 3 成分が違うが、数えるのは 1 画素
        before = bytes(BLACK) * 4
        after = bytes((255, 255, 255, 255)) + bytes(BLACK) * 3
        self.assertEqual(shots.frame_change(before, after), 0.25)

    def test_1_階調の違いも_1_画素に数える(self):
        # 前後の木の比べ (`difference_stats`) と同じ数え方
        before = bytes(GREY) * 4
        after = bytes((128, 129, 128, 255)) + bytes(GREY) * 3
        self.assertEqual(shots.frame_change(before, after), 0.25)

    def test_明るさが同じで色だけ違う画素も数える(self):
        before = bytes((255, 0, 0, 255)) * 2
        after = bytes((0, 0, 255, 255)) + bytes((255, 0, 0, 255))
        self.assertEqual(shots.frame_change(before, after), 0.5)

    def test_長さの違う_2_枚は落ちる(self):
        with self.assertRaises(ValueError):
            shots.frame_change(bytes(8), bytes(4))

    def test_バイトが同じ_2_枚は復号しない(self):
        self.put_frames(lambda index: grey_rows(20, 10))
        frames = sorted((self.out / self.motion.name).glob("f.*.png"))
        with mock.patch.object(shots, "decode_rgba", side_effect=AssertionError("復号した")):
            self.assertEqual(shots.largest_change(frames), 0.0)

    def test_下限に届いた所で測るのをやめる(self):
        # 3 枚目からは PNG ですらない。最初の組で下限に届けば、そこは読まれない
        self.put_frames(moving_rows)
        frames = sorted((self.out / self.motion.name).glob("f.*.png"))
        for frame in frames[2:]:
            frame.write_bytes(b"not a png")
        self.assertGreaterEqual(shots.largest_change(frames), shots.MOTION_FLOOR)

    # ---- 撮影設定

    def test_黙らせる理由を読む(self):
        self.use_attributes(f"frames={self.FRAMES} still=止めた時刻の絵が続く")
        self.assertEqual(self.motion.still, "止めた時刻の絵が続く")

    def test_空白を含む理由は引用符で包める(self):
        self.use_attributes(f'frames={self.FRAMES} still="noLoop() の例" symmetric=y')
        self.assertEqual((self.motion.still, self.motion.symmetric), ("noLoop() の例", "y"))

    def test_黙らせない動きは理由を持たない(self):
        self.assertEqual(self.motion.still, "")

    def test_理由の無い黙らせは場所を名乗って落ちる(self):
        for attributes in (f"frames={self.FRAMES} still=", f'frames={self.FRAMES} still=""'):
            with self.subTest(attributes=attributes), self.assertRaises(ValueError) as caught:
                self.use_attributes(attributes)
            self.assertIn("理由が無い", str(caught.exception))
            self.assertIn("Sources/Sketch.swift:", str(caught.exception))

    def test_静止画は黙らせられない(self):
        with self.assertRaises(ValueError) as caught:
            self.use_attributes("still=理由")
        self.assertIn("frames=N", str(caught.exception))

    def test_黙らせる指定は指紋を動かさない(self):
        before = self.motion.fingerprint
        self.use_attributes(f"frames={self.FRAMES} still=理由")
        self.assertEqual(self.motion.fingerprint, before)

    # ---- 入口: 上げる前に止まる

    def run_capture(self, rows_of):
        """`--capture` を通す。組む・上げる・書き戻すは偽物で、呼ばれたかだけを記録する。"""
        uploaded, written = [], []

        def render(root, found, out):
            self.out = out
            self.put_frames(rows_of)

        def upload(image, token, alt):
            uploaded.append(image)
            return f"https://example.invalid/{image.name}"

        err = io.StringIO()
        with tempfile.TemporaryDirectory() as out, \
                mock.patch.object(shots, "collect", lambda root: self.shots), \
                mock.patch.object(shots, "render", render), \
                mock.patch.object(shots, "report_mirrors", lambda *a, **k: None), \
                mock.patch.object(shots, "upload", upload), \
                mock.patch.object(shots, "write_back", lambda *a: written.append(a) or 0), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            code = shots.main(
                ["--capture", "--render", out, "--token-command", "echo token"],
                which=lambda name: f"/opt/tools/{name}",
            )
        return code, uploaded, written, err.getvalue()

    def test_止まった動きがあれば上げも書き戻しもせずに止まる(self):
        code, uploaded, written, err = self.run_capture(lambda index: grey_rows(20, 10))
        self.assertEqual(code, 1, err)
        self.assertEqual((uploaded, written), ([], []))
        self.assertIn(self.motion.where, err)
        self.assertIn("上げも書き戻しもせずに止める", err)

    def test_動いていれば上げて書き戻す(self):
        code, uploaded, written, err = self.run_capture(moving_rows)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(uploaded), len(self.shots))
        self.assertEqual(len(written), 1)



# ---------------------------------------------------------------- 公開メンバが例か宣言を持つか (#2116)

MEMBER_DIRECTORY = "Sources/MokumeCore/Sketch"
MEMBER_FILE = f"{MEMBER_DIRECTORY}/Sketch+Foo.swift"

# 宣言が公開される説明文に出ないこと (ADR-0027 決定 2) は、説明文を読む側 (api-surface.py の
# `slash_doc`) で確かめる
_api_spec = importlib.util.spec_from_file_location("api_surface", REPO / "scripts" / "api-surface.py")
api_surface = importlib.util.module_from_spec(_api_spec)
_api_spec.loader.exec_module(api_surface)


def swift(*members):
    """`extension Sketch` の本体に口を並べたソース。口は 4 字下げで書く。"""
    return "extension Sketch {\n" + "\n".join(members) + "}\n"


def line_of(source, needle):
    """`needle` を含む最初の行の番号 (1 起点)。期待する行を数え間違えないために使う。"""
    for number, line in enumerate(source.split("\n"), start=1):
        if needle in line:
            return number
    raise AssertionError(f"{needle!r} が無い")


def pictured(name, parameters="_ size: some ScalarConvertible", extra=""):
    """例と絵 (囲み) を持つ口。`extra` は説明文と宣言の間に挟む行 (`//` の宣言など)。"""
    return (
        f"    /// {name} を描く。\n"
        "    ///\n"
        "    /// ```swift\n"
        "    /// circle(200, 150, 160)\n"
        "    /// ```\n"
        f"    /// <!-- shot: {name} の絵 -->\n"
        "    /// <!-- /shot -->\n"
        f"{extra}"
        f"    public func {name}({parameters}) {{}}\n"
    )


def bare(name, parameters="_ size: some ScalarConvertible", extra=""):
    """説明文だけの口 (例も絵も無い)。"""
    return f"    /// {name} を置く。\n{extra}    public func {name}({parameters}) {{}}\n"


# 参照の面の見出し (`name(labels)`) と型の並び。許容一覧の綴りになる
PLAIN = bare("ellipsoid", "_ size: some ScalarConvertible, _ detail: Int = 24")
PLAIN_KEY = "ellipsoid(_:_:) (some ScalarConvertible, Int)"


class MemberTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        (self.root / MEMBER_DIRECTORY).mkdir(parents=True)

    def write(self, source, name="Sketch+Foo.swift"):
        (self.root / MEMBER_DIRECTORY / name).write_text(source, encoding="utf-8")

    def members(self):
        return shots.collect_members(self.root)

    def gap(self, key, name="Sketch+Foo.swift"):
        return f"{MEMBER_DIRECTORY}/{name}: {key}"

    def judge(self, source=None, gaps=""):
        """検査を走らせて指摘の一覧を返す。**印字は伏せる** (本物の件数と見分けが付かなくなるため)。"""
        if source is not None:
            self.write(source)
        table, found = shots.load_gaps(gaps)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            problems = found + shots.check_members(self.members(), table)
        self.output = out.getvalue()
        return problems


class MemberCoverageTest(MemberTestCase):
    """3〜5 — 名指しして赤にする・一覧が増える方向に動けない・空回りを隠さない。"""

    # ---- 3: 例も宣言も許容一覧も無い口

    def test_例も宣言も許容一覧も無い口をファイルと行つきで名指しして赤い(self):
        source = swift(PLAIN)
        problems = self.judge(source)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn(f"{MEMBER_FILE}:{line_of(source, 'public func ellipsoid')}", problems[0])
        self.assertIn(PLAIN_KEY, problems[0])
        self.assertIn("許容一覧にも無い", problems[0])

    def test_説明文だけの口を足すと赤くなる(self):
        """#2116 の例そのもの。`///` だけで足した口は、以前は `ok` を返していた。"""
        self.assertEqual(self.judge(swift(pictured("circle"))), [])
        problems = self.judge(swift(pictured("circle"), bare("ellipsoid")))
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("ellipsoid(_:)", problems[0])

    def test_例と絵を持つ口は通る(self):
        self.assertEqual(self.judge(swift(pictured("circle"))), [])
        self.assertIn("例と絵 1", self.output)

    def test_許容一覧に載っている口は通る(self):
        self.assertEqual(self.judge(swift(PLAIN), gaps=self.gap(PLAIN_KEY)), [])
        self.assertIn("許容一覧 1", self.output)

    def test_許容一覧の一致はファイルも見る(self):
        """同じ綴りの口でも、別のファイルの行は載っていないものとして赤にする。"""
        problems = self.judge(swift(PLAIN), gaps=self.gap(PLAIN_KEY, name="Sketch+Bar.swift"))
        self.assertTrue(any("許容一覧にも無い" in p for p in problems), problems)
        self.assertTrue(any("ソースに無い" in p for p in problems), problems)

    # ---- 4: 許容一覧に載ったまま、例か宣言が付いた口

    def test_許容一覧の口に例が付いたのに消していなければ赤い(self):
        gaps = "# 先頭の注釈は読まない\n\n" + self.gap("circle(_:) (some ScalarConvertible)")
        problems = self.judge(swift(pictured("circle")), gaps=gaps)
        self.assertEqual(len(problems), 1, problems)
        # 一覧の側の行を名指しする (消す行が分かる)
        self.assertIn(f"scripts/example-shots-gaps.txt:{line_of(gaps, 'circle')}", problems[0])
        self.assertIn("許容一覧から消す", problems[0])

    def test_許容一覧の口に撮れない宣言が付いたのに消していなければ赤い(self):
        source = swift(bare("ellipsoid", extra="    // shot: 撮れない 値を返すだけで絵にならない\n"))
        problems = self.judge(source, gaps=self.gap("ellipsoid(_:) (some ScalarConvertible)"))
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("許容一覧から消す", problems[0])

    def test_消せば通る(self):
        self.assertEqual(self.judge(swift(pictured("circle")), gaps=""), [])

    def test_ソースに無い口が許容一覧に載っていれば赤い(self):
        gaps = self.gap(PLAIN_KEY) + "\n" + self.gap("gone(_:) (Int)")
        problems = self.judge(swift(PLAIN), gaps=gaps)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("scripts/example-shots-gaps.txt:2", problems[0])
        self.assertIn("ソースに無い", problems[0])

    def test_引数の型を変えた口は一覧の行も書き直させる(self):
        """綴りが変われば、新しい口と古い行の両方が赤になる。数を足さずに書き直せば通る。"""
        renamed = bare("ellipsoid", "_ size: Float")
        problems = self.judge(swift(renamed), gaps=self.gap(PLAIN_KEY))
        self.assertEqual(len(problems), 2, problems)
        self.assertEqual(self.judge(swift(renamed), gaps=self.gap("ellipsoid(_:) (Float)")), [])

    def test_読めない行と重なった行は赤い(self):
        table, problems = shots.load_gaps("これは口の行ではない\n" + self.gap(PLAIN_KEY) + "\n" + self.gap(PLAIN_KEY))
        self.assertEqual(len(table), 1)
        self.assertEqual(len(problems), 2, problems)
        self.assertIn("scripts/example-shots-gaps.txt:1", problems[0])
        self.assertIn("同じ口が重なっている", problems[1])

    # ---- 5: 空回り

    def test_拾えた口が1本も無ければ赤い(self):
        problems = self.judge("")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("1 本も拾えなかった", problems[0])

    def test_ファイルが1つも無くても赤い(self):
        table, _ = shots.load_gaps("")
        problems = shots.check_members(self.members(), table)
        self.assertIn("1 本も拾えなかった", problems[0])

    def test_Sketch_以外の拡張だけなら赤い(self):
        problems = self.judge("extension Canvas {\n    public func ellipsoid() {}\n}\n")
        self.assertIn("1 本も拾えなかった", problems[0])

    def test_一覧が空でなくても拾えなければ空回りとして赤い(self):
        """一覧の行が全部「ソースに無い」と言われる代わりに、先に拾えていないことを名乗る。"""
        problems = self.judge("", gaps=self.gap(PLAIN_KEY))
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("1 本も拾えなかった", problems[0])

    # ---- 拾い方

    def test_公開でない口は数えない(self):
        source = swift(
            "    func hidden() {}\n",
            "    internal func inside() {}\n",
            "    private func secret() {}\n",
            "    fileprivate func quiet() {}\n",
            "    package func shared() {}\n",
            PLAIN,
        )
        self.write(source)
        self.assertEqual([m.key for m in self.members()], [PLAIN_KEY])

    def test_public_extension_の口は既定で公開_private_は除く(self):
        source = (
            "public extension Sketch {\n"
            "    func shown() {}\n"
            "    private func hidden() {}\n"
            "    internal func inside() {}\n"
            "}\n"
        )
        self.write(source)
        self.assertEqual([m.key for m in self.members()], ["shown()"])

    def test_本体の直下だけを拾う(self):
        """入れ子の型と、関数の中の宣言は口ではない。"""
        source = (
            "public struct Outside {\n    public func notMine() {}\n}\n"
            "extension Sketch {\n"
            "    public func mine() {\n"
            "        func local() {}\n"
            '        let braces = "{ {"\n'
            "    }\n"
            "    public struct Nested {\n        public func deeper() {}\n    }\n"
            "    public func after() {}\n"
            "}\n"
        )
        self.write(source)
        self.assertEqual([m.title for m in self.members()], ["mine()", "after()"])

    def test_extension_の波括弧が次の行にあっても拾う(self):
        self.write("extension Sketch\n{\n    public func shown() {}\n}\n")
        self.assertEqual([m.key for m in self.members()], ["shown()"])

    def test_同名の_overload_は引数の型で見分ける(self):
        source = swift(
            bare("fill", "_ gray: some ScalarConvertible, _ alpha: some ScalarConvertible = 255"),
            bare("fill", "_ color: LinearRGBA, _ alpha: some ScalarConvertible"),
        )
        problems = self.judge(source)
        self.assertEqual(len(problems), 2, problems)
        keys = [m.key for m in self.members()]
        self.assertEqual(len(set(keys)), 2)
        self.assertIn("fill(_:_:) (LinearRGBA, some ScalarConvertible)", keys)

    def test_複数行の宣言と既定値と入れ子の型を読む(self):
        source = swift(
            "    /// 粒を出す。\n"
            "    public func emit(\n"
            "        _ particles: Particles,\n"
            "        rate: Float = 1,\n"
            "        life: ClosedRange<Float> = 0...1,\n"
            "        body: (Int, [String: Float]) -> Void,\n"
            "        tint: LinearRGBA? = nil,\n"
            "        _ forces: Force...\n"
            "    ) {}\n"
        )
        self.write(source)
        (member,) = self.members()
        self.assertEqual(member.title, "emit(_:rate:life:body:tint:_:)")
        self.assertEqual(
            member.types,
            ("Particles", "Float", "ClosedRange<Float>", "(Int, [String: Float]) -> Void",
             "LinearRGBA?", "Force..."),
        )

    def test_引数の無い口と変数を読む(self):
        source = swift(
            bare("noLoop", parameters=""),
            "    /// 画素。\n    public var pixels: Pixels { Pixels() }\n",
        )
        self.write(source)
        self.assertEqual([m.key for m in self.members()], ["noLoop()", "pixels"])

    def test_読めない公開メンバは黙って落とさず名乗って落ちる(self):
        """落とすと、その口は検査の外に出る。"""
        self.write(swift("    /// 組。\n    public var (a, b) = (1, 2)\n"))
        with self.assertRaises(SystemExit) as caught:
            self.members()
        self.assertIn(f"{MEMBER_FILE}:3", str(caught.exception))

    def test_属性と二重斜線の行を跨いで説明文に着く(self):
        source = swift(
            "    /// 円を塗る。\n"
            "    // 覚え書き\n"
            "    @discardableResult\n"
            "    public func circle() -> Int { 0 }\n"
        )
        self.write(source)
        (member,) = self.members()
        self.assertTrue(member.has_doc)

    def test_空行で離れた説明文は説明文ではない(self):
        self.write(swift("    /// 離れた説明文。\n\n    public func circle() {}\n"))
        (member,) = self.members()
        self.assertFalse(member.has_doc)

    def test_実物のソースから口が拾える(self):
        """拾い方が壊れたときに、許容一覧との突き合わせより先に気付けるように。"""
        members = shots.collect_members(REPO)
        self.assertGreater(len(members), 100)
        keys = {(m.path.name, m.key) for m in members}
        self.assertIn(("Sketch+Loop.swift", "noLoop()"), keys)
        self.assertIn(("Sketch+Color.swift", "fill(_:_:) (LinearRGBA, some ScalarConvertible)"), keys)


class MemberStatementTest(MemberTestCase):
    """1・2 — 撮れない宣言と、別の口の絵への参照。"""

    # ---- 1: 撮れない宣言

    def test_理由つきの撮れない宣言は通る(self):
        source = swift(bare("save", extra="    // shot: 撮れない 結果が絵ではなくファイルになる\n"))
        self.assertEqual(self.judge(source), [])
        self.assertIn("撮れない宣言 1", self.output)

    def test_理由の無い撮れない宣言は赤い(self):
        source = swift(bare("save", extra="    // shot: 撮れない\n"))
        problems = self.judge(source)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn(f"{MEMBER_FILE}:{line_of(source, '// shot: 撮れない')}", problems[0])
        self.assertIn("理由が無い", problems[0])

    def test_理由が空白だけの宣言も赤い(self):
        problems = self.judge(swift(bare("save", extra="    // shot: 撮れない   \n")))
        self.assertIn("理由が無い", problems[0])

    def test_宣言は公開される説明文に出ない(self):
        """ADR-0027 決定 2。宣言は `//` の行なので、`slash_doc` は `///` を説明文と読み続ける。"""
        source = swift(bare("save", extra="    // shot: 撮れない 結果がファイルになる\n"))
        self.write(source)
        path = self.root / MEMBER_FILE
        line = line_of(source, "public func save") - 1
        symbol = {"location": {"uri": path.as_uri(), "position": {"line": line}}}
        self.assertEqual(api_surface.slash_doc(symbol), "")

    def test_宣言は撮影の記録と並べて置ける(self):
        extra = "    // shot: 1 snippet=0a1b2c3d\n    // shot: 撮れない 値を返すだけ\n"
        self.assertEqual(self.judge(swift(bare("save", extra=extra))), [])

    def test_知らない宣言は赤い(self):
        """綴りの誤りが黙って普通のコメントになると、「宣言が無い」としか言われない。"""
        source = swift(bare("save", extra="    // shot: 取れない 結果がファイルになる\n"))
        problems = self.judge(source)
        self.assertTrue(any("知らない宣言" in p and "取れない" in p for p in problems), problems)

    def test_絵を持つ口に撮れない宣言を付けると赤い(self):
        source = swift(pictured("circle", extra="    // shot: 撮れない 理由\n"))
        problems = self.judge(source)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("どちらかが古い", problems[0])

    def test_宣言は_1_つだけ(self):
        extra = "    // shot: 撮れない 理由\n    // shot: 撮れない もう 1 つ\n"
        problems = self.judge(swift(pictured("circle"), bare("save", extra=extra)))
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("宣言は 1 つだけ", problems[0])

    def test_説明文の無い口に宣言は置けない(self):
        """`//` の宣言が説明文として読まれ、説明文の検査から消える抜け道を作らない。"""
        source = swift("    // shot: 撮れない 理由\n    public func save() {}\n")
        problems = self.judge(source)
        self.assertTrue(any("説明文" in p for p in problems), problems)

    # ---- 2: 別の口の絵への参照

    def references(self, target, *others):
        return swift(
            pictured("circle"),
            bare("disc", extra=f"    // shot: 参照 {target}\n"),
            *others,
        )

    def test_別の口の絵を参照できる(self):
        self.assertEqual(self.judge(self.references("circle(_:)")), [])
        self.assertIn("参照 1", self.output)

    def test_型まで添えた綴りで参照できる(self):
        self.assertEqual(self.judge(self.references("circle(_:) (some ScalarConvertible)")), [])

    def test_参照先が無ければ赤い(self):
        source = self.references("ellipse(_:)")
        problems = self.judge(source)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn(f"{MEMBER_FILE}:{line_of(source, '// shot: 参照')}", problems[0])
        self.assertIn("ellipse(_:) が無い", problems[0])

    def test_参照先が絵を持たなければ赤い(self):
        source = swift(bare("circle"), bare("disc", extra="    // shot: 参照 circle(_:)\n"))
        problems = self.judge(source, gaps=self.gap("circle(_:) (some ScalarConvertible)"))
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("絵を持たない", problems[0])

    def test_参照の参照は赤い(self):
        """絵は 1 歩で着く。参照を連ねると、どれが絵を持つのかが読めなくなる。"""
        source = swift(
            pictured("circle"),
            bare("disc", extra="    // shot: 参照 circle(_:)\n"),
            bare("ring", extra="    // shot: 参照 disc(_:)\n"),
        )
        problems = self.judge(source)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("disc(_:) (some ScalarConvertible) が絵を持たない", problems[0])

    def test_自分自身は参照先にならない(self):
        source = swift(bare("disc", extra="    // shot: 参照 disc(_:)\n"))
        problems = self.judge(source)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("が無い", problems[0])

    def test_名前が複数の口に当たるときは型まで添えさせる(self):
        two = swift(
            pictured("fill", "_ gray: some ScalarConvertible, _ alpha: Int"),
            pictured("fill", "_ color: LinearRGBA, _ alpha: Int"),
            bare("tint", extra="    // shot: 参照 fill(_:_:)\n"),
        )
        problems = self.judge(two)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("複数ある", problems[0])
        precise = two.replace("参照 fill(_:_:)", "参照 fill(_:_:) (LinearRGBA, Int)")
        self.assertEqual(self.judge(precise), [])

    def test_参照先は別のファイルでもよい(self):
        self.write(swift(pictured("circle")), name="Sketch+Bar.swift")
        source = swift(bare("disc", extra="    // shot: 参照 circle(_:)\n"))
        self.assertEqual(self.judge(source), [])

    def test_参照先の書かれていない参照は赤い(self):
        problems = self.judge(swift(pictured("circle"), bare("disc", extra="    // shot: 参照\n")))
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("参照先が無い", problems[0])


class DeferredShotTest(unittest.TestCase):
    """6 — Gyazo の鍵を持たない人が、「後で撮る」の印で検査を通す。"""

    MARK = "    // shot: 後で撮る\n"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        (self.root / "Sources").mkdir()
        self.path = self.root / "Sources" / "Sketch.swift"
        self.write(SOURCE.replace("    public func circle() {}", self.MARK + "    public func circle() {}"))

    def write(self, source):
        self.path.write_text(source, encoding="utf-8")

    def collect(self):
        return shots.collect(self.root)

    def check(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            problems = shots.check(self.collect())
        self.output = out.getvalue()
        return problems

    def test_印を読む(self):
        found = self.collect()
        self.assertEqual({shot.deferred_line for shot in found}, {line_of(self.path.read_text(encoding="utf-8"), "後で撮る") - 1})

    def test_印があれば撮っていなくても赤くならない(self):
        self.assertEqual(self.check(), [])

    def test_印が無ければ撮っていないのは赤い(self):
        self.write(SOURCE)
        problems = self.check()
        self.assertEqual(len(problems), 2, problems)
        self.assertTrue(all("まだ撮っていない" in p for p in problems), problems)

    def test_印で入った口は出力で追える(self):
        self.check()
        number = line_of(self.path.read_text(encoding="utf-8"), "後で撮る")
        self.assertIn("後で撮る: 2 本", self.output)
        self.assertIn(f"Sources/Sketch.swift:{number}", self.output)
        self.assertIn("中央の橙色の円", self.output)

    def test_印が無ければ出力に後で撮るを出さない(self):
        self.write(SOURCE)
        self.check()
        self.assertNotIn("後で撮る", self.output)

    def test_撮れているのに印が残っていれば赤い(self):
        shots.write_back(self.root, self.collect(), {s.name: f"https://example.invalid/{s.name}.png" for s in self.collect()})
        self.write(self.path.read_text(encoding="utf-8").replace(
            "    public func circle() {}", self.MARK + "    public func circle() {}"))
        problems = self.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("印が残っている", problems[0])
        self.assertIn(f"Sources/Sketch.swift:{line_of(self.path.read_text(encoding='utf-8'), '後で撮る')}", problems[0])

    def test_例を書き換えたあとも印があれば撮り直しを待てる(self):
        found = self.collect()
        shots.write_back(self.root, found, {s.name: f"https://example.invalid/{s.name}.png" for s in found})
        text = self.path.read_text(encoding="utf-8")
        self.write(text.replace("circle(200, 150, 160)", "circle(200, 150, 200)").replace(
            "    public func circle() {}", self.MARK + "    public func circle() {}"))
        self.assertEqual(self.check(), [])
        self.assertIn("後で撮る: 1 本", self.output)

    def test_書き戻しは印を外し_ほかの二重斜線の行は残す(self):
        note = "    // 覚え書き: この口は後で畳む\n"
        self.write(SOURCE.replace("    public func circle() {}", note + self.MARK + "    public func circle() {}"))
        found = self.collect()
        urls = {s.name: f"https://example.invalid/{s.name}.png" for s in found}
        self.assertEqual(shots.write_back(self.root, found, urls), 1)
        text = self.path.read_text(encoding="utf-8")
        self.assertNotIn("後で撮る", text)
        self.assertIn(note.strip(), text)
        self.assertIn("// shot: 1 snippet=", text)
        self.assertEqual(self.check(), [])
        self.assertNotIn("後で撮る", self.output)
        # 2 回目は何も動かない (べき等)
        self.assertEqual(shots.write_back(self.root, self.collect(), urls), 0)

    def test_記録の前に印があっても古い記録を残さない(self):
        found = self.collect()
        urls = {s.name: f"https://example.invalid/{s.name}.png" for s in found}
        shots.write_back(self.root, found, urls)
        text = self.path.read_text(encoding="utf-8")
        self.write(text.replace("    // shot: 1 snippet=", self.MARK + "    // shot: 1 snippet=", 1))
        found = self.collect()
        shots.write_back(self.root, found, urls)
        text = self.path.read_text(encoding="utf-8")
        self.assertEqual(text.count("// shot: 1 snippet="), 1)
        self.assertEqual(text.count("// shot: 2 snippet="), 1)
        self.assertNotIn("後で撮る", text)

class DeferredMemberTest(MemberTestCase):
    """6 — 口の側から見た「後で撮る」の印。"""

    MARK = DeferredShotTest.MARK

    def test_印の付いた口は例と絵を持つ口として数える(self):
        self.assertEqual(self.judge(swift(pictured("circle", extra=self.MARK))), [])
        self.assertIn("例と絵 1", self.output)

    def test_印は撮る囲みの無い口には付けられない(self):
        """許容一覧への追加や撮れない宣言の代わりにはならない — 撮れば絵になる口にしか付かない。"""
        source = swift(bare("ellipsoid", extra=self.MARK))
        problems = self.judge(source, gaps=self.gap("ellipsoid(_:) (some ScalarConvertible)"))
        self.assertEqual(len(problems), 1, problems)
        self.assertIn(f"{MEMBER_FILE}:{line_of(source, '後で撮る')}", problems[0])
        self.assertIn("撮る囲みが無い", problems[0])

    def test_印の付いた口が許容一覧に残っていれば赤い(self):
        source = swift(pictured("circle", extra=self.MARK))
        problems = self.judge(source, gaps=self.gap("circle(_:) (some ScalarConvertible)"))
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("許容一覧から消す", problems[0])


class MemberEntryTest(unittest.TestCase):
    """入口 — 赤なら書き方を添えて落ちる。実物の許容一覧は緑のまま通る。"""

    def run_main(self, member_problems):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(shots, "members_problems", lambda root: member_problems), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = shots.main([], which=lambda name: None)
        return code, err.getvalue()

    def test_口の指摘があれば落ちて書き方を添える(self):
        code, err = self.run_main(["Sources/X.swift:3: foo() に例も撮れない宣言も無く、許容一覧にも無い"])
        self.assertEqual(code, 1)
        self.assertIn("Sources/X.swift:3", err)
        for word in ("// shot: 撮れない <理由>", "// shot: 参照 <口>", "// shot: 後で撮る", "へは足さない"):
            self.assertIn(word, err)

    def test_口の指摘が無ければ通る(self):
        code, err = self.run_main([])
        self.assertEqual(code, 0, err)

    def test_実物の許容一覧は全部の口に当たっている(self):
        """一覧の行がソースに 1 つ残らず当たり、載っていない穴も無い。**一覧が古びれば赤くなる。**"""
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(shots.members_problems(REPO), [])

    def test_許容一覧が無ければ赤い(self):
        with tempfile.TemporaryDirectory() as tmp:
            problems = shots.members_problems(Path(tmp))
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("許容一覧", problems[0])


if __name__ == "__main__":
    unittest.main()
