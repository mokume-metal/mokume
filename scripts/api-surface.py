#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""公開 API の一覧を組み立て、名前と面の規範に沿っているかを検査する。

## 一覧はリポジトリへ置かない

生成物をリポジトリへ置くと、**それが古くないことを守る検査**が要るようになり、以後
すべての変更がその検査に引っかかる。置かずに要るときだけ組み立てれば、そのクラスの
検査ごと不要になる (ADR-0001 原則 8)。だから出力先は必ず引数で受け取り、既定値を
持たない。

## 数えるのは生成側の仕事

**件数を文書へ直書きしない。** 直書きした数は API が増えた瞬間に嘘になり、しかも
嘘になったことが誰にも分からない。数える必要があるものはここから出す。

材料はコンパイラが出すシンボルグラフで、ソースの見た目ではない。公開されているかの
判定を自前の構文解析に持たせると、ソースの書き方が変わるたびに判定が狂う。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

# 利用者が最初に触る層。ここだけ手本 (Processing / p5) の綴りが正になる (ADR-0020 決定 1)
ENTRY_TYPE = "Sketch"
# 転送先の層。ここは常に Swift の慣行が正
LOWER_TYPE = "Canvas"

KIND_ORDER = [
    "swift.protocol",
    "swift.class",
    "swift.struct",
    "swift.enum",
]


def load_requirements(graphs: pathlib.Path, module: str) -> set[str]:
    """プロトコルの要件と、その既定の実装。転送先ではないので、対称性の検査から外す。"""
    requirements: set[str] = set()
    for path in sorted(graphs.glob("*.symbols.json")):
        name = path.name.split(".symbols.json")[0]
        if name != module and not name.startswith(f"{module}@"):
            continue
        document = json.loads(path.read_text(encoding="utf-8"))
        for relationship in document.get("relationships", []):
            if relationship.get("kind") in {"requirementOf", "defaultImplementationOf"}:
                requirements.add(relationship["source"])
    return requirements


def load_symbols(graphs: pathlib.Path, module: str) -> list[dict]:
    """モジュールのシンボルを読む。拡張のぶんは別ファイルに出るのでまとめて拾う。"""
    symbols: list[dict] = []
    for path in sorted(graphs.glob("*.symbols.json")):
        name = path.name.split(".symbols.json")[0]
        if name != module and not name.startswith(f"{module}@"):
            continue
        document = json.loads(path.read_text(encoding="utf-8"))
        for symbol in document.get("symbols", []):
            if symbol.get("accessLevel") == "public":
                symbols.append(symbol)
    # プロトコルの要件と既定の実装は同じ名前で 2 度出る。一覧では 1 つに畳む
    unique: dict[tuple[str, str], dict] = {}
    for symbol in symbols:
        unique.setdefault((owner(symbol), title(symbol)), symbol)
    return list(unique.values())


def declaration(symbol: dict) -> str:
    return "".join(fragment["spelling"] for fragment in symbol.get("declarationFragments", []))


def doc(symbol: dict) -> str:
    lines = symbol.get("docComment", {}).get("lines", [])
    return "\n".join(line.get("text", "") for line in lines).strip()


def owner(symbol: dict) -> str:
    path = symbol.get("pathComponents", [])
    return path[0] if len(path) > 1 else ""


def title(symbol: dict) -> str:
    return symbol.get("names", {}).get("title", "")


# ---------------------------------------------------------------- 一覧


def render(symbols: list[dict], version: str) -> str:
    by_owner: dict[str, list[dict]] = {}
    top: list[dict] = []
    for symbol in symbols:
        if owner(symbol):
            by_owner.setdefault(owner(symbol), []).append(symbol)
        else:
            top.append(symbol)

    out: list[str] = []
    out.append(f"# mokume {version} の公開 API")
    out.append("")
    out.append(
        f"公開シンボル {len(symbols)} 個 / 型 {len(top)} 個。"
        "この一覧は版ごとに組み立てたもので、リポジトリには置かれていない。"
    )
    out.append("")

    def sort_key(symbol: dict) -> tuple:
        kind = symbol["kind"]["identifier"]
        rank = KIND_ORDER.index(kind) if kind in KIND_ORDER else len(KIND_ORDER)
        return (rank, title(symbol))

    for parent in sorted(top, key=sort_key):
        name = title(parent)
        out.append(f"## {name}")
        out.append("")
        summary = doc(parent).split("\n")[0]
        if summary:
            out.append(summary)
            out.append("")
        out.append("```swift")
        out.append(declaration(parent))
        for member in sorted(by_owner.get(name, []), key=title):
            out.append("    " + declaration(member))
        out.append("```")
        out.append("")

    orphans = sorted(set(by_owner) - {title(s) for s in top})
    if orphans:
        out.append("## その他")
        out.append("")
        out.append("```swift")
        for parent in orphans:
            for member in sorted(by_owner[parent], key=title):
                out.append(f"{parent}.{declaration(member)}")
        out.append("```")
        out.append("")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- 検査

ONOFF_PREFIXES = ("enable", "disable", "clear")


