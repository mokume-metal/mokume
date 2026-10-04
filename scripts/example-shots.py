#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""説明文の中の例を撮って、説明文へ書き戻す (#480)。

**絵は人が貼るものではなく、コードから機械が撮って書き戻すものにする。** 説明文
(`///`) の中に、そのまま `draw()` の本体として動く短いコードを書き、その直後を囲みで
区切る。囲みの中だけが機械の領域で、外は人の文章である
([ADR-0027](../docs/decisions/0027-readable-surfaces.md) 決定 2)。

    /// @Row {
    ///   @Column(size: 3) {
    ///     ```swift
    ///     background(.display(red: 0.09, green: 0.10, blue: 0.12))
    ///     circle(200, 150, 160)
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 濃い灰色の下地の中央に、白い円 -->
    ///     ![濃い灰色の下地の中央に、白い円](https://i.gyazo.com/xxxx.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=3f9a1c8d

**例と絵は左右に並べる。** 縦に積むと絵が本文の幅いっぱいに出て、目が例と結び付け
にくい。列の重みを 3:1 にしてあるのは、**例の行が折り返さずに収まる幅**を先に確保する
ためで、絵はその余りでちょうど手本 (p5.js) の小さなキャンバスくらいになる。

**一文の説明は開く側にだけ書く。** 機械が作る `![…](…)` の行はその写しなので、人が
直すのは 1 か所で済む。空の説明は落とす — 絵を見られない読者に何も渡らないうえ、
「この例が何を示すつもりか」が書かれていない絵は後から検めようがない。

**撮影の記録は `//` の行に置く** (ADR-0027 決定 2)。`///` に混ぜると公開される文章に
指紋が出る。説明文と宣言の間に置いてよいことは確かめてある — `api-surface.py` の
`slash_doc` は上に `///` があれば空を返すので、説明文の検査と衝突しない。

## 指紋が見ていない範囲

