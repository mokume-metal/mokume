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


def parse_attributes(text: str | None) -> tuple[int, int, int]:
    """`frames=90 size=400x400` → (幅, 高さ, 枚数)。知らない鍵は落とす前に名乗る。"""
    width, height = DEFAULT_SIZE
    frames = 0
    for token in (text or "").split():
        key, _, value = token.partition("=")
        if key == "frames":
            frames = int(value)
        elif key == "size":
            width, height = (int(part) for part in value.lower().split("x"))
        else:
            raise ValueError(f"知らない撮影設定: {token}")
    return width, height, frames


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


def dedent(snippet: list[str]) -> list[str]:
    """共通の字下げを落とす。**指紋を入れ子の深さから独立させる** — 2 段組へ入れた
    だけで撮り直しを要求されると、絵は同じなのに URL が動く。"""
    body = [line for line in snippet if line.strip()]
    if not body:
        return snippet
    common = min(len(line) - len(line.lstrip()) for line in body)
    return [line[common:] if line.strip() else "" for line in snippet]


def strip_doc(line: str) -> str:
    """`/// ` を剥がす。中の字下げは残す。"""
    text = line.lstrip()
    text = text[3:] if text.startswith("///") else text
    return text[1:] if text.startswith(" ") else text


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
        width, height, frames = parse_attributes(match["attributes"])
        pending.append(
            Shot(
                path=path,
                open_line=number,
                close_line=close,
                alt=match["alt"].strip(),
                width=width,
                height=height,
                frames=frames,
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
        body.append(f"/// {shot.where}")
        body.append(f"final class {_type_name(shot)}: Sketch {{")
        body.append(
            f"    var settings = SketchSettings(width: {shot.width}, height: {shot.height},"
            f' title: "{shot.name}")'
        )
        body.append("    func draw() {")
        body += [f"        {line}" if line else "" for line in shot.snippet]
        body.append("    }")
        body.append("}")
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