def check_onoff(symbols: list[dict]) -> list[str]:
    """ADR-0020 決定 2: オンオフは 1 系統で表す。

    対になる綴りを許すと「どちらの系統かを予測する規則」が無くなる。前身では凍結の
    直前に 4 系統が併存していた。
    """
    problems = []
    for symbol in symbols:
        name = title(symbol).split("(")[0]
        for prefix in ONOFF_PREFIXES:
            if name.startswith(prefix) and len(name) > len(prefix) and name[len(prefix)].isupper():
                problems.append(
                    f"{owner(symbol) or '(トップレベル)'}.{title(symbol)}: "
                    f"`{prefix}*` の綴りはオンオフの系統を増やす (ADR-0020 決定 2)。"
                    "手本があれば手本の綴り、無ければ真偽値を 1 つ取る関数を 1 本置く"
                )
    return problems


def check_forwarding(symbols: list[dict], requirements: set[str]) -> list[str]:
    """ADR-0020 決定 1: 下の層が上の層の転送先なら、同じ名前・同じ引数ラベルを保つ。

    ずれると、上で書けたコードが下で書けない (逆も然り) という食い違いが、
    型の上では見えないまま入る。
    """
    entry = {
        title(s): s
        for s in symbols
        if owner(s) == ENTRY_TYPE and s["identifier"]["precise"] not in requirements
    }
    lower = {title(s): s for s in symbols if owner(s) == LOWER_TYPE}
    lower_bases: dict[str, set[str]] = {}
    for name in lower:
        lower_bases.setdefault(name.split("(")[0], set()).add(name)

    problems = []
    for name in sorted(entry):
        base = name.split("(")[0]
        if base not in lower_bases or name in lower:
            continue
        problems.append(
            f"{ENTRY_TYPE}.{name} と {LOWER_TYPE}.{sorted(lower_bases[base])[0]} で"
            "引数ラベルが食い違う (ADR-0020 決定 1: 転送の対称性)"
        )
    return problems


def check_doc_canon(symbols: list[dict]) -> list[str]:
    """ADR-0020 決定 4 / ADR-0001 原則 9: 説明文の正本は、利用者が最初に触る層に置く。

    同じ説明を 2 か所に置けば必ず食い違い、その食い違いは**生成した一覧を通して
    エージェントの書くコードに届く**。
    """
    entry = {title(s): s for s in symbols if owner(s) == ENTRY_TYPE}
    lower = {title(s): s for s in symbols if owner(s) == LOWER_TYPE}

    problems = []
    for name, symbol in sorted(entry.items()):
        twin = lower.get(name)
        if twin is None:
            continue
        upper_doc, lower_doc = doc(symbol), doc(twin)
        if not lower_doc:
            continue
        if upper_doc and lower_doc == upper_doc:
            problems.append(
                f"{name}: 同じ説明文が {ENTRY_TYPE} と {LOWER_TYPE} の両方にある "
                "(ADR-0020 決定 4: 正本は 1 層)"
            )
        elif upper_doc and len(lower_doc) > len(upper_doc):
            problems.append(
                f"{name}: {LOWER_TYPE} 側の説明文が {ENTRY_TYPE} 側より長い "
                "(ADR-0020 決定 4: 下の層には転送であることだけを書く)"
            )
    return problems


COUNT_PATTERN = re.compile(r"公開\s*(?:されている)?\s*(?:シンボル|API)[^\n。]{0,16}?(\d+)\s*(?:個|本)")


def check_no_written_counts(root: pathlib.Path) -> list[str]:
    """件数を文書へ直書きしない。数える必要があるものは生成側から出す。"""
    problems = []
    for path in sorted(root.rglob("*.md")):
        if any(part in {".build", ".git", "LICENSES"} for part in path.parts):
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if COUNT_PATTERN.search(line):
                problems.append(
                    f"{path.relative_to(root)}:{number}: 公開 API の件数が直書きされている。"
                    "数える必要があるものは scripts/api-surface.py から出す"
                )
    return problems


# ---------------------------------------------------------------- 入口


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["list", "check"])
    parser.add_argument("--graphs", required=True, type=pathlib.Path)
    parser.add_argument("--module", default="MokumeCore")
    parser.add_argument("--version", default="(開発版)")
    parser.add_argument("--output", type=pathlib.Path)
    arguments = parser.parse_args()

    symbols = load_symbols(arguments.graphs, arguments.module)
    if not symbols:
        print(
            f"シンボルグラフが見つからない: {arguments.graphs} に "
            f"{arguments.module}.symbols.json が要る",
            file=sys.stderr,
        )
        return 1

    if arguments.action == "list":
        text = render(symbols, arguments.version)
        if arguments.output:
            arguments.output.write_text(text, encoding="utf-8")
            print(f"ok: {arguments.output} に公開シンボル {len(symbols)} 個を書いた")
        else:
            sys.stdout.write(text)
        return 0

    root = pathlib.Path(__file__).resolve().parent.parent
    problems = (
        check_onoff(symbols)
        + check_forwarding(symbols, load_requirements(arguments.graphs, arguments.module))
        + check_doc_canon(symbols)
        + check_no_written_counts(root)
    )
    if problems:
        print("公開 API が規範に沿っていない:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print(f"ok: 公開シンボル {len(symbols)} 個が規範に沿っている")
    return 0


if __name__ == "__main__":
    sys.exit(main())
