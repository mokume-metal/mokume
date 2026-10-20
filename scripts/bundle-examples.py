#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""説明文の中の例から、道具に同梱する作例の束を作る (#2436)。

    python3 scripts/bundle-examples.py [--out DIR] [--list]

`mokume examples` が並べ、`mokume new <名前> --from <例>` が 1 本のスケッチにする
ものの**材料**を、説明文 (`///`) から作る。**説明文が唯一の正典** (ADR-0027 決定 1) で、
ここが作るのはその写しではなく、道具が読める形にした**生成物**である — リポジトリに
コミットしない (AGENTS.md「してはならないこと」)。作る段は `make cli-dist` (版を作る段)
で、手元の `swift build` で試すときは `make cli-examples` が同じ道具を呼ぶ。

## 何を同梱するか

`make examples` (`check-examples.py`) が組める例のうち、**説明文が付いた宣言の例**
(`Sources/` の `///` の中) を、次の規則で選ぶ。

- **宣言に結べる例だけ。** 例の置かれた説明文の直下にある宣言の名前で引くので、宣言に
  結べない例 (カタログ `Documentation/mokume.docc/*.md` の入口の例) は同梱しない
- **`組めない` の印が付いた例は同梱しない。** 一覧に出るのは、組めると機械が見た例だけ
- **資材を読む例は同梱しない。** `assets/`・`data/` の下の名前を指す例 (`loadImage("assets/grain.png")`
  など) は、写せる実体が無いので一覧から外す。自分で書いたファイルを読む例 (`NSTemporaryDirectory()`
  の下に書いてから読む) は、資材を要らないので同梱する
- **型の段の例 (`enum` へ包まれるもの) は同梱しない。** `@main` を持つ 1 本のスケッチに
  包めない — 包み方は `example_wrapping.py` が持ち、ここは同じ規則に従う (撮る側・組める側と
  同じ。原則 9)

## 引き方 (綴り)

