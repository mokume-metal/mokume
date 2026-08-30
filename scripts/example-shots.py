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
    // shot: 1 snippet=3f9a1c8d taken=8d814ff

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
絵が変わっても「変わっていない」と答える。埋め合わせに記録は撮った版を持ち、`--check`
は「N 本は撮影後に実装が変わっている」と**要約だけ**伝える。**合否には混ぜない** —
実装が変わっても絵が変わったとは限らず、混ぜれば実装を触るたびに赤くなって、赤を
無視する習慣が育つ。

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
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from example_wrapping import LEVEL_BODY, dedent, strip_doc, wrap  # noqa: E402

# 囲みの開き。`|` の後ろは撮影設定 (frames=90 / size=400x400)
OPEN = re.compile(r"^(?P<indent>\s*)///\s*<!--\s*shot:\s*(?P<alt>[^|]*?)\s*(?:\|\s*(?P<attributes>[^>]*?)\s*)?-->\s*$")
CLOSE = re.compile(r"^\s*///\s*<!--\s*/shot\s*-->\s*$")
FENCE_OPEN = re.compile(r"^\s*///\s*```swift\s*$")
FENCE_CLOSE = re.compile(r"^\s*///\s*```\s*$")
DOC = re.compile(r"^\s*///")
# 撮影の記録。書くのも読むのもこの 1 行だけ
RECORD = re.compile(r"^\s*//\s*shot:\s*(?P<index>\d+)\s+snippet=(?P<snippet>[0-9a-f]+)\s+taken=(?P<taken>\S+)\s*$")
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
# `symmetric=` を足すのは嘘になる)。両端は `--mirror-report` で撮り直すたびに見られる。
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
    index: int  # 同じ説明文の中で何番目か (記録の鍵)
    record_line: int | None
    record_snippet: str | None
    record_taken: str | None

    @property
    def name(self) -> str:
        return f"shot-{self.fingerprint}"

    @property
    def fingerprint(self) -> str:
        """スニペットと撮影設定だけから採る。**実装は入らない** (冒頭の注記)。"""
        material = json.dumps(
            {"snippet": self.snippet, "size": [self.width, self.height], "frames": self.frames},
            ensure_ascii=False,
            sort_keys=True,
        )
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


def records_after(lines: list[str], close_line: int) -> dict[int, tuple[int, str, str]]:
    """説明文の塊の直後に積まれた記録。鍵は説明文の中での番号。"""
    index = close_line + 1
    while index < len(lines) and DOC.match(lines[index]):
        index += 1
    found: dict[int, tuple[int, str, str]] = {}
    while index < len(lines):
        match = RECORD.match(lines[index])
        if not match:
            break
        found[int(match["index"])] = (index, match["snippet"], match["taken"])
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
                index=0,
                record_line=None,
                record_snippet=None,
                record_taken=None,
            )
        )
    # 同じ説明文の塊に属するものへ 1 から番号を振り、記録と突き合わせる
    for shot in pending:
        siblings = [other for other in pending if _same_block(lines, other, shot)]
        shot.index = siblings.index(shot) + 1
        records = records_after(lines, max(other.close_line for other in siblings))
        if record := records.get(shot.index):
            shot.record_line, shot.record_snippet, shot.record_taken = record
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


def touched_since(root: pathlib.Path, commit: str) -> bool | None:
    """その版から今までに実装が動いたか。判定できなければ None (浅い clone など)。"""
    result = subprocess.run(
        ["git", "-C", str(root), "rev-list", "--count", f"{commit}..HEAD", "--", "Sources"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return int(result.stdout.strip() or 0) > 0


def check(root: pathlib.Path, shots: list[Shot]) -> list[str]:
    problems: list[str] = []
    stale_implementation = 0
    unknown_version = 0
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
        touched = touched_since(root, shot.record_taken or "")
        if touched is None:
            unknown_version += 1
        elif touched:
            stale_implementation += 1

    print(f"例の絵: {len(shots)} 本 (動き {sum(1 for s in shots if s.is_motion)} 本)")
    if stale_implementation:
        # **合否に混ぜない。** 実装が変わっても絵が変わったとは限らない (冒頭の注記)
        print(f"  参考: {stale_implementation} 本は撮影後に実装が動いている (指紋はそこを見ていない)")
    if unknown_version:
        print(f"  参考: {unknown_version} 本は撮った版を辿れなかった (浅い clone では判定できない)")
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
        # 段は見分けさせず本体で固定する — 撮る対象は `draw()` の中身だけである
        body.append(f"/// {shot.where}")
        body += wrap(
            _type_name(shot),
            shot.snippet,
            level=LEVEL_BODY,
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


def render(root: pathlib.Path, shots: list[Shot], out: pathlib.Path) -> None:
    package = root / ".build" / "example-shots"
    generate(root, shots, package)
    subprocess.run(["swift", "build", "--package-path", str(package)], check=True)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    subprocess.run(
        ["swift", "run", "--package-path", str(package), "example-shots", str(out)], check=True
    )
    for shot in shots:
        if shot.is_motion:
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

    **反転しても見分けが付かない絵でも、差は 0 にならない。** 面の中心と画素の中心は
    半画素ずれるので、反転は縁に必ず 1 画素ぶんのずれを作る。この床は絵ごとに違う —
    縁が長く濃い絵ほど高い — ので、**床そのものを測って割る**。1 倍前後なら「反転は
    1 画素ずらしと同じ程度の違いしか作っていない」と読める。

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


def write_back(root: pathlib.Path, shots: list[Shot], urls: dict[str, str], taken: str) -> int:
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
                f"{indent}// shot: {shot.index} snippet={shot.fingerprint} taken={taken}"
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


def head_commit(root: pathlib.Path) -> str:
    return subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--short", "HEAD"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()


# ---------------------------------------------------------------- 入口


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--render", type=pathlib.Path, help="撮って置き場へ書き出す (GPU が要る)")
    parser.add_argument("--capture", action="store_true", help="撮って上げて書き戻す (GPU と鍵が要る)")
    parser.add_argument("--token-command", help="Gyazo のトークンを標準出力に出すコマンド")
    parser.add_argument(
        "--mirror-report",
        action="store_true",
        help="反転したときの差を 1 本ずつ出す (境目を決め直すときに見る)",
    )
    arguments = parser.parse_args()

    root = pathlib.Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
    )
    shots = collect(root)

    if not arguments.render and not arguments.capture:
        problems = check(root, shots)
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
    changed = write_back(root, shots, urls, head_commit(root))
    print(f"書き戻した: {changed} ファイル")
    return 0


if __name__ == "__main__":
    sys.exit(main())