指紋の材料は**スニペットと撮影設定だけ**で、実装は入らない。つまり実装だけが変わって
絵が変わっても、指紋は「変わっていない」と答える。**指紋では見ない** —
かつては記録が撮った版 (`taken=`) を持ち、`--check` が「N 本は撮影後に実装が変わって
いる」と要約していたが、判定が `Sources` 全体を見るので**常に全数が該当し、どの絵が
疑わしいかを 1 本も絞れていなかった** (#671)。合否に混ぜるのはもとより避けている —
実装が変わっても絵が変わったとは限らず、混ぜれば実装を触るたびに赤くなって、赤を
無視する習慣が育つ。

**実装だけの変化は、render-pr が前後の描画で名指しする (警告のみ)。** 描画のパスに
触れる PR で、専用機が base と head の木の両方で例の絵を描き (`--drift`)、画素が変わった
絵を、説明文のファイル・`snippet=`・違う画素の数・最大の差つきで言う (#1986)。ただし
merge queue が専用機を待っている間は render-pr ごと見送られ (#2062)、名指しも出ない —
見送られた PR は、queue が空いてから push し直すか run を走らせ直すと名指しが出る。実装だけ
が変わって絵が古くなったことは、#1454 (6 枚) と #1625 で、機械が何も言わないまま人が
気付くまで残っていた。

- **止めない。** 撮り直して書き戻すには Gyazo の鍵が要るが、専用機は secrets を持たない
  (ADR-0019 決定 7)。止めると、Gyazo が止まったときに描画 PR が全部止まる
- **記録の形は変えない。** 撮った時点の画素のハッシュを持たせる案 (#671 の候補 1) は
  採らない — 撮るのはメンテナの手元 (別の OS) で、照合するのは専用機になり、OS の版の
  違いが誤報になる。**比べる 2 枚は同じ機械・同じ OS で、いま描く**
- **比べるのは画素で、PNG のバイトではない。** バイトだけが違う絵 (#1454 の
  `shadows(_:)`) は、画素が同じなら言わない。画素が違うなら、違う数と最大の差を添える。
  閾値は置いていない (同じ木を 2 回描いて差が出ないことは確かめてある・#1986)
- **比べるのは両方の木に在る絵だけ。** 例そのものが書き換わった絵は指紋が変わって片側
  にしか無く、それは上の `check` が「撮り直していない」と言う

手元でも、撮り直しの差分そのものが効く。`--capture` を打つと、絵が実際に変わった囲みの
`![…](…)` だけが書き換わる。

## 冪等性を借りている先 (#671)

**撮り直しても絵が変わっていなければ URL が動かないのは、Gyazo が同じ画素に同じ URL を
返すからである。** こちらは毎回すべてを上げ直しており、同じ URL が返ることに依存して
いる — つまり**この性質は借りものであって、こちらが保証しているのではない。**

破れたら (同じ画素に別の URL が返るようになったら) 撮るたびに全数の URL が動く。その
ときは**撮った絵の内容 (画素のハッシュ) を記録に持ち、変わった絵だけ上げ直す**形へ移る
— #671 の候補 1 がそれで、そこまでは足さない (実害が出てから足す・ADR-0008)。

## 撮れた絵が何かを示しているか (#481)

**絵があることと、その絵が説明になっていることは別である。** 向きを決める引数を間違えても
同じ絵になるなら、その絵は引数の誤りを写せていない。撮った直後に上下・左右を反転した絵と
比べ、見分けが付かないものを言う。

**止めない。** 対称なのが正しい絵 (真円・正方形・放射状のもの) は普通にあるので、止めると
作業が詰まる。分かっているものは撮影設定で軸ごとに黙らせる:

    /// <!-- shot: 濃い灰色の下地の中央に、白い円 | symmetric=xy -->

**この穴は絵を見比べても発見できない。** 人は「それらしい絵」を見ると納得してしまう。
測り方と境目の当て方は `mirror_ratio` と `INDISTINGUISHABLE` が持つ。

## 撮る側

スニペット全部で**実行ファイルを 1 個**作る (`Sketches/main.swift` と同じ形)。1 本ごとに
実行ファイルを作ると SwiftPM のターゲットが数百個になり、「1 回のビルドで全部を作る」
のほうが先に壊れる。生成物は `.build/` に置いてコミットしない (原則 7)。
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import zlib
from collections.abc import Callable

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

# **例の囲みと印の綴りは example_wrapping から取る** (#815)。組めることを見る側
# (check-examples.py) と同じものを読まないと、組める例と撮れる例が食い違う (#667)。
# こちらは説明文の中しか見ないので、`///` を必須にした綴りを使う
from example_wrapping import (  # noqa: E402
    DOC_FENCE_CLOSE as FENCE_CLOSE,
    DOC_FENCE_OPEN as FENCE_OPEN,
    LEVEL_TYPE,
    MARK,
    MARK_CONTEXT,
    dedent,
    level_of,
    strip_doc,
    wrap,
)

# 囲みの開き。`|` の後ろは撮影設定 (frames=90 / size=400x400)
OPEN = re.compile(r"^(?P<indent>\s*)///\s*<!--\s*shot:\s*(?P<alt>[^|]*?)\s*(?:\|\s*(?P<attributes>[^>]*?)\s*)?-->\s*$")
CLOSE = re.compile(r"^\s*///\s*<!--\s*/shot\s*-->\s*$")
DOC = re.compile(r"^\s*///")
# 撮影の記録。書くのも読むのもこの 1 行だけ
RECORD = re.compile(r"^\s*//\s*shot:\s*(?P<index>\d+)\s+snippet=(?P<snippet>[0-9a-f]+)\s*$")
IMAGE = re.compile(r"^\s*///\s*!\[")
# 囲みの上を遡るときに跨ぐ行 — 空の説明文行と、2 段組の足場
SCAFFOLD = re.compile(r"^\s*(///\s*(@Row\b.*|@Column\b.*|\}|)\s*)?$")

DEFAULT_SIZE = (400, 300)

# 反転の軸。名前は撮影設定にそのまま出る (`symmetric=xy`)
MIRROR_FILTERS = {"x": "hflip", "y": "vflip"}
# 同じ軸で 1 画素ずらすときの、重ねる 2 枚の切り出し方 (`crop` の引数)。
# **足した縁を持たない** — 両側から 1 画素ぶん切り落として重ねるので、
# 空いた列を何色で埋めるかを決めずに済む
SHIFT_CROPS = {"x": ("iw-1:ih:0:0", "iw-1:ih:1:0"), "y": ("iw:ih-1:0:0", "iw:ih-1:0:1")}

# **反転しても見分けが付かない**と見なす境目。単位は「その絵を 1 画素ずらしたときの差の
# 何倍か」で、0…255 の生の差ではない (理由は `mirror_ratio`)。
#
# 実測から決めてある。手元の 45 本を軸ごとに測る (90 通り) と、両側は次で分かれた:
#
# - 反転しても同じに見える側 — ほとんどが 1.00 前後に集まり、**最大は 2.00**
#   (`circle(200, 150, 200)` に太い線を付けたもの。反転の差がちょうど 1 画素ずらし
#   2 つぶんになる — 縁の乗り方が左右で 1 画素ずれていて、それ以上の違いは無い)
# - 見分けが付く側 — **最小は 2.33** (太さ 8 の輪を 3 つ横に並べ、両端の色だけを
#   橙と黄で入れ替えたもの。明るさが近いので比が伸びにくい)。次は 5.56 で、以降は離れる
#
# **谷は狭い (2.00 と 2.33)。** 境目はその中に置き、対称な側へ寄せる — 下へ外すと
# 対称な絵が毎回鳴り、上へ外すと**黙らせようのない警告**が出る (本当に見分けが付く絵に
# `symmetric=` を足すのは嘘になる)。両端は `--mirror-report` を付けて撮ると 1 本ずつ見られる (境目を決め直すときの道具で、Makefile からは渡していない)。
INDISTINGUISHABLE = 2.2
GYAZO_UPLOAD = "https://upload.gyazo.com/api/upload"


@dataclasses.dataclass
class Shot:
    path: pathlib.Path
    open_line: int  # 囲みの開き (0 起点)
    close_line: int  # 囲みの閉じ
    alt: str
    width: int
    height: int
    frames: int  # 0 なら静止画
    # 反転しても見分けが付かないことが**分かっている**軸 (#481)。指紋には入らない —
    # 黙らせる指定を足しても絵は 1 画素も変わらないので、撮り直しを起こさない
    symmetric: str
    snippet: list[str]
    # 例が前提にしているものの宣言 (<!-- example: 文脈 … -->)。読者には見せない補いで、
    # 組めることを見る側 (check-examples.py) が前から渡していたもの (#667)
    context: list[str]
    index: int  # 同じ説明文の中で何番目か (記録の鍵)
    record_line: int | None
    record_snippet: str | None

    @property
    def name(self) -> str:
        return f"shot-{self.fingerprint}"

    @property
    def fingerprint(self) -> str:
        """スニペットと撮影設定だけから採る。**実装は入らない** (冒頭の注記)。"""
        parts: dict[str, object] = {
            "snippet": self.snippet,
            "size": [self.width, self.height],
            "frames": self.frames,
        }
        # **文脈は在るときだけ足す。** 空でも鍵を置くと材料の JSON が変わり、文脈を
        # 持たない既存の絵まで全部「撮り直し」になる (#667)
        if self.context:
            parts["context"] = self.context
        material = json.dumps(parts, ensure_ascii=False, sort_keys=True)
        return hashlib.sha256(material.encode("utf-8")).hexdigest()[:8]

    @property
    def is_motion(self) -> bool:
        return self.frames > 0

    @property
    def where(self) -> str:
        return f"{self.path}:{self.open_line + 1}"


def parse_attributes(text: str | None) -> tuple[int, int, int, str]:
    """`frames=90 size=400x400 symmetric=x` → (幅, 高さ, 枚数, 黙らせる軸)。

    知らない鍵は落とす前に名乗る。`symmetric` は**反転しても見分けが付かないことが
    分かっている軸**で、真円・正方形・放射状のものに付く (#481)。
    """
    width, height = DEFAULT_SIZE
    frames = 0
    symmetric = ""
    for token in (text or "").split():
        key, _, value = token.partition("=")
        if key == "frames":
            frames = int(value)
        elif key == "size":
            width, height = (int(part) for part in value.lower().split("x"))
        elif key == "symmetric":
            symmetric = normalize_axes(value)
        else:
            raise ValueError(f"知らない撮影設定: {token}")
    return width, height, frames, symmetric


def normalize_axes(value: str) -> str:
    """`xy` / `yx` / `x` → 並びを固定した軸。知らない軸は名乗って落とす。"""
    axes = sorted(set(value))
    unknown = [axis for axis in axes if axis not in MIRROR_FILTERS]
    if unknown:
        raise ValueError(f"知らない軸: {''.join(unknown)} (使えるのは {''.join(MIRROR_FILTERS)})")
    return "".join(axes)


def snippet_above(lines: list[str], open_line: int) -> list[str]:
    """囲みの直前にある ```swift の中身。無ければ空を返す (呼び出し側が落とす)。

    **2 段組の足場 (`@Row` / `@Column` / 閉じ括弧) は跨ぐ。** 例と絵を左右に並べると、
    例の塊と囲みの間にそれらの行が挟まる。
    """
    index = open_line - 1
    while index >= 0 and SCAFFOLD.match(lines[index]):
        index -= 1
    if index < 0 or not FENCE_CLOSE.match(lines[index]):
        return []
    end = index
    index -= 1
    while index >= 0 and DOC.match(lines[index]):
        if FENCE_OPEN.match(lines[index]):
            return dedent([strip_doc(line) for line in lines[index + 1 : end]])
        index -= 1
    return []


def context_above(lines: list[str], open_line: int) -> list[str]:
    """例の直前に積まれた `文脈` の宣言。

    印は `example_wrapping.MARK` の 1 本で、**あちらが読むものをこちらも読む** —
    片方だけが読むと、組める例と撮れる例がまた食い違う (#667)。かつてここには
    `文脈` だけを拾う 3 つ目の綴りがあった (#815 が畳んだ)。
    """
    index = open_line - 1
    while index >= 0 and SCAFFOLD.match(lines[index]):
        index -= 1
    if index < 0 or not FENCE_CLOSE.match(lines[index]):
        return []
    index -= 1
    while index >= 0 and DOC.match(lines[index]):
        if FENCE_OPEN.match(lines[index]):
            break
        index -= 1
    found: list[str] = []
    index -= 1
    while index >= 0:
        match = MARK.match(lines[index])
        # `組めない` の印はここで止める — 積み上がる宣言ではない
        if not match or match["kind"] != MARK_CONTEXT:
            break
        found.insert(0, match["rest"] or "")
        index -= 1
    return found


def records_after(lines: list[str], close_line: int) -> dict[int, tuple[int, str, str]]:
    """説明文の塊の直後に積まれた記録。鍵は説明文の中での番号。"""
    index = close_line + 1
    while index < len(lines) and DOC.match(lines[index]):
        index += 1
    found: dict[int, tuple[int, str]] = {}
    while index < len(lines):
        match = RECORD.match(lines[index])
        if not match:
            break
        found[int(match["index"])] = (index, match["snippet"])
        index += 1
    return found


def shots_in(root: pathlib.Path, path: pathlib.Path) -> list[Shot]:
    """`path` は根からの相対。読み書きは根と繋いで行う。"""
    lines = (root / path).read_text(encoding="utf-8").split("\n")
    found: list[Shot] = []
    pending: list[Shot] = []
    for number, line in enumerate(lines):
        match = OPEN.match(line)
        if not match:
            continue
        close = number + 1
        while close < len(lines) and not CLOSE.match(lines[close]):
            # **閉じ忘れを次の囲みで吸わせない。** 吸うと 2 つ目の例と説明が丸ごと
            # 機械の領域に入り、書き戻しで消える
            if not DOC.match(lines[close]) or OPEN.match(lines[close]):
                raise SystemExit(f"{path}:{number + 1} の囲みが閉じていない (<!-- /shot -->)")
            close += 1
        if close >= len(lines):
            raise SystemExit(f"{path}:{number + 1} の囲みが閉じていない (<!-- /shot -->)")
        width, height, frames, symmetric = parse_attributes(match["attributes"])
        pending.append(
            Shot(
                path=path,
                open_line=number,
                close_line=close,
                alt=match["alt"].strip(),
                width=width,
                height=height,
                frames=frames,
                symmetric=symmetric,
                snippet=snippet_above(lines, number),
                context=context_above(lines, number),
                index=0,
                record_line=None,
                record_snippet=None,
            )
        )
    # 同じ説明文の塊に属するものへ 1 から番号を振り、記録と突き合わせる
    for shot in pending:
        siblings = [other for other in pending if _same_block(lines, other, shot)]
        shot.index = siblings.index(shot) + 1
        records = records_after(lines, max(other.close_line for other in siblings))
        if record := records.get(shot.index):
            shot.record_line, shot.record_snippet = record
        found.append(shot)
    return found


def _same_block(lines: list[str], a: Shot, b: Shot) -> bool:
    """2 つの囲みが同じ説明文の塊にあるか (間が `///` だけで繋がっているか)。"""
    low, high = sorted((a.open_line, b.open_line))
    return all(DOC.match(lines[index]) for index in range(low, high))


def collect(root: pathlib.Path) -> list[Shot]:
    """`Sources/` の下を全部見る。**除外リストを持たない** — 除いた先に穴が空くため。

    パスは根からの相対で持つ。手元の置き場が出力に混ざると、貼り付けた報告が
    その機械でしか意味を持たなくなる。
    """
    shots: list[Shot] = []
    for path in sorted((root / "Sources").rglob("*.swift")):
        shots += shots_in(root, path.relative_to(root))
    return shots


# ---------------------------------------------------------------- 検査


def check(shots: list[Shot]) -> list[str]:
    problems: list[str] = []
    for shot in shots:
        if not shot.alt:
            problems.append(f"{shot.where}: 絵の一文の説明が空 (`<!-- shot: … -->` に書く)")
        if not shot.snippet:
            problems.append(f"{shot.where}: 囲みの直前に ```swift の塊が無い")
        if shot.record_snippet is None:
            problems.append(f"{shot.where}: まだ撮っていない (make example-shots で撮る)")
            continue
        if shot.record_snippet != shot.fingerprint:
            problems.append(
                f"{shot.where}: 例を書き換えたのに撮り直していない "
                f"(記録 {shot.record_snippet} / いま {shot.fingerprint})"
            )
            continue

    print(f"例の絵: {len(shots)} 本 (動き {sum(1 for s in shots if s.is_motion)} 本)")
    # **見ていないことを名乗る** (#671)。かつてここには「N 本は撮影後に実装が動いている」
    # が出ていたが、常に全数が該当して 1 本も絞れていなかった。数を出せないなら、境目を
    # 1 行で言うほうが正確である。実装だけの変化は render-pr が名指しする (#1986)
    print("  実装が変わって絵が古くなっているかは、ここでは見ていない")
    print("  (描画のパスに触れる PR では render-pr が前後の描画で名指しする・警告のみ。")
    print("   merge queue が専用機を待っている間は render-pr ごと見送られる — #2062)")
    return problems


# ---------------------------------------------------------------- 撮る

PACKAGE = """\
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "example-shots",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "{root}")],
    targets: [
        // 経路で足した依存の呼び名は**その置き場のディレクトリ名**で決まる (worktree なら
        // そちらの名前になる)。決め打ちにすると worktree からは組めない
        .executableTarget(
            name: "example-shots",
            dependencies: [.product(name: "mokume", package: "{identity}")],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)])
    ]
)
"""

MAIN = """\
// 説明文の中の例を描く。生成物 — 直接編集しない (scripts/example-shots.py が書く)。
import Foundation
import mokume

let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "shots")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let gpu = try RenderDevice()

for entry in catalogue {
    let runtime = try SketchRuntime(sketch: entry.make(), gpu: gpu)
    guard entry.frames > 0 else {
        // **最初のフレームを撮る。** 秒で待つと待つ間に進む枚数が実行ごとに変わり、
        // 撮り直すたびに別の絵になる
        try runtime.advance()
        let url = directory.appendingPathComponent("\\(entry.name).png")
        try runtime.target.writePNG(to: url)
        print("\\(entry.name) → \\(url.lastPathComponent)")
        continue
    }
    let folder = directory.appendingPathComponent(entry.name)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 0..<entry.frames {
        try runtime.advance()
        try runtime.target.writePNG(to: folder.appendingPathComponent(String(format: "f.%04d.png", index)))
    }
    print("\\(entry.name) → \\(folder.lastPathComponent) (\\(entry.frames) 枚)")
}
"""


def generate(root: pathlib.Path, shots: list[Shot], package: pathlib.Path) -> None:
    sources = package / "Sources" / "example-shots"
    shutil.rmtree(package, ignore_errors=True)
    sources.mkdir(parents=True)
    (package / "Package.swift").write_text(
        PACKAGE.format(root=root, identity=root.name.lower()), encoding="utf-8"
    )

    body = ["// 生成物 — 直接編集しない (scripts/example-shots.py が書く)。", "import mokume", ""]
    for shot in shots:
        # 包み方は example_wrapping が持つ。**組めることを見る側 (check-examples) と
        # 同じ規則**にしておかないと、撮れる例と組める例が食い違う (原則 9)。
        # 段も文脈もあちらと同じに渡す — 絵を作る口はどれも投げるので、`draw()` の
        # 本体に固定すると絵を持つ例が 1 枚も撮れない (#667)
        level = level_of(shot.snippet)
        if level == LEVEL_TYPE:
            raise SystemExit(
                f"{shot.where} の例は型の宣言から始まっている — 撮る側は例を Sketch として"
                " 走らせるので、型の段は撮れない。setup() / draw() の段まで下ろすこと"
            )
        body.append(f"/// {shot.where}")
        body += wrap(
            _type_name(shot),
            shot.snippet,
            level=level,
            context=shot.context,
            members=[
                f"var settings = SketchSettings(width: {shot.width}, height: {shot.height},"
                f' title: "{shot.name}")'
            ],
        )
        body.append("")
    body.append("let catalogue: [(name: String, frames: Int, make: () -> any Sketch)] = [")
    for shot in shots:
        body.append(f'    ("{shot.name}", {shot.frames}, {{ {_type_name(shot)}() }}),')
    body.append("]")
    (sources / "Shots.swift").write_text("\n".join(body) + "\n", encoding="utf-8")
    (sources / "main.swift").write_text(MAIN, encoding="utf-8")


def _type_name(shot: Shot) -> str:
    return f"Shot_{shot.fingerprint}"


def render(
    root: pathlib.Path, shots: list[Shot], out: pathlib.Path, bundle: bool = True
) -> None:
    """`bundle` は動きの連番を GIF へ束ねるか。束ねるのは上げるためで、比べるだけなら要らない。"""
    package = root / ".build" / "example-shots"
    generate(root, shots, package)
    subprocess.run(["swift", "build", "--package-path", str(package)], check=True)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    subprocess.run(
        ["swift", "run", "--package-path", str(package), "example-shots", str(out)], check=True
    )
    for shot in shots:
        if shot.is_motion and bundle:
            _bundle_gif(out, shot)


def _bundle_gif(out: pathlib.Path, shot: Shot) -> None:
    """連番を GIF へ束ねる。**参照の面は WebP を無言で落とす**ので GIF に限る。"""
    folder = out / shot.name
    palette = folder / "palette.png"
    target = out / f"{shot.name}.gif"
    frames = str(folder / "f.%04d.png")
    common = ["-framerate", "30", "-i", frames]
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", *common, "-vf", "palettegen", str(palette)],
        check=True,
    )
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", *common, "-i", str(palette),
         "-lavfi", "paletteuse", "-loop", "0", str(target)],
        check=True,
    )


# ---------------------------------------------------------------- 何かを示しているか


def average_difference(image: pathlib.Path, lavfi: str) -> float:
    """`lavfi` が作った差の絵の、3 原色を通した平均 (0…255)。

    引き算を ffmpeg にやらせているのは速さのためだけではない — 撮った絵を読むのに
    画像の復号を自前で持たずに済む (ffmpeg は動きを束ねるのに既に要る)。

    **受け取るのは色のままで、畳むのはこちら側でやる。** 明るさへ畳む指定を作る絵の側に
    書くと、その要求が引き算より前へ遡り、**引く前に明るさへ畳まれる** (実測)。そうなると
    明るさが同じで色だけ違う 2 枚が「差 0」になる — 例えば赤い円と青い円を入れ替えた絵は、
    人には一目で違うのに差がほぼ出なくなる。3 原色を等しく数えるので、色だけの違いも残る。
    """
    result = subprocess.run(
        [
            "ffmpeg", "-v", "error", "-i", str(image), "-lavfi", lavfi,
            "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
        ],
        check=True,
        capture_output=True,
    )
    data = result.stdout
    if not data:
        raise SystemExit(f"{image} の差を測れなかった")
    return sum(data) / len(data)


def mirror_ratio(image: pathlib.Path, axis: str) -> float:
    """反転したときの差が、**その絵を 1 画素ずらしたときの差の何倍か**。

    生の差をそのまま見ない理由が 2 つある。

    **反転しても見分けが付かない絵でも、差は 0 にならない。** 塗りの縁は整数の座標で
    画素の境目に乗るが、線の中心は画素の中心に乗る (ADR-0039 決定 2) ので、面の中心で
    反転すると線は 1 画素ずれ、塗りも AA の丸めで縁が揃い切らない。この床は絵ごとに
    違う — 縁が長く濃い絵ほど高い — ので、**床そのものを測って割る**。1 倍前後なら
    「反転は 1 画素ずらしと同じ程度の違いしか作っていない」と読める。

    **生の差は、描いたものが絵に占める広さに引きずられる。** 隅に小さく描いたものは、
    反転で丸ごと動いても平均への効きが小さく、見分けが付かない側へ落ちる。割ると
    その依存が消える (床も同じだけ小さくなるため)。
    """
    difference = average_difference(
        image,
        f"[0:v]split[a][b];[b]{MIRROR_FILTERS[axis]}[c];"
        "[a][c]blend=all_mode=difference",
    )
    kept, shifted = SHIFT_CROPS[axis]
    floor = average_difference(
        image,
        f"[0:v]split[a][b];[a]crop={kept}[a1];[b]crop={shifted}[b1];"
        "[a1][b1]blend=all_mode=difference",
    )
    if floor == 0:
        # その軸に縁が 1 本も無い (行または列が一色)。反転しても必ず同じ絵になる
        return 0.0
    return difference / floor


def measured_image(out: pathlib.Path, shot: Shot) -> pathlib.Path:
    """測る 1 枚。動きは**真ん中の 1 枚**を見る。

    動きの全部を見ないのは、軸の対称は 1 枚ごとの性質だからである。時間の向きが
    出ているかは別の問いで、ここでは扱わない。
    """
    if not shot.is_motion:
        return out / f"{shot.name}.png"
    frames = sorted((out / shot.name).glob("f.*.png"))
    if not frames:
        raise SystemExit(f"{shot.name} の連番が無い")
    return frames[len(frames) // 2]


def mirror_warnings(name: str, where: str, ratios: dict[str, float], silenced: str) -> list[str]:
    """見分けが付かない軸を 1 行ずつ。**黙らせた軸は数えない。**

    純関数にしてあるのは、境目の当て方を絵を撮らずに検められるようにするためである。
    """
    lines = []
    for axis, ratio in sorted(ratios.items()):
        if axis in silenced or ratio > INDISTINGUISHABLE:
            continue
        lines.append(
            f"{where}: {name} は {axis} 軸で反転しても見分けが付かない "
            f"(1 画素ずらしの {ratio:.2f} 倍 ≦ {INDISTINGUISHABLE} 倍)。"
            f"向きを決める引数を間違えても同じ絵になる。"
            f"対称なのが正しいなら撮影設定へ symmetric={axis} を足す"
        )
    return lines


def report_mirrors(out: pathlib.Path, shots: list[Shot], verbose: bool = False) -> None:
    """撮れた絵が**何かを示しているか**を測って言う (#481)。

    **止めない。** 対称なのが正しい絵 (真円・正方形・放射状のもの) は普通にあるので、
    エラーにすると作業が詰まる。分かっているものは軸ごとに黙らせられる。
    """
    warnings: list[str] = []
    for shot in shots:
        image = measured_image(out, shot)
        ratios = {axis: mirror_ratio(image, axis) for axis in MIRROR_FILTERS}
        if verbose:
            measured = " ".join(f"{axis}={value:.2f}" for axis, value in sorted(ratios.items()))
            silenced = f" symmetric={shot.symmetric}" if shot.symmetric else ""
            print(f"  {shot.name} {measured}{silenced} {shot.where}")
        warnings += mirror_warnings(shot.name, shot.where, ratios, shot.symmetric)
    if not warnings:
        print(f"ok: 撮れた絵 {len(shots)} 本は、どれも反転すれば見分けが付く")
        return
    print(f"注意: 反転しても見分けが付かない絵が {len(warnings)} 件", file=sys.stderr)
    for line in warnings:
        print(f"  {line}", file=sys.stderr)


# ---------------------------------------------------------------- 前後の木で描き比べる (#1986)


@dataclasses.dataclass
class Drift:
    """head で絵が変わっていた 1 本。数えるのは画素で、PNG のバイトではない。"""

    shot: Shot  # head の木の囲み。説明文のファイルと行はこちらで言う
    pixels: int  # 違う画素の数 (動きは全部の枚の合計)
    total: int  # 比べた画素の数
    largest: int  # 画素のどれか 1 つの色成分の、最大の差 (0…255)
    frames: int  # 動きで、違う画素を持つ枚の数。静止画は 0


def difference_stats(difference: bytes, channels: int = 4) -> tuple[int, int]:
    """差の絵 (`|a - b|` を 1 画素 `channels` バイトで並べたもの) → (違う画素の数, 最大の差)。

    **純関数にしてあるのは、画素の数え方を絵を描かずに検められるようにするため** である
    (`mirror_warnings` と同じ)。引き算は呼ぶ側 (`image_difference`) が済ませるので、
    ここに渡るのは差の絵になる。

    違う画素は**どの色成分でも**差があるものを数える。成分ごとに数えると、同じ 1 画素が
    3 回数えられて「違う画素の数」と言えなくなる。数え方は C の速さで済ませる — 成分を
    1 本ずつ剥がして OR し、0 でないバイトを数える。
    """
    if len(difference) % channels:
        raise ValueError(f"差の長さ {len(difference)} が {channels} バイトで割り切れない")
    if not any(difference):
        return 0, 0
    merged = int.from_bytes(difference[0::channels], "big")
    for offset in range(1, channels):
        merged |= int.from_bytes(difference[offset::channels], "big")
    pixels = len(difference) // channels
    count = pixels - merged.to_bytes(pixels, "big").count(0)
    return count, max(difference)


def image_difference(base: pathlib.Path, head: pathlib.Path) -> tuple[int, int, int]:
    """2 枚の PNG → (違う画素の数, 比べた画素の数, 最大の差)。

    バイトが同じ PNG は画素も同じなので、復号せずに返す (大半の絵はここで終わる)。
    **ffmpeg を使わない** — 専用機には入っておらず (#1986 の実機で `ffmpeg が見つからない`)、
    比べるためだけに入れさせるより、撮る側が書く PNG を自前で読むほうが小さい。
    """
    if base.read_bytes() == head.read_bytes():
        return 0, _pixel_count(head), 0
    base_size, base_pixels = decode_rgba(base)
    head_size, head_pixels = decode_rgba(head)
    if base_size != head_size:
        raise SystemExit(f"{base.name} の大きさが前後で違う: {base_size} と {head_size}")
    difference = bytes(
        x - y if x >= y else y - x for x, y in zip(base_pixels, head_pixels)
    )
    pixels, largest = difference_stats(difference)
    return pixels, len(difference) // 4, largest


def decode_rgba(image: pathlib.Path) -> tuple[tuple[int, int], bytes]:
    """PNG → ((幅, 高さ), 1 画素 4 バイトの RGBA)。**撮る側が書く形だけ**を読む。

    撮る側 (`writePNG`) が書くのは 8 bit・インターレースなしの PNG で、色の型は RGBA か RGB。
    ほかの形は読めないと名乗って落とす — 黙って読み違えると、絵が変わっていないのに
    名指しするか、変わったのに黙る。色の管理の印 (`iCCP` など) は読まない。比べるのは
    書かれた画素の値で、それは前後で同じ解釈になる。
    """
    data = image.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{image.name} は PNG ではない")
    position, header, compressed = 8, None, []
    while position < len(data):
        length = int.from_bytes(data[position : position + 4], "big")
        kind = data[position + 4 : position + 8]
        body = data[position + 8 : position + 8 + length]
        if kind == b"IHDR":
            header = body
        elif kind == b"IDAT":
            compressed.append(body)
        position += 12 + length
    if header is None:
        raise SystemExit(f"{image.name} に IHDR が無い")
    width, height = int.from_bytes(header[:4], "big"), int.from_bytes(header[4:8], "big")
    depth, colour, _, _, interlace = header[8:13]
    channels = {2: 3, 6: 4}.get(colour)
    if depth != 8 or interlace != 0 or channels is None:
        raise SystemExit(
            f"{image.name} は読めない形 (ビット深度 {depth}・色の型 {colour}・"
            f"インターレース {interlace})。読めるのは 8 bit の RGB / RGBA・インターレースなし"
        )
    raw = zlib.decompress(b"".join(compressed))
    stride = width * channels
    if len(raw) != height * (stride + 1):
        raise SystemExit(f"{image.name} の画素の長さが合わない")
    rows: list[bytes] = []
    previous = bytes(stride)
    for y in range(height):
        start = y * (stride + 1)
        row = _unfilter(raw[start], bytearray(raw[start + 1 : start + 1 + stride]), previous, channels)
        rows.append(row)
        previous = row
    pixels = b"".join(rows)
    if channels == 3:
        # RGB は alpha を 255 で足し、RGBA と同じ並びにして比べる
        rgba = bytearray(width * height * 4)
        rgba[0::4], rgba[1::4], rgba[2::4], rgba[3::4] = (
            pixels[0::3], pixels[1::3], pixels[2::3], b"\xff" * (width * height),
        )
        pixels = bytes(rgba)
    return (width, height), pixels


def _unfilter(kind: int, row: bytearray, previous: bytes, step: int) -> bytes:
    """PNG の 1 行の差分符号 (filter) を戻す。`step` は 1 画素のバイト数。"""
    if kind == 0:
        return bytes(row)
    if kind == 1:  # Sub
        for i in range(step, len(row)):
            row[i] = (row[i] + row[i - step]) & 255
    elif kind == 2:  # Up
        for i in range(len(row)):
            row[i] = (row[i] + previous[i]) & 255
    elif kind == 3:  # Average
        for i in range(len(row)):
            left = row[i - step] if i >= step else 0
            row[i] = (row[i] + ((left + previous[i]) >> 1)) & 255
    elif kind == 4:  # Paeth
        for i in range(len(row)):
            left = row[i - step] if i >= step else 0
            up = previous[i]
            corner = previous[i - step] if i >= step else 0
            estimate = left + up - corner
            da, db, dc = abs(estimate - left), abs(estimate - up), abs(estimate - corner)
            guess = left if da <= db and da <= dc else up if db <= dc else corner
            row[i] = (row[i] + guess) & 255
    else:
        raise SystemExit(f"知らない PNG の filter: {kind}")
    return bytes(row)


def _pixel_count(image: pathlib.Path) -> int:
    """PNG の画素の数。ヘッダー (IHDR) の幅と高さだけを読む。"""
    header = image.read_bytes()[16:24]
    return int.from_bytes(header[:4], "big") * int.from_bytes(header[4:], "big")


def measure_drift(base_out: pathlib.Path, head_out: pathlib.Path, shot: Shot) -> Drift | None:
    """1 本を前後で比べる。変わっていなければ None。動きは連番を 1 枚ずつ比べる。"""
    if not shot.is_motion:
        pairs = [(base_out / f"{shot.name}.png", head_out / f"{shot.name}.png")]
    else:
        names = sorted(path.name for path in (head_out / shot.name).glob("f.*.png"))
        pairs = [(base_out / shot.name / name, head_out / shot.name / name) for name in names]
    pixels = total = largest = frames = 0
    for base, head in pairs:
        changed, compared, biggest = image_difference(base, head)
        pixels += changed
        total += compared
        largest = max(largest, biggest)
        frames += 1 if changed else 0
    if not pixels:
        return None
    return Drift(shot=shot, pixels=pixels, total=total, largest=largest, frames=frames)


def compare_trees(
    base_shots: list[Shot],
    head_shots: list[Shot],
    base_out: pathlib.Path,
    head_out: pathlib.Path,
    measure: Callable[[pathlib.Path, pathlib.Path, Shot], Drift | None] = measure_drift,
) -> tuple[int, list[Drift]]:
    """両方の木に在る絵だけを比べる → (比べた本数, 変わっていた絵)。

    **鍵は指紋 (`shot.name`)。** 例そのものが書き換わった絵は指紋が変わり、片側にしか
    無い — それは `check` が「撮り直していない」と言う領分で、**実装だけの変化**を
    言うここでは数えない。
    """
    in_base = {shot.name for shot in base_shots}
    both = [shot for shot in head_shots if shot.name in in_base]
    drifts = [drift for shot in both if (drift := measure(base_out, head_out, shot))]
    return len(both), drifts


def _escape_data(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def _escape_property(text: str) -> str:
    return _escape_data(text).replace(":", "%3A").replace(",", "%2C")


def drift_message(drift: Drift) -> str:
    """名指しの 1 行。説明文の場所は annotation の file / line が持つので入れない。"""
    shot = drift.shot
    motion = f"動き {drift.frames} 枚で " if shot.is_motion else ""
    return (
        f"{shot.alt} (snippet={shot.fingerprint}) — {motion}違う画素 {drift.pixels} / "
        f"全 {drift.total} 画素・最大の差 {drift.largest} (0…255)"
    )


def drift_annotation(drift: Drift) -> str:
    """GitHub Actions の warning。**警告だけで、job は赤にならない。**"""
    shot = drift.shot
    return (
        f"::warning file={_escape_property(str(shot.path))},line={shot.open_line + 1},"
        f"title={_escape_property('例の絵が変わった')}::{_escape_data(drift_message(drift))}"
    )


def drift_summary(
    compared: int, drifts: list[Drift], timings: dict[str, float], base_rev: str
) -> str:
    """run の要約 (Markdown)。変わった絵が無ければ 1 行だけ。"""
    lines = ["## 例の絵の前後の比較", ""]
    if not drifts:
        lines.append(f"{compared} 本を {base_rev} と比べて、画素が変わった絵は無い。")
    else:
        lines += [
            f"{compared} 本を {base_rev} と比べて、**{len(drifts)} 本の画素が変わっている。** "
            "実装だけが変わって絵が古くなっていないか、撮り直す前に確かめる "
            "(警告のみ・merge は止めない)。",
            "",
            "| 説明文 | snippet= | 違う画素 | 最大の差 | 一文の説明 |",
            "| --- | --- | --- | --- | --- |",
        ]
        for drift in drifts:
            shot = drift.shot
            motion = f" (動き・{drift.frames} 枚)" if shot.is_motion else ""
            alt = shot.alt.replace("|", "\\|")
            lines.append(
                f"| `{shot.where}` | `{shot.fingerprint}` | {drift.pixels} / {drift.total}"
                f"{motion} | {drift.largest} | {alt} |"
            )
    lines += ["", "所要 (秒): " + " / ".join(f"{name} {seconds:.0f}" for name, seconds in timings.items())]
    return "\n".join(lines) + "\n"


def report_drift(
    compared: int, drifts: list[Drift], timings: dict[str, float], base_rev: str
) -> None:
    """annotation は Actions の上でだけ出す (手元に `::warning` の生の行を出さない)。"""
    on_actions = bool(os.environ.get("GITHUB_ACTIONS"))
    summary = drift_summary(compared, drifts, timings, base_rev)
    if on_actions:
        for drift in drifts:
            print(drift_annotation(drift))
    else:
        for drift in drifts:
            print(f"{drift.shot.where}: {drift_message(drift)}")
    if path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(summary)
    else:
        print(summary)
    print(f"例の絵: {compared} 本を比べて、画素が変わったのは {len(drifts)} 本")


def drift(root: pathlib.Path, head_shots: list[Shot], base_rev: str, out: pathlib.Path) -> int:
    """base の木を取り出し、両方で例の絵を描いて比べる。

    **撮る経路 (`render`) をそのまま 2 回使う** — 撮る側と比べる側で描き方が割れると、
    比べた絵が手元で撮る絵と別物になる。base は `git worktree` で `.build/` の下へ
    取り出す (追跡されず、専用機の作業ディレクトリごと次のジョブが消す)。
    """
    base_root = root / ".build" / "example-shots-base"
    _remove_worktree(root, base_root)
    subprocess.run(
        ["git", "-C", str(root), "worktree", "add", "--detach", str(base_root), base_rev],
        check=True,
    )
    timings: dict[str, float] = {}
    try:
        base_shots = collect(base_root)
        if not head_shots or not base_shots:
            print(f"比べる例の絵が片側に無い (base {len(base_shots)} 本・head {len(head_shots)} 本)")
            return 0
        # **同じ機械で順に描く** — 比べる 2 枚は同じ OS・同じ GPU で描いたものでなければ、
        # OS の版の違いが誤報になる (冒頭の「指紋が見ていない範囲」)
        base_out, head_out = out / "base", out / "head"
        started = time.monotonic()
        render(base_root, base_shots, base_out, bundle=False)
        timings["base の build+render"] = time.monotonic() - started
        started = time.monotonic()
        render(root, head_shots, head_out, bundle=False)
        timings["head の build+render"] = time.monotonic() - started
        started = time.monotonic()
        compared, drifts = compare_trees(base_shots, head_shots, base_out, head_out)
        timings["比較"] = time.monotonic() - started
    finally:
        _remove_worktree(root, base_root)
    report_drift(compared, drifts, timings, base_rev)
    return 0


def _remove_worktree(root: pathlib.Path, path: pathlib.Path) -> None:
    subprocess.run(
        ["git", "-C", str(root), "worktree", "remove", "--force", str(path)],
        capture_output=True,
    )
    shutil.rmtree(path, ignore_errors=True)
    subprocess.run(["git", "-C", str(root), "worktree", "prune"], capture_output=True)


# ---------------------------------------------------------------- 上げる・書き戻す


def upload(image: pathlib.Path, token: str, alt: str) -> str:
    """Gyazo へ上げて URL を得る。**同じ中身には同じ URL が返る**ので撮り直しはべき等。"""
    boundary = "----mokume-example-shots"
    parts: list[bytes] = []

    def field(name: str, value: str) -> None:
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
        )

    field("access_token", token)
    field("title", alt)
    field("app", "mokume")
    field("metadata_is_public", "true")
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="imagedata"; '
        f'filename="{image.name}"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode()
    )
    parts.append(image.read_bytes())
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    request = urllib.request.Request(
        GYAZO_UPLOAD,
        data=b"".join(parts),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        answer = json.loads(response.read().decode("utf-8"))
    if not (url := answer.get("url")):
        raise SystemExit(f"Gyazo が URL を返さなかった: {answer}")
    return url


def blocks_of(lines: list[str], shots: list[Shot]) -> list[list[Shot]]:
    """同じ説明文の塊に属する囲みをまとめる。塊の順に並べて返す。"""
    grouped: list[list[Shot]] = []
    for shot in sorted(shots, key=lambda s: s.open_line):
        if grouped and _same_block(lines, grouped[-1][-1], shot):
            grouped[-1].append(shot)
        else:
            grouped.append([shot])
    return grouped


def write_back(root: pathlib.Path, shots: list[Shot], urls: dict[str, str]) -> int:
    """囲みの中と記録を書き戻す。**囲みの外は 1 文字も触らない。**

    位置で対応づけるので、初回・撮り直し・中断後の再実行がすべて同じ操作になる。
    記録は塊ごとにまとめて置き換える — 1 本ずつ差し込むと、同じ塊の他の記録の
    行番号が動いて次の書き込みが的を外す。
    """
    changed = 0
    for path in sorted({shot.path for shot in shots}):
        original = (root / path).read_text(encoding="utf-8")
        lines = original.split("\n")
        # 塊も囲みも**後ろから**書き換える。行が増減しても、まだ触っていない側の
        # 行番号が動かない
        for block in reversed(blocks_of(lines, [s for s in shots if s.path == path])):
            # 記録の行は宣言と同じ深さ、絵の行は囲みと同じ深さに置く。囲みが
            # 2 段組の中にあると両者は違う
            indent = re.match(r"^(\s*)", lines[block[0].open_line]).group(1)
            end = max(shot.close_line for shot in block)
            after = end + 1
            while after < len(lines) and DOC.match(lines[after]):
                after += 1
            records_end = after
            while records_end < len(lines) and RECORD.match(lines[records_end]):
                records_end += 1
            lines[after:records_end] = [
                f"{indent}// shot: {shot.index} snippet={shot.fingerprint}"
                for shot in block
            ]
            for shot in reversed(block):
                prefix = lines[shot.open_line].split("<!--")[0]
                image = f"{prefix}![{shot.alt}]({urls[shot.name]})"
                lines[shot.open_line + 1 : shot.close_line] = [image]
        text = "\n".join(lines)
        if text != original:
            (root / path).write_text(text, encoding="utf-8")
            changed += 1
    return changed


# ---------------------------------------------------------------- 入口

# **撮る側が要る道具と、その入れ方** (#1598)。ffmpeg は動きの束ね (`_bundle_gif`) と
# 反転の測り (`average_difference`) の両方に要るので、無ければ撮り終えても最後まで
# 通らない — それは撮る前に分かる。見るだけの既定の実行は ffmpeg を使わないので探さない
NEEDED_TO_SHOOT = {"ffmpeg": "brew install ffmpeg"}


def missing_tool(which: Callable[[str], str | None]) -> str | None:
    """撮るのに要る道具のうち見つからない最初の 1 つを、入れ方を添えた 1 行で返す。"""
    for tool, install in NEEDED_TO_SHOOT.items():
        if which(tool) is None:
            return f"{tool} が見つからない — 撮るのに要る。入れるには {install}"
    return None


def main(
    argv: list[str] | None = None, which: Callable[[str], str | None] = shutil.which
) -> int:
    """`which` は道具を探す先。検査が「無い手元」を作るために差し替える。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--render", type=pathlib.Path, help="撮って置き場へ書き出す (GPU が要る)")
    parser.add_argument("--capture", action="store_true", help="撮って上げて書き戻す (GPU と鍵が要る)")
    parser.add_argument(
        "--drift",
        metavar="BASE_REV",
        help="BASE_REV の木と今の木の両方で例の絵を描き、画素が変わった絵を名指しする "
        "(GPU が要る・警告のみで鍵も ffmpeg も要らない)",
    )
    parser.add_argument("--token-command", help="Gyazo のトークンを標準出力に出すコマンド")
    parser.add_argument(
        "--mirror-report",
        action="store_true",
        help="反転したときの差を 1 本ずつ出す (境目を決め直すときに見る)",
    )
    arguments = parser.parse_args(argv)

    # **組む前に確かめる。** 撮り終えた後で道具が無いと分かると、組んで撮った時間が
    # 丸ごと無駄になり、止まり方も traceback になる
    if arguments.drift and (arguments.render or arguments.capture):
        print("--drift は --render / --capture と一緒に使えない", file=sys.stderr)
        return 1
    if arguments.render or arguments.capture:
        missing = missing_tool(which)
        if missing:
            print(missing, file=sys.stderr)
            return 1

    root = pathlib.Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
    )
    shots = collect(root)

    if arguments.drift:
        return drift(root, shots, arguments.drift, root / ".build" / "example-shots-drift-out")

    if not arguments.render and not arguments.capture:
        problems = check(shots)
        if problems:
            print("例の絵が揃っていない:", file=sys.stderr)
            for problem in problems:
                print(f"  {problem}", file=sys.stderr)
            print("\n撮り直しは make example-shots。", file=sys.stderr)
            return 1
        print("ok: 例の絵は全部そろっていて、撮った後にスニペットが動いていない")
        return 0

    if not shots:
        print("撮る例が 1 つも無い", file=sys.stderr)
        return 1

    out = arguments.render or (root / ".build" / "example-shots-out")
    render(root, shots, out)
    # **撮った直後に測る。** 上げてしまってからでは、直すのに撮り直しが要る
    report_mirrors(out, shots, verbose=arguments.mirror_report)
    if not arguments.capture:
        print(f"書き出した: {out}")
        return 0

    if not arguments.token_command:
        print("--capture には --token-command が要る (Gyazo のトークンを出すコマンド)", file=sys.stderr)
        return 1
    token = subprocess.run(
        ["bash", "-c", arguments.token_command], capture_output=True, text=True, check=True
    ).stdout.strip()
    if not token:
        print("トークンが空だった", file=sys.stderr)
        return 1

    urls = {}
    for shot in shots:
        image = out / (f"{shot.name}.gif" if shot.is_motion else f"{shot.name}.png")
        urls[shot.name] = upload(image, token, shot.alt)
        print(f"上げた: {shot.name} → {urls[shot.name]}")
    changed = write_back(root, shots, urls)
    print(f"書き戻した: {changed} ファイル")
    return 0


if __name__ == "__main__":
    sys.exit(main())
