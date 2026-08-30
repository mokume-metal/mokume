#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""説明文の中の例が、実際にコンパイルできることを見る (#479)。

説明文は**参照の面と公開 API の一覧の両方を養う**ので、ここが腐ると下流が全部腐る。
そして腐った例は説明が無いより悪い — 読者はそれを写して、通らない理由を自分の側に
探す。実際に `loadModel` の例は Processing 由来の `millis()` を呼んでいて、**そんな口は
無い**。カタログの最初のページの例も通らなかった ([#556](https://github.com/mokume-metal/mokume/issues/556))。

## 何を見るか

`Sources/**/*.swift` の `///` と、カタログ (`Documentation/mokume.docc/*.md`) の中の
```swift の塊を全部集め、1 つのファイルへ包んで `swiftc -typecheck` に掛ける。
包み方は `example_wrapping.py` が持ち、**撮る側 (`example-shots.py`) と同じ規則**である。

**組み直さない。** `swift build` が作った成果物 (`.build/debug/Modules`) へ直接当てる
ので、パッケージを 2 つ目に作って CI の時間を倍にしなくて済む。だから `make build` の
後に置く必要がある (`make examples` が順序を持つ)。

## 印

既定は「印なし = 組む」。**印は例外の側に付く** — 逆にすると、新しく書かれた例は
既定で誰にも見られないまま入り、それは印を忘れた人には見分けが付かない。

    /// <!-- example: 文脈 var dust: Particles! -->
    /// ```swift
    /// emit(dust, from: .point(width / 2, 40), rate: 600, life: 1...2.5)
    /// ```

    /// <!-- example: 組めない VideoSender は外のパッケージが持つ (このリポジトリには無い) -->

- `文脈` — その例が前提にしているものの宣言。囲みの直前に何行でも積める。**面には
  出ない** (`<!-- -->` は docc の出力に残らない)。読者向けの説明は本文が持つ
- `組めない` — 組み立てない。**理由は必須**。空の印は「見ていないこと」を隠すので赤にする

印は囲みの**直前**に置く。離して置いたものは取り違えようがあるので、行き先の無い印は
赤にする。

## 見ていない範囲

- **例が動くことは見ない。** 型検査までで、走らせて絵にするのは `make example-shots`
  (GPU と鍵が要るので手元だけ)
- **型検査の警告は落とさない** (使われない値など)。例は断片なので、そこを揃えると
  読みにくい書き方を強いることになる
- `README.md` / `Documentation/site/` / `docs/` の例は見ない。説明文ではないので、
  ここへ足すのは実害が出てからにする ([ADR-0008](../docs/decisions/0008-mechanism-needs-demonstrated-harm.md))
- `組めない` と宣言されたもの。**何本をどこで外したかは毎回出力が挙げる**
"""

from __future__ import annotations

import argparse
import bisect
import dataclasses
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from example_wrapping import dedent, split_imports, strip_doc, wrap  # noqa: E402

FENCE_OPEN = re.compile(r"^\s*(?:///\s*)?```swift\s*$")
FENCE_CLOSE = re.compile(r"^\s*(?:///\s*)?```\s*$")
MARK = re.compile(
    r"^\s*(?:///\s*)?<!--\s*example:\s*(?P<kind>文脈|組めない)(?:\s+(?P<rest>.*?))?\s*-->\s*$"
)
# 印を名乗りかけて綴りを外したもの。黙って素通しにすると「書いたのに効かない」になる
MARK_LOOSE = re.compile(r"^\s*(?:///\s*)?<!--\s*example:")

CATALOG = "Documentation/mokume.docc"
GENERATED = pathlib.Path(".build") / "example-check" / "examples.swift"
# Package.swift の SwiftSetting.mokume と揃える。SwiftPM を通さないので写しになるが、
# 食い違えば「本体では通るのに例だけ落ちる」で気付く (逆は起きない)
SWIFT_FLAGS = ["-swift-version", "6", "-default-isolation", "MainActor"]


@dataclasses.dataclass
class Example:
    path: pathlib.Path  # 根からの相対
    line: int  # ```swift の行 (1 起点)
    body: list[str]
    context: list[str]
    skip: str | None  # 組めない理由

    @property
    def where(self) -> str:
        return f"{self.path}:{self.line}"


def sources(root: pathlib.Path) -> list[pathlib.Path]:
    """見るファイル。**追跡されているものだけ**を git に挙げさせる — 生成物や手元の
    書き捨てを拾うと、他人の手元で結果が変わる。"""
    listed = subprocess.run(
        ["git", "-C", str(root), "ls-files", "Sources", CATALOG],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    return [pathlib.Path(name) for name in listed if name.endswith((".swift", ".md"))]


def examples_in(text: str, path: pathlib.Path) -> tuple[list[Example], list[str]]:
    """1 ファイルぶんの例と、行き先の無い印。"""
    lines = text.split("\n")
    found: list[Example] = []
    problems: list[str] = []
    pending: list[tuple[str, str, int]] = []  # (種類, 中身, 行)
    index = 0
    while index < len(lines):
        line = lines[index]
        match = MARK.match(line)
        if match:
            rest = (match["rest"] or "").strip()
            if not rest:
                kind = match["kind"]
                need = "宣言" if kind == "文脈" else "理由"
                problems.append(f"{path}:{index + 1} 印 `{kind}` に{need}が書かれていない")
            pending.append((match["kind"], rest, index + 1))
            index += 1
            continue
        if MARK_LOOSE.match(line):
            problems.append(f"{path}:{index + 1} 印の綴りが違う (使えるのは 文脈 / 組めない)")
            index += 1
            continue
        if FENCE_OPEN.match(line):
            close = index + 1
            body: list[str] = []
            while close < len(lines) and not FENCE_CLOSE.match(lines[close]):
                body.append(strip_doc(lines[close]))
                close += 1
            skip = next((rest for kind, rest, _ in pending if kind == "組めない"), None)
            found.append(
                Example(
                    path=path,
                    line=index + 1,
                    body=dedent(body),
                    context=[rest for kind, rest, _ in pending if kind == "文脈"],
                    skip=skip,
                )
            )
            pending = []
            index = close + 1
            continue
        problems += [f"{path}:{at} 印の行き先が無い (直後は ```swift でなければならない)" for _, _, at in pending]
        pending = []
        index += 1
    problems += [f"{path}:{at} 印の行き先が無い (直後は ```swift でなければならない)" for _, _, at in pending]
    return found, problems


def collect(root: pathlib.Path) -> tuple[list[Example], list[str]]:
    found: list[Example] = []
    problems: list[str] = []
    for path in sources(root):
        text = (root / path).read_text(encoding="utf-8")
        if "```swift" not in text and "example:" not in text:
            continue
        part, trouble = examples_in(text, path)
        found += part
        problems += trouble
    return found, problems


def build_source(examples: list[Example]) -> tuple[str, list[int], list[Example]]:
    """全部を 1 つのファイルへ。返るのは 本文 / 各例の始まる行 / その例。"""
    # 例が自分で書いている import も集める。型の中へは入れられないので、
    # ここでファイルの先頭へ上げる (example_wrapping.split_imports の注記)
    imported = dict.fromkeys(
        ["import mokume"] + [line for example in examples for line in split_imports(example.body)[0]]
    )
    lines = [
        "// 生成物 — 直接編集しない (scripts/check-examples.py が書く)。",
        *imported,
        "",
    ]
    starts: list[int] = []
    ordered: list[Example] = []
    for number, example in enumerate(examples):
        starts.append(len(lines) + 1)
        ordered.append(example)
        lines.append(f"// {example.where}")
        lines += wrap(f"Example{number:03d}", example.body, context=example.context)
        lines.append("")
    return "\n".join(lines) + "\n", starts, ordered


def typecheck(source: pathlib.Path, modules: pathlib.Path) -> list[tuple[int, str]]:
    """`(行, 言い分)` の並び。**error だけを拾う。**"""
    result = subprocess.run(
        ["swiftc", "-typecheck", *SWIFT_FLAGS, "-I", str(modules), str(source)],
        capture_output=True,
        text=True,
    )
    reported = re.compile(rf"^{re.escape(str(source))}:(\d+):\d+: error: (.*)$")
    found = [
        (int(match[1]), match[2])
        for line in result.stderr.splitlines()
        if (match := reported.match(line))
    ]
    if not found and result.returncode != 0:
        # 型検査が例のせいでなく落ちた (成果物が無い・道具が壊れている)。黙って
        # 緑にしないよう、そのまま見せる
        raise SystemExit(f"swiftc が落ちた:\n{result.stderr.strip()}")
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description="説明文の中の例が組めるかを見る")
    parser.add_argument(
        "--modules",
        type=pathlib.Path,
        default=pathlib.Path(".build/debug/Modules"),
        help="swift build が作った成果物の置き場",
    )
    arguments = parser.parse_args()

    root = pathlib.Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
    )
    modules = arguments.modules if arguments.modules.is_absolute() else root / arguments.modules
    if not (modules / "mokume.swiftmodule").exists():
        print(f"ng: {modules} に mokume が無い — 先に swift build (make build) を打つ")
        return 1

    examples, problems = collect(root)
    usable = [example for example in examples if example.skip is None]
    skipped = [example for example in examples if example.skip is not None]

    source, starts, ordered = build_source(usable)
    generated = root / GENERATED
    generated.parent.mkdir(parents=True, exist_ok=True)
    generated.write_text(source, encoding="utf-8")

    failures: dict[str, list[str]] = {}
    for line, complaint in typecheck(generated, modules):
        index = bisect.bisect_right(starts, line) - 1
        where = ordered[index].where if index >= 0 else str(GENERATED)
        failures.setdefault(where, []).append(complaint)

    print(f"例 {len(examples)} 本 — 組んだ {len(usable)} / 組めないと宣言 {len(skipped)}")
    for where, complaints in failures.items():
        print(f"  ng {where}")
        for complaint in dict.fromkeys(complaints):
            print(f"       {complaint}")
    for trouble in problems:
        print(f"  ng {trouble}")

    print("見ていない範囲:")
    print("  - 例が動くこと (型検査まで。走らせて絵にするのは make example-shots)")
    print("  - 型検査の警告 (使われない値など) — 断片なので落とさない")
    print("  - README.md / Documentation/site/ / docs/ の例 (説明文ではない)")
    if skipped:
        print(f"  - 「組めない」と宣言された {len(skipped)} 本:")
        for example in skipped:
            print(f"       {example.where} — {example.skip}")

    if failures or problems:
        print(f"組み立てたものは {GENERATED} にある")
        return 1
    print("ok: 説明文の中の例はすべて組める")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
