#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""説明文の中の例を、Swift のコンパイル単位へ持っていく (#479)。

`///` を剥がし、字下げを揃え、**その例がどの段に書かれているか**を見分けて包む。

**包み方をここ 1 つに置く** ([ADR-0001](../docs/decisions/0001-founding-principles.md)
原則 9)。撮る側 (`example-shots.py`) と組めることを見る側 (`check-examples.py`) が
別々に包むと、撮れる例と組める例が食い違い、どちらが正しいのか誰にも分からなくなる。
とりわけ **`draw()` の中で書けないもの (投げる呼び出しなど) を、片方だけが通す**のは
無言の破れ方である。

## 段

例は書かれている高さがまちまちで、そのまま並べても組めない。

| 段 | 見分け方 | 包み |
| --- | --- | --- |
| 型 | 最初の中身が型の宣言 | `enum <名前> { … }` |
| メンバ | 段 0 に `func` か計算プロパティがある | `final class <名前>: Sketch { … }` |
| 本体 | それ以外 | `final class <名前>: Sketch { func draw() { … } }` |

型を `enum` で包むのは、複数の例が同じ名前 (`MySketch` など) を名乗っても衝突させない
ため。**`extension` は包めない** (Swift はファイルの直下しか許さない) ので、そういう例が
出てきたら組み立ての側で外す。

**本体は `draw()` に置く。投げられる場所としては扱わない。** 読者がそこへ貼るのは
`draw()` か `setup()` で、どちらも投げないからである — 素の `try` を通すと、貼ると
落ちる例が緑のまま残る。
"""

from __future__ import annotations

import re

LEVEL_TYPE = "型"
LEVEL_MEMBER = "メンバ"
LEVEL_BODY = "本体"

# 型の宣言。`@MainActor public final class` のような前置きを跨いで見る
_TYPE = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+)*"
    r"(?:class|struct|enum|actor|extension|protocol|typealias)\b"
)
# メンバの宣言。計算プロパティ (`var x: T {`) も含む
_MEMBER = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|static\s+|final\s+|override\s+)*"
    r"(?:func|init|deinit|subscript)\b"
)
_COMPUTED = re.compile(r"^(?:public\s+|internal\s+|private\s+|static\s+)*var\s+\w+\s*:\s*[^=]*\{\s*$")


def strip_doc(line: str) -> str:
    """`/// ` を剥がす。中の字下げは残す。

    **`///` が無い行はそのまま返す。** カタログの `.md` の中の例は素の Markdown で
    書かれていて、そこで頭を削ると入れ子が潰れる。
    """
    stripped = line.lstrip()
    if not stripped.startswith("///"):
        return line
    text = stripped[3:]
    return text[1:] if text.startswith(" ") else text


def dedent(snippet: list[str]) -> list[str]:
    """共通の字下げを落とす。**指紋を入れ子の深さから独立させる** — 2 段組へ入れた
    だけで撮り直しを要求されると、絵は同じなのに URL が動く。"""
    body = [line for line in snippet if line.strip()]
    if not body:
        return snippet
    common = min(len(line) - len(line.lstrip()) for line in body)
    return [line[common:] if line.strip() else "" for line in snippet]


def split_imports(snippet: list[str]) -> tuple[list[str], list[str]]:
    """`import` の行を切り離す。

    **型の中へは入れられない**ので、包む前に外へ出して組み立ての先頭へ集める。
    そのまま包むと `declaration is only valid at file scope` になり、**例そのものの
    誤りが、包み方の都合に埋もれて見えなくなる** (カタログの `import mokume` で踏んだ)。
    """
    imports = [line.strip() for line in snippet if line.strip().startswith("import ")]
    rest = [line for line in snippet if not line.strip().startswith("import ")]
    return imports, rest


def level_of(snippet: list[str]) -> str:
    """例がどの段に書かれているか。**注釈と `import` は数えない** — 例の頭に置かれた
    `// waves.metal` のような説明で段が変わってはいけない。"""
    _, snippet = split_imports(snippet)
    meaningful = [line for line in snippet if line.strip() and not line.lstrip().startswith("//")]
    if not meaningful:
        return LEVEL_BODY
    if _TYPE.match(meaningful[0]):
        return LEVEL_TYPE
    for line in snippet:
        if _MEMBER.match(line) or _COMPUTED.match(line):
            return LEVEL_MEMBER
    return LEVEL_BODY


def _shift(lines, depth: int) -> list[str]:
    pad = " " * depth
    return [pad + line if line.strip() else "" for line in lines]


def wrap(
    name: str,
    snippet: list[str],
    *,
    level: str | None = None,
    context: list[str] | None = None,
    members: list[str] | None = None,
) -> list[str]:
    """例を 1 つの型に包む。返るのは行の並び。

    - `context` — 例が前提にしているものの宣言。**読者には見せない**補い
    - `members` — 包む側の都合で足す宣言 (撮る側の `settings` など)

    どちらも段に合わせた高さへ置く。
    """
    level = level or level_of(snippet)
    # `import` は呼び出し側がファイルの先頭へ集める (split_imports の注記)
    _, snippet = split_imports(snippet)
    inner = _shift(list(members or []) + list(context or []), 4)
    if level == LEVEL_TYPE:
        return [f"enum {name} {{", *inner, *_shift(snippet, 4), "}"]
    if level == LEVEL_MEMBER:
        return [f"final class {name}: Sketch {{", *inner, *_shift(snippet, 4), "}"]
    return [
        f"final class {name}: Sketch {{",
        *inner,
        "    func draw() {",
        *_shift(snippet, 8),
        "    }",
        "}",
    ]