**参照の面の見出しと同じ綴り**を引き方にする (決定: #2436 の 2026-10-16 のコメント)。
`Sketch` と `SketchPart` の口は `fill(_:_:_:_:)` のように名前と引数のラベルで、それ以外の
型の口は `Circle.draw()` のように型の名前を前に付ける (`example-shots.py` の口の綴りと同じ)。
型そのものの例は `Circle` のように型の名前で引く。

- 1 つに決まる口は、その綴りが引き方になる
- **同じ綴りに例が複数ある口** (説明文に例が複数ある・overload が同じ綴りを名乗る) は、
  ソースの並びで `#1`・`#2` と番号を添える (`circle(_:_:_:)#2`)。番号は一覧が名乗る
- 引数のラベルを省いた**短い名前** (`triangle`) でも、1 本に決まるなら引ける。それは
  道具 (`Sources/MokumeCLI/Examples.swift`) が決めるので、ここは綴りと番号を作るだけ

## 束の形

`DIR` (既定は `Sources/MokumeCLI/Examples`) に次を書く。**道具の資源として束ねられる**。

- `index.tsv` — 1 行 1 本。`綴り<TAB>ファイル名<TAB>1 行の説明`
- `NNNN.swift.template` — `@main` を持つスケッチ 1 本。`{{TYPE}}` (クラスの名前) と
  `{{NAME}}` (窓の題) は `mokume new` が差し込む

**`.swift` で置かない。** 道具のソースの下には、`.swift` の中の日本語を見る検査 (`tool-language`)
がある。例は作例の中身 (日本語のコメントがありうる) で、道具が話す言葉ではない。

一覧に出る 1 行の説明は、宣言の説明文の**最初の 1 文**である。
"""

from __future__ import annotations

import argparse
import dataclasses
import importlib.util
import pathlib
import re
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from example_wrapping import (  # noqa: E402
    LEVEL_TYPE,
    dedent,
    file_imports,
    level_of,
    wrap,
)


def _load(name: str, path: pathlib.Path):
    """ハイフンの綴りのスクリプトを読む。**あちらが持つ読み方を写さず、そのまま借りる**
    (原則 9)。"""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


check_examples = _load("check_examples_for_bundle", HERE / "check-examples.py")
example_shots = _load("example_shots_for_bundle", HERE / "example-shots.py")

DEFAULT_OUT = pathlib.Path("Sources") / "MokumeCLI" / "Examples"
INDEX_NAME = "index.tsv"
# 置き場に常に在る 1 枚。資源の宣言 (`.copy("Examples")`) は置き場が実在することを要るので、
# 束を作っていない手元でも組めるようにコミットしてある。作り直すときも消さない
KEEP = {"README.md"}

# `Sketch` の語彙は、口の綴りに型の名前を付けない (参照の面の見出しがそうである)
VOCABULARY_OWNERS = {"Sketch", "SketchPart"}

TYPE_HEAD = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|internal|private|fileprivate|open|final|package|nonisolated|indirect)\s+)*"
    r"(?P<kind>struct|class|enum|actor|protocol|extension)\s+(?P<name>[A-Za-z_][\w.]*)"
)
# 宣言の頭。属性・修飾語の後の種類と名前の読み出し
DECLARATION = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|internal|private|fileprivate|static|final|override|open|nonisolated|mutating|"
    r"indirect|lazy|required|convenience|class|prefix|postfix|infix)\s+)*"
    r"(?P<kind>func|init|subscript|var|let|struct|class|enum|actor|protocol|typealias|macro)\b"
)
TYPE_KINDS = {"struct", "class", "enum", "actor", "protocol", "typealias"}
# 例が読む資材。説明文の例は `assets/` か `data/` の下の、**在るつもりのファイル**を名指しする
# (どちらも説明文のための名前で、リポジトリにも束にも実体が無い)。資材ごと写す道は採らず、
# 一覧から外す — 写せるファイルが無いので、開いても資材が見つからず絵が出ない
ASSET_READ = re.compile(r'"(?:assets|data)/[^"]*"')


@dataclasses.dataclass
class Entry:
    """同梱する作例 1 本。"""

    heading: str  # 参照の面の見出しと同じ綴り (番号を添える前)
    path: pathlib.Path  # 根からの相対
    line: int  # 例の ```swift の行 (1 起点)
    summary: str
    source: str  # `{{TYPE}}` と `{{NAME}}` を持つスケッチ
    spelling: str = ""  # 番号を添えた後の、引き方


@dataclasses.dataclass
class Left:
    """同梱しなかった例と、その理由。"""

    where: str
    reason: str


# ---------------------------------------------------------------- 宣言へ結ぶ


def owners_by_line(lines: list[str]) -> list[list[str]]:
    """各行の**頭**で、その行を囲む型の名前の並び。波括弧の深さで追う (コメントと文字列の
    中の括弧は数えない — `example_shots.code_of`)。"""
    owners: list[list[str]] = []
    stack: list[tuple[str, int]] = []
    depth = 0
    pending: str | None = None
    for line in lines:
        owners.append([name for name, _ in stack])
        code = example_shots.code_of(line)
        if (match := TYPE_HEAD.match(code)) and pending is None:
            pending = match["name"]
        if pending is not None and "{" in code:
            stack.append((pending, depth + 1))
            pending = None
        depth += code.count("{") - code.count("}")
        while stack and depth < stack[-1][1]:
            stack.pop()
    return owners


def declaration_after(lines: list[str], fence_line: int) -> int | None:
    """例の囲み (0 起点の行) の直下にある宣言の行。**空行で切れたら結ばない** (離れた説明文は
    その宣言のものではない)。説明文の下の `//` の行と属性は跨ぐ。"""
    index = fence_line
    while index < len(lines) and lines[index].lstrip().startswith("///"):
        index += 1
    while index < len(lines) and (
        lines[index].lstrip().startswith("//") or lines[index].lstrip().startswith("@")
    ):
        index += 1
    if index >= len(lines) or not lines[index].strip():
        return None
    return index


def heading_of(lines: list[str], owners: list[str], line: int) -> str | None:
    """宣言の行から、参照の面の見出しと同じ綴りを読む。読めなければ None。"""
    code = example_shots.code_of(lines[line]).strip()
    match = DECLARATION.match(code)
    if not match:
        return None
    kind = match["kind"]
    prefix = ".".join(name for name in owners if name not in VOCABULARY_OWNERS)
    prefix = prefix + "." if prefix else ""
    if kind in TYPE_KINDS:
        name = re.search(rf"\b{kind}\s+([A-Za-z_]\w*)", code)
        return prefix + name[1] if name else None
    probe = lines
    if kind == "macro":
        # マクロの見出しは関数と同じ綴り (`Param(name:)`)。読み方は関数のものを借りる
        probe = list(lines)
        probe[line] = re.sub(r"\bmacro\b", "func", probe[line], count=1)
        kind = "func"
    declared = example_shots.parse_declaration(probe, line, kind)
    return prefix + declared[0] if declared else None


def summary_of(lines: list[str], fence_line: int) -> str:
    """説明文の**最初の 1 文**。見つからなければ空。

    説明文の先頭の段落 (最初の空の `///` まで) を 1 行に畳み、最初の `。` までを取る。記法の
    飾りは外す — 一覧は端末に出る素の文で、docc の記法は読めない。"""
    start = fence_line
    while start > 0 and lines[start - 1].lstrip().startswith("///"):
        start -= 1
    paragraph: list[str] = []
    for line in lines[start:]:
        text = line.lstrip()
        if not text.startswith("///"):
            break
        text = text[3:].strip()
        if not text:
            if paragraph:
                break
            continue
        if text.startswith(("```", "<!--", "@", "#", "|", "- ", "* ")):
            if paragraph:
                break
            continue
        paragraph.append(text)
    joined = " ".join(paragraph)
    joined = re.sub(r"``([^`]*)``", r"\1", joined)
    joined = re.sub(r"`([^`]*)`", r"\1", joined)
    joined = re.sub(r"\*\*([^*]*)\*\*", r"\1", joined)
    joined = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", joined)
    joined = re.sub(r"\s+", " ", joined).strip()
    cut = joined.find("。")
    return joined[: cut + 1] if cut >= 0 else joined


# ---------------------------------------------------------------- 包む

BANNER = "// Example from the mokume reference: {heading}"


def size_table(root: pathlib.Path) -> dict[tuple, tuple[int, int]]:
    """絵の囲みを持つ例の大きさ。**撮る側が撮るときの大きさ**で、窓を同じ大きさにする。"""
    table: dict[tuple, tuple[int, int]] = {}
    for shot in example_shots.collect(root):
        table.setdefault((str(shot.path), tuple(shot.snippet), tuple(shot.context)), (shot.width, shot.height))
    return table


def package(entry_heading: str, example, size: tuple[int, int]) -> str:
    """例を `@main` を持つスケッチ 1 本に包む。**包み方は `example_wrapping.wrap` のもの**で、
    撮る側と同じに `settings` を足す (例か文脈が宣言していれば足さない)。"""
    body = example.body
    wrapped = wrap(
        "{{TYPE}}",
        body,
        context=example.context,
        members=[f'var settings = SketchSettings(width: {size[0]}, height: {size[1]}, title: "{{{{NAME}}}}")'],
    )
    text = "\n".join(
        [
            BANNER.format(heading=entry_heading),
            *file_imports([body]),
            "",
            "@main",
            *wrapped,
            "",
        ]
    )
    return text


def build(root: pathlib.Path) -> tuple[list[Entry], list[Left]]:
    """同梱する作例と、同梱しなかった例。"""
    examples, problems = check_examples.collect(root)
    if problems:
        raise SystemExit("説明文の例の印に誤りがある (make examples で名指しされる):\n" + "\n".join(problems))
    sizes = size_table(root)
    entries: list[Entry] = []
    left: list[Left] = []
    cache: dict[pathlib.Path, tuple[list[str], list[list[str]]]] = {}
    for example in examples:
        if example.path.parts[0] != "Sources":
            left.append(Left(example.where, "カタログの例 (宣言に結べない)"))
            continue
        if example.skip is not None:
            left.append(Left(example.where, f"組めない印 ({example.skip})"))
            continue
        if ASSET_READ.search("\n".join(example.body + example.context)):
            left.append(Left(example.where, "資材を読む (束に実体が無い)"))
            continue
        if level_of(example.body) == LEVEL_TYPE:
            left.append(Left(example.where, "型の段 (スケッチ 1 本に包めない)"))
            continue
        if example.path not in cache:
            lines = (root / example.path).read_text(encoding="utf-8").split("\n")
            cache[example.path] = (lines, owners_by_line(lines))
        lines, owners = cache[example.path]
        fence = example.line - 1
        declared = declaration_after(lines, fence)
        heading = heading_of(lines, owners[declared], declared) if declared is not None else None
        if heading is None:
            left.append(Left(example.where, "宣言に結べない"))
            continue
        summary = summary_of(lines, fence)
        if not summary:
            left.append(Left(example.where, "説明文の最初の 1 文が読めない"))
            continue
        size = sizes.get(
            (str(example.path), tuple(example.body), tuple(example.context)), example_shots.DEFAULT_SIZE
        )
        source = package(heading, example, size)
        if "{{" in source.replace("{{TYPE}}", "").replace("{{NAME}}", ""):
            left.append(Left(example.where, "例の中に `{{` がある (差し込みの鍵と紛れる)"))
            continue
        entries.append(Entry(heading, example.path, example.line, summary, source))
    number(entries)
    return entries, left


def number(entries: list[Entry]) -> None:
    """綴りを決める。**同じ見出しに 2 本以上あれば、ソースの並びで番号を添える。**"""
    groups: dict[str, list[Entry]] = {}
    for entry in sorted(entries, key=lambda e: (str(e.path), e.line)):
        groups.setdefault(entry.heading, []).append(entry)
    for heading, group in groups.items():
        for index, entry in enumerate(group, start=1):
            entry.spelling = heading if len(group) == 1 else f"{heading}#{index}"


# ---------------------------------------------------------------- 書く


def index_text(entries: list[Entry]) -> str:
    rows = []
    for number_, entry in enumerate(sorted(entries, key=lambda e: e.spelling.lower()), start=1):
        for field in (entry.spelling, entry.summary):
            if "\t" in field or "\n" in field:
                raise SystemExit(f"{entry.path}:{entry.line}: 綴りか説明に tab か改行がある: {field!r}")
        rows.append((entry, f"{number_:04d}.swift.template"))
    return "".join(f"{entry.spelling}\t{name}\t{entry.summary}\n" for entry, name in rows)


def write(entries: list[Entry], out: pathlib.Path) -> None:
    """束を書く。**前の束は消す** (古い版の例が残って、いまの説明文から作ったものと混ざらない)。"""
    out.mkdir(parents=True, exist_ok=True)
    for child in out.iterdir():
        if child.name in KEEP:
            continue
        shutil.rmtree(child) if child.is_dir() else child.unlink()
    ordered = sorted(entries, key=lambda e: e.spelling.lower())
    for number_, entry in enumerate(ordered, start=1):
        (out / f"{number_:04d}.swift.template").write_text(entry.source, encoding="utf-8")
    (out / INDEX_NAME).write_text(index_text(entries), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="説明文の例から、道具に同梱する作例の束を作る")
    parser.add_argument("--out", type=pathlib.Path, default=None, help=f"置き場 (既定 {DEFAULT_OUT})")
    parser.add_argument("--list", action="store_true", help="束は書かず、同梱するものと外すものを出す")
    arguments = parser.parse_args()

    root = pathlib.Path(
        subprocess.run(
            ["git", "-C", str(HERE), "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
    )
    entries, left = build(root)
    if not entries:
        # 空の束を作って緑にしない (読み方が壊れても通ってしまう)
        raise SystemExit("同梱できる例が 1 本も見つからなかった (説明文の読み方が壊れている)")
    if arguments.list:
        for entry in sorted(entries, key=lambda e: e.spelling.lower()):
            print(f"{entry.spelling}\t{entry.summary}")
    else:
        out = arguments.out or root / DEFAULT_OUT
        write(entries, out)
        print(f"作例 {len(entries)} 本を {out} に書いた (同梱しない {len(left)} 本)")
    reasons: dict[str, int] = {}
    for item in left:
        reasons[item.reason.split(" (")[0]] = reasons.get(item.reason.split(" (")[0], 0) + 1
    for reason, count in sorted(reasons.items()):
        print(f"  同梱しない: {reason} — {count} 本", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
